//
//  LocalSendArrival.swift
//  boringCode
//
//  Chegada pelo LocalSend no Shelf: o arquivo aparece grande ocupando o Shelf
//  ("de iPhone do Renan", com progresso) e, ao terminar, encolhe e voa até o
//  lugar dele entre os itens. Depois disso o item de verdade assume.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LocalSendArrival {
    /// Espaço de coordenadas do Shelf (slot + painel), onde a chegada acontece.
    static let space = "localsend-arrival"
}

/// Posição de cada item do Shelf, para o arquivo pousar no lugar certo.
struct LocalSendArrivalFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct LocalSendArrivalFrameReader: View {
    let id: UUID

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: LocalSendArrivalFramesKey.self, value: [id: geometry.frame(in: .named(LocalSendArrival.space))])
        }
    }
}

struct LocalSendArrivalOverlay: View {
    /// Molduras dos itens do Shelf (no espaço `LocalSendArrival.space`).
    let frames: [UUID: CGRect]

    @ObservedObject private var service = LocalSendService.shared

    var body: some View {
        GeometryReader { geometry in
            if let transfer = service.incoming, !transfer.landed {
                LocalSendArrivalCard(transfer: transfer, area: geometry.size, frames: frames)
                    .id(transfer.id)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(service.incoming.map { !$0.landed } ?? false)
        .animation(.smooth(duration: 0.3), value: service.incoming?.landed)
        .animation(.smooth(duration: 0.3), value: service.incoming?.id)
    }
}

private struct LocalSendArrivalCard: View {
    let transfer: LocalSendService.Incoming
    let area: CGSize
    let frames: [UUID: CGRect]

    private enum Phase { case presenting, flying }

    @State private var phase: Phase = .presenting
    /// Os textos saem um instante antes do voo (não cruzam os itens do Shelf).
    @State private var textsHidden = false
    @State private var appeared = false
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Cartão: ícone à esquerda, texto à direita, centralizado no Shelf.
    private static let iconSize: CGFloat = 64
    private static let textWidth: CGFloat = 220
    private static let gap: CGFloat = 14
    /// Miniatura do item no Shelf (ShelfItemView: 56 pt, 10 pt do topo).
    private static let shelfThumb: CGFloat = 56
    private static let shelfThumbTop: CGFloat = 10

    private var cardWidth: CGFloat { Self.iconSize + Self.gap + Self.textWidth }

    private var iconHome: CGRect {
        CGRect(x: (area.width - cardWidth) / 2, y: (area.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
    }

    /// Onde o ícone pousa: a miniatura do (primeiro) item que chegou.
    private var iconTarget: CGRect? {
        guard let id = transfer.itemIDs.first, let frame = frames[id] else { return nil }
        return CGRect(x: frame.midX - Self.shelfThumb / 2, y: frame.minY + Self.shelfThumbTop, width: Self.shelfThumb, height: Self.shelfThumb)
    }

    private var iconRect: CGRect {
        phase == .flying ? (iconTarget ?? iconHome) : iconHome
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Fundo do notch cobrindo o Shelf; some enquanto o arquivo voa.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)
                .opacity(phase == .flying ? 0 : 1)

            texts
                .frame(width: Self.textWidth, alignment: .leading)
                .position(x: iconHome.maxX + Self.gap + Self.textWidth / 2, y: area.height / 2)
                .opacity(textsHidden ? 0 : 1)
                .offset(x: textsHidden ? 8 : 0)

            icon
                .frame(width: iconRect.width, height: iconRect.height)
                .position(x: iconRect.midX, y: iconRect.midY)
                .opacity(phase == .flying && iconTarget == nil ? 0 : 1)
        }
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .smooth(duration: 0.3) : LocalSendSlotContent.spring) { appeared = true }
            loadImage()
        }
        .onChange(of: transfer.finished) { _, _ in scheduleLanding() }
        .onChange(of: transfer.itemIDs) { _, _ in
            loadImage()
            scheduleLanding()
        }
        .task { scheduleLanding() }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Partes

    /// Uma imagem só (mesma identidade): trocar o ícone genérico pelo do arquivo não pisca.
    private var icon: some View {
        Group {
            if transfer.isText, image == nil {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.09)))
            } else {
                Image(nsImage: image ?? Self.placeholderIcon(for: transfer))
                    .resizable()
                    .scaledToFit()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let title = transfer.title {
                    Text(verbatim: title)
                } else {
                    Text("\(transfer.itemCount) items")
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.middle)

            HStack(spacing: 5) {
                Image(systemName: transfer.symbolName)
                    .font(.system(size: 10, weight: .medium))
                Text("from \(transfer.senderAlias)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.gray)

            status
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var status: some View {
        if transfer.finished {
            HStack(spacing: 5) {
                Image(systemName: transfer.failed ? "xmark" : "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(transfer.failed ? Color.red : Color.green)
                Text(transfer.failed ? "Couldn't receive" : "Received")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
        } else {
            // Mesma barra do player (trilho cinza, 4 pt, cantos redondos).
            Capsule()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 140, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.effectiveAccent)
                        .frame(width: max(4, 140 * transfer.fraction), height: 4)
                        .animation(.smooth(duration: 0.3), value: transfer.fraction)
                }
                .transition(.opacity)
        }
    }

    // MARK: - Sequência

    /// Terminou: um instante para ler o ✓ e o arquivo voa para o lugar.
    private func scheduleLanding() {
        guard transfer.finished, phase == .presenting else { return }
        let id = transfer.id
        guard !transfer.failed, !transfer.itemIDs.isEmpty else {
            if transfer.failed {
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    LocalSendService.shared.markArrivalLanded(id)
                }
            }
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            guard phase == .presenting else { return }
            withAnimation(.easeOut(duration: 0.18)) { textsHidden = true }
            try? await Task.sleep(for: .seconds(0.14))
            withAnimation(reduceMotion ? .smooth(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.82)) {
                phase = .flying
            }
            try? await Task.sleep(for: .seconds(0.55))
            LocalSendService.shared.markArrivalLanded(id)
        }
    }

    private func loadImage() {
        guard let id = transfer.itemIDs.first,
              let item = ShelfStateViewModel.shared.items.first(where: { $0.id == id })
        else { return }
        image = item.icon
        guard let url = item.fileURL else { return }
        Task {
            if let thumbnail = await ThumbnailService.shared.thumbnail(for: url, size: CGSize(width: 56, height: 56)) {
                image = NSImage(cgImage: thumbnail, size: CGSize(width: 56, height: 56))
            }
        }
    }

    /// Antes de o arquivo existir: ícone do tipo pela extensão (pasta se não tiver).
    private static func placeholderIcon(for transfer: LocalSendService.Incoming) -> NSImage {
        guard transfer.itemCount == 1, let title = transfer.title else {
            return NSWorkspace.shared.icon(for: .data)
        }
        let ext = (title as NSString).pathExtension
        if ext.isEmpty { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
