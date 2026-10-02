//
//  ClipboardPaster.swift
//  BoringNotchXPCHelper
//
//  boringCode — histórico do clipboard. Depois que o app põe o item escolhido no
//  clipboard, o helper aperta ⌘V para colar no app da frente. Fica no helper porque
//  enviar teclas para outros apps precisa da Acessibilidade, que é dele.
//

import ApplicationServices
import Carbon.HIToolbox

extension BoringNotchXPCHelper {
    @objc func pasteCommandV(toPID pid: Int32, with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted() else {
            reply(false)
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        // Tecla V (posição física) com ⌘: é o que os apps tratam como "Colar".
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            reply(false)
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        if pid > 0 {
            // O notch está com o teclado (busca em uso): entrega direto ao app de destino.
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        reply(true)
    }
}
