//
//  LocalSendClient.swift
//  boringCode
//
//  Lado "enviar" do LocalSend: register, prepare-upload, upload e cancel.
//  Apresenta o certificado do boringCode (mTLS) e confere o do outro lado
//  pelo fingerprint que ele anunciou.
//

import Foundation
import UniformTypeIdentifiers

enum LocalSendError: LocalizedError {
    case rejected
    case busy
    case pinRequired
    case unreachable
    case timedOut
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .rejected: String(localized: "Declined")
        case .busy: String(localized: "Busy")
        case .pinRequired: String(localized: "Needs a PIN")
        case .unreachable: String(localized: "Couldn't connect")
        case .timedOut: String(localized: "Timed out")
        case .status: String(localized: "Failed")
        }
    }
}

final class LocalSendClient: Sendable {
    private let identity: LocalSendIdentity
    private let session: URLSession

    init(identity: LocalSendIdentity) {
        self.identity = identity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]  // proxy do sistema quebra conexões na rede local
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration)
    }

    /// Apresenta este Mac a um aparelho e devolve os dados dele.
    func register(host: String, port: UInt16, https: Bool, expectedFingerprint: String?, info: LocalSendInfo, timeout: TimeInterval = 3) async throws -> LocalSendInfo {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "\(https ? "https" : "http")://\(hostPart):\(port)\(LocalSendProtocol.apiPrefix)/register") else {
            throw LocalSendError.unreachable
        }
        var body = info
        body.announce = nil
        let data = try await post(url, json: body, expectedFingerprint: https ? expectedFingerprint : nil, timeout: timeout).data
        guard let response = try? JSONDecoder().decode(LocalSendInfo.self, from: data) else { throw LocalSendError.status(200) }
        return response
    }

    /// nil = o outro lado não precisa de transferência (204, ex.: mensagem de texto).
    func prepareUpload(to device: LocalSendDevice, request: LocalSendPrepareUploadRequest) async throws -> LocalSendPrepareUploadResponse? {
        guard let url = device.baseURL?.appendingPathComponent("prepare-upload") else { throw LocalSendError.unreachable }
        // O outro lado pode estar esperando alguém tocar em "Aceitar".
        let (data, status) = try await post(url, json: request, expectedFingerprint: device.https ? device.fingerprint : nil, timeout: 120)
        if status == 204 { return nil }
        guard let response = try? JSONDecoder().decode(LocalSendPrepareUploadResponse.self, from: data) else {
            throw LocalSendError.status(status)
        }
        return response
    }

    func upload(to device: LocalSendDevice, sessionID: String, fileID: String, token: String, file: URL?, data: Data? = nil, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard var components = device.baseURL.flatMap({ URLComponents(url: $0.appendingPathComponent("upload"), resolvingAgainstBaseURL: false) }) else {
            throw LocalSendError.unreachable
        }
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionID),
            URLQueryItem(name: "fileId", value: fileID),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = components.url else { throw LocalSendError.unreachable }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let delegate = TaskDelegate(identity: identity, expectedFingerprint: device.https ? device.fingerprint : nil, progress: progress)
        let response: URLResponse
        do {
            if let file {
                (_, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
            } else {
                (_, response) = try await session.upload(for: request, from: data ?? Data(), delegate: delegate)
            }
        } catch {
            throw Self.map(error)
        }
        try Self.check((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func cancel(device: LocalSendDevice, sessionID: String) async {
        guard var components = device.baseURL.flatMap({ URLComponents(url: $0.appendingPathComponent("cancel"), resolvingAgainstBaseURL: false) }) else { return }
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        guard let url = components.url else { return }
        _ = try? await post(url, body: Data(), expectedFingerprint: device.https ? device.fingerprint : nil, timeout: 3)
    }

    // MARK: - HTTP

    private func post<T: Encodable>(_ url: URL, json: T, expectedFingerprint: String?, timeout: TimeInterval) async throws -> (data: Data, status: Int) {
        try await post(url, body: JSONEncoder().encode(json), expectedFingerprint: expectedFingerprint, timeout: timeout)
    }

    private func post(_ url: URL, body: Data, expectedFingerprint: String?, timeout: TimeInterval) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let delegate = TaskDelegate(identity: identity, expectedFingerprint: expectedFingerprint, progress: nil)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch {
            throw Self.map(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try Self.check(status)
        return (data, status)
    }

    /// Cancelado continua cancelamento; tempo esgotado ≠ aparelho fora do ar.
    private static func map(_ error: Error) -> Error {
        if Task.isCancelled { return CancellationError() }
        // `.cancelled` sem a Task cancelada = TLS recusado (fingerprint diferente): trata como fora do ar.
        return (error as? URLError)?.code == .timedOut ? LocalSendError.timedOut : LocalSendError.unreachable
    }

    private static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw LocalSendError.pinRequired
        case 403: throw LocalSendError.rejected
        case 409: throw LocalSendError.busy
        default: throw LocalSendError.status(status)
        }
    }

    // MARK: - Arquivos → DTO

    struct OutgoingFile {
        let dto: LocalSendFileDTO
        let url: URL?
        let data: Data?
    }

    /// Arquivos e pastas (recursivo, com caminho relativo, como o LocalSend faz).
    static func outgoingFiles(for urls: [URL]) -> [OutgoingFile] {
        var files: [OutgoingFile] = []
        let manager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let base = url.deletingLastPathComponent().path
                let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let child = enumerator?.nextObject() as? URL {
                    guard (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let relative = String(child.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if let file = fileDTO(child, name: relative) { files.append(file) }
                }
            } else if let file = fileDTO(url, name: url.lastPathComponent) {
                files.append(file)
            }
        }
        return files
    }

    static func outgoingText(_ text: String) -> OutgoingFile {
        let data = Data(text.utf8)
        let dto = LocalSendFileDTO(
            id: UUID().uuidString,
            fileName: "\(UUID().uuidString).txt",
            size: Int64(data.count),
            fileType: "text/plain",
            preview: text
        )
        return OutgoingFile(dto: dto, url: nil, data: data)
    }

    private static func fileDTO(_ url: URL, name: String) -> OutgoingFile? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentAccessDateKey])
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let formatter = ISO8601DateFormatter()
        let metadata = LocalSendFileDTO.Metadata(
            modified: values?.contentModificationDate.map(formatter.string(from:)),
            accessed: values?.contentAccessDate.map(formatter.string(from:))
        )
        let dto = LocalSendFileDTO(
            id: UUID().uuidString,
            fileName: name,
            size: Int64(values?.fileSize ?? 0),
            fileType: mime,
            metadata: metadata
        )
        return OutgoingFile(dto: dto, url: url, data: nil)
    }
}

/// Autenticação TLS por requisição: certificado do cliente + fingerprint esperado do servidor.
private final class TaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let identity: LocalSendIdentity
    private let expectedFingerprint: String?
    private let progress: (@Sendable (Int64) -> Void)?

    init(identity: LocalSendIdentity, expectedFingerprint: String?, progress: (@Sendable (Int64) -> Void)?) {
        self.identity = identity
        self.expectedFingerprint = expectedFingerprint?.uppercased()
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            else { return (.cancelAuthenticationChallenge, nil) }
            if let expectedFingerprint, LocalSendIdentity.fingerprint(of: leaf) != expectedFingerprint {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            return (.useCredential, URLCredential(identity: identity.identity, certificates: [identity.certificate], persistence: .forSession))
        default:
            return (.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent)
    }
}
