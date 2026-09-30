//
//  ShelfSettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct ShelfSettingsView: View {
    @Default(.shelfTapToOpen) var shelfTapToOpen: Bool
    @Default(.quickShareProvider) var quickShareProvider
    @Default(.expandedDragDetection) var expandedDragDetection: Bool
    @StateObject private var quickShareService = QuickShareService.shared

    private var selectedProvider: QuickShareProvider? {
        quickShareService.availableProviders.first(where: { $0.id == quickShareProvider })
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .boringShelf) {
                    Text("Enable shelf")
                }
                Defaults.Toggle(key: .openShelfByDefault) {
                    Text("Open shelf by default if items are present")
                }
                Defaults.Toggle(key: .expandedDragDetection) {
                    Text("Expanded drag detection area")
                }
                .onChange(of: expandedDragDetection) {
                    NotificationCenter.default.post(
                        name: Notification.Name.expandedDragDetectionChanged,
                        object: nil
                    )
                }
                Defaults.Toggle(key: .copyOnDrag) {
                    Text("Copy items on drag")
                }
                Defaults.Toggle(key: .autoRemoveShelfItems) {
                    Text("Remove from shelf after dragging")
                }
                Defaults.Toggle(key: .reverseShelfOrdering) {
                    Text("Keep newer shelf items in front")
                }
            } header: {
                Text("General")
            }

            Section {
                Picker("Quick Share Service", selection: $quickShareProvider) {
                    ForEach(quickShareService.availableProviders, id: \.id) { provider in
                        HStack {
                            Group {
                                if let icon = quickShareService.icon(for: provider.id, size: 16) {
                                    Image(nsImage: icon)
                                        .resizable().scaledToFit()
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .frame(width: 16, height: 16)
                            .foregroundColor(.accentColor)
                            Text(provider.id)
                        }
                        .tag(provider.id)
                    }
                }
                .pickerStyle(.menu)

                if let selectedProvider = selectedProvider {
                    HStack {
                        Group {
                            if let icon = quickShareService.icon(for: selectedProvider.id, size: 16) {
                                Image(nsImage: icon)
                                    .resizable().scaledToFit()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .frame(width: 16, height: 16)
                        .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Currently selected: \(selectedProvider.id)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Files dropped on the shelf will be shared via this service")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Quick Share")
                }
            } footer: {
                Text("Choose which service to use when sharing files from the shelf. Click the shelf button to select files, or drag files onto it to share immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            LocalSendSettingsSection()
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Shelf")
    }
}

/// boringCode: LocalSend integrado (enviar e receber sem abrir o app).
private struct LocalSendSettingsSection: View {
    @Default(.localSendEnabled) private var localSendEnabled
    @Default(.localSendAlias) private var localSendAlias
    @ObservedObject private var service = LocalSendService.shared

    private var computerName: String { Host.current().localizedName ?? "boringCode" }

    var body: some View {
        Section {
            Defaults.Toggle(key: .localSendEnabled) {
                Text("Send and receive with LocalSend")
            }
            Defaults.Toggle(key: .localSendReceive) {
                Text("Receive files automatically")
            }
            .disabled(!localSendEnabled)
            TextField("Device name", text: $localSendAlias, prompt: Text(computerName))
                .disabled(!localSendEnabled)
            if localSendEnabled {
                LabeledContent("Nearby") {
                    Text(service.devices.isEmpty
                         ? String(localized: "No devices")
                         : service.devices.map(\.alias).formatted(.list(type: .and)))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } header: {
            Text(verbatim: "LocalSend")
        } footer: {
            Text("Phones and computers with LocalSend on the same network show up in the shelf's LocalSend slot — no need to open the app. Received files go to Downloads and appear on the shelf.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
