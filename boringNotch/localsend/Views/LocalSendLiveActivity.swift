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
                Image(systemName: transfer.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(transfer.failed ? Color.red : Color.green)
                    .frame(width: size * 0.8, height: size * 0.8)
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
