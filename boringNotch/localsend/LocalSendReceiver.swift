//
//  LocalSendReceiver.swift
//  boringCode
//
//  Lado "receber" do LocalSend: responde register/info e aceita envios sozinho
//  (decisão do dono: sem perguntar), salvando em Downloads. Mesma sequência do
//  protocolo v2: prepare-upload → upload (um por arquivo) → pronto.
//
//  Como aceita de qualquer aparelho da rede: arquivos entram em quarentena
//  (o Gatekeeper confere antes de abrir), o tamanho declarado é respeitado,
//  o espaço em disco é conferido e sessão parada expira sozinha.
//

import CoreServices
import CryptoKit
import Foundation
import os

final class LocalSendReceiver: @unchecked Sendable {  // estado só é tocado em `queue`
    enum Event: Sendable {
        /// `title`: nome do arquivo/pasta quando é um só item; nil para vários.
        case started(id: String, sender: LocalSendDevice, title: String?, itemCount: Int, totalBytes: Int64)
        case progress(id: String, fraction: Double)
        /// Itens de primeiro nível salvos (arquivos ou pastas).
        case finished(id: String, items: [URL])
        case failed(id: String)
        case text(String, sender: LocalSendDevice)
        case register(LocalSendDevice)
    }

    /// Fila do servidor (onde tudo aqui roda).
    let queue: DispatchQueue
    /// Dados deste Mac para register/info (lidos na fila do servidor).
    var ownInfo: (() -> LocalSendInfo)?
    /// Receber está ligado?
    var isAccepting: (() -> Bool)?
    var destination: () -> URL = { LocalSendReceiver.downloadsFolder }
    var onEvent: ((Event) -> Void)?

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    static let partialSuffix = ".boringcode-part"

    private struct IncomingFile {
        let dto: LocalSendFileDTO
        let token: String
        var done = false
        var inProgress = false
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
        /// Pastas de primeiro nível (envio de pasta) → URL única em Downloads.
        var folders: [String: URL] = [:]
        /// O que vai para o Shelf, na ordem em que ficou pronto.
        var items: [URL] = []

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

    /// Sem atividade por esse tempo, a sessão é abandonada (o celular saiu, bloqueou a tela…).
    private static let sessionTimeout: TimeInterval = 30

    init(queue: DispatchQueue) {
        self.queue = queue
    }

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

    /// Apaga `.part` que ficaram de um recebimento interrompido (app fechado no meio).
    func removeLeftoverPartials() {
        queue.async {
            let folder = self.destination()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix(".") && name.hasSuffix(Self.partialSuffix) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
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
              !payload.files.isEmpty,
              payload.files.values.allSatisfy({ $0.size >= 0 })
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
        if let available = availableSpace(), newSession.totalBytes > available {
            return .message(507, "Not enough space")
        }
        session = newSession
        // O que vai aparecer no Shelf: arquivos soltos + pastas de primeiro nível.
        let topLevel = Set(payload.files.values.compactMap { file in
            file.fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).first.map(String.init)
        })
        let title = topLevel.count == 1 ? topLevel.first : nil
        onEvent?(.started(id: newSession.id, sender: sender, title: title, itemCount: max(1, topLevel.count), totalBytes: newSession.totalBytes))
        watch(newSession)

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
        guard !file.inProgress else { return .reject(.message(409, "Upload already in progress")) }

        session.lastActivity = Date()
        guard let target = targetURL(for: file.dto.fileName, in: session) else {
            return .reject(.message(500, "Could not create file"))
        }
        do {
            let sink = try FileSink(
                target: target,
                expectedSize: file.dto.size,
                expectedSHA256: file.dto.sha256,
                modified: file.dto.metadata?.modified,
                onWrite: { [weak self] written in self?.progress(session, added: written) },
                completion: { [weak self] savedURL in self?.fileFinished(fileID, savedURL: savedURL, in: session) }
            )
            session.files[fileID]?.inProgress = true
            return .stream(sink)
        } catch {
            log.error("LocalSend: não deu para criar \(target.path, privacy: .private): \(error.localizedDescription)")
            return .reject(.message(500, "Could not create file"))
        }
    }

    private func cancel(_ request: LocalSendServer.Request) -> LocalSendServer.Response {
        // Só quem está mandando pode cancelar.
        if let session, request.remoteHost == session.senderHost,
           request.query["sessionId"] == nil || request.query["sessionId"] == session.id {
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

    /// `savedURL` nil = falhou (o remetente pode tentar de novo; se parar, a sessão expira).
    private func fileFinished(_ fileID: String, savedURL: URL?, in session: Session) {
        session.files[fileID]?.inProgress = false
        session.lastActivity = Date()
        guard let savedURL else { return }
        session.files[fileID]?.done = true
        if savedURL.deletingLastPathComponent().standardizedFileURL == destination().standardizedFileURL {
            session.items.append(savedURL)  // arquivo solto (os de pasta entram pela pasta)
        }
        guard session.files.values.allSatisfy(\.done) else { return }
        if self.session === session { self.session = nil }
        onEvent?(.finished(id: session.id, items: session.items))
    }

    private func abandon(_ session: Session) {
        if self.session === session { self.session = nil }
        // Arquivos já completos ficam; os .part somem sozinhos (FileSink.abort).
        onEvent?(.failed(id: session.id))
    }

    /// Vigia a sessão: parada por mais que o limite, é abandonada.
    private func watch(_ session: Session) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            let transferring = session.files.values.contains(where: \.inProgress)
            if !transferring, Date().timeIntervalSince(session.lastActivity) > Self.sessionTimeout {
                self.abandon(session)
            } else {
                self.watch(session)
            }
        }
    }

    private func availableSpace() -> Int64? {
        let values = try? destination().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Caminho seguro dentro de Downloads, preservando subpastas de um envio de pasta.
    private func targetURL(for fileName: String, in session: Session) -> URL? {
        let parts = fileName
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.replacingOccurrences(of: ":", with: "-") }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return destination().appendingPathComponent(first) }

        let root: URL
        if let existing = session.folders[first] {
            root = existing
        } else {
            root = Self.uniqueURL(destination().appendingPathComponent(first))
            session.folders[first] = root
            session.items.append(root)
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

/// Escreve o upload num `.part` oculto e só move para o nome final quando terminar certo.
private final class FileSink: LocalSendServer.Sink {
    enum SinkError: Error { case tooLarge }

    private let target: URL
    private let partial: URL
    private let handle: FileHandle
    private let expectedSize: Int64
    private var written: Int64 = 0
    private let expectedSHA256: String?
    private var hasher = SHA256()
    private let modified: String?
    private let onWrite: (Int) -> Void
    private let completion: (URL?) -> Void
    private var closed = false

    init(target: URL, expectedSize: Int64, expectedSHA256: String?, modified: String?,
         onWrite: @escaping (Int) -> Void, completion: @escaping (URL?) -> Void) throws {
        self.target = target
        let token = UUID().uuidString.prefix(8)
        partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(token)\(LocalSendReceiver.partialSuffix)")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        handle = try FileHandle(forWritingTo: partial)
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256?.lowercased()
        self.modified = modified
        self.onWrite = onWrite
        self.completion = completion
    }

    func write(_ data: Data) throws {
        // Não aceita mais que o tamanho declarado no prepare-upload.
        guard written + Int64(data.count) <= expectedSize else { throw SinkError.tooLarge }
        try handle.write(contentsOf: data)
        written += Int64(data.count)
        if expectedSHA256 != nil { hasher.update(data: data) }
        onWrite(data.count)
    }

    func finish() -> LocalSendServer.Response {
        guard !closed else { return .message(500, "Closed") }
        closed = true
        try? handle.close()

        guard written == expectedSize else {
            try? FileManager.default.removeItem(at: partial)
            completion(nil)
            return .message(400, "Size mismatch")
        }
        if let expectedSHA256 {
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expectedSHA256 else {
                try? FileManager.default.removeItem(at: partial)
                completion(nil)
                return .message(422, "Checksum mismatch")
            }
        }
        do {
            var final = LocalSendReceiver.uniqueURL(target)
            try FileManager.default.moveItem(at: partial, to: final)
            Self.quarantine(&final)
            if let modified, let date = Self.parseDate(modified) {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: final.path)
            }
            completion(final)
            return LocalSendServer.Response(status: 200)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            completion(nil)
            return .message(500, "Could not save file")
        }
    }

    func abort() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: partial)
        completion(nil)
    }

    /// Como um download do navegador: o macOS confere (e avisa) antes de abrir algo executável.
    private static func quarantine(_ url: inout URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "boringCode",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try? url.setResourceValues(values)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
