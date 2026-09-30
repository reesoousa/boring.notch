//
//  LocalSendIdentity.swift
//  boringCode
//
//  Identidade TLS do boringCode na rede LocalSend: chave RSA-2048 e certificado
//  autoassinado (CN=LocalSend User), como o app LocalSend gera. O fingerprint
//  (SHA-256 do certificado em DER, hex maiúsculo) é o "nome" do aparelho no
//  protocolo. Chave e certificado ficam em ~/Library/Application Support/boringCode
//  (a chave só com permissão do usuário), fora do chaveiro: assim o macOS nunca
//  pede a senha do chaveiro, nem quando a assinatura do app muda entre versões.
//

import CryptoKit
import Foundation
import Security

struct LocalSendIdentity: @unchecked Sendable {  // SecIdentity/SecCertificate são imutáveis
    let identity: SecIdentity
    let certificate: SecCertificate
    let fingerprint: String

    /// Nome dos arquivos (os testes usam outro para não mexer nos do app).
    nonisolated(unsafe) static var label = "boringCode LocalSend"

    enum IdentityError: Error {
        case keyGeneration(String)
        case signing(String)
        case invalidCertificate
        case invalidKey
        case identityUnavailable
    }

    /// Reusa a identidade guardada ou cria uma nova.
    static func loadOrCreate() throws -> LocalSendIdentity {
        if let existing = try? load() { return existing }
        return try create()
    }

    static func fingerprint(of certificate: SecCertificate) -> String {
        fingerprint(ofDER: SecCertificateCopyData(certificate) as Data)
    }

    static func fingerprint(ofDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Arquivos

    private static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("boringCode", isDirectory: true)
    }

    private static var baseName: String { label.replacingOccurrences(of: " ", with: "-").lowercased() }
    private static var certificateURL: URL { folder.appendingPathComponent("\(baseName).der") }
    private static var keyURL: URL { folder.appendingPathComponent("\(baseName).key") }

    private static func load() throws -> LocalSendIdentity {
        guard let der = try? Data(contentsOf: certificateURL),
              let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { throw IdentityError.invalidCertificate }
        guard let keyData = try? Data(contentsOf: keyURL),
              let privateKey = SecKeyCreateWithData(keyData as CFData, [
                  kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                  kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
              ] as CFDictionary, nil)
        else { throw IdentityError.invalidKey }
        return try identity(certificate: certificate, privateKey: privateKey)
    }

    private static func create() throws -> LocalSendIdentity {
        var error: Unmanaged<CFError>?
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data?
        else {
            throw IdentityError.keyGeneration(error?.takeRetainedValue().localizedDescription ?? "?")
        }

        let tbs = CertificateBuilder.tbsCertificate(rsaPublicKey: [UInt8](publicKeyData))
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, &error) as Data? else {
            throw IdentityError.signing(error?.takeRetainedValue().localizedDescription ?? "?")
        }
        let der = CertificateBuilder.certificate(tbs: tbs, signature: [UInt8](signature))
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw IdentityError.invalidCertificate
        }

        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        manager.createFile(atPath: keyURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try privateKeyData.write(to: keyURL)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try Data(der).write(to: certificateURL, options: .atomic)
        return try identity(certificate: certificate, privateKey: privateKey)
    }

    /// `SecIdentityCreate` junta certificado + chave em memória (sem chaveiro).
    /// É da Security.framework desde o macOS 10.x, mas não está nos headers públicos.
    private static func identity(certificate: SecCertificate, privateKey: SecKey) throws -> LocalSendIdentity {
        typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(handle, "SecIdentityCreate"),
              let identity = unsafeBitCast(symbol, to: Create.self)(nil, certificate, privateKey)?.takeRetainedValue()
        else { throw IdentityError.identityUnavailable }
        return LocalSendIdentity(identity: identity, certificate: certificate, fingerprint: fingerprint(of: certificate))
    }
}

/// X.509 v3 mínimo em DER: sha256WithRSAEncryption, emissor = assunto = CN=LocalSend User.
private enum CertificateBuilder {
    private static let sha256WithRSA: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    private static let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let commonName: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
    private static let null: [UInt8] = [0x05, 0x00]

    static func tbsCertificate(rsaPublicKey: [UInt8]) -> [UInt8] {
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F  // positivo
        serial[0] |= 0x01  // sem zero à esquerda

        let algorithm = sequence(sha256WithRSA + null)
        let name = sequence(tlv(0x31, sequence(commonName + tlv(0x0C, Array("LocalSend User".utf8)))))
        let now = Date()
        let validity = sequence(time(now.addingTimeInterval(-86_400)) + time(Date(timeIntervalSince1970: 4_102_444_800)))  // até 2100
        let publicKeyInfo = sequence(sequence(rsaEncryption + null) + tlv(0x03, [0x00] + rsaPublicKey))

        return sequence(
            tlv(0xA0, tlv(0x02, [0x02]))  // versão v3
                + tlv(0x02, serial)
                + algorithm
                + name
                + validity
                + name
                + publicKeyInfo
        )
    }

    static func certificate(tbs: [UInt8], signature: [UInt8]) -> [UInt8] {
        sequence(tbs + sequence(sha256WithRSA + null) + tlv(0x03, [0x00] + signature))
    }

    private static func sequence(_ content: [UInt8]) -> [UInt8] { tlv(0x30, content) }

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    private static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// UTCTime até 2049, GeneralizedTime depois (RFC 5280, 4.1.2.5).
    private static func time(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Array(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Array(formatter.string(from: date).utf8))
    }
}
