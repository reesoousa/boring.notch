//
//  WindowSnapper.swift
//  boringCode
//
//  Calcula onde a janela vai ficar e pede ao helper para levá-la até lá. Quem
//  mexe na janela (API de Acessibilidade) é o helper XPC, que tem a permissão.
//

import AppKit
import Defaults

enum WindowSnapper {
    /// Espaço entre janelas com margens ligadas (metade de cada lado de uma divisa).
    private static let margin: CGFloat = 8

    /// Onde a janela vai ficar, em coordenadas do Cocoa (origem embaixo à esquerda).
    @MainActor
    static func targetFrame(for zone: SnapZone, on screen: NSScreen) -> CGRect {
        let area = screen.visibleFrame
        var frame = CGRect(
            x: area.minX + area.width * zone.rect.minX,
            y: area.maxY - area.height * zone.rect.maxY,
            width: area.width * zone.rect.width,
            height: area.height * zone.rect.height
        )
        if Defaults[.windowSnapMargins] {
            // Margem cheia na borda da tela, meia nas divisas: entre duas janelas fica uma margem só.
            let full = margin, half = margin / 2
            let left = abs(frame.minX - area.minX) < 1 ? full : half
            let right = abs(frame.maxX - area.maxX) < 1 ? full : half
            let bottom = abs(frame.minY - area.minY) < 1 ? full : half
            let top = abs(frame.maxY - area.maxY) < 1 ? full : half
            frame = CGRect(
                x: frame.minX + left,
                y: frame.minY + bottom,
                width: frame.width - left - right,
                height: frame.height - top - bottom
            )
        }
        return frame.integral
    }

    /// Encaixa a janela. `completion` volta quando ela chegou (ou desistiu).
    @MainActor
    static func snap(
        _ window: WindowDragMonitor.DraggedWindow,
        to zone: SnapZone,
        on screen: NSScreen,
        completion: @escaping @MainActor () -> Void
    ) {
        let target = targetFrame(for: zone, on: screen)
        // AX usa origem no canto superior esquerdo da tela principal.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let axTarget = CGRect(x: target.minX, y: primaryMaxY - target.maxY, width: target.width, height: target.height)
        let animate = Defaults[.windowSnapAnimate] && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        Task { @MainActor in
            // Um respiro para o app terminar o próprio arraste antes de mexermos na janela.
            try? await Task.sleep(for: .milliseconds(40))
            let moved = await XPCHelperClient.shared.moveWindow(
                pid: window.pid, windowID: window.windowID, to: axTarget, animate: animate
            )
            if !moved { NSLog("[boringCode] encaixe de janela: não deu para mover \(window.appName)") }
            completion()
        }
    }
}
