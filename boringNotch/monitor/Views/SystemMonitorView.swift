//
//  SystemMonitorView.swift
//  boringCode
//
//  Aba do monitor: CPU, memória, armazenamento, bateria, download e upload em
//  cartões (3×2) no visual do app — cinza/branco, cantos 12, barra do player.
//  Ao abrir, os cartões chegam em cascata (desfoque → nítido, com mola) e as
//  barras crescem enquanto os números contam do zero até o valor atual.
//

import Defaults
import SwiftUI

struct SystemMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    @Default(.monitorShowCPU) private var showCPU
    @Default(.monitorShowMemory) private var showMemory
    @Default(.monitorShowStorage) private var showStorage
    @Default(.monitorShowBattery) private var showBattery
    @Default(.monitorShowDownload) private var showDownload
    @Default(.monitorShowUpload) private var showUpload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false

    private var metrics: [SystemMetric] {
        [
            showCPU ? .cpu : nil,
            showMemory ? .memory : nil,
            showStorage ? .storage : nil,
            showBattery && SystemPower.hasInternalBattery ? .battery : nil,
            showDownload ? .download : nil,
            showUpload ? .upload : nil,
        ].compactMap { $0 }
    }

    /// 1–3 lado a lado; 4 em 2×2; 5–6 em linhas de três.
    private var rows: [[SystemMetric]] {
        let perRow = metrics.count == 4 ? 2 : 3
        return stride(from: 0, to: metrics.count, by: perRow).map {
            Array(metrics[$0..<min($0 + perRow, metrics.count)])
        }
    }

    var body: some View {
        Group {
            if metrics.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 8) {
                            ForEach(Array(row.enumerated()), id: \.element) { columnIndex, metric in
                                SystemMonitorTile(
                                    metric: metric,
                                    reading: reading(for: metric),
                                    appeared: appeared,
                                    // Cascata na diagonal: a onda desce e anda para a direita.
                                    order: rowIndex + columnIndex
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                    }
                }
                .animation(.smooth(duration: 0.35), value: metrics)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            monitor.begin()
            if reduceMotion {
                appeared = true
            } else {
                // Um quadro depois, para tudo sair do zero.
                DispatchQueue.main.async { appeared = true }
            }
        }
        .onDisappear {
            monitor.end()
            appeared = false
        }
    }

    // MARK: - Leituras

    private func reading(for metric: SystemMetric) -> SystemMonitorTile.Reading {
        let sample = monitor.sample
        switch metric {
        case .cpu:
            return .init(
                number: (sample.cpu ?? 0) * 100,
                format: .percent,
                detail: String(localized: "\(ProcessInfo.processInfo.activeProcessorCount) cores"),
                fraction: sample.cpu ?? 0,
                ready: sample.cpu != nil
            )
        case .memory:
            let used = SystemMonitor.memory(sample.memoryUsed)
            let total = SystemMonitor.memory(sample.memoryTotal)
            return .init(
                number: (sample.memoryFraction ?? 0) * 100,
                format: .percent,
                detail: String(localized: "\(used) of \(total)"),
                fraction: sample.memoryFraction ?? 0,
                ready: sample.memoryFraction != nil
            )
        case .storage:
            return .init(
                number: (sample.storageUsedFraction ?? 0) * 100,
                format: .percent,
                detail: sample.storageAvailable.map { String(localized: "\(SystemMonitor.bytes($0)) free") } ?? "",
                fraction: sample.storageUsedFraction ?? 0,
                ready: sample.storageUsedFraction != nil
            )
        case .battery:
            return .init(
                number: Double(battery.levelBattery),
                format: .percent,
                detail: batteryDetail,
                fraction: Double(battery.levelBattery) / 100,
                ready: true,
                symbol: batterySymbol
            )
        case .download:
            return .init(
                number: sample.download ?? 0,
                format: .rate,
                detail: String(localized: "Peak \(SystemMonitor.rate(monitor.downloadScale))"),
                fraction: min(1, (sample.download ?? 0) / monitor.downloadScale),
                ready: sample.download != nil
            )
        case .upload:
            return .init(
                number: sample.upload ?? 0,
                format: .rate,
                detail: String(localized: "Peak \(SystemMonitor.rate(monitor.uploadScale))"),
                fraction: min(1, (sample.upload ?? 0) / monitor.uploadScale),
                ready: sample.upload != nil
            )
        }
    }

    private var batterySymbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.levelBattery {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryDetail: String {
        if battery.isCharging {
            if battery.timeToFullCharge > 0 {
                return String(localized: "Full in \(SystemMonitor.duration(minutes: battery.timeToFullCharge))")
            }
            return String(localized: "Charging")
        }
        if battery.isPluggedIn { return String(localized: "Plugged in") }
        if battery.timeToDischarge > 0 {
            return String(localized: "\(SystemMonitor.duration(minutes: battery.timeToDischarge)) left")
        }
        return String(localized: "On battery")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.gray)
            Text("Choose what to monitor in Settings")
                .font(.system(.title3, design: .rounded))
                .fontWeight(.medium)
                .foregroundStyle(.gray)
        }
    }
}

enum SystemMetric: Hashable {
    case cpu, memory, storage, battery, download, upload

    var title: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .battery: "Battery"
        case .download: "Download"
        case .upload: "Upload"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .battery: "battery.100percent"
        case .download: "arrow.down"
        case .upload: "arrow.up"
        }
    }
}

// MARK: - Cartão

struct SystemMonitorTile: View {
    struct Reading: Equatable {
        enum Format: Equatable { case percent, rate }

        /// Valor que os números "contam" (0–100 em %, bytes/s na rede).
        var number: Double
        var format: Format
        var detail: String
        var fraction: Double
        /// Já tem leitura? Antes disso o número mostra "—".
        var ready: Bool
        /// Ícone próprio (bateria muda com o nível).
        var symbol: String?
    }

    let metric: SystemMetric
    let reading: Reading
    let appeared: Bool
    /// Posição na cascata de entrada.
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cartão chega: desfoque → nítido, sobe um pouco, com mola suave.
    private var entrance: Animation {
        reduceMotion ? .smooth(duration: 0.2)
            : .spring(response: 0.6, dampingFraction: 0.82).delay(Double(order) * 0.06)
    }

    /// Barra e número juntos, logo depois do cartão.
    private var fill: Animation {
        reduceMotion ? .smooth(duration: 0.2)
            : .spring(response: 1.0, dampingFraction: 0.86).delay(0.1 + Double(order) * 0.07)
    }

    private var shownNumber: Double { appeared && reading.ready ? reading.number : 0 }
    private var shownFraction: Double { appeared ? reading.fraction : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: reading.symbol ?? metric.symbol)
                    // Bateria é um símbolo largo: um ponto menor para caber na mesma coluna.
                    .font(.system(size: metric == .battery ? 10.5 : 12, weight: .medium))
                    .foregroundStyle(.gray)
                    .frame(width: 18)
                    .contentTransition(.symbolEffect(.replace))
                Text(metric.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .fixedSize()  // nomes curtos: sempre inteiros
                Spacer(minLength: 4)
                Group {
                    if reading.ready || !appeared {
                        CountingText(value: shownNumber, format: reading.format)
                    } else {
                        Text(verbatim: "—")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .animation(.smooth(duration: 0.6), value: reading.number)
                .animation(fill, value: appeared)
            }

            // Alinhado ao nome (ícone de 18 + espaço de 6).
            Text(verbatim: reading.detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray.opacity(0.8))
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.4), value: reading.detail)
                .padding(.leading, 24)

            Spacer(minLength: 0)

            SystemMonitorBar(fraction: shownFraction)
                .animation(.smooth(duration: 0.6), value: reading.fraction)
                .animation(fill, value: appeared)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .blur(radius: appeared || reduceMotion ? 0 : 6)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .animation(entrance, value: appeared)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(metric.title))
        .accessibilityValue(Text(verbatim: "\(CountingText.string(reading.number, reading.format)), \(reading.detail)"))
    }
}

/// Número que conta até o valor (interpolado a cada quadro pela animação), com a
/// unidade menor e em cinza ao lado — "36 %", "23,9 MB/s" — como nos apps da Apple.
struct CountingText: View, Animatable {
    var value: Double
    let format: SystemMonitorTile.Reading.Format

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let parts = Self.parts(value, format)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: parts.number)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(verbatim: parts.unit)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.gray)
        }
    }

    static func string(_ value: Double, _ format: SystemMonitorTile.Reading.Format) -> String {
        let parts = parts(value, format)
        return format == .percent ? "\(parts.number)\(parts.unit)" : "\(parts.number) \(parts.unit)"
    }

    static func parts(_ value: Double, _ format: SystemMonitorTile.Reading.Format) -> (number: String, unit: String) {
        switch format {
        case .percent: ("\(Int(value.rounded()))", "%")
        case .rate: SystemMonitor.rateParts(value)
        }
    }
}

/// A barra do player de música: trilho cinza, 4 pt, cantos redondos, preenchimento branco.
struct SystemMonitorBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                Capsule()
                    .fill(Color.white)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
    }
}

/// Botão do cabeçalho, no mesmo formato dos vizinhos (cápsula preta de 30 pt).
/// Aberto, ganha o fundo da aba selecionada.
struct SystemMonitorHeaderButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isActive ? Color(nsColor: .secondarySystemFill) : Color.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .foregroundColor(.white)
                        .padding()
                        .imageScale(.medium)
                }
                .animation(.smooth(duration: 0.3), value: isActive)
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text("System monitor"))
        .accessibilityLabel(Text("System monitor"))
    }
}
