//
//  ClipboardSettingsView.swift
//  boringCode
//
//  Ajustes do histórico do clipboard: ligar, permissão do macOS, quantos itens
//  guardar, colar direto ao escolher e o atalho.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct ClipboardSettingsView: View {
    @ObservedObject private var history = ClipboardHistory.shared
    @Default(.clipboardEnabled) private var clipboardEnabled
    @Default(.clipboardHistoryLimit) private var historyLimit
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .clipboardEnabled) {
                    Text("Keep a clipboard history")
                }
            } footer: {
                Text("Adds a Clipboard tab to the open notch with what you copied recently: text, links, images and files.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                HStack {
                    Label {
                        Text(accessTitle)
                    } icon: {
                        Image(systemName: history.access == .allowed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(history.access == .allowed ? .green : .orange)
                    }
                    Spacer()
                    if history.access != .allowed {
                        Button(history.access == .notRequested ? "Allow Access" : "Go to Settings") {
                            Task { await history.requestAccess() }
                        }
                        .disabled(history.isRequestingAccess)
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("macOS asks before an app reads what you copy in other apps. Turn on boringCode in Privacy & Security › Paste from Other Apps so it doesn't ask on every copy.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .disabled(!clipboardEnabled)

            Section {
                Picker("Keep the last", selection: $historyLimit) {
                    Text("25 items").tag(25)
                    Text("50 items").tag(50)
                    Text("100 items").tag(100)
                    Text("200 items").tag(200)
                }
                Defaults.Toggle(key: .clipboardPasteOnSelect) {
                    Text("Paste when choosing an item")
                }
                KeyboardShortcuts.Recorder("Open clipboard:", name: .openClipboard)
            } header: {
                Text("History")
            } footer: {
                Text("Pasting uses the Accessibility permission. Without it, choosing an item only copies it. Items from password managers are never saved, and the history stays on this Mac.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .disabled(!clipboardEnabled)

            Section {
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Text("Clear History…")
                }
                .disabled(history.items.isEmpty)
                .confirmationDialog("Clear the clipboard history?", isPresented: $confirmingClear) {
                    Button("Clear History", role: .destructive) { history.clear() }
                } message: {
                    Text("This removes the \(history.items.count) saved items. What is on the clipboard now stays.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clipboard")
        .onAppear { history.refreshAccess() }
    }

    private var accessTitle: LocalizedStringKey {
        switch history.access {
        case .allowed: "boringCode can read the clipboard"
        case .notRequested: "boringCode hasn't asked for access yet"
        case .needsSettings: "Turn on boringCode in Paste from Other Apps"
        }
    }
}
