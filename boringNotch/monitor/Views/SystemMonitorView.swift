//
//  SystemMonitorView.swift
//  boringCode
//
//  Aba do monitor: CPU, armazenamento, download e upload em cartões 2×2 no
//  visual do app (cinza/branco, cantos 12, barra do player). As barras entram
//  crescendo em sequência, com mola suave; depois acompanham as leituras.
//

import Defaults
import SwiftUI

struct SystemMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @Default(.monitorShowCPU) private var showCPU
    @Default(.monitorShowStorage) private var showStorage
    @Default(.monitorShowDownload) private var showDownload
    @Default(.monitorShowUpload) private var showUpload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false

    private var metrics: [SystemMetric] {
        [
            showCPU ? .cpu : nil,
            showStorage ? .storage : nil,
            showDownload ? .download : nil,
            showUpload ? .upload : nil,
        ].compactMap { $0 }
    }

    /// Linhas de dois; sobrando um, ele ocupa a linha inteira.
    private var rows: [[SystemMetric]] {
        stride(from: 0, to: metrics.count, by: 2).map { Array(metrics[$0..<min($0 + 2, metrics.count)]) }
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
                                    order: rowIndex * 2 + columnIndex
                                )
                            }
                        }
                    }
                }
                .animation(.smooth(duration: 0.5), value: monitor.sample)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            monitor.begin()
            if reduceMotion {
                appeared = true
            } else {
                // Um quadro depois, para as barras saírem do zero.
                DispatchQueue.main.async { appeared = true }
            }
        }
        .onDisappear {
            monitor.end()
            appeared = false
        }
    }

    private func reading(for metric: SystemMetric) -> SystemMonitorTile.Reading {
        let sample = monitor.sample
        switch metric {
        case .cpu:
            return .init(
                value: sample.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                detail: String(localized: "\(ProcessInfo.processInfo.activeProcessorCount) cores"),
                fraction: sample.cpu ?? 0
            )
        case .storage:
            return .init(
                value: sample.storageUsedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                detail: sample.storageAvailable.map { String(localized: "\(SystemMonitor.bytes($0)) free") } ?? "",
                fraction: sample.storageUsedFraction ?? 0
            )
        case .download:
            return .init(
                value: SystemMonitor.rate(sample.download),
                detail: String(localized: "Peak \(SystemMonitor.rate(monitor.downloadScale))"),
                fraction: min(1, (sample.download ?? 0) / monitor.downloadScale)
            )
        case .upload:
            return .init(
                value: SystemMonitor.rate(sample.upload),
                detail: String(localized: "Peak \(SystemMonitor.rate(monitor.uploadScale))"),
                fraction: min(1, (sample.upload ?? 0) / monitor.uploadScale)
            )
        }
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
    case cpu, storage, download, upload

    var title: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .storage: "Storage"
        case .download: "Download"
        case .upload: "Upload"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .storage: "internaldrive"
        case .download: "arrow.down"
        case .upload: "arrow.up"
        }
    }
}

struct SystemMonitorTile: View {
    struct Reading: Equatable {
        var value: String
        var detail: String
        var fraction: Double
    }

    let metric: SystemMetric
    let reading: Reading
    let appeared: Bool
    /// Posição na grade: cada cartão entra um pouco depois do anterior.
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entrance: Animation {
        reduceMotion ? .smooth(duration: 0.2)
            : .spring(response: 0.55, dampingFraction: 0.86).delay(Double(order) * 0.05)
    }

    private var barEntrance: Animation {
        reduceMotion ? .smooth(duration: 0.2)
            : .spring(response: 0.9, dampingFraction: 0.88).delay(0.12 + Double(order) * 0.07)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
                    .frame(width: 16)
                Text(metric.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.gray)
                Spacer(minLength: 6)
                Text(verbatim: reading.value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }

            // Alinhado ao nome (ícone de 16 + espaço de 6).
            Text(verbatim: reading.detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray.opacity(0.8))
                .lineLimit(1)
                .contentTransition(.numericText())
                .padding(.leading, 22)

            Spacer(minLength: 0)

            SystemMonitorBar(fraction: appeared ? reading.fraction : 0)
                .animation(appeared ? .smooth(duration: 0.6) : nil, value: reading.fraction)
                .animation(barEntrance, value: appeared)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 6)
        .animation(entrance, value: appeared)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(metric.title))
        .accessibilityValue(Text(verbatim: "\(reading.value), \(reading.detail)"))
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
