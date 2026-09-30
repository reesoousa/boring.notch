//
//  LocalSendReceiver.swift
//  boringCode
//
//  Lado "receber" do LocalSend: responde register/info e aceita envios sozinho
//  (decisão do dono: sem perguntar), salvando em Downloads. Mesma sequência do
//  protocolo v2: prepare-upload → upload (um por arquivo) → pronto.
//

import CryptoKit
import Foundation
import os

final class LocalSendReceiver: @unchecked Sendable {  // estado só é tocado na fila do servidor
    enum Event: Sendable {
        case started(id: String, sender: LocalSendDevice, fileCount: Int, totalBytes: Int64)
        case progress(id: String, fraction: Double)
        /// Itens de primeiro nível salvos (arquivos ou pastas).
        case finished(id: String, items: [URL])
        case failed(id: String)
        case text(String, sender: LocalSendDevice)
        case register(LocalSendDevice)
    }

    /// Dados deste Mac para register/info (lidos na fila do servidor).
    var ownInfo: (() -> LocalSendInfo)?
    /// Receber está ligado?
    var isAccepting: (() -> Bool)?
    var destination: () -> URL = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
    var onEvent: ((Event) -> Void)?

    private struct IncomingFile {
        let dto: LocalSendFileDTO
        let token: String
        var done = false
    }

    private final class Session {
        let id: String
        let sender: LocalSendDevice
        let senderHost: String
        var files: [String: IncomingFile]
        let totalBytes: Int64
        var receivedBytes: Int64 = 0
        var lastActivity = Date()
        var lastProgressEvent = Date.distantPast
        /// Nome original de primeiro nível → URL única em Downloads.
        var topLevel: [String: URL] = [:]
        var topLevelOrder: [URL] = []

        init(id: String, sender: LocalSendDevice, senderHost: String, files: [String: IncomingFile]) {
            self.id = id
            self.sender = sender
            self.senderHost = senderHost
            self.files = files
            totalBytes = files.values.reduce(0) { $0 + max(0, $1.dto.size) }
        }
    }

    private var session: Session?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "boringcode", category: "LocalSend")

    /// Sem atividade por esse tempo, a sessão é considerada abandonada.
    private static let sessionTimeout: TimeInterval = 60

    func route(_ request: LocalSendServer.Request) -> LocalSendServer.BodyPlan {
        let api = LocalSendProtocol.apiPrefix
        switch (request.method, request.path) {
        case ("POST", "\(api)/register"):
            return .collect(limit: 64 * 1024) { [weak self] body in self?.register(body, request: request) ?? .message(500, "") }
        case ("GET", "/api/localsend/v1/info"), ("GET", "\(api)/info"):
            return .reject(.json(infoResponse()))
        case ("POST", "\(api)/prepare-upload"):
            return .collect(limit: 16 * 1024 * 1024) { [weak self] body in self?.prepareUpload(body, request: request) ?? .message(500, "") }
        case ("POST", "\(api)/upload"):
            return upload(request)
        case ("POST", "\(api)/cancel"):
            return .collect(limit: 1024) { [weak self] _ in self?.cancel(request) ?? .message(500, "") }
        default:
            return .reject(.message(404, "Not found"))
        }
    }

    // MARK: - Rotas

    private func infoResponse() -> LocalSendInfo {
        var info = ownInfo?() ?? LocalSendInfo(alias: "boringCode", version: LocalSendProtocol.version, fingerprint: "")
        info.port = nil
        info.protocol = nil
        info.announce = nil
        info.download = false
        return info
    }

    private func register(_ body: Data, request: LocalSendServer.Request) -> LocalSendServer.Response {
        if let info = try? JSONDecoder().decode(LocalSendInfo.self, from: body),
           isTrusted(info, request: request),
           info.fingerprint.uppercased() != ownInfo?().fingerprint.uppercased() {
            onEvent?(.register(LocalSendDevice(info: info, host: request.remoteHost)))
        }
        return .json(infoResponse())
    }

    /// Com mTLS, só vale o fingerprint que o certificado comprova.
    private func isTrusted(_ info: LocalSendInfo, request: LocalSendServer.Request) -> Bool {
        guard let peer = request.peerFingerprint else { return true }
        return info.fingerprint.uppercased() == peer
    }

    private func prepareUpload(_ body: Data, request: LocalSendServer.Request) -> LocalSendServer.Response {
        guard isAccepting?() ?? false else { return .message(403, "Rejected") }
        guard let payload = try? JSONDecoder().decode(LocalSendPrepareUploadRequest.self, from: body),
              !payload.files.isEmpty
        else { return .message(400, "Invalid body") }

        if let current = session {
            if Date().timeIntervalSince(current.lastActivity) < Self.sessionTimeout {
                return .message(409, "Blocked by another session")
            }
            abandon(current)
        }

        let sender = LocalSendDevice(
            info: payload.info,
            host: request.remoteHost,
            fingerprint: request.peerFingerprint ?? payload.info.fingerprint
        )
        onEvent?(.register(sender))

        // Mensagem de texto: o texto já vem no preview, nada para transferir (204).
        let files = Array(payload.files.values)
        if files.allSatisfy({ $0.fileType.hasPrefix("text/") && $0.preview != nil }) {
            for file in files {
                if let text = file.preview { onEvent?(.text(text, sender: sender)) }
            }
            return LocalSendServer.Response(status: 204)
        }

        let incoming = Dictionary(uniqueKeysWithValues: payload.files.map { key, dto in
            (key, IncomingFile(dto: dto, token: UUID().uuidString))
        })
        let newSession = Session(id: UUID().uuidString, sender: sender, senderHost: request.remoteHost, files: incoming)
        session = newSession
        onEvent?(.started(id: newSession.id, sender: sender, fileCount: incoming.count, totalBytes: newSession.totalBytes))

        return .json(LocalSendPrepareUploadResponse(
            sessionId: newSession.id,
            files: incoming.mapValues(\.token)
        ))
    }

    private func upload(_ request: LocalSendServer.Request) -> LocalSendServer.BodyPlan {
        guard let session, session.id == request.query["sessionId"],
              let fileID = request.query["fileId"],
              let file = session.files[fileID],
              file.token == request.query["token"],
              !file.done
        else { return .reject(.message(403, "Invalid token")) }
        guard request.remoteHost == session.senderHost else { return .reject(.message(403, "Invalid IP")) }

        session.lastActivity = Date()
        guard let target = targetURL(for: file.dto.fileName, in: session) else {
            return .reject(.message(500, "Could not create file"))
        }
        do {
            let sink = try FileSink(target: target, expectedSHA256: file.dto.sha256, modified: file.dto.metadata?.modified) { [weak self] written in
                self?.progress(session, added: written)
            } completion: { [weak self] success in
                self?.fileFinished(fileID, success: success, in: session)
            }
            return .stream(sink)
        } catch {
            log.error("LocalSend: não deu para criar \(target.path): \(error.localizedDescription)")
            return .reject(.message(500, "Could not create file"))
        }
    }

    private func cancel(_ request: LocalSendServer.Request) -> LocalSendServer.Response {
        if let session, session.id == request.query["sessionId"] || request.query["sessionId"] == nil {
            abandon(session)
        }
        return LocalSendServer.Response(status: 200)
    }

    // MARK: - Sessão

    private func progress(_ session: Session, added: Int) {
        session.receivedBytes += Int64(added)
        session.lastActivity = Date()
        guard Date().timeIntervalSince(session.lastProgressEvent) > 0.1, session.totalBytes > 0 else { return }
        session.lastProgressEvent = Date()
        onEvent?(.progress(id: session.id, fraction: min(1, Double(session.receivedBytes) / Double(session.totalBytes))))
    }

    private func fileFinished(_ fileID: String, success: Bool, in session: Session) {
        guard success else { return }  // o remetente pode tentar de novo
        session.files[fileID]?.done = true
        session.lastActivity = Date()
        guard session.files.values.allSatisfy(\.done) else { return }
        if self.session === session { self.session = nil }
        onEvent?(.finished(id: session.id, items: session.topLevelOrder))
    }

    private func abandon(_ session: Session) {
        if self.session === session { self.session = nil }
        // Arquivos já completos ficam; os .part somem sozinhos (FileSink.abort).
        onEvent?(.failed(id: session.id))
    }

    /// Caminho seguro dentro de Downloads, preservando subpastas de um envio de pasta.
    private func targetURL(for fileName: String, in session: Session) -> URL? {
        let parts = fileName
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { $0.replacingOccurrences(of: ":", with: "-") }
        guard let first = parts.first else { return nil }

        let root: URL
        if let existing = session.topLevel[first] {
            root = existing
        } else {
            root = Self.uniqueURL(destination().appendingPathComponent(first))
            session.topLevel[first] = root
            session.topLevelOrder.append(root)
        }
        let target = parts.dropFirst().reduce(root) { $0.appendingPathComponent($1) }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return target
    }

    /// "foto.jpg" → "foto (1).jpg" se já existir.
    static func uniqueURL(_ url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for index in 1...9_999 {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }
}

/// Escreve o upload num `.part` e só move para o nome final quando terminar certo.
private final class FileSink: LocalSendServer.Sink {
    private let target: URL
    private let partial: URL
    private let handle: FileHandle
    private let expectedSHA256: String?
    private var hasher = SHA256()
    private let modified: String?
    private let onWrite: (Int) -> Void
    private let completion: (Bool) -> Void
    private var closed = false

    init(target: URL, expectedSHA256: String?, modified: String?, onWrite: @escaping (Int) -> Void, completion: @escaping (Bool) -> Void) throws {
        self.target = target
        partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).boringcode-part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        handle = try FileHandle(forWritingTo: partial)
        self.expectedSHA256 = expectedSHA256?.lowercased()
        self.modified = modified
        self.onWrite = onWrite
        self.completion = completion
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        if expectedSHA256 != nil { hasher.update(data: data) }
        onWrite(data.count)
    }

    func finish() -> LocalSendServer.Response {
        guard !closed else { return .message(500, "Closed") }
        closed = true
        try? handle.close()

        if let expectedSHA256 {
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expectedSHA256 else {
                try? FileManager.default.removeItem(at: partial)
                completion(false)
                return .message(422, "Checksum mismatch")
            }
        }
        do {
            let final = LocalSendReceiver.uniqueURL(target)
            try FileManager.default.moveItem(at: partial, to: final)
            if let modified, let date = Self.parseDate(modified) {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: final.path)
            }
            completion(true)
            return LocalSendServer.Response(status: 200)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            completion(false)
            return .message(500, "Could not save file")
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    func abort() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: partial)
        completion(false)
    }
}
