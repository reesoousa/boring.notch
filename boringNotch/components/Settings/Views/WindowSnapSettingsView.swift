//
//  WindowSnapSettingsView.swift
//  boringCode
//
//  Ajustes do encaixe de janelas pelo notch.
//

import Defaults
import SwiftUI

struct WindowSnapSettingsView: View {
    @Default(.windowSnapEnabled) private var enabled
    @Default(.windowSnapHiddenLayouts) private var hiddenLayouts
    /// Quem move as janelas é o helper, então vale a permissão dele (a mesma das notificações).
    @State private var isTrusted = true

    var body: some View {
        Form {
            if !isTrusted {
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: AccessibilityPermission.systemImageName)
                            .font(.title)
                            .foregroundStyle(Color.effectiveAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(AccessibilityPermission.displayName) Required")
                                .font(.headline)
                            Text("Grant \(AccessibilityPermission.displayName) to move and resize windows.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant Access") {
                            Task {
                                isTrusted = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            }
                        }
                    }
                }
            }

            Section {
                Defaults.Toggle(key: .windowSnapEnabled) {
                    Text("Snap windows dragged to the notch")
                }
            } footer: {
                Text("Drag a window by its title bar up to the notch, then drop it on a layout. To keep dragging normally, just move away from the notch.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                ForEach(SnapLayout.all) { layout in
                    Toggle(isOn: binding(for: layout)) {
                        HStack(spacing: 10) {
                            WindowSnapLayoutGlyph(layout: layout)
                                .frame(width: 32, height: 20)
                            Text(verbatim: layout.title)
                        }
                    }
                }
            } header: {
                Text("Layouts")
            }
            .disabled(!enabled)

            Section {
                Defaults.Toggle(key: .windowSnapAnimate) {
                    Text("Slide windows into place")
                }
                Defaults.Toggle(key: .windowSnapMargins) {
                    Text("Leave margins between windows")
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("With Reduce Motion on, windows jump straight to their place.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Window Snapping")
        .task { isTrusted = await XPCHelperClient.shared.isAccessibilityAuthorized() }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { notification in
            if let granted = notification.userInfo?["granted"] as? Bool { isTrusted = granted }
        }
    }

    private func binding(for layout: SnapLayout) -> Binding<Bool> {
        Binding(
            get: { !hiddenLayouts.contains(layout.id) },
            set: { visible in
                if visible {
                    hiddenLayouts.removeAll { $0 == layout.id }
                } else if !hiddenLayouts.contains(layout.id) {
                    hiddenLayouts.append(layout.id)
                }
            }
        )
    }
}

/// Miniatura do layout nos Ajustes (mesmo desenho do notch, em tons do sistema).
private struct WindowSnapLayoutGlyph: View {
    let layout: SnapLayout

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                ForEach(layout.zones) { zone in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(
                            width: max(0, (size.width - 4) * zone.rect.width - 1.5),
                            height: max(0, (size.height - 4) * zone.rect.height - 1.5)
                        )
                        .offset(
                            x: 2 + (size.width - 4) * zone.rect.minX + 0.75,
                            y: 2 + (size.height - 4) * zone.rect.minY + 0.75
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
