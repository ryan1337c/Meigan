//
//  RegisterView.swift
//  Meigan
//
//  Email + password account creation. Shared field components live in
//  `AuthFieldComponents.swift`.
//

import SwiftUI
import Supabase

struct RegisterView: View {
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCheckEmailBanner = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 28) {

                    // Header
                    VStack(spacing: 6) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .padding(.bottom, 4)

                        Text("Create your account")
                            .font(.title2.weight(.bold))
                    }
                    .padding(.top, 32)

                    if let errorMessage {
                        AuthErrorBanner(message: errorMessage)
                    }

                    // Fields
                    VStack(spacing: 20) {
                        HStack(alignment: .top, spacing: 12) {
                            AuthLabeledTextField(
                                title: "First name",
                                placeholder: "Andrew",
                                text: $firstName,
                                textContentType: .givenName,
                                autocapitalization: .words
                            )

                            AuthLabeledTextField(
                                title: "Last name",
                                placeholder: "Smith",
                                text: $lastName,
                                textContentType: .familyName,
                                autocapitalization: .words
                            )
                        }

                        AuthLabeledTextField(
                            title: "Email",
                            placeholder: "user@email.com",
                            text: $email,
                            keyboardType: .emailAddress,
                            textContentType: .emailAddress
                        )

                        AuthLabeledSecureField(
                            title: "Password",
                            placeholder: "••••••••",
                            text: $password,
                            isVisible: $isPasswordVisible,
                            textContentType: .newPassword
                        )

                        if !password.isEmpty {
                            PasswordStrengthIndicator(password: password)
                        }
                    }

                    // Create account button
                    Button {
                        createAccount()
                    } label: {
                        Group {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Create account")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                    .disabled(!isFormValid || isLoading)
                    .opacity(isFormValid ? 1 : 0.5)

                    // Already have an account
                    HStack(spacing: 4) {
                        Text("Already have an account?")
                            .font(.subheadline)
                            .foregroundColor(Color(UIColor.secondaryLabel))
                        Button("Log in") { dismiss() }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemGroupedBackground))

            if showCheckEmailBanner {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.fill")
                        .font(.body.weight(.semibold))
                    Text("Check your email to confirm your account")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onOpenURL { _ in
            firstName = ""
            lastName = ""
            email = ""
            password = ""
            errorMessage = nil
            showCheckEmailBanner = false
            dismiss()
        }
        .onDisappear {
            firstName = ""
            lastName = ""
            email = ""
            password = ""
            isPasswordVisible = false
            errorMessage = nil
            isLoading = false
            showCheckEmailBanner = false
        }
    }

    // MARK: - Helpers

    private var isFormValid: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    // MARK: - Actions

    private func createAccount() {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFirst.isEmpty, !trimmedLast.isEmpty, !trimmedEmail.isEmpty, !password.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await supabase.auth.signUp(
                    email: trimmedEmail,
                    password: password
                )

                if response.user.identities?.isEmpty ?? true {
                    throw AuthClientError.emailAlreadyExists
                }

                await MainActor.run {
                    settings.firstName = trimmedFirst
                    settings.lastName = trimmedLast
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showCheckEmailBanner = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showCheckEmailBanner = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = userFacingMessage(from: error)
                }
            }
            await MainActor.run { isLoading = false }
        }
    }
}

#Preview("Register") {
    NavigationStack {
        RegisterView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
}
