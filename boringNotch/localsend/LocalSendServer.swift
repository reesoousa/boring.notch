//
//  LocalSendServer.swift
//  boringCode
//
//  Servidor HTTPS mínimo (HTTP/1.1, uma requisição por conexão) para receber
//  do LocalSend. TLS com a identidade do boringCode e certificado do cliente
//  obrigatório — o LocalSend 1.18 faz igual e usa o fingerprint do certificado
//  para saber quem está mandando.
//

import Foundation
import Network
import os
import Security

final class LocalSendServer: @unchecked Sendable {  // estado só é tocado em `queue`
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let remoteHost: String
        /// Fingerprint do certificado do cliente (mTLS).
        let peerFingerprint: String?
    }

    struct Response {
        var status: Int
        var body: Data = Data()

        static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONEncoder().encode(value)) ?? Data())
        }

        static func message(_ status: Int, _ text: String) -> Response {
            json(["message": text], status: status)
        }
    }

    /// Destino do corpo de um upload, escrito aos pedaços.
    protocol Sink: AnyObject {
        func write(_ data: Data) throws
        /// Corpo completo. Devolve a resposta.
        func finish() -> Response
        /// Conexão caiu ou o corpo veio inválido.
        func abort()
    }

    enum BodyPlan {
        /// Junta o corpo (até `limit` bytes) e chama `respond`.
        case collect(limit: Int, respond: (Data) -> Response)
        case stream(Sink)
        case reject(Response)
    }

    /// Decide o que fazer com cada requisição (chamado em `queue`, depois dos cabeçalhos).
    var route: ((Request) -> BodyPlan)?
    /// Porta em que ficou escutando (53317, ou outra se estiver ocupada).
    private(set) var port: UInt16?
    var onReady: ((UInt16) -> Void)?

    let queue: DispatchQueue
    private var listener: NWListener?
    private var identity: LocalSendIdentity?
    private var connections: [ObjectIdentifier: LocalSendHTTPConnection] = [:]
    private var stopped = true
    /// Teto de conexões simultâneas (um envio usa poucas; o resto é abuso).
    private static let maxConnections = 32
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "boringcode", category: "LocalSend")

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(identity: LocalSendIdentity) {
        queue.async {
            self.identity = identity
            self.stopped = false
            self.listen(on: LocalSendProtocol.port)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.port = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections = [:]
        }
    }

    private func listen(on requestedPort: UInt16?) {
        guard !stopped, let identity, let secIdentity = sec_identity_create(identity.identity) else { return }

        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        // Certificados do LocalSend são autoassinados: a identidade é o fingerprint,
        // conferido depois contra o que o aparelho diz ser.
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) }, queue)

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let port = requestedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            log.error("LocalSend: listener falhou: \(error.localizedDescription)")
            if requestedPort != nil { listen(on: nil) }
            return
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                let actual = listener.port?.rawValue ?? requestedPort ?? LocalSendProtocol.port
                self.port = actual
                self.log.info("LocalSend: recebendo na porta \(actual)")
                self.onReady?(actual)
            case .failed(let error):
                self.log.error("LocalSend: listener caiu: \(error.localizedDescription)")
                listener.cancel()
                if self.listener === listener {
                    self.listener = nil
                    // Porta ocupada (ex.: app LocalSend aberto) → qualquer porta livre.
                    self.queue.asyncAfter(deadline: .now() + 1) {
                        self.listen(on: requestedPort == nil || self.isAddressInUse(error) ? nil : requestedPort)
                    }
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let handler = LocalSendHTTPConnection(connection: connection, queue: queue) { [weak self] request in
            self?.route?(request) ?? .reject(.message(404, "Not found"))
        }
        let id = ObjectIdentifier(handler)
        handler.onClose = { [weak self] in self?.connections[id] = nil }
        connections[id] = handler
        handler.start()
    }
}

/// Uma conexão: lê cabeçalhos, corpo (Content-Length ou chunked), responde e fecha.
private final class LocalSendHTTPConnection: @unchecked Sendable {
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let route: (LocalSendServer.Request) -> LocalSendServer.BodyPlan

    private enum Framing {
        case length(remaining: Int)
        case chunked(ChunkedDecoder)
    }

    private var headerBuffer = Data()
    private var plan: LocalSendServer.BodyPlan?
    private var framing: Framing?
    private var collected = Data()
    private var responded = false
    private var closed = false
    private var lastActivity = Date()

    private static let maxHeaderBytes = 64 * 1024
    /// Sem receber nada por esse tempo, a conexão cai (celular saiu da rede, cliente parado).
    private static let idleTimeout: TimeInterval = 30

    init(connection: NWConnection, queue: DispatchQueue, route: @escaping (LocalSendServer.Request) -> LocalSendServer.BodyPlan) {
        self.connection = connection
        self.queue = queue
        self.route = route
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
        scheduleIdleCheck()
    }

    /// Conexão parada não fica pendurada para sempre (nem o arquivo parcial aberto).
    private func scheduleIdleCheck() {
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastActivity) > Self.idleTimeout {
                self.cancel()
            } else {
                self.scheduleIdleCheck()
            }
        }
    }

    func cancel() {
        connection.cancel()
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        // Idempotente: depois de um upload completo o sink já está fechado.
        if case .stream(let sink)? = plan { sink.abort() }
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            self.lastActivity = Date()
            if let data, !data.isEmpty { self.consume(data) }
            if self.responded || self.closed { return }
            if isComplete || error != nil {
                self.cancel()
                return
            }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        guard plan != nil else {
            headerBuffer.append(data)
            guard let end = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                if headerBuffer.count > Self.maxHeaderBytes { respond(.message(431, "Headers too large")) }
                return
            }
            let head = headerBuffer[headerBuffer.startIndex..<end.lowerBound]
            let rest = headerBuffer[end.upperBound...]
            headerBuffer = Data()
            guard let request = parseHead(Data(head)) else {
                respond(.message(400, "Bad request"))
                return
            }
            startBody(for: request)
            if !rest.isEmpty, !responded { consumeBody(Data(rest)) }
            return
        }
        consumeBody(data)
    }

    private func parseHead(_ head: Data) -> LocalSendServer.Request? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let components = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }

        var remoteHost = ""
        if case .hostPort(let host, _) = connection.endpoint {
            remoteHost = "\(host)".components(separatedBy: "%").first ?? "\(host)"
        }

        return LocalSendServer.Request(
            method: String(parts[0]).uppercased(),
            path: components?.path ?? String(parts[1]),
            query: query,
            headers: headers,
            remoteHost: remoteHost,
            peerFingerprint: peerFingerprint()
        )
    }

    private func peerFingerprint() -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        var fingerprint: String?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard fingerprint == nil else { return }
            let secCertificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
            fingerprint = LocalSendIdentity.fingerprint(of: secCertificate)
        }
        return fingerprint
    }

    private func startBody(for request: LocalSendServer.Request) {
        let plan = route(request)
        self.plan = plan
        if case .reject(let response) = plan {
            respond(response)
            return
        }
        if request.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            framing = .chunked(ChunkedDecoder())
        } else if let length = Int(request.headers["content-length"] ?? "0"), length >= 0 {
            framing = .length(remaining: length)
        } else {
            respond(.message(400, "Invalid Content-Length"))
            return
        }
        if request.headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        if case .length(0)? = framing { finishBody() }
    }

    private func consumeBody(_ data: Data) {
        guard let framing, !responded else { return }
        switch framing {
        case .length(let remaining):
            let piece = data.prefix(remaining)
            deliver(Data(piece))
            let left = remaining - piece.count
            self.framing = .length(remaining: left)
            if left == 0 { finishBody() }
        case .chunked(let decoder):
            do {
                let (pieces, done) = try decoder.feed(data)
                pieces.forEach(deliver)
                if done { finishBody() }
            } catch {
                respond(.message(400, "Invalid chunked body"))
            }
        }
    }

    private func deliver(_ data: Data) {
        guard !data.isEmpty, !responded else { return }
        switch plan {
        case .collect(let limit, _)?:
            collected.append(data)
            if collected.count > limit { respond(.message(413, "Body too large")) }
        case .stream(let sink)?:
            do {
                try sink.write(data)
            } catch {
                sink.abort()
                respond(.message(500, "Could not write file"))
            }
        default:
            break
        }
    }

    private func finishBody() {
        guard !responded else { return }
        switch plan {
        case .collect(_, let respondWith)?:
            respond(respondWith(collected))
        case .stream(let sink)?:
            respond(sink.finish())
        default:
            break
        }
    }

    private func respond(_ response: LocalSendServer.Response) {
        guard !responded else { return }
        responded = true
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.close()
        })
    }
}

/// Decodificador incremental de `Transfer-Encoding: chunked`.
private final class ChunkedDecoder {
    enum DecodeError: Error { case invalid }

    private enum State {
        case size
        case data(remaining: Int)
        case dataEnd
        case trailer
        case done
    }

    private var state: State = .size
    private var buffer = Data()
    /// Linha de tamanho/trailer maior que isso é lixo.
    private static let maxLine = 1024

    /// Devolve os pedaços decodificados e se o corpo terminou.
    func feed(_ data: Data) throws -> ([Data], Bool) {
        buffer.append(data)
        var output: [Data] = []
        let crlf = Data("\r\n".utf8)

        loop: while true {
            switch state {
            case .size:
                guard let end = buffer.range(of: crlf) else {
                    if buffer.count > Self.maxLine { throw DecodeError.invalid }
                    break loop
                }
                let line = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .ascii) ?? ""
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                let hex = line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else { throw DecodeError.invalid }
                state = size == 0 ? .trailer : .data(remaining: size)
            case .data(let remaining):
                guard !buffer.isEmpty else { break loop }
                let piece = buffer.prefix(remaining)
                output.append(Data(piece))
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + piece.count))
                let left = remaining - piece.count
                state = left == 0 ? .dataEnd : .data(remaining: left)
            case .dataEnd:
                guard buffer.count >= 2 else { break loop }
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 2))
                state = .size
            case .trailer:
                guard let end = buffer.range(of: crlf) else {
                    if buffer.count > Self.maxLine { throw DecodeError.invalid }
                    break loop
                }
                let isEmptyLine = end.lowerBound == buffer.startIndex
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                if isEmptyLine { state = .done }
            case .done:
                return (output, true)
            }
        }
        return (output, false)
    }
}
