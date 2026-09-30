//
//  LocalSendSlot.swift
//  boringCode
//
//  Slot do LocalSend no Shelf. Parado, é igual aos outros serviços (ícone +
//  nome). Com um arquivo por cima, vira a lista de aparelhos da rede: solte
//  num aparelho para enviar, ou no slot para escolher depois.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalSendSlot: View {
    let dropInteraction: DropInteractionState
    let icon: NSImage?
    /// Clique no slot parado: escolher arquivos.
    let onPick: () -> Void
    /// Menu de contexto: mandar pelo app LocalSend (se instalado).
    let onOpenApp: (() -> Void)?

    @ObservedObject private var service = LocalSendService.shared
    @State private var isTargeted = false
    @State private var dragHoverID: String?
    @State private var mouseHoverID: String?
    @State private var rowFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let dropTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .data, .image]
    private static let space = "localsend-slot"
    private static let moreRowID = "localsend-more"
    /// Linhas que cabem no quadrado durante o arraste (sem rolagem enquanto arrasta).
    private static let visibleRows = 3

    private var isExpanded: Bool {
        isTargeted || service.pending != nil || service.outgoing != nil || service.isPreparingPending
    }

    private var highlightedID: String? { dragHoverID ?? mouseHoverID }

    var body: some View {
        ZStack {
            background

            if isExpanded {
                expanded
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            } else {
                idle
                    .padding(18)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onDrop(of: Self.dropTypes, delegate: SlotDropDelegate(
            isTargeted: $isTargeted,
            hoveredID: $dragHoverID,
            frames: rowFrames,
            interaction: dropInteraction,
            onEnter: { service.refresh() },
            onDrop: handleDrop
        ))
        .onTapGesture {
            if !isExpanded { onPick() }
        }
        .animation(.smooth(duration: 0.3), value: isExpanded)
        .onAppear { service.refresh() }
        .onDisappear { service.clearPending() }
        .contextMenu {
            Button("Search for devices") { service.refresh(force: true) }
            if let onOpenApp {
                Button("Open LocalSend", action: onOpenApp)
            }
        }
    }

    // MARK: - Fundo (o mesmo dos outros serviços do Shelf)

    private var background: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isTargeted ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                    )
            )
            .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 2)
    }

    // MARK: - Parado

    private var idle: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.white.opacity(0.09))
                    .frame(width: 55, height: 55)
                    .overlay {
                        Group {
                            if let icon {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .resizable().scaledToFit()
                                    .padding(4)
                            }
                        }
                        .frame(width: 34, height: 34)
                        .foregroundStyle(Color.gray)
                    }

                if !service.devices.isEmpty {
                    Text("\(service.devices.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.14), in: Capsule())
                        .offset(x: 6, y: -2)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityLabel(Text("\(service.devices.count) devices nearby"))
                }
            }
            .animation(.smooth(duration: 0.3), value: service.devices.count)

            Text(verbatim: "LocalSend")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Lista de aparelhos

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if service.devices.isEmpty {
                emptyState
                    .transition(.opacity)
            } else if service.pending != nil {
                ScrollView(.vertical) {
                    rows(service.devices)
                }
                .scrollIndicators(.never)
            } else {
                rows(Array(service.devices.prefix(service.devices.count > Self.visibleRows ? Self.visibleRows - 1 : Self.visibleRows)))
                if service.devices.count > Self.visibleRows {
                    moreRow(service.devices.count - (Self.visibleRows - 1))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Group {
                if let pending = service.pending {
                    Text(pending.count == 1 ? "Send 1 item to" : "Send \(pending.count) items to")
                } else {
                    Text("Send to")
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.gray)
            .lineLimit(1)

            Spacer(minLength: 0)

            if service.isSearching, !service.devices.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.gray)
                    .transition(.opacity)
            }
            if service.pending != nil {
                Button {
                    service.clearPending()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel"))
            }
        }
        .frame(height: 16)
    }

    private func rows(_ devices: [LocalSendDevice]) -> some View {
        VStack(spacing: 4) {
            ForEach(devices) { device in
                LocalSendDeviceRow(
                    device: device,
                    highlighted: highlightedID == device.id,
                    phase: service.outgoing?.deviceID == device.id ? service.outgoing?.phase : nil,
                    dimmed: service.outgoing.map { $0.deviceID != device.id } ?? false
                )
                .background(RowFrameReader(id: device.id, space: Self.space))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { hovering in
                    guard service.pending != nil else { return }
                    withAnimation(.smooth(duration: 0.2)) { mouseHoverID = hovering ? device.id : (mouseHoverID == device.id ? nil : mouseHoverID) }
                }
                .onTapGesture { service.sendPending(to: device) }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func moreRow(_ count: Int) -> some View {
        Text("+\(count) more")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(highlightedID == Self.moreRowID ? 0.14 : 0.06))
            )
            .background(RowFrameReader(id: Self.moreRowID, space: Self.space))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.gray)
                .symbolEffect(.variableColor.iterative, isActive: service.isSearching && !reduceMotion)
            Text(service.isSearching ? "Looking for devices…" : "No devices nearby")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
            if !service.isSearching {
                Text("Open LocalSend on the other device")
                    .font(.system(size: 9))
                    .foregroundStyle(.gray.opacity(0.8))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Soltar

    private func handleDrop(_ providers: [NSItemProvider], on id: String?) {
        if let id, let device = service.devices.first(where: { $0.id == id }) {
            service.send(providers, to: device)
        } else {
            service.arm(providers)
        }
    }
}

/// Uma linha da lista: ícone do aparelho + nome; o fundo enche com o progresso do envio.
private struct LocalSendDeviceRow: View {
    let device: LocalSendDevice
    let highlighted: Bool
    let phase: LocalSendService.SendPhase?
    let dimmed: Bool

    private var failureMessage: String? {
        if case .failed(let message)? = phase { return message }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: device.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)
            Text(failureMessage ?? device.alias)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            accessory
        }
        .foregroundStyle(.white.opacity(dimmed ? 0.35 : 0.9))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(highlighted ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.08))
                    if case .sending(let fraction)? = phase {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: max(16, geometry.size.width * fraction))
                            .animation(.smooth(duration: 0.25), value: fraction)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(highlighted ? 0.9 : 0), lineWidth: 1)
        )
        .help(Text(device.deviceModel.map { "\(device.alias) · \($0)" } ?? device.alias))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var accessory: some View {
        switch phase {
        case .waiting?:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
                .help(Text("Waiting for the other device to accept"))
        case .sending(let fraction)?:
            Text(verbatim: "\(Int(fraction * 100))%")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        case .done?:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .failed?:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Arrastar por cima de uma linha

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct RowFrameReader: View {
    let id: String
    let space: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: RowFramesKey.self, value: [id: geometry.frame(in: .named(space))])
        }
    }
}

/// Um alvo só para o slot inteiro; a linha sob o cursor sai da posição do arraste.
/// Alvos separados por linha piscariam ao passar de um para o outro.
private struct SlotDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var hoveredID: String?
    let frames: [String: CGRect]
    let interaction: DropInteractionState
    let onEnter: () -> Void
    let onDrop: ([NSItemProvider], String?) -> Void

    private func row(at location: CGPoint) -> String? {
        frames.first { $0.value.contains(location) }?.key
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: LocalSendSlot.dropTypes)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        interaction.dropZoneTargeting = true
        hoveredID = row(at: info.location)
        onEnter()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let id = row(at: info.location)
        if id != hoveredID {
            withAnimation(.smooth(duration: 0.2)) { hoveredID = id }
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        interaction.dropZoneTargeting = false
        hoveredID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let id = row(at: info.location)
        let providers = info.itemProviders(for: LocalSendSlot.dropTypes)
        interaction.dropEvent = true
        interaction.dropZoneTargeting = false
        hoveredID = nil
        isTargeted = false
        onDrop(providers, id)
        return true
    }
}
