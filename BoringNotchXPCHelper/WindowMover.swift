//
//  WindowMover.swift
//  BoringNotchXPCHelper
//
//  boringCode — encaixe de janelas. Move e redimensiona a janela de outro app pela
//  API de Acessibilidade; fica no helper porque é ele que tem essa permissão (a
//  mesma das notificações e do OSD). Roda numa fila própria: cada chamada espera
//  o outro app responder.
//

import AppKit
import ApplicationServices
import QuartzCore

/// Liga um elemento AX ao número da janela no WindowServer. Privada, mas estável há
/// anos e usada por gerenciadores de janela conhecidos; é o único jeito de achar
/// exatamente a janela que está sendo arrastada quando o app tem várias.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

extension BoringNotchXPCHelper {
    @objc func moveWindow(
        _ pid: Int32, windowID: UInt32,
        x: Double, y: Double, width: Double, height: Double,
        animate: Bool,
        with reply: @escaping (Bool) -> Void
    ) {
        let target = CGRect(x: x, y: y, width: width, height: height)
        WindowMover.queue.async {
            reply(WindowMover.move(pid: pid, windowID: windowID, to: target, animate: animate))
        }
    }
}

enum WindowMover {
    static let queue = DispatchQueue(label: "com.reesoousa.boringcode.windowmover", qos: .userInteractive)
    private static let animationDuration: CFTimeInterval = 0.24
    /// Se mover a janela demora mais que isso, o app é pesado demais para deslizar: pula direto.
    private static let slowStepThreshold: CFTimeInterval = 0.03

    static func move(pid: pid_t, windowID: CGWindowID, to target: CGRect, animate: Bool) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        guard let element = axWindow(in: app, matching: windowID) else { return false }

        // Com a "interface melhorada" ligada (VoiceOver, alguns apps Electron) cada passo
        // vira uma animação lenta do próprio app. Desliga enquanto mexe e devolve depois.
        let enhanced = bool(kEnhancedUserInterface, of: app) == true
        if enhanced { set(kEnhancedUserInterface, false, on: app) }
        defer { if enhanced { set(kEnhancedUserInterface, true, on: app) } }

        if animate, let start = frame(of: element) {
            slide(element, from: start, to: target)
        }
        apply(target, to: element)
        return true
    }

    // MARK: - Movimento

    /// Desliza a janela até o destino (curva que desacelera no fim, como as do sistema).
    private static func slide(_ element: AXUIElement, from start: CGRect, to end: CGRect) {
        let begin = CACurrentMediaTime()
        var frameIndex = 1.0
        while true {
            let progress = (CACurrentMediaTime() - begin) / animationDuration
            guard progress < 1 else { return }
            let eased = 1 - pow(1 - progress, 4)
            let step = CGRect(
                x: start.minX + (end.minX - start.minX) * eased,
                y: start.minY + (end.minY - start.minY) * eased,
                width: start.width + (end.width - start.width) * eased,
                height: start.height + (end.height - start.height) * eased
            ).integral

            let stepBegin = CACurrentMediaTime()
            let moved = setPosition(step.origin, of: element)
            let sized = setSize(step.size, of: element)
            guard moved || sized else { return }
            if CACurrentMediaTime() - stepBegin > slowStepThreshold { return }

            // Próximo quadro de 60 Hz.
            let next = begin + frameIndex / 60
            frameIndex += 1
            let wait = next - CACurrentMediaTime()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }

    /// Tamanho → posição → tamanho: ao trocar de tela, o app pode recusar um tamanho que
    /// não cabia na posição antiga; a segunda chamada corrige.
    private static func apply(_ frame: CGRect, to element: AXUIElement) {
        setSize(frame.size, of: element)
        setPosition(frame.origin, of: element)
        setSize(frame.size, of: element)
    }

    // MARK: - AX

    private static let kEnhancedUserInterface = "AXEnhancedUserInterface"

    private static func axWindow(in app: AXUIElement, matching windowID: CGWindowID) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            for window in windows {
                var id: CGWindowID = 0
                if _AXUIElementGetWindow(window, &id) == .success, id == windowID {
                    return window
                }
            }
        }
        // Reserva: quem está sendo arrastado ganhou o foco com o clique.
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    private static func setPosition(_ point: CGPoint, of element: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    private static func setSize(_ size: CGSize, of element: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    private static func bool(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func set(_ attribute: String, _ flag: Bool, on element: AXUIElement) {
        AXUIElementSetAttributeValue(element, attribute as CFString, flag as CFBoolean)
    }
}
