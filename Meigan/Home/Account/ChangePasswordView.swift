//
//  ChangePasswordView.swift
//  Meigan
//

import SwiftUI
import Supabase

/// Self-contained password-change flow for a signed-in user. Mirrors the
/// "Forgot password" experience (emailed code → verify → set new password)
/// but skips the email entry step (the code is sent automatically to the
/// account email) and never signs the user out. Built independently of the
/// auth flow's components so the two screens stay decoupled.
struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case code
        case newPassword
        case success
    }

    @State private var step: Step = .code
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isNewPasswordVisible = false
    @State private var isConfirmPasswordVisible = false
    @State private var isLoading = false
    @State private var didRequestInitialCode = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private var accountEmail: String {
        supabase.auth.currentSession?.user.email ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if let errorMessage {
                    banner(text: errorMessage, systemImage: "exclamationmark.circle.fill", color: .red)
                }

                if let infoMessage {
                    banner(text: infoMessage, systemImage: "envelope.fill", color: .accentColor)
                }

                switch step {
                case .code:        codeStep
                case .newPassword: newPasswordStep
                case .success:     successStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
            .animation(.easeInOut(duration: 0.25), value: errorMessage)
            .animation(.easeInOut(duration: 0.25), value: infoMessage)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                }
                .disabled(isLoading)
            }
        }
        .task {
            guard !didRequestInitialCode else { return }
            didRequestInitialCode = true
            await sendCode()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.rotation")
                .font(.system(size: 40, weight: .regular))
                .foregroundColor(.accentColor)
                .padding(.bottom, 2)

            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 16)
    }

    private var title: String {
        switch step {
        case .code:        return "Enter verification code"
        case .newPassword: return "Set a new password"
        case .success:     return "All done"
        }
    }

    private var subtitle: String? {
        switch step {
        case .code:
            return accountEmail.isEmpty
                ? "We've emailed you a verification code."
                : "We've emailed a verification code to \(accountEmail)."
        case .newPassword:
            return "Choose a strong password you'll remember."
        case .success:
            return nil
        }
    }

    // MARK: - Step 1: Code

    private var codeStep: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Verification code")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)

                TextField("Enter 8 digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
            }

            primaryButton(title: "Verify code", isEnabled: !trimmed(code).isEmpty) {
                verifyCode()
            }

            Button {
                Task { await sendCode() }
            } label: {
                Text("Resend code")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            }
            .disabled(isLoading)
        }
    }

    // MARK: - Step 2: New password

    private var newPasswordStep: some View {
        VStack(spacing: 20) {
            secureField(
                title: "New password",
                text: $newPassword,
                isVisible: $isNewPasswordVisible
            )

            if !newPassword.isEmpty {
                passwordHint
            }

            secureField(
                title: "Confirm password",
                text: $confirmPassword,
                isVisible: $isConfirmPasswordVisible
            )

            if !confirmPassword.isEmpty && confirmPassword != newPassword {
                hintRow(text: "Passwords don't match", color: .red)
            }

            primaryButton(title: "Update password", isEnabled: isNewPasswordValid) {
                updatePassword()
            }
        }
    }

    private var passwordHint: some View {
        let isLongEnough = newPassword.count >= 6
        return hintRow(
            text: isLongEnough ? "Looks good" : "Minimum 6 characters",
            color: isLongEnough ? .green : .orange
        )
    }

    // MARK: - Step 3: Success

    private var successStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
                .padding(.top, 8)

            Text("Your password has been updated.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            primaryButton(title: "Done", isEnabled: true) {
                dismiss()
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Reusable controls

    private func banner(text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func primaryButton(
        title: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .foregroundColor(.white)
        .background(Color.accentColor)
        .clipShape(Capsule())
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func secureField(
        title: String,
        text: Binding<String>,
        isVisible: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Group {
                    if isVisible.wrappedValue {
                        TextField("••••••••", text: text)
                    } else {
                        SecureField("••••••••", text: text)
                    }
                }
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button {
                    isVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                        .font(.body.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func hintRow(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Validation

    private var isNewPasswordValid: Bool {
        newPassword.count >= 6 && newPassword == confirmPassword
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func sendCode() async {
        let email = trimmed(accountEmail)
        guard !email.isEmpty else {
            errorMessage = "We couldn't find your account email. Please sign in again."
            return
        }

        isLoading = true
        errorMessage = nil
        infoMessage = nil

        do {
            try await supabase.auth.resetPasswordForEmail(email)
            infoMessage = "Code sent. Check your inbox."
        } catch {
            errorMessage = "Couldn't send a code. Please try again."
        }

        isLoading = false
    }

    private func verifyCode() {
        let email = trimmed(accountEmail)
        let token = trimmed(code)
        guard !token.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await supabase.auth.verifyOTP(
                    email: email,
                    token: token,
                    type: .recovery
                )
                infoMessage = nil
                step = .newPassword
            } catch {
                errorMessage = "That code didn't work. Check it and try again."
            }
            isLoading = false
        }
    }

    private func updatePassword() {
        guard isNewPasswordValid else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await supabase.auth.update(user: UserAttributes(password: newPassword))
                step = .success
            } catch {
                errorMessage = changePasswordErrorMessage(from: error)
            }
            isLoading = false
        }
    }

    private func changePasswordErrorMessage(from error: Error) -> String {
        let message = "\(error)".lowercased()
        if message.contains("same password") ||
            message.contains("same as") ||
            message.contains("different from") ||
            message.contains("old password") ||
            message.contains("previous password")
        {
            return "Your new password must be different from your current password."
        }
        if message.contains("session") || message.contains("jwt") || message.contains("not authenticated") {
            return "Your verification expired. Request a new code and try again."
        }
        return "Couldn't update your password. Please try again."
    }
}
