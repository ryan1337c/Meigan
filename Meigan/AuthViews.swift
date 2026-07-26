//
//  AuthViews.swift
//  Meigan
//
//  Traditional email + password login / register.
//

import SwiftUI
import Supabase

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject private var appSession: AppSession

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?

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

                // Error banner
                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.move(edge: .top).combined(with: .opacity))
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
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || isLoading)
                .opacity((email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty) ? 0.5 : 1)

                // Divider
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
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Forgot Password

struct ForgotPasswordView: View {
    @EnvironmentObject private var appSession: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

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

                // Error banner
                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.move(edge: .top).combined(with: .opacity))
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

            Button {
                sendCode()
            } label: {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Email me a code")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .foregroundColor(.white)
            .background(Color.accentColor)
            .clipShape(Capsule())
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            .opacity(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
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

            Button {
                verifyCode()
            } label: {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify code")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .foregroundColor(.white)
            .background(Color.accentColor)
            .clipShape(Capsule())
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            .opacity(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)

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

            Button {
                updatePassword()
            } label: {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
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
            .disabled(!isNewPasswordValid || isLoading)
            .opacity(isNewPasswordValid ? 1 : 0.5)
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

    // MARK: - Validation

    private var isNewPasswordValid: Bool {
        newPassword.count >= 6 && newPassword == confirmPassword
    }

    // MARK: - Actions

    private func sendCode() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        infoMessage = nil

        Task {
            do {
                try await supabase.auth.resetPasswordForEmail(trimmed)
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
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Reset flow helpers

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

// MARK: - Register

struct RegisterView: View {
    @EnvironmentObject private var appSession: AppSession
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var settings: SettingsManager

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

                // Error banner
                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.move(edge: .top).combined(with: .opacity))
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


// MARK: - Auth Field Components

private enum AuthFieldStyle {
    static let cornerRadius: CGFloat = 10
    static let verticalPadding: CGFloat = 14
    static let horizontalPadding: CGFloat = 16

    static func labelColor(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.88)
            : Color(red: 0.32, green: 0.38, blue: 0.48)
    }

    static func placeholderColor(for scheme: ColorScheme) -> Color {
        labelColor(for: scheme).opacity(0.45)
    }

    static func fieldBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.14)
            : Color(red: 0.93, green: 0.95, blue: 0.97)
    }

    static func iconColor(for scheme: ColorScheme) -> Color {
        labelColor(for: scheme).opacity(0.85)
    }

    static func borderColor(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.32)
            : Color(red: 0.32, green: 0.38, blue: 0.48).opacity(0.22)
    }

    static let borderWidth: CGFloat = 1

    @ViewBuilder
    static func fieldChrome<Content: View>(
        for scheme: ColorScheme,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fieldBackground(for: scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor(for: scheme), lineWidth: borderWidth)
            )
    }
}

private struct AuthLabeledTextField: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var autocapitalization: TextInputAutocapitalization = .never

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AuthFieldStyle.labelColor(for: colorScheme))

            AuthFieldStyle.fieldChrome(for: colorScheme) {
                TextField(
                    "",
                    text: $text,
                    prompt: Text(placeholder).foregroundColor(AuthFieldStyle.placeholderColor(for: colorScheme))
                )
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .padding(.horizontal, AuthFieldStyle.horizontalPadding)
                .padding(.vertical, AuthFieldStyle.verticalPadding)
            }
        }
    }
}

private struct AuthLabeledSecureField: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let placeholder: String
    @Binding var text: String
    @Binding var isVisible: Bool
    var textContentType: UITextContentType? = .password

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AuthFieldStyle.labelColor(for: colorScheme))

            AuthFieldStyle.fieldChrome(for: colorScheme) {
                HStack(spacing: 8) {
                    Group {
                        if isVisible {
                            TextField(
                                "",
                                text: $text,
                                prompt: Text(placeholder).foregroundColor(AuthFieldStyle.placeholderColor(for: colorScheme))
                            )
                        } else {
                            ZStack(alignment: .leading) {
                                if text.isEmpty {
                                    Text(placeholder)
                                        .foregroundColor(AuthFieldStyle.placeholderColor(for: colorScheme))
                                        .allowsHitTesting(false)
                                }
                                SecureField("", text: $text)
                            }
                        }
                    }
                    .textContentType(textContentType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        isVisible.toggle()
                    } label: {
                        Image(systemName: isVisible ? "eye.slash" : "eye")
                            .font(.body.weight(.medium))
                            .foregroundColor(AuthFieldStyle.iconColor(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isVisible ? "Hide password" : "Show password")
                }
                .padding(.horizontal, AuthFieldStyle.horizontalPadding)
                .padding(.vertical, AuthFieldStyle.verticalPadding)
            }
        }
    }
}

// MARK: - Password Strength

private enum PasswordStrength {
    case invalid, weak, strong

    init(password: String) {
        if password.count < 6 {
            self = .invalid
            return
        }
        let hasSpecial = password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
        let variety = [hasSpecial].filter { $0 }.count

        if password.count >= 8 && variety >= 1 {
            self = .strong
        } else {
            self = .weak
        }
    }

    var label: String {
        switch self {
        case .invalid: return "Too short — minimum 6 characters"
        case .weak:    return "Weak password - at least 8 characters and 1 special character"
        case .strong:  return "Strong password"
        }
    }

    var color: Color {
        switch self {
        case .invalid: return .red
        case .weak:    return .orange
        case .strong:  return .green
        }
    }
}

private struct PasswordStrengthIndicator: View {
    let password: String

    var body: some View {
        let strength = PasswordStrength(password: password)
        HStack(spacing: 6) {
            Circle()
                .fill(strength.color)
                .frame(width: 8, height: 8)
            Text(strength.label)
                .font(.caption)
                .foregroundColor(strength.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: strength.label)
    }
}

// MARK: - Helpers

private enum AuthClientError: LocalizedError {
    case emailAlreadyExists

    var errorDescription: String? {
        switch self {
        case .emailAlreadyExists:
            return "Email already exists"
        }
    }
}

private func userFacingMessage(from error: Error) -> String {
    if let clientError = error as? AuthClientError {
        return clientError.errorDescription ?? "Something went wrong. Please try again."
    }

    if let authError = error as? AuthError {
        switch authError.errorCode {
        case .userAlreadyExists, .emailExists:
            return "Email already exists"
        default:
            break
        }
    }

    let message = "\(error)".lowercased()
    if message.contains("email not confirmed") || message.contains("email_not_confirmed") || message.contains("confirm your email") {
        return "Please confirm your email before signing in. Check your inbox."
    }
    if message.contains("invalid login credentials") || message.contains("invalid_credentials") {
        return "Incorrect email or password."
    }
    if message.contains("user already registered") ||
        message.contains("user already exists") ||
        message.contains("user_already_exists") ||
        message.contains("email_exists") ||
        message.contains("email already exists")
    {
        return "Email already exists"
    }
    if message.contains("rate limit") || message.contains("too many requests") || message.contains("over_email_send_rate_limit") {
        return "Too many attempts. Please wait a moment and try again."
    }
    if message.contains("network") || message.contains("timed out") || message.contains("urlsessiontask") {
        return "Network error. Check your connection and try again."
    }
    if message.contains("password") && (message.contains("short") || message.contains("least")) {
        return "Password must be at least 6 characters."
    }
    if message.contains("signup_disabled") {
        return "Sign-up is currently disabled."
    }
    print("Unhandled auth error: \(error)")
    return "Something went wrong. Please try again."
}

// MARK: - Previews

#Preview("Login") {
    NavigationStack {
        LoginView()
    }
    .environmentObject(AppSession())
}

#Preview("Register") {
    NavigationStack {
        RegisterView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
}

#Preview("Forgot Password") {
    NavigationStack {
        ForgotPasswordView(prefilledEmail: "user@email.com")
    }
    .environmentObject(AppSession())
}
