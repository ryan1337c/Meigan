//
//  ForgotPasswordView.swift
//  Meigan
//
//  Four-step password reset: request emailed code → verify → set new password → success.
//  Shared field components live in `AuthFieldComponents.swift`.
//

import SwiftUI
import Supabase

struct ForgotPasswordView: View {
    @EnvironmentObject private var appSession: AppSession
    @Environment(\.dismiss) private var dismiss

    /// The steps of the reset flow.
    private enum Step {
        case verify       // enter email and request a verification code
        case code         // enter the emailed verification code
        case newPassword  // set + confirm the new password
        case success      // animated confirmation
    }

    let prefilledEmail: String

    @State private var step: Step = .verify
    @State private var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isNewPasswordVisible = false
    @State private var isConfirmPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    init(prefilledEmail: String = "") {
        self.prefilledEmail = prefilledEmail
        _email = State(initialValue: prefilledEmail)
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

                    Text(title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)

                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(Color(UIColor.secondaryLabel))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 32)

                if let errorMessage {
                    AuthErrorBanner(message: errorMessage)
                }

                // Info banner
                if let infoMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(infoMessage)
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Step content
                switch step {
                case .verify:      verifyStep
                case .code:        codeStep
                case .newPassword: newPasswordStep
                case .success:     successStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
            .animation(.easeInOut(duration: 0.25), value: errorMessage)
            .animation(.easeInOut(duration: 0.25), value: infoMessage)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Forgot password")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(step == .success || isLoading)
        .onAppear { appSession.beginPasswordReset() }
        .onDisappear { appSession.endPasswordReset() }
    }

    // MARK: - Header copy

    private var title: String {
        switch step {
        case .verify:      return "Reset your password"
        case .code:        return "Enter verification code"
        case .newPassword: return "Set a new password"
        case .success:     return "All done"
        }
    }

    private var subtitle: String? {
        switch step {
        case .verify:      return "Verify your identity to continue"
        case .code:        return nil
        case .newPassword: return "Choose a strong password you'll remember"
        case .success:     return nil
        }
    }

    // MARK: - Step 1: Verify identity

    private var verifyStep: some View {
        VStack(spacing: 20) {
            AuthLabeledTextField(
                title: "Email",
                placeholder: "user@email.com",
                text: $email,
                keyboardType: .emailAddress,
                textContentType: .emailAddress
            )

            primaryButton(title: "Email me a code", isEnabled: !trimmed(email).isEmpty) {
                sendCode()
            }
        }
    }

    // MARK: - Step 2: Enter emailed code

    private var codeStep: some View {
        VStack(spacing: 20) {
            AuthLabeledTextField(
                title: "Verification code",
                placeholder: "Enter 8 digit code",
                text: $code,
                keyboardType: .numberPad,
                textContentType: .oneTimeCode
            )

            primaryButton(title: "Verify code", isEnabled: !trimmed(code).isEmpty) {
                verifyCode()
            }

            Button {
                sendCode()
            } label: {
                Text("Resend code")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            }
            .disabled(isLoading)
        }
    }

    // MARK: - Step 3: New password

    private var newPasswordStep: some View {
        VStack(spacing: 20) {
            AuthLabeledSecureField(
                title: "New password",
                placeholder: "••••••••",
                text: $newPassword,
                isVisible: $isNewPasswordVisible,
                textContentType: .newPassword
            )

            if !newPassword.isEmpty {
                PasswordStrengthIndicator(password: newPassword)
            }

            AuthLabeledSecureField(
                title: "Confirm password",
                placeholder: "••••••••",
                text: $confirmPassword,
                isVisible: $isConfirmPasswordVisible,
                textContentType: .newPassword
            )

            if !confirmPassword.isEmpty && confirmPassword != newPassword {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Passwords don't match")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            primaryButton(title: "Continue", isEnabled: isNewPasswordValid) {
                updatePassword()
            }
        }
    }

    // MARK: - Step 4: Success

    private var successStep: some View {
        VStack(spacing: 20) {
            SuccessCheckmark()
                .padding(.top, 16)

            Text("Your password has been updated. Sign in with your new password to continue.")
                .font(.subheadline)
                .foregroundColor(Color(UIColor.secondaryLabel))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Button {
                appSession.endPasswordReset()
                dismiss()
            } label: {
                Text("Back to sign in")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .foregroundColor(.white)
            .background(Color.accentColor)
            .clipShape(Capsule())
            .padding(.top, 8)
        }
    }

    // MARK: - Reusable controls

    /// Accent capsule button that swaps in a spinner while a request is in flight.
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
                    Text(title)
                        .fontWeight(.semibold)
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

    // MARK: - Validation

    private var isNewPasswordValid: Bool {
        newPassword.count >= 6 && newPassword == confirmPassword
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func sendCode() {
        let trimmedEmail = trimmed(email)
        guard !trimmedEmail.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        infoMessage = nil

        Task {
            do {
                try await supabase.auth.resetPasswordForEmail(trimmedEmail)
                await MainActor.run {
                    isLoading = false
                    infoMessage = "Code sent. Check your inbox."
                    if step != .code { step = .code }
                }
            } catch {
                await MainActor.run {
                    errorMessage = userFacingMessage(from: error)
                    isLoading = false
                }
            }
        }
    }

    private func verifyCode() {
        let trimmedEmail = trimmed(email)
        let trimmedCode = trimmed(code)
        guard !trimmedCode.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await supabase.auth.verifyOTP(
                    email: trimmedEmail,
                    token: trimmedCode,
                    type: .recovery
                )
                await MainActor.run {
                    isLoading = false
                    infoMessage = nil
                    step = .newPassword
                }
            } catch {
                await MainActor.run {
                    errorMessage = userFacingMessage(from: error)
                    isLoading = false
                }
            }
        }
    }

    private func updatePassword() {
        guard isNewPasswordValid else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await supabase.auth.update(user: UserAttributes(password: newPassword))
                await MainActor.run {
                    isLoading = false
                    step = .success
                }
            } catch {
                await MainActor.run {
                    errorMessage = updatePasswordErrorMessage(from: error)
                    isLoading = false
                }
            }
        }
    }

    private func updatePasswordErrorMessage(from error: Error) -> String {
        let message = "\(error)".lowercased()
        if message.contains("same password") ||
            message.contains("same as") ||
            message.contains("different from") ||
            message.contains("old password") ||
            message.contains("previous password")
        {
            return "Your new password must be different from your previous password."
        }
        if message.contains("session") || message.contains("missing") || message.contains("not authenticated") || message.contains("jwt") {
            return "We couldn't verify your session. Please verify by email to reset your password."
        }
        return userFacingMessage(from: error)
    }
}

// MARK: - Success animation

/// Draws the checkmark "tick" so it can be animated with `.trim`.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: 0.16 * w, y: 0.54 * h))
        path.addLine(to: CGPoint(x: 0.42 * w, y: 0.78 * h))
        path.addLine(to: CGPoint(x: 0.84 * w, y: 0.24 * h))
        return path
    }
}

private struct SuccessCheckmark: View {
    @State private var ringScale: CGFloat = 0.4
    @State private var ringOpacity: Double = 0
    @State private var checkTrim: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 124, height: 124)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            Circle()
                .stroke(Color.accentColor, lineWidth: 4)
                .frame(width: 124, height: 124)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 60, height: 60)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                ringScale = 1
                ringOpacity = 1
            }
            withAnimation(.easeInOut(duration: 0.45).delay(0.25)) {
                checkTrim = 1
            }
        }
        .accessibilityLabel("Password reset complete")
    }
}

#Preview("Forgot Password") {
    NavigationStack {
        ForgotPasswordView(prefilledEmail: "user@email.com")
    }
    .environmentObject(AppSession())
}
