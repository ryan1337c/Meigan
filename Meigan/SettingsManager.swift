//
//  SettingsManager.swift
//  Meigan
//
//  Single source of truth for user preferences.
//  AppStorage provides instant local persistence; Supabase is the
//  cloud source of truth for authenticated users.
//

import Combine
import Foundation
import SwiftUI
import Supabase

@MainActor
final class SettingsManager: ObservableObject {

    // MARK: - User Profile

    @Published var firstName: String {
        didSet {
            guard firstName != oldValue else { return }
            defaults.set(firstName, forKey: Keys.firstName)
            pushToCloudIfNeeded()
        }
    }

    @Published var lastName: String {
        didSet {
            guard lastName != oldValue else { return }
            defaults.set(lastName, forKey: Keys.lastName)
            pushToCloudIfNeeded()
        }
    }

    // MARK: - Settings (backed by UserDefaults via AppStorage keys)

    @Published var measurementUnit: String {
        didSet {
            guard measurementUnit != oldValue else { return }
            defaults.set(measurementUnit, forKey: Keys.measurementUnit)
            pushToCloudIfNeeded()
        }
    }

    @Published var hapticFeedbackEnabled: Bool {
        didSet {
            guard hapticFeedbackEnabled != oldValue else { return }
            defaults.set(hapticFeedbackEnabled, forKey: Keys.hapticFeedback)
            pushToCloudIfNeeded()
        }
    }

    @Published var autoSaveMeasurements: Bool {
        didSet {
            guard autoSaveMeasurements != oldValue else { return }
            defaults.set(autoSaveMeasurements, forKey: Keys.autoSave)
            pushToCloudIfNeeded()
        }
    }

    // MARK: - Dependencies

    private let defaults = UserDefaults.standard
    private var isAuthenticated: Bool = false

    private enum Keys {
        static let firstName       = "meigan.firstName"
        static let lastName        = "meigan.lastName"
        static let measurementUnit = "measurementUnit"
        static let hapticFeedback  = "hapticFeedbackEnabled"
        static let autoSave        = "autoSaveMeasurements"
    }

    private enum Defaults {
        static let measurementUnit = MeasurementUnit.metric.rawValue
        static let hapticFeedback  = true
        static let autoSave        = true
    }

    // MARK: - Init

    init() {
        let d = UserDefaults.standard

        firstName             = d.string(forKey: Keys.firstName) ?? ""
        lastName              = d.string(forKey: Keys.lastName) ?? ""
        measurementUnit       = d.string(forKey: Keys.measurementUnit) ?? Defaults.measurementUnit
        hapticFeedbackEnabled = d.object(forKey: Keys.hapticFeedback) as? Bool ?? Defaults.hapticFeedback
        autoSaveMeasurements  = d.object(forKey: Keys.autoSave) as? Bool ?? Defaults.autoSave
    }

    // MARK: - Cloud Sync

    /// Call when user signs in. Fetches settings from Supabase and
    /// overwrites local values. Falls back to AppStorage if fetch fails.
    func syncFromCloud() async {
        isAuthenticated = true

        guard let userId = supabase.auth.currentSession?.user.id else { return }

        do {
            let row: UserSettings = try await supabase
                .from("profile")
                .select()
                .eq("uid", value: userId.uuidString)
                .single()
                .execute()
                .value

            firstName              = row.firstName
            lastName               = row.lastName
            measurementUnit        = row.measurementUnit
            hapticFeedbackEnabled  = row.hapticFeedback
            autoSaveMeasurements   = row.autoSave
        } catch {
            print("Settings sync from cloud failed, using local: \(error)")

            await pushInitialSettingsToCloud(userId: userId)
        }
    }

    /// Call on sign-out to stop cloud pushes and clear user-specific data.
    func markSignedOut() {
        isAuthenticated = false
        firstName = ""
        lastName = ""
        defaults.removeObject(forKey: Keys.firstName)
        defaults.removeObject(forKey: Keys.lastName)
    }

    // MARK: - Private

    /// Pushes the current local settings to Supabase in the background.
    private func pushToCloudIfNeeded() {
        guard isAuthenticated else { return }

        guard let userId = supabase.auth.currentSession?.user.id else { return }

        let userSettings = UserSettings(
            userId: userId,
            firstName: firstName,
            lastName: lastName,
            measurementUnit: measurementUnit,
            hapticFeedback: hapticFeedbackEnabled,
            autoSave: autoSaveMeasurements
        )

        Task {
            do {
                try await supabase
                    .from("profile")
                    .upsert(userSettings)
                    .execute()
            } catch {
                print("Failed to push settings to cloud: \(error)")
            }
        }
    }

    /// For first-time sign-up: push existing local settings to cloud
    /// so guest preferences carry over to the new account.
    private func pushInitialSettingsToCloud(userId: UUID) async {

        let userSettings = UserSettings(
            userId: userId,
            firstName: firstName,
            lastName: lastName,
            measurementUnit: measurementUnit,
            hapticFeedback: hapticFeedbackEnabled,
            autoSave: autoSaveMeasurements
        )

        do {
            try await supabase
                .from("profile")
                .insert(userSettings)
                .execute()
        } catch {
            print("Failed to push initial settings to cloud: \(error)")
        }
    }

    struct UserSettings: Codable {
        let userId: UUID
        let firstName: String
        let lastName: String
        let measurementUnit: String
        let hapticFeedback: Bool
        let autoSave: Bool

        enum CodingKeys: String, CodingKey {
            case userId = "uid"
            case firstName = "first_name"
            case lastName = "last_name"
            case measurementUnit = "measurement_unit"
            case hapticFeedback = "haptic_feedback"
            case autoSave = "auto_save"
        }
    }
}
