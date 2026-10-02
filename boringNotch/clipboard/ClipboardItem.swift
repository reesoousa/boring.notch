//
//  ClipboardItem.swift
//  boringCode
//
//  Um item do histórico do clipboard: texto, link, imagem ou arquivos. Guarda o
//  bastante para colar de novo igual ao original (texto com formatação, imagem no
//  formato em que veio, os mesmos arquivos) e para achar depois (busca por texto,
//  endereço, nome de arquivo ou app de onde veio).
//

import AppKit
import CryptoKit
import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text, link, image, file
    }

    let id: UUID
    let kind: Kind
    /// Quando foi copiado (ou copiado de novo — o item sobe para o começo).
    var date: Date
    /// Texto ou endereço do link.
    var text: String?
    /// Formatação do texto (RTF), quando o app de origem mandou e é pequena.
    var rtf: Data?
    /// Arquivo da imagem dentro da pasta do histórico, com o tipo em que veio.
    var imageFile: String?
    var imageType: String?
    var imagePixelSize: CGSize?
    var filePaths: [String]?
    var sourceBundleID: String?
    var sourceName: String?
    /// Resumo do conteúdo: o mesmo conteúdo copiado de novo não vira item repetido.
    let fingerprint: String

    var fileURLs: [URL] { (filePaths ?? []).map { URL(fileURLWithPath: $0) } }

    var linkURL: URL? {
        guard kind == .link, let text else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// O que a busca procura.
    var searchableText: String {
        var parts: [String] = []
        if let text { parts.append(text) }
        parts.append(contentsOf: fileURLs.map(\.lastPathComponent))
        if let sourceName { parts.append(sourceName) }
        return parts.joined(separator: "\n")
    }

    static func fingerprint(kind: Kind, _ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return kind.rawValue + ":" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Filtros do topo da aba.
enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all, text, links, images, files

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text
        case .links: item.kind == .link
        case .images: item.kind == .image
        case .files: item.kind == .file
        }
    }
}
