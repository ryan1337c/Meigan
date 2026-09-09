//
//  EditPersonalInfoView.swift
//  Meigan
//
//  Lets a signed-in user edit their first / last name, syncing to Supabase.
//

import SwiftUI

struct EditPersonalInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var subscriptions: SubscriptionManager

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: PersonalInfoField?

    private enum PersonalInfoField: Hashable {
        case firstName
        case lastName
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    avatar

                    VStack(spacing: 0) {
                        PersonalInfoFieldRow(
                            title: "First Name",
                            placeholder: "First name",
                            text: $firstName,
                            textContentType: .givenName
                        )
                        .focused($focusedField, equals: .firstName)

                        Divider().padding(.leading, 18)

                        PersonalInfoFieldRow(
                            title: "Last Name",
                            placeholder: "Last name",
                            text: $lastName,
                            textContentType: .familyName
                        )
                        .focused($focusedField, equals: .lastName)
                    }
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)

            if isLoading {
                ProgressView()
                    .padding(18)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Personal Info")
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                }
                .disabled(isSaving)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark")
                            .font(.headline)
                    }
                }
                .disabled(!canSave || isSaving || isLoading)
            }
        }
        .task { await loadName() }
    }

    private var avatar: some View {
        AvatarBadge(initial: avatarInitial)
            .scaleEffect(2.8)
            .frame(width: 116, height: 116)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 6)
            .padding(.top, 8)
    }

    private var avatarInitial: String {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let char = trimmedFirst.first {
            return String(char).uppercased()
        }
        return "?"
    }

    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Data

    private func loadName() async {
        firstName = settings.firstName
        lastName = settings.lastName
        errorMessage = nil

        do {
            let profileName = try await subscriptions.fetchProfile()
            let fetchedFirst = profileName.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fetchedLast = profileName.lastName.trimmingCharacters(in: .whitespacesAndNewlines)

            if !fetchedFirst.isEmpty || !fetchedLast.isEmpty {
                firstName = fetchedFirst
                lastName = fetchedLast
            }
        } catch {
            errorMessage = "Could not refresh your profile. Showing saved info."
        }

        isLoading = false
    }

    private func save() {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFirst.isEmpty, !trimmedLast.isEmpty else { return }

        isSaving = true
        errorMessage = nil
        focusedField = nil

        Task {
            do {
                try await subscriptions.updateProfile(
                    firstName: trimmedFirst,
                    lastName: trimmedLast
                )
                settings.firstName = trimmedFirst
                settings.lastName = trimmedLast
                dismiss()
            } catch {
                errorMessage = "Could not save your changes. Please try again."
            }
            isSaving = false
        }
    }
}

// MARK: - Field row

private struct PersonalInfoFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let textContentType: UITextContentType

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundColor(.secondary)

            TextField(placeholder, text: $text)
                .textContentType(textContentType)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.body)
                .foregroundColor(.primary)
                .submitLabel(.done)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
