//
//  NSRunningApplication+SingleInstance.swift
//  boringNotch
//

import AppKit

extension NSRunningApplication {
    /// Fecha as outras cópias do app abertas antes desta. Duas instâncias desenham dois
    /// notches e disputam o socket dos agentes e a porta do LocalSend.
    /// A mais nova fica: é a que a pessoa acabou de abrir, e o "Reiniciar" e o Sparkle
    /// também abrem a nova antes de fechar a antiga.
    static func terminateOlderInstances(timeout: TimeInterval = 3) {
        let current = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier,
              let launchDate = current.launchDate
        else { return }

        let older = runningApplications(withBundleIdentifier: bundleID).filter { app in
            guard app.processIdentifier != current.processIdentifier else { return false }
            guard let otherLaunch = app.launchDate else { return true }
            if otherLaunch == launchDate { return app.processIdentifier < current.processIdentifier }
            return otherLaunch < launchDate
        }
        guard !older.isEmpty else { return }

        // Pede para sair (salva o Shelf etc.); quem não sair até o prazo é forçado.
        older.forEach { $0.terminate() }
        func alive() -> [NSRunningApplication] { older.filter { kill($0.processIdentifier, 0) == 0 } }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !alive().isEmpty {
            usleep(50_000)
        }
        alive().forEach { $0.forceTerminate() }
    }
}
