//
//  WindowSnapPickerView.swift
//  boringCode
//
//  O que o notch mostra enquanto você arrasta uma janela até ele: uma fileira de
//  miniaturas de tela, uma por layout. A zona sob o ponteiro acende em branco e o
//  cartão cresce um pouco; o cabeçalho diz o app e onde a janela vai ficar.
//  Mesma linguagem do monitor: cartões de canto 12 em branco 6%, cinza e branco,
//  entrada em cascata e molas suaves (Reduzir movimento respeitado).
//

import Defaults
import SwiftUI

struct WindowSnapPickerView: View {
    @ObservedObject private var monitor = WindowDragMonitor.shared
    @Default(.windowSnapHiddenLayouts) private var hiddenLayouts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var layouts: [SnapLayout] {
        let visible = SnapLayout.all.filter { !hiddenLayouts.contains($0.id) }
        return visible.isEmpty ? [SnapLayout.halves] : visible
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(layouts.enumerated()), id: \.element.id) { index, layout in
                WindowSnapLayoutCard(
                    layout: layout,
                    hoveredZoneID: monitor.hoveredTarget?.layoutID == layout.id ? monitor.hoveredTarget?.zone.id : nil,
                    appeared: appeared,
                    order: index
                )
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                DispatchQueue.main.async { appeared = true }
            }
        }
        .onDisappear { appeared = false }
    }
}

private struct WindowSnapLayoutCard: View {
    let layout: SnapLayout
    let hoveredZoneID: String?
    let appeared: Bool
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { hoveredZoneID != nil }

    private var entrance: Animation {
        reduceMotion ? .smooth(duration: 0.2)
            : .spring(response: 0.5, dampingFraction: 0.82).delay(Double(order) * 0.04)
    }

    var body: some View {
        VStack(spacing: 7) {
            miniScreen
            Text(layout.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? .white : .gray)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .animation(.smooth(duration: 0.2), value: isActive)
        }
        .padding(.horizontal, 7)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isActive ? 0.1 : 0.06))
        )
        .scaleEffect(isActive && !reduceMotion ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isActive)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .blur(radius: appeared || reduceMotion ? 0 : 6)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .animation(entrance, value: appeared)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(layout.title))
    }

    /// Miniatura da tela (16:10) com as zonas do layout; é ela que registra o retângulo
    /// usado para acertar as zonas com o ponteiro.
    private var miniScreen: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Zonas por dentro do contorno, com 2 pt entre elas.
            let inset: CGFloat = 3
            let inner = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
            ZStack(alignment: .topLeading) {
                // A "tela": dá a escala do layout (Centro não se confunde com Preencher).
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(isActive ? 0.16 : 0.1), lineWidth: 1)
                ForEach(layout.zones) { zone in
                    let isHovered = zone.id == hoveredZoneID
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.92 : (isActive ? 0.2 : 0.13)))
                        .frame(
                            width: max(0, inner.width * zone.rect.width - 2),
                            height: max(0, inner.height * zone.rect.height - 2)
                        )
                        .offset(x: inset + inner.width * zone.rect.minX + 1, y: inset + inner.height * zone.rect.minY + 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: isHovered)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .background(ScreenRectReader(layoutID: layout.id))
    }
}

/// Cabeçalho do notch durante o arraste: o app à esquerda do notch físico e, à
/// direita, para onde a janela vai (ou a dica de soltar).
struct WindowSnapHeader: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var monitor = WindowDragMonitor.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @State private var appIcon: NSImage?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text(verbatim: monitor.draggedWindow?.appName ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                .frame(width: vm.closedNotchSize.width)
                .mask { NotchShape() }

            Group {
                if !monitor.canMoveWindows {
                    // Sem permissão: avisa antes de soltar (soltar abre o pedido do sistema).
                    Label {
                        Text("Needs permission")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                    .foregroundStyle(.gray)
                } else if let zone = monitor.hoveredTarget?.zone {
                    Text(verbatim: zone.title)
                        .foregroundStyle(.white)
                        .id(zone.title)
                } else {
                    Text("Drop on a layout")
                        .foregroundStyle(.gray)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.smooth(duration: 0.2), value: monitor.hoveredTarget?.zone.title)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear(perform: loadIcon)
        .onChange(of: monitor.draggedWindow?.pid) { _, _ in loadIcon() }
    }

    private func loadIcon() {
        appIcon = monitor.draggedWindow.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon }
    }
}

/// Deixa o monitor saber onde a miniatura está na tela. Ele pergunta na hora de
/// acertar a zona (posição do AppKit, sem a escala da animação de abrir).
private struct ScreenRectReader: NSViewRepresentable {
    let layoutID: String

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.layoutID = layoutID
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.layoutID = layoutID
    }

    final class ReaderView: NSView {
        var layoutID = "" {
            didSet {
                guard layoutID != oldValue, window != nil else { return }
                WindowDragMonitor.shared.unregisterRegion(self, for: oldValue)
                WindowDragMonitor.shared.registerRegion(self, for: layoutID)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                WindowDragMonitor.shared.unregisterRegion(self, for: layoutID)
            } else {
                WindowDragMonitor.shared.registerRegion(self, for: layoutID)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
