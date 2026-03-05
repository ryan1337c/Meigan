//
//  SettingsView.swift
//  Meigan
//
//  Created by Ryan Chen on 2026-02-19.
//

import SwiftUI

enum MeasurementUnit: String, CaseIterable {
    case metric = "Metric"
    case imperial = "Imperial"

    var subtitle: String {
        switch self {
        case .metric: return "cm, m"
        case .imperial: return "in, ft"
        }
    }
}

struct SettingsView: View {
    @AppStorage("measurementUnit") private var measurementUnit: String = MeasurementUnit.metric.rawValue
    @State private var hapticFeedbackEnabled = true
    @State private var magnifierWindowEnabled = false
    @State private var autoSaveMeasurements = true

    var body: some View {
        Form {
            // Measurement Units
            Section {
                Picker("Units", selection: $measurementUnit) {
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

            // AR Precision & Feedback
            Section {
                Toggle("Haptic Feedback", isOn: $hapticFeedbackEnabled)
                Toggle("Magnifier Window", isOn: $magnifierWindowEnabled)
            } header: {
                Label("AR Precision & Feedback", systemImage: "scope")
            } footer: {
                Text("Haptic feedback vibrates when a point is placed. The magnifier helps you see exactly where you're targeting.")
            }

            // Data Management
            Section {
                Toggle("Auto-save to history", isOn: $autoSaveMeasurements)
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
}
