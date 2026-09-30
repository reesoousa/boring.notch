//
//  LocalSendSlot.swift
//  boringCode
//
//  Slot do LocalSend no Shelf. Parado, é igual aos outros serviços (ícone +
//  nome, num quadrado). Com um arquivo por cima, alarga para a direita e mostra
//  os aparelhos da rede como os itens do Shelf — círculo + nome embaixo, no
//  espírito do AirDrop. Solte num aparelho para enviar, ou no slot para
//  escolher depois.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Liga o slot ao `LocalSendService` e cuida do arraste.
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
    @State private var tileFrames: [String: CGRect] = [:]

    static let dropTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .data, .image]

    var body: some View {
        LocalSendSlotContent(
            state: LocalSendSlotContent.State(
                devices: service.devices,
                isSearching: service.isSearching,
                outgoing: service.outgoing,
                pendingCount: service.pending?.count,
                isTargeted: isTargeted,
                isPreparing: service.isPreparingPending
            ),
            icon: icon,
            dragHoverID: dragHoverID,
            onSelect: { service.sendPending(to: $0) },
            onCancel: { service.clearPending() }
        )
        .onPreferenceChange(LocalSendTileFramesKey.self) { tileFrames = $0 }
        .onDrop(of: Self.dropTypes, delegate: SlotDropDelegate(
            isTargeted: $isTargeted,
            hoveredID: $dragHoverID,
            frames: tileFrames,
            interaction: dropInteraction,
            onEnter: { service.refresh() },
            onDrop: handleDrop
        ))
        .onTapGesture {
            if service.pending == nil, service.outgoing == nil { onPick() }
        }
        .onAppear { service.refresh() }
        .onDisappear { service.clearPending() }
        .contextMenu {
            Button("Search for devices") { service.refresh(force: true) }
            if let onOpenApp {
                Button("Open LocalSend", action: onOpenApp)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], on id: String?) {
        if let id, let device = service.devices.first(where: { $0.id == id }) {
            service.send(providers, to: device)
        } else {
            service.arm(providers)
        }
    }
}

/// O visual do slot, só a partir do estado (usado também nas imagens de conferência).
struct LocalSendSlotContent: View {
    struct State: Equatable {
        var devices: [LocalSendDevice]
        var isSearching: Bool
        var outgoing: LocalSendService.Outgoing?
        var pendingCount: Int?
        var isTargeted: Bool
        var isPreparing = false

        var isExpanded: Bool { isTargeted || pendingCount != nil || outgoing != nil || isPreparing }
    }

    let state: State
    let icon: NSImage?
    var dragHoverID: String?
    var onSelect: (LocalSendDevice) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @SwiftUI.State private var mouseHoverID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let space = "localsend-slot"
    static let moreTileID = "localsend-more"

    // Medidas: tiles com a mesma leitura dos itens do Shelf (ícone + nome de 12 pt).
    static let tileWidth: CGFloat = 76
    static let tileSpacing: CGFloat = 8
    static let padding: CGFloat = 12
    /// Tiles visíveis enquanto arrasta (sem rolagem durante o arraste).
    static let maxTiles = 4

    private var highlightedID: String? { dragHoverID ?? mouseHoverID }

    /// Aparelhos mostrados e se sobra um "+N".
    private var visible: (devices: [LocalSendDevice], more: Int) {
        let devices = state.devices
        if state.pendingCount != nil || devices.count <= Self.maxTiles { return (devices, 0) }
        return (Array(devices.prefix(Self.maxTiles - 1)), devices.count - (Self.maxTiles - 1))
    }

    /// Largura aberta: cabe os tiles lado a lado (até `maxTiles`); nunca menor que o quadrado.
    private var expandedWidth: CGFloat {
        let count = state.devices.isEmpty ? 1 : min(visible.devices.count + (visible.more > 0 ? 1 : 0), Self.maxTiles)
        return CGFloat(count) * Self.tileWidth + CGFloat(max(0, count - 1)) * Self.tileSpacing + 2 * Self.padding
    }

    var body: some View {
        LocalSendSlotLayout(expandedWidth: state.isExpanded ? expandedWidth : 0) {
            ZStack {
                background

                if state.isExpanded {
                    expanded
                        .padding(Self.padding)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                } else {
                    idle
                        .padding(18)
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
            }
            .coordinateSpace(name: Self.space)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .animation(.smooth(duration: 0.35), value: state.isExpanded)
        .animation(.smooth(duration: 0.35), value: expandedWidth)
    }

    // MARK: - Fundo (o mesmo dos outros serviços do Shelf)

    private var background: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        state.isTargeted ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1),
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

                if !state.devices.isEmpty {
                    Text(verbatim: "\(state.devices.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.14), in: Capsule())
                        .offset(x: 6, y: -2)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityLabel(Text("\(state.devices.count) devices nearby"))
                }
            }
            .animation(.smooth(duration: 0.3), value: state.devices.count)

            Text(verbatim: "LocalSend")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Aberto

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if state.devices.isEmpty {
                emptyState
                    .transition(.opacity)
            } else if state.pendingCount != nil, state.devices.count > Self.maxTiles {
                ScrollView(.horizontal) { tiles }
                    .scrollIndicators(.never)
            } else {
                tiles
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Group {
                if let count = state.pendingCount {
                    Text(count == 1 ? "Send 1 item to" : "Send \(count) items to")
                } else {
                    Text("Send to")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.gray)
            .lineLimit(1)

            Spacer(minLength: 0)

            if state.isSearching, !state.devices.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.gray)
                    .transition(.opacity)
            }
            if state.pendingCount != nil {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel"))
            }
        }
        .frame(height: 16)
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: Self.tileSpacing) {
            ForEach(visible.devices) { device in
                LocalSendDeviceTile(
                    device: device,
                    highlighted: highlightedID == device.id,
                    targeted: dragHoverID == device.id,
                    phase: state.outgoing?.deviceID == device.id ? state.outgoing?.phase : nil,
                    dimmed: state.outgoing.map { $0.deviceID != device.id } ?? false
                )
                .background(LocalSendTileFrameReader(id: device.id))
                .onHover { hovering in
                    guard state.pendingCount != nil else { return }
                    withAnimation(.smooth(duration: 0.2)) {
                        mouseHoverID = hovering ? device.id : (mouseHoverID == device.id ? nil : mouseHoverID)
                    }
                }
                .onTapGesture { onSelect(device) }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if visible.more > 0 {
                moreTile(visible.more)
            }
        }
    }

    private func moreTile(_ count: Int) -> some View {
        VStack(spacing: 6) {
            Circle()
                .fill(Color.white.opacity(dragHoverID == Self.moreTileID ? 0.14 : 0.06))
                .frame(width: LocalSendDeviceTile.circleSize, height: LocalSendDeviceTile.circleSize)
                .overlay {
                    Text(verbatim: "+\(count)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.gray)
                }
            Text("more")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.gray)
        }
        .frame(width: Self.tileWidth)
        .padding(.vertical, 4)
        .background(LocalSendTileFrameReader(id: Self.moreTileID))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.gray)
                .symbolEffect(.variableColor.iterative, isActive: state.isSearching && !reduceMotion)
            Text(state.isSearching ? "Looking for devices…" : "No devices nearby")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.gray)
            if !state.isSearching {
                Text("Open LocalSend on the other device")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray.opacity(0.8))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Um aparelho: círculo com o ícone e o nome embaixo, como um item do Shelf.
/// O anel em volta do círculo mostra o envio; um selo marca ✓ ou erro.
struct LocalSendDeviceTile: View {
    let device: LocalSendDevice
    let highlighted: Bool
    let targeted: Bool
    let phase: LocalSendService.SendPhase?
    let dimmed: Bool

    static let circleSize: CGFloat = 44

    @SwiftUI.State private var waitingPulse = false

    private var failureMessage: String? {
        if case .failed(let message)? = phase { return message }
        return nil
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.white.opacity(highlighted ? 0.14 : 0.09))
                    .frame(width: Self.circleSize, height: Self.circleSize)
                    .overlay {
                        Image(systemName: device.symbolName)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .overlay { ring }

                badge
                    .offset(x: 3, y: 3)
            }

            Text(failureMessage ?? device.alias)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(failureMessage == nil ? Color.white.opacity(0.9) : Color.gray)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
        }
        .frame(width: LocalSendSlotContent.tileWidth)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.25) : Color.white.opacity(highlighted ? 0.06 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(targeted ? 0.9 : 0), lineWidth: 2)
        )
        .opacity(dimmed ? 0.4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.smooth(duration: 0.25), value: highlighted)
        .animation(.smooth(duration: 0.25), value: targeted)
        .animation(.smooth(duration: 0.3), value: phase)
        .help(Text(verbatim: device.deviceModel.map { "\(device.alias) · \($0)" } ?? device.alias))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var ring: some View {
        switch phase {
        case .waiting?:
            // Esperando o outro lado aceitar: anel respira devagar.
            Circle()
                .stroke(Color.white.opacity(waitingPulse ? 0.55 : 0.2), lineWidth: 2.5)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: waitingPulse)
                .onAppear { waitingPulse = true }
                .onDisappear { waitingPulse = false }
        case .sending(let fraction)?:
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.25), value: fraction)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch phase {
        case .done?:
            statusBadge("checkmark.circle.fill", color: .green)
        case .failed?:
            statusBadge("xmark.circle.fill", color: .red)
        default:
            EmptyView()
        }
    }

    private func statusBadge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .background(Circle().fill(.black).padding(1))
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

// MARK: - Largura do slot

/// Quadrado parado; aberto, alarga para caber os tiles. A largura é animável,
/// então o Shelf ao lado encolhe junto, sem pulo.
private struct LocalSendSlotLayout: Layout {
    /// 0 = quadrado.
    var expandedWidth: CGFloat

    var animatableData: CGFloat {
        get { expandedWidth }
        set { expandedWidth = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = proposal.height ?? 140
        return CGSize(width: max(height, expandedWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

// MARK: - Arrastar por cima de um aparelho

struct LocalSendTileFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct LocalSendTileFrameReader: View {
    let id: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: LocalSendTileFramesKey.self, value: [id: geometry.frame(in: .named(LocalSendSlotContent.space))])
        }
    }
}

/// Um alvo só para o slot inteiro; o aparelho sob o cursor sai da posição do arraste.
/// Alvos separados por aparelho piscariam ao passar de um para o outro.
private struct SlotDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var hoveredID: String?
    let frames: [String: CGRect]
    let interaction: DropInteractionState
    let onEnter: () -> Void
    let onDrop: ([NSItemProvider], String?) -> Void

    private func tile(at location: CGPoint) -> String? {
        frames.first { $0.value.contains(location) }?.key
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: LocalSendSlot.dropTypes)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        interaction.dropZoneTargeting = true
        hoveredID = tile(at: info.location)
        onEnter()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let id = tile(at: info.location)
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
        let id = tile(at: info.location)
        let providers = info.itemProviders(for: LocalSendSlot.dropTypes)
        interaction.dropEvent = true
        interaction.dropZoneTargeting = false
        hoveredID = nil
        isTargeted = false
        onDrop(providers, id)
        return true
    }
}
