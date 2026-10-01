//
//  FeatureRequestView.swift
//  boringCode
//
//  Uma tela do onboarding por recurso: pergunta se você quer usar e, no "sim", já
//  liga o recurso e pede a permissão do sistema que ele precisa. Mostra o que está
//  acontecendo (pedindo, esperando você nos Ajustes, pronto) e segue sozinha.
//  Substitui a tela de permissões do Boring Notch, que só pedia acesso.
//

import SwiftUI

enum FeatureRequestStatus: Equatable {
    case idle
    /// Pedido aberto (diálogo do sistema na frente).
    case working
    /// Esperando você ligar o boringCode nos Ajustes do Sistema.
    case waitingForSettings
    case done
}

struct FeatureRequestView<Options: View>: View {
    typealias Status = FeatureRequestStatus

    let icon: Image
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let privacyNote: LocalizedStringKey?
    let primaryTitle: LocalizedStringKey
    /// Posição nas telas de recursos (0…total-1), para os pontinhos.
    let step: Int
    let total: Int
    @Binding var status: Status
    let onPrimary: () -> Void
    let onSkip: () -> Void
    /// Abre o painel certo dos Ajustes quando a permissão tem que ser ligada lá.
    var onOpenSettings: (() -> Void)?
    @ViewBuilder var options: () -> Options

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            ZStack {
                if status == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    icon
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.effectiveAccent)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .frame(width: 70, height: 56)
            .animation(reduceMotion ? .smooth(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.7), value: status)
            .padding(.bottom, 22)

            Text(title)
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)

            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            options()
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .disabled(status != .idle)

            if let privacyNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                    Text(privacyNote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
                .padding(.top, 18)
            }

            Spacer(minLength: 16)

            statusLine
                .frame(minHeight: 40)
                .animation(.smooth(duration: 0.25), value: status)

            HStack(spacing: 10) {
                Button(status == .waitingForSettings ? "Skip" : "Not Now", action: onSkip)
                    .buttonStyle(.bordered)
                    .disabled(status == .working || status == .done)
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(status != .idle)
            }
            .controlSize(.large)
            .padding(.top, 6)

            OnboardingProgressDots(step: step, total: total)
                .padding(.top, 18)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            ProgressView()
                .controlSize(.small)
        case .waitingForSettings:
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Turn on boringCode in System Settings, then come back here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onOpenSettings {
                    Button("Open System Settings", action: onOpenSettings)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 28)
            .transition(.opacity)
        case .done:
            Text("All set")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .transition(.opacity)
        }
    }
}

extension FeatureRequestView where Options == EmptyView {
    init(
        icon: Image,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        privacyNote: LocalizedStringKey?,
        primaryTitle: LocalizedStringKey,
        step: Int,
        total: Int,
        status: Binding<Status>,
        onPrimary: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.init(
            icon: icon, title: title, description: description, privacyNote: privacyNote,
            primaryTitle: primaryTitle, step: step, total: total, status: status,
            onPrimary: onPrimary, onSkip: onSkip, onOpenSettings: nil, options: { EmptyView() }
        )
    }
}

/// Uma linha de escolha (caixinha + ícone + nome + explicação curta).
struct FeatureOptionRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.effectiveAccent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isOn ? 0.07 : 0.03))
        )
        .animation(.smooth(duration: 0.2), value: isOn)
    }
}

/// Pontinhos de progresso: o atual vira uma cápsula.
struct OnboardingProgressDots: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(index == step ? Color.effectiveAccent : Color.primary.opacity(0.18))
                    .frame(width: index == step ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(step + 1) of \(total)"))
    }
}
