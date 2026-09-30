//
//  LocalSendSlot.swift
//  boringCode
//
//  Slot do LocalSend no Shelf. Parado, é igual aos outros serviços (ícone +
//  nome, num quadrado). Com um arquivo por cima, abre com a mola do próprio
//  slot: o nome do arquivo em cima e cada aparelho num box grande que ocupa
//  o espaço. Solte, clique no aparelho: envia, mostra ✓ e fecha.
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
    @State private var drag: LocalSendSlotContent.DragPreview?

    static let dropTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .data, .image]

    var body: some View {
        LocalSendSlotContent(
            state: LocalSendSlotContent.State(
                devices: service.devices,
                isSearching: service.isSearching,
                outgoing: service.outgoing,
                pending: service.pending.map { .init(title: $0.title, count: $0.count) },
                drag: drag,
                isPreparing: service.isPreparingPending
            ),
            icon: icon,
            onSelect: { service.sendPending(to: $0) },
            onCancel: { service.clearPending() }
        )
        .onDrop(of: Self.dropTypes, delegate: SlotDropDelegate(
            drag: $drag,
            interaction: dropInteraction,
            onEnter: { service.refresh() },
            onDrop: { service.arm($0) }
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
}

/// O visual do slot, só a partir do estado (usado também nas imagens de conferência).
struct LocalSendSlotContent: View {
    /// O que está sendo arrastado (antes de soltar).
    struct DragPreview: Equatable {
        var title: String?
        var count: Int
    }

    struct Items: Equatable {
        var title: String?
        var count: Int
    }

    struct State: Equatable {
        var devices: [LocalSendDevice]
        var isSearching: Bool
        var outgoing: LocalSendService.Outgoing?
        var pending: Items?
        var drag: DragPreview?
        var isPreparing = false

        var isExpanded: Bool { drag != nil || pending != nil || outgoing != nil || isPreparing }

        /// O que mostrar no topo: enviando > esperando você escolher > arrastando.
        var items: Items? {
            if let outgoing { return Items(title: outgoing.title, count: outgoing.count) }
            if let pending { return pending }
            if let drag { return Items(title: drag.title, count: drag.count) }
            return nil
        }
    }

    let state: State
    let icon: NSImage?
    var onSelect: (LocalSendDevice) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Medidas: o box de um aparelho ocupa o quadrado do slot; mais aparelhos alargam o slot.
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 8
    static let headerHeight: CGFloat = 18
    /// Boxes visíveis lado a lado (mais que isso: rolagem, ou "+N" durante o arraste).
    static let maxBoxes = 3

    /// A mola do slot (a mesma do ícone de compartilhar do Shelf): abre com um leve "elástico".
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)

    private var visible: (devices: [LocalSendDevice], more: Int) {
        let devices = state.devices
        if state.pending != nil || devices.count <= Self.maxBoxes { return (devices, 0) }
        return (Array(devices.prefix(Self.maxBoxes - 1)), devices.count - (Self.maxBoxes - 1))
    }

    private var boxCount: Int {
        state.devices.isEmpty ? 1 : min(visible.devices.count + (visible.more > 0 ? 1 : 0), Self.maxBoxes)
    }

    var body: some View {
        LocalSendSlotLayout(boxCount: state.isExpanded ? boxCount : 0, padding: Self.padding, spacing: Self.spacing) {
            ZStack {
                background

                if state.isExpanded {
                    expanded
                        .padding(Self.padding)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                } else {
                    idle
                        .padding(18)
                        .transition(.opacity.combined(with: .scale(scale: 1.06)))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .animation(reduceMotion ? .smooth(duration: 0.3) : Self.spring, value: state.isExpanded)
        .animation(reduceMotion ? .smooth(duration: 0.3) : Self.spring, value: boxCount)
    }

    // MARK: - Fundo (o mesmo dos outros serviços do Shelf)

    private var background: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        state.drag != nil ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1),
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
        VStack(alignment: .leading, spacing: Self.spacing) {
            header

            if state.devices.isEmpty {
                emptyState
                    .transition(.opacity)
            } else if state.pending != nil, state.devices.count > Self.maxBoxes {
                ScrollView(.horizontal) { boxes }
                    .scrollIndicators(.never)
            } else {
                boxes
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// O arquivo que vai: ícone + nome (ou "3 itens").
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: state.items.map { $0.count > 1 ? "doc.on.doc.fill" : "doc.fill" } ?? "doc.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.gray)
                .frame(width: 14)

            Group {
                if let title = state.items?.title {
                    Text(verbatim: title)
                } else {
                    Text("\(state.items?.count ?? 1) items")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.middle)
            .contentTransition(.opacity)

            Spacer(minLength: 0)

            if state.isSearching, !state.devices.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.gray)
                    .transition(.opacity)
            }
            if state.pending != nil {
                LocalSendIconButton(systemName: "xmark", label: "Cancel", action: onCancel)
                    .transition(.opacity)
            }
        }
        .frame(height: Self.headerHeight)
    }

    private var boxes: some View {
        HStack(spacing: Self.spacing) {
            ForEach(visible.devices) { device in
                LocalSendDeviceBox(
                    device: device,
                    phase: state.outgoing?.deviceID == device.id ? state.outgoing?.phase : nil,
                    dimmed: state.outgoing.map { $0.deviceID != device.id } ?? false,
                    selectable: state.pending != nil
                ) {
                    onSelect(device)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if visible.more > 0 {
                moreBox(visible.more)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func moreBox(_ count: Int) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: "+\(count)")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.gray)
            Text("more")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
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

/// Um aparelho num box grande: ícone + nome + linha de status. Enviando, o box
/// enche de baixo para cima com o progresso; no fim o ícone vira ✓.
struct LocalSendDeviceBox: View {
    let device: LocalSendDevice
    let phase: LocalSendService.SendPhase?
    let dimmed: Bool
    /// Tem itens esperando: o box é clicável (com hover).
    let selectable: Bool
    var onTap: () -> Void = {}

    @State private var isHovering = false
    @State private var waitingPulse = false

    private var symbol: String {
        switch phase {
        case .done?: "checkmark"
        case .failed?: "xmark"
        default: device.symbolName
        }
    }

    private var symbolColor: Color {
        switch phase {
        case .done?: .green
        case .failed?: .red
        default: .white.opacity(0.9)
        }
    }

    private var status: Text {
        switch phase {
        case .waiting?: Text("Waiting…")
        case .sending(let fraction)?: Text(verbatim: "\(Int(fraction * 100))%")
        case .done?: Text("Sent")
        case .failed(let message)?: Text(verbatim: message)
        case nil: Text(verbatim: device.deviceModel ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(symbolColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 30)

            Text(verbatim: device.alias)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            status
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.gray)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    // Hover igual ao dos botões do app (HoverButton).
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.gray.opacity(isHovering && selectable ? 0.2 : 0))
                    if case .sending(let fraction)? = phase {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(height: geometry.size.height * fraction)
                            .animation(.smooth(duration: 0.3), value: fraction)
                    }
                    if case .waiting? = phase {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(waitingPulse ? 0.1 : 0.02))
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: waitingPulse)
                            .onAppear { waitingPulse = true }
                            .onDisappear { waitingPulse = false }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .opacity(dimmed ? 0.4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) { isHovering = hovering }
        }
        .onTapGesture { if selectable { onTap() } }
        .animation(.smooth(duration: 0.3), value: phase)
        .help(Text(verbatim: device.deviceModel.map { "\(device.alias) · \($0)" } ?? device.alias))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectable ? .isButton : [])
    }
}

/// Ícone solto com o hover dos botões do app (cápsula cinza, como o HoverButton).
struct LocalSendIconButton: View {
    let systemName: String
    let label: LocalizedStringKey
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.gray)
                .frame(width: 18, height: 18)
                .background(Capsule().fill(Color.gray.opacity(isHovering ? 0.2 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) { isHovering = hovering }
        }
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Largura do slot

/// Quadrado parado; aberto, cada aparelho ganha um box do tamanho do quadrado.
/// A largura é animável, então o Shelf ao lado encolhe junto (com a mesma mola).
private struct LocalSendSlotLayout: Layout {
    /// 0 = quadrado.
    var boxCount: Int
    let padding: CGFloat
    let spacing: CGFloat
    var animatedCount: CGFloat

    init(boxCount: Int, padding: CGFloat, spacing: CGFloat) {
        self.boxCount = boxCount
        self.padding = padding
        self.spacing = spacing
        animatedCount = CGFloat(boxCount)
    }

    var animatableData: CGFloat {
        get { animatedCount }
        set { animatedCount = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = proposal.height ?? 140
        let box = height - 2 * padding
        let count = max(1, animatedCount)
        let width = count * box + (count - 1) * spacing + 2 * padding
        return CGSize(width: max(height, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

// MARK: - Arrastar

/// Enquanto o arquivo está por cima, mostra o nome dele; ao soltar, ele fica
/// esperando você clicar no aparelho.
private struct SlotDropDelegate: DropDelegate {
    @Binding var drag: LocalSendSlotContent.DragPreview?
    let interaction: DropInteractionState
    let onEnter: () -> Void
    let onDrop: ([NSItemProvider]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: LocalSendSlot.dropTypes)
    }

    func dropEntered(info: DropInfo) {
        let providers = info.itemProviders(for: LocalSendSlot.dropTypes)
        drag = .init(
            title: providers.count == 1 ? providers.first?.suggestedName : nil,
            count: max(1, providers.count)
        )
        interaction.dropZoneTargeting = true
        onEnter()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        drag = nil
        interaction.dropZoneTargeting = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: LocalSendSlot.dropTypes)
        interaction.dropEvent = true
        interaction.dropZoneTargeting = false
        onDrop(providers)  // `isPreparingPending` segura o slot aberto até os itens chegarem
        drag = nil
        return true
    }
}
