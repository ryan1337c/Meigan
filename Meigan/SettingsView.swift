//
//  SettingsView.swift
//  Meigan
//
//  Created by Ryan Chen on 2026-02-19.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        Form {

            Section {
                Picker("Units", selection: $settings.measurementUnit) {
                    ForEach(MeasurementUnit.allCases, id: \.rawValue) { unit in
                        Text("\(unit.rawValue) (\(unit.subtitle))")
                            .tag(unit.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Label("Measurement Units", systemImage: "ruler")
            } footer: {
                Text("Choose how distances are displayed in the app")
            }

            Section {
                Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)
            } header: {
                Label("AR Precision & Feedback", systemImage: "scope")
            } footer: {
                Text("Haptic feedback vibrates when a point is placed.")
            }

            Section {
                Toggle("Auto-save to history", isOn: $settings.autoSaveMeasurements)
                Button {
                    // TODO: Export data
                } label: {
                    Label("Export as CSV or PDF", systemImage: "square.and.arrow.up")
                }
                .foregroundStyle(.primary)
            } header: {
                Label("Data Management", systemImage: "externaldrive")
            } footer: {
                Text("Save measurements to a history log and export them for use in other apps.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
}
