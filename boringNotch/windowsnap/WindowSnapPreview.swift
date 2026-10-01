//
//  WindowSnapPreview.swift
//  boringCode
//
//  O retângulo translúcido que mostra onde a janela vai cair, como o do macOS ao
//  arrastar janelas para as bordas. Fica num painel transparente do tamanho da
//  tela, logo abaixo da janela arrastada, e desliza de uma zona para outra.
//

import AppKit
import SwiftUI

@MainActor
final class WindowSnapPreview {
    static let shared = WindowSnapPreview()

    private let model = PreviewModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var holdsUntilSnapped = false

    private init() {}

    /// Mostra (ou leva) a prévia até `frame`, em coordenadas de tela do Cocoa.
    func show(_ frame: CGRect, on screen: NSScreen, below windowID: CGWindowID) {
        hideTask?.cancel()
        holdsUntilSnapped = false
        let panel = panel ?? makePanel()
        self.panel = panel

        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        // Coordenadas do painel (origem em cima à esquerda, como no SwiftUI).
        let local = CGRect(
            x: frame.minX - screen.frame.minX,
            y: screen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        let wasVisible = model.isVisible && panel.isVisible
        if !panel.isVisible {
            panel.order(.below, relativeTo: Int(windowID))
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        if wasVisible {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.rect = local }
        } else {
            model.rect = local
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) { model.isVisible = true }
        }
    }

    /// Soltou numa zona: a prévia segura no lugar até a janela chegar.
    func keepVisibleUntilSnapped() {
        holdsUntilSnapped = true
    }

    func hide() {
        // Quem chamou foi o ponteiro saindo da zona no instante do soltar: espera o encaixe.
        if holdsUntilSnapped && hideTask == nil && model.isVisible {
            holdsUntilSnapped = false
            return
        }
        holdsUntilSnapped = false
        guard model.isVisible || panel?.isVisible == true else { return }
        withAnimation(.smooth(duration: 0.22)) { model.isVisible = false }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, let self else { return }
            self.panel?.orderOut(nil)
            self.hideTask = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: WindowSnapPreviewView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

@MainActor
private final class PreviewModel: ObservableObject {
    @Published var rect: CGRect = .zero
    @Published var isVisible = false
}

private struct WindowSnapPreviewView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            shape
                .frame(width: model.rect.width, height: model.rect.height)
                .offset(x: model.rect.minX, y: model.rect.minY)
                .opacity(model.isVisible ? 1 : 0)
                .scaleEffect(model.isVisible ? 1 : 0.97)
        }
        .ignoresSafeArea()
    }

    private var shape: some View {
        let outline = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return PreviewBlur()
            .overlay(Color.white.opacity(0.06))
            .clipShape(outline)
            .overlay(outline.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
            .padding(2)
    }
}

/// Vidro escuro de verdade (desfoca o que está atrás da janela, não só dentro dela).
private struct PreviewBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
