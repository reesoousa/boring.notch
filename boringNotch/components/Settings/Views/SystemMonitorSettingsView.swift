//
//  SystemMonitorSettingsView.swift
//  boringCode
//
//  Ajustes do monitor do sistema (CPU, armazenamento, download e upload).
//

import Defaults
import SwiftUI

struct SystemMonitorSettingsView: View {
    @Default(.monitorEnabled) private var monitorEnabled
    @Default(.monitorInterval) private var monitorInterval

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .monitorEnabled) {
                    Text("Show the system monitor in the notch")
                }
            } footer: {
                Text("Adds a button next to the mirror in the open notch.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Defaults.Toggle(key: .monitorShowCPU) { Text("CPU") }
                Defaults.Toggle(key: .monitorShowStorage) { Text("Storage") }
                Defaults.Toggle(key: .monitorShowDownload) { Text("Download") }
                Defaults.Toggle(key: .monitorShowUpload) { Text("Upload") }
            } header: {
                Text("Metrics")
            }
            .disabled(!monitorEnabled)

            Section {
                Picker("Update every", selection: $monitorInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Updates")
            } footer: {
                Text("Readings only happen while the monitor is open, so it costs nothing in the background.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .disabled(!monitorEnabled)
        }
        .formStyle(.grouped)
        .navigationTitle("System Monitor")
    }
}
