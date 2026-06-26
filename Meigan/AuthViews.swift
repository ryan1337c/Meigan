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
                VStack(spacing: 14) {
                    TextField("", text: $email, prompt: Text("Email address").foregroundColor(Color(UIColor.placeholderText)))
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(UIColor.separator), lineWidth: 1)
                        )

                    HStack(spacing: 8) {
                        Group {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(Color(UIColor.secondaryLabel))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(UIColor.separator), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 4)

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
                                .foregroundColor(.accentColor)
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
        #if DEBUG
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Skip") { appSession.continueAsGuest() }
                    .font(.subheadline)
            }
        }
        #endif
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
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        TextField("", text: $firstName, prompt: Text("First name").foregroundColor(Color(UIColor.placeholderText)))
                            .textContentType(.givenName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(UIColor.separator), lineWidth: 1)
                            )

                        TextField("", text: $lastName, prompt: Text("Last name").foregroundColor(Color(UIColor.placeholderText)))
                            .textContentType(.familyName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(UIColor.separator), lineWidth: 1)
                            )
                    }

                    TextField("", text: $email, prompt: Text("Email address").foregroundColor(Color(UIColor.placeholderText)))
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(UIColor.separator), lineWidth: 1)
                        )

                    HStack(spacing: 8) {
                        Group {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.init(rawValue: ""))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(Color(UIColor.secondaryLabel))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(UIColor.separator), lineWidth: 1)
                    )

                    if !password.isEmpty {
                        PasswordStrengthIndicator(password: password)
                    }
                }
                .padding(.horizontal, 4)

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
                        .foregroundColor(.accentColor)
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
                try await supabase.auth.signUp(
                    email: trimmedEmail,
                    password: password
                )
                await MainActor.run {
                    settings.firstName = trimmedFirst
                    settings.lastName = trimmedLast
                }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showCheckEmailBanner = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showCheckEmailBanner = false
                        }
                    }
                }
            catch {
                await MainActor.run {
                    errorMessage = userFacingMessage(from: error)
                }
            }
            await MainActor.run { isLoading = false }
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

private func userFacingMessage(from error: Error) -> String {
    let message = "\(error)".lowercased()
    if message.contains("email not confirmed") || message.contains("email_not_confirmed") || message.contains("confirm your email") {
        return "Please confirm your email before signing in. Check your inbox."
    }
    if message.contains("invalid login credentials") || message.contains("invalid_credentials") {
        return "Incorrect email or password."
    }
    if message.contains("user already registered") {
        return "An account with this email already exists."
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
}
