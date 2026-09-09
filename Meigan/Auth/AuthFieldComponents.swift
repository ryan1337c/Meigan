//
//  AuthFieldComponents.swift
//  Meigan
//
//  Shared styling, fields, banners, and error mapping for the auth screens
//  (`LoginView`, `RegisterView`, `ForgotPasswordView`).
//

import SwiftUI
import Supabase

// MARK: - Field style

enum AuthFieldStyle {
    static let cornerRadius: CGFloat = 10
    static let verticalPadding: CGFloat = 14
    static let horizontalPadding: CGFloat = 16
    static let borderWidth: CGFloat = 1

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

// MARK: - Fields

struct AuthLabeledTextField: View {
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

struct AuthLabeledSecureField: View {
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

// MARK: - Banners

/// Full-width red error banner used at the top of every auth screen.
struct AuthErrorBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Password strength

enum PasswordStrength {
    case invalid, weak, strong

    init(password: String) {
        if password.count < 6 {
            self = .invalid
            return
        }
        let hasSpecial = password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
        self = (password.count >= 8 && hasSpecial) ? .strong : .weak
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

struct PasswordStrengthIndicator: View {
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

// MARK: - Error mapping

enum AuthClientError: LocalizedError {
    case emailAlreadyExists

    var errorDescription: String? {
        switch self {
        case .emailAlreadyExists:
            return "Email already exists"
        }
    }
}

func userFacingMessage(from error: Error) -> String {
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
