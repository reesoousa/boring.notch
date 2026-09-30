//
//  LocalSendLiveActivity.swift
//  boringCode
//
//  Notch fechado enquanto chega um arquivo pelo LocalSend: aparelho de origem
//  à esquerda, progresso à direita (vira ✓ ao terminar). Mesma geometria do
//  NotificationLiveActivity.
//

import SwiftUI

struct LocalSendLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    let transfer: LocalSendService.Incoming

    private var itemSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    var body: some View {
        HStack {
            Image(systemName: transfer.symbolName)
                .font(.system(size: itemSize * 0.6, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: itemSize, height: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            LocalSendProgressRing(transfer: transfer, size: itemSize)
                .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement()
        .accessibilityLabel(Text("Receiving from \(transfer.senderAlias)"))
    }
}

private struct LocalSendProgressRing: View {
    let transfer: LocalSendService.Incoming
    let size: CGFloat

    var body: some View {
        ZStack {
            if transfer.finished {
                // Só o símbolo, como os outros ícones do app (sem círculo atrás).
                Image(systemName: transfer.failed ? "xmark" : "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(transfer.failed ? Color.red : Color.green)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.04, transfer.fraction))
                    .stroke(Color.effectiveAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.25), value: transfer.fraction)
            }
        }
        .frame(width: size * 0.7, height: size * 0.7)
        .animation(.smooth(duration: 0.3), value: transfer.finished)
    }
}

/// Notch aberto: cápsula no cabeçalho, no formato do OSD aberto (volume/brilho) —
/// "Recebendo de…" com progresso, depois "Recebido de…" com ✓.
struct LocalSendHeaderPill: View {
    let transfer: LocalSendService.Incoming

    private var verb: String {
        if transfer.failed { return String(localized: "Couldn't receive from") }
        if transfer.finished { return String(localized: "Received from") }
        return String(localized: "Receiving from")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: transfer.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 20, alignment: .center)

            // Duas linhas, como título + subtítulo das linhas dos agentes: cabe o nome inteiro.
            VStack(alignment: .leading, spacing: 0) {
                Text(verb)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
                    .contentTransition(.opacity)
                Text(verbatim: transfer.senderAlias)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .truncationMode(.tail)
            }
            .lineLimit(1)

            LocalSendProgressRing(transfer: transfer, size: 20)
                .frame(width: 16, height: 16)
                .padding(.leading, 2)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .animation(.smooth(duration: 0.3), value: transfer.finished)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "\(verb) \(transfer.senderAlias)"))
    }
}
