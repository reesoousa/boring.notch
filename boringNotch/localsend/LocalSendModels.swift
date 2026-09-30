//
//  LocalSendModels.swift
//  boringCode
//
//  Mensagens do protocolo LocalSend v2 (github.com/localsend/protocol) —
//  o mesmo formato que o app LocalSend usa, para o boringCode conversar
//  direto com celulares e PCs da rede sem abrir o app.
//

import Foundation

enum LocalSendProtocol {
    static let version = "2.2"
    static let port: UInt16 = 53317
    static let multicastGroup = "224.0.0.167"
    static let apiPrefix = "/api/localsend/v2"
}

enum LocalSendDeviceType: String, Codable, Sendable {
    case mobile, desktop, web, headless, server

    /// Tipos desconhecidos viram desktop (seção 7.1 do protocolo).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LocalSendDeviceType(rawValue: raw.lowercased()) ?? .desktop
    }
}

/// Anúncio multicast, corpo do `register` e resposta do `register`/`info`
/// (os campos que não se aplicam ficam nil e não vão no JSON).
struct LocalSendInfo: Codable, Sendable {
    var alias: String
    var version: String
    var deviceModel: String?
    var deviceType: LocalSendDeviceType?
    var fingerprint: String
    var port: UInt16?
    var `protocol`: String?
    var download: Bool?
    /// Campo legado do v2: `true` = anúncio (responda), `false` = resposta.
    var announce: Bool?
}

struct LocalSendFileDTO: Codable, Sendable {
    struct Metadata: Codable, Sendable {
        var modified: String?
        var accessed: String?
    }

    var id: String
    var fileName: String
    var size: Int64
    var fileType: String
    var sha256: String?
    var preview: String?
    var metadata: Metadata?
}

struct LocalSendPrepareUploadRequest: Codable, Sendable {
    var info: LocalSendInfo
    var files: [String: LocalSendFileDTO]
}

struct LocalSendPrepareUploadResponse: Codable, Sendable {
    var sessionId: String
    var files: [String: String]
}

/// Um aparelho encontrado na rede.
struct LocalSendDevice: Identifiable, Hashable, Sendable {
    var id: String { fingerprint }
    let fingerprint: String
    var alias: String
    var deviceModel: String?
    var deviceType: LocalSendDeviceType
    var host: String
    var port: UInt16
    var https: Bool
    var lastSeen: Date

    init(info: LocalSendInfo, host: String, port: UInt16? = nil, https: Bool? = nil, fingerprint: String? = nil) {
        self.fingerprint = (fingerprint ?? info.fingerprint).uppercased()
        alias = info.alias
        deviceModel = info.deviceModel
        deviceType = info.deviceType ?? .desktop
        self.host = host
        self.port = port ?? info.port ?? LocalSendProtocol.port
        self.https = https ?? (info.protocol?.lowercased() != "http")
        lastSeen = Date()
    }

    var baseURL: URL? {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(https ? "https" : "http")://\(hostPart):\(port)\(LocalSendProtocol.apiPrefix)")
    }

    /// SF Symbol do aparelho.
    var symbolName: String {
        let model = (deviceModel ?? "").lowercased()
        switch deviceType {
        case .mobile:
            if model.contains("ipad") { return "ipad" }
            if model.contains("iphone") || model.contains("ios") { return "iphone" }
            return "smartphone"
        case .desktop:
            if model.contains("mac") { return "laptopcomputer" }
            return "desktopcomputer"
        case .web: return "globe"
        case .headless, .server: return "server.rack"
        }
    }
}
