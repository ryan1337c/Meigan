//
//  LoginView.swift
//  Meigan
//
//  Traditional email + password login. Shared field components live in
//  `AuthFieldComponents.swift`.
//

import SwiftUI
import Supabase

struct LoginView: View {
    @EnvironmentObject private var appSession: AppSession

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedEmail.isEmpty && !password.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {

                // Header
                VStack(spacing: 6) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .padding(.bottom, 4)

                    Text("Sign in to Meigan")
                        .font(.title2.weight(.bold))
                }
                .padding(.top, 32)

                if let errorMessage {
                    AuthErrorBanner(message: errorMessage)
                }

                // Fields
                VStack(spacing: 20) {
                    AuthLabeledTextField(
                        title: "Email",
                        placeholder: "user@email.com",
                        text: $email,
                        keyboardType: .emailAddress,
                        textContentType: .emailAddress
                    )

                    VStack(alignment: .trailing, spacing: 10) {
                        AuthLabeledSecureField(
                            title: "Password",
                            placeholder: "••••••••",
                            text: $password,
                            isVisible: $isPasswordVisible,
                            textContentType: .password
                        )

                        NavigationLink {
                            ForgotPasswordView(prefilledEmail: email)
                        } label: {
                            Text("Forgot password?")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                    }
                }

                // Continue button
                Button {
                    signIn()
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Continue")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .foregroundColor(.white)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .disabled(!canSubmit || isLoading)
                .opacity(canSubmit ? 1 : 0.5)

                VStack(spacing: 18) {
                    // Continue as guest
                    Button {
                        appSession.continueAsGuest()
                    } label: {
                        Text("Continue as guest")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .foregroundColor(.primary)
                    .overlay(Capsule().stroke(Color.primary, lineWidth: 1.5))

                    HStack(spacing: 4) {
                        Text("Don't have an account?")
                            .font(.subheadline)
                            .foregroundColor(Color(UIColor.secondaryLabel))
                        NavigationLink {
                            RegisterView()
                        } label: {
                            Text("Create account")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            email = ""
            password = ""
            isPasswordVisible = false
            errorMessage = nil
            isLoading = false
        }
    }

    // MARK: - Actions

    private func signIn() {
        let trimmedEmail = self.trimmedEmail
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await supabase.auth.signIn(
                    email: trimmedEmail,
                    password: password
                )
            } catch {
                await MainActor.run {
                    errorMessage = userFacingMessage(from: error)
                    isLoading = false
                }
            }
        }
    }
}

#Preview("Login") {
    NavigationStack {
        LoginView()
    }
    .environmentObject(AppSession())
}
