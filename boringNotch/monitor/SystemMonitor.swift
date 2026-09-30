//
//  SystemMonitor.swift
//  boringCode
//
//  Monitor do sistema do notch: só mede enquanto a aba está na tela (a view
//  chama `begin`/`end`). Com o notch fechado ou em outra aba, custo zero.
//

import Combine
import Defaults
import Foundation

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var sample = SystemSample()
    /// Picos recentes da rede (decaem devagar) — escala das barras de download/upload.
    @Published private(set) var downloadScale: Double = SystemMonitor.minimumNetworkScale
    @Published private(set) var uploadScale: Double = SystemMonitor.minimumNetworkScale

    /// Abaixo disso a barra não "enche" com tráfego mínimo de fundo (256 KB/s).
    static let minimumNetworkScale: Double = 256 * 1024
    /// Quanto o pico cai por segundo sem tráfego novo.
    private static let peakDecayPerSecond = 0.92

    private let sampler = SystemSampler()
    private var loop: Task<Void, Never>?
    private var viewers = 0

    private init() {}

    /// A aba apareceu.
    func begin() {
        viewers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// A aba sumiu.
    func end() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    private func run() async {
        await sampler.reset()
        // Primeira leitura só "arma" os contadores; a segunda, logo depois, já tem valores.
        publish(await sampler.sample(), elapsed: 0)
        try? await Task.sleep(for: .milliseconds(350))

        var last = Date()
        while !Task.isCancelled {
            let now = Date()
            publish(await sampler.sample(), elapsed: now.timeIntervalSince(last))
            last = now
            let interval = max(0.5, Defaults[.monitorInterval])
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func publish(_ new: SystemSample, elapsed: TimeInterval) {
        var merged = new
        // Mantém o último valor até ter um novo (não pisca "—" entre leituras).
        merged.cpu = new.cpu ?? sample.cpu
        merged.download = new.download ?? sample.download
        merged.upload = new.upload ?? sample.upload
        if merged != sample { sample = merged }

        let decay = pow(Self.peakDecayPerSecond, max(1, elapsed))
        let down = max(Self.minimumNetworkScale, merged.download ?? 0, downloadScale * decay)
        let up = max(Self.minimumNetworkScale, merged.upload ?? 0, uploadScale * decay)
        if down != downloadScale { downloadScale = down }
        if up != uploadScale { uploadScale = up }
    }

    // MARK: - Texto

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesActualByteCount = false
        formatter.zeroPadsFractionDigits = false
        formatter.allowsNonnumericFormatting = false  // "0 KB", nunca "Zero KB"
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
