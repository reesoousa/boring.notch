//
//  OnboardingView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI
import AVFoundation
import Defaults
import Sparkle

enum OnboardingStep: Hashable {
    case welcome
    // boringCode: uma tela por recurso — pergunta se quer usar e já pede a permissão.
    case agents
    case windowControl
    case localSend
    case cameraPermission
    case calendarPermission
    case audioCapturePermission
    case musicPermission
    case softwareUpdatePermission
    case finished
}

private let calendarService = CalendarService()

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let updater: SPUUpdater?
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    typealias Status = FeatureRequestStatus
    @State private var status: Status = .idle

    // Escolhas da tela de Acessibilidade (o encaixe já vem marcado, como no app).
    @State private var wantsWindowSnap = Defaults[.windowSnapEnabled]
    @State private var wantsNotifications = Defaults[.notificationLiveActivity]
    @State private var wantsOSD = Defaults[.osdReplacement]
    @State private var accessibilityAlreadyGranted = false
    @State private var authorizationPoll: Task<Void, Never>?

    /// Telas de recurso, na ordem (a de áudio só existe a partir do macOS 14.2).
    private var featureSteps: [OnboardingStep] {
        var steps: [OnboardingStep] = [.agents, .windowControl, .localSend, .cameraPermission, .calendarPermission]
        if #available(macOS 14.2, *) { steps.append(.audioCapturePermission) }
        return steps
    }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    go(to: .agents)
                }
                .transition(.opacity)

            case .agents:
                FeatureRequestView(
                    icon: Image(systemName: "apple.terminal"),
                    title: "Your AI agents in the notch",
                    description: "Follow Claude Code and Codex while they work, approve requests and answer questions right in the notch, and jump back to the right terminal with a click.",
                    privacyNote: "boringCode adds a hook to the Claude Code and Codex settings (with a backup). Nothing leaves your Mac.",
                    primaryTitle: "Use Agents",
                    step: index(of: .agents), total: featureSteps.count,
                    status: $status,
                    onPrimary: {
                        Defaults[.agentsEnabled] = true
                        AgentSessionStore.shared.start()
                        finishStep()
                    },
                    onSkip: {
                        Defaults[.agentsEnabled] = false
                        advance()
                    }
                )
                .transition(.opacity)

            case .windowControl:
                FeatureRequestView(
                    icon: Image(systemName: "rectangle.split.2x1"),
                    title: "Windows and system controls",
                    description: "These features need \(AccessibilityPermission.displayName) to move windows and read alerts from other apps. Choose the ones you want:",
                    privacyNote: "\(AccessibilityPermission.displayName) is used only for these features. No data is collected or shared.",
                    primaryTitle: windowControlPrimaryTitle,
                    step: index(of: .windowControl), total: featureSteps.count,
                    status: $status,
                    onPrimary: confirmWindowControl,
                    onSkip: {
                        stopAuthorizationPoll()
                        advance()
                    },
                    onOpenSettings: openAccessibilitySettings
                ) {
                    VStack(spacing: 6) {
                        FeatureOptionRow(
                            symbol: "rectangle.split.2x1",
                            title: "Snap windows",
                            detail: "Drag a window to the notch and choose where it goes.",
                            isOn: $wantsWindowSnap
                        )
                        FeatureOptionRow(
                            symbol: "bell.badge",
                            title: "Notifications in the notch",
                            detail: "Shows alerts from your apps in the notch.",
                            isOn: $wantsNotifications
                        )
                        FeatureOptionRow(
                            symbol: "dial.medium",
                            title: "Volume and brightness",
                            detail: "Replaces the system indicator with the notch one.",
                            isOn: $wantsOSD
                        )
                    }
                }
                .task { accessibilityAlreadyGranted = await XPCHelperClient.shared.isAccessibilityAuthorized() }
                .transition(.opacity)

            case .localSend:
                FeatureRequestView(
                    icon: Image(systemName: "iphone.gen3.radiowaves.left.and.right"),
                    title: "Share files with your phone",
                    description: "Send and receive files with iPhone and Android through LocalSend, right from the Shelf, without opening another app. Received files go to Downloads.",
                    privacyNote: "Everything stays on your local network, encrypted. macOS will ask for Local Network access.",
                    primaryTitle: "Use LocalSend",
                    step: index(of: .localSend), total: featureSteps.count,
                    status: $status,
                    onPrimary: {
                        Defaults[.localSendEnabled] = true
                        // Começa a procurar aparelhos agora: é o que faz o macOS pedir a Rede Local.
                        LocalSendService.shared.start()
                        finishStep()
                    },
                    onSkip: {
                        Defaults[.localSendEnabled] = false
                        advance()
                    }
                )
                .transition(.opacity)

            case .cameraPermission:
                FeatureRequestView(
                    icon: Image(systemName: "web.camera"),
                    title: "A mirror in the notch",
                    description: "Check your look before a call with a live camera preview, right from the notch.",
                    privacyNote: "The camera only turns on while the mirror is open. Nothing is recorded or stored.",
                    primaryTitle: "Use Mirror",
                    step: index(of: .cameraPermission), total: featureSteps.count,
                    status: $status,
                    onPrimary: {
                        status = .working
                        Task {
                            let granted = await AVCaptureDevice.requestAccess(for: .video)
                            Defaults[.showMirror] = granted
                            granted ? finishStep() : advance()
                        }
                    },
                    onSkip: {
                        Defaults[.showMirror] = false
                        advance()
                    }
                )
                .transition(.opacity)

            case .calendarPermission:
                FeatureRequestView(
                    icon: Image(systemName: "calendar"),
                    title: "Your day at a glance",
                    description: "See your upcoming events and reminders in the open notch.",
                    privacyNote: "Your calendar and reminders are only used to show your schedule and are never shared.",
                    primaryTitle: "Use Calendar",
                    step: index(of: .calendarPermission), total: featureSteps.count,
                    status: $status,
                    onPrimary: {
                        status = .working
                        Task {
                            let events = (try? await calendarService.requestAccess(to: .event)) ?? false
                            _ = try? await calendarService.requestAccess(to: .reminder)
                            Defaults[.showCalendar] = events
                            events ? finishStep() : advance()
                        }
                    },
                    onSkip: {
                        Defaults[.showCalendar] = false
                        advance()
                    }
                )
                .transition(.opacity)

            case .audioCapturePermission:
                FeatureRequestView(
                    icon: Image(systemName: "waveform"),
                    title: "A live visualizer",
                    description: "boringCode can analyze the audio playing from your music app to draw a live waveform in the notch, with only a minimal impact on CPU usage.",
                    privacyNote: "Audio is processed locally for the visualizer and never recorded, stored, or shared.",
                    primaryTitle: "Use Visualizer",
                    step: index(of: .audioCapturePermission), total: featureSteps.count,
                    status: $status,
                    onPrimary: {
                        status = .working
                        Task {
                            let granted = await AudioCaptureManager.shared.requestAudioCapturePermission()
                            if granted { Defaults[.realtimeAudioWaveform] = true }
                            granted ? finishStep() : advance()
                        }
                    },
                    onSkip: advance
                )
                .transition(.opacity)

            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
                        if BoringViewCoordinator.shared.firstLaunch {
                            go(to: .softwareUpdatePermission)
                        } else {
                            go(to: .finished)
                        }
                    }
                )
                .transition(.opacity)

            case .softwareUpdatePermission:
                SoftwareUpdatePermissionView(
                    updater: updater,
                    onContinue: {
                        BoringViewCoordinator.shared.firstLaunch = false
                        go(to: .finished)
                    }
                )
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
            }
        }
        .frame(width: 400, height: 640)
        .onDisappear(perform: stopAuthorizationPoll)
    }

    // MARK: - Navegação

    private func index(of step: OnboardingStep) -> Int {
        featureSteps.firstIndex(of: step) ?? 0
    }

    private func go(to next: OnboardingStep) {
        status = .idle
        withAnimation(.easeInOut(duration: 0.6)) { step = next }
    }

    /// Próxima tela de recurso; depois delas, a escolha do player de música.
    private func advance() {
        guard let current = featureSteps.firstIndex(of: step), current + 1 < featureSteps.count else {
            go(to: .musicPermission)
            return
        }
        go(to: featureSteps[current + 1])
    }

    /// Mostra o "pronto" um instante e segue.
    private func finishStep() {
        withAnimation { status = .done }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(850))
            advance()
        }
    }

    // MARK: - Acessibilidade

    private var needsAccessibility: Bool { wantsWindowSnap || wantsNotifications || wantsOSD }

    private var windowControlPrimaryTitle: LocalizedStringKey {
        needsAccessibility && !accessibilityAlreadyGranted ? "Allow Access" : "Continue"
    }

    private func confirmWindowControl() {
        Defaults[.windowSnapEnabled] = wantsWindowSnap
        Defaults[.notificationLiveActivity] = wantsNotifications
        Defaults[.osdReplacement] = wantsOSD

        guard needsAccessibility, !accessibilityAlreadyGranted else {
            needsAccessibility ? finishStep() : advance()
            return
        }
        // O macOS mostra o aviso com o botão para os Ajustes; a permissão é ligada lá.
        // A janela sai do modo flutuante para não cobrir os Ajustes.
        XPCHelperClient.shared.requestAccessibilityAuthorization()
        setOnboardingWindowFloating(false)
        status = .waitingForSettings
        authorizationPoll?.cancel()
        authorizationPoll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if await XPCHelperClient.shared.isAccessibilityAuthorized() {
                    setOnboardingWindowFloating(true)
                    NSApp.activate(ignoringOtherApps: true)
                    finishStep()
                    return
                }
            }
        }
    }

    private func stopAuthorizationPoll() {
        authorizationPoll?.cancel()
        authorizationPoll = nil
        setOnboardingWindowFloating(true)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setOnboardingWindowFloating(_ floating: Bool) {
        NSApp.windows
            .first { $0.identifier?.rawValue == "OnboardingWindow" }?
            .level = floating ? .floating : .normal
    }
}

struct SoftwareUpdatePermissionView: View {
    let updater: SPUUpdater?
    let onContinue: () -> Void

    @State private var automaticallyChecksForUpdates = true
    @State private var automaticallyDownloadsUpdates = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.effectiveAccent)

            Text("Keep Boring Notch Updated")
                .font(.title)
                .fontWeight(.semibold)

            Text("Boring Notch can check for updates in the background. You can still check manually from the menu bar at any time.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 34)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Check for updates automatically", isOn: $automaticallyChecksForUpdates)

                Toggle("Download and install updates automatically", isOn: $automaticallyDownloadsUpdates)
                    .disabled(!automaticallyChecksForUpdates)
                    .opacity(automaticallyChecksForUpdates ? 1 : 0.45)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 44)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Button("Continue") {
                applyUpdatePreference(
                    checksAutomatically: automaticallyChecksForUpdates,
                    downloadsAutomatically: automaticallyChecksForUpdates && automaticallyDownloadsUpdates
                )
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onChange(of: automaticallyChecksForUpdates) { _, enabled in
            if !enabled {
                automaticallyDownloadsUpdates = false
            }
        }
    }

    private func applyUpdatePreference(checksAutomatically: Bool, downloadsAutomatically: Bool) {
        guard let updater else {
            UserDefaults.standard.set(checksAutomatically, forKey: "SUEnableAutomaticChecks")
            UserDefaults.standard.set(downloadsAutomatically, forKey: "SUAutomaticallyUpdate")
            return
        }

        updater.automaticallyChecksForUpdates = checksAutomatically
        updater.automaticallyDownloadsUpdates = downloadsAutomatically
    }
}
