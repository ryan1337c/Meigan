//
//  HomeView.swift
//  Meigan
//
//  Created by Ryan Chen on 2026-02-19.
//

import SwiftUI
import StoreKit
import Supabase

struct HomeView: View {
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var settings: SettingsManager

    @State private var showARMeasurement = false
    @State private var showAccount = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geometry in
            let logoSize = geometry.size.height / 4

            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(spacing: 32) {
                        VStack(spacing: 12) {
                            Image("Logo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: logoSize, height: logoSize)

                            Text("Meigan")
                                .font(.largeTitle)
                                .fontWeight(.bold)

                            Text("Precision 3D measurement")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Button {
                            showARMeasurement = true
                        } label: {
                            Text("Start Measuring")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.horizontal, 24)

                        Button {
                            // TODO: Show how it works
                        } label: {
                            HStack {
                                Image(systemName: "questionmark.circle")
                                Text("How it works")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)

                ProfileAvatarMenu(
                    initial: profileInitial,
                    isGuest: appSession.isGuest,
                    onAccount: { showAccount = true },
                    onSettings: { showSettings = true },
                    onLogOut: { appSession.logOut() }
                )
                .padding(.leading, 20)
                .padding(.top, 12)
            }
        }
        .navigationDestination(isPresented: $showARMeasurement) {
            ARMeasurementView()
        }
        .navigationDestination(isPresented: $showAccount) {
            AccountView()
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var profileInitial: String {
        let first = settings.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let char = first.first {
            return String(char).uppercased()
        }
        return appSession.isGuest ? "G" : "?"
    }
}

// MARK: - Profile Avatar + Dropdown Menu

private struct ProfileAvatarMenu: View {
    let initial: String
    let isGuest: Bool
    let onAccount: () -> Void
    let onSettings: () -> Void
    let onLogOut: () -> Void

    var body: some View {
        Menu {
            Button { onAccount() } label: {
                Label("Account", systemImage: "person.crop.circle")
            }
            Button { onSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            if isGuest {
                Button { onLogOut() } label: {
                    Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                }
                .tint(.accentColor)
            } else {
                Button(role: .destructive) { onLogOut() } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            AvatarBadge(initial: initial)
        }
    }
}

private struct AvatarBadge: View {
    let initial: String

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(white: 0.18))
                .frame(width: 40, height: 40)

            Circle()
                .fill(Color(red: 0.38, green: 0.58, blue: 0.92))
                .frame(width: 28, height: 28)

            Text(initial)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Account Screen

struct AccountView: View {
    @EnvironmentObject private var appSession: AppSession
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var subscriptions: SubscriptionManager

    @State private var showUpdatePaywall = false
    @State private var showCancelConfirmation = false
    @State private var showManageSubscriptions = false
    @State private var showPersonalInfoEditor = false
    @State private var showChangePassword = false
    @State private var showDeleteConfirmation = false
    @State private var deletionState: AccountDeletionSubscriptionState?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(displayName)
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 8)

                yourPlanSection
                accountSection
                securitySection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPersonalInfoEditor) {
            EditPersonalInfoView()
        }
        .navigationDestination(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
        .fullScreenCover(isPresented: $showUpdatePaywall, onDismiss: {
            subscriptions.clearPurchaseError()
        }) {
            SubscriptionPaywallView(
                priceLabel: subscriptions.proPriceLabel,
                isPurchasing: subscriptions.isPurchasing,
                errorMessage: subscriptions.purchaseError,
                currentTier: subscriptions.currentTier,
                isRestoring: subscriptions.isRestoring,
                onRestore: {
                    Task { 
                        await subscriptions.restorePurchases() 
                        if subscriptions.currentTier == .pro {
                            showUpdatePaywall = false
                        }
                    }
                },
                onSkip: {
                    showUpdatePaywall = false
                },
                onSelectPro: {
                    Task { 
                        await subscriptions.upgradeToPro() 
                        if subscriptions.currentTier == .pro {
                            showUpdatePaywall = false
                        }
                    }
                }
            )
            .task { await subscriptions.loadProductsIfNeeded() }
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .onChange(of: showManageSubscriptions) { isPresented in
            guard !isPresented else { return }

            Task {
                await subscriptions.reconcileEntitlements()
            }
        }
        .overlay {
            if showCancelConfirmation {
                CancelPremiumDialog(
                    bullets: cancelDialogBullets,
                    onManage: {
                        showCancelConfirmation = false
                        showManageSubscriptions = true
                    },
                    onKeep: {
                        showCancelConfirmation = false
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .overlay {
            if let message = subscriptions.restoreMessager {
                RestoreResultDialog(
                    isSuccess: subscriptions.currentTier == .pro,
                    message: message,
                    onDone: { subscriptions.clearRestoreMessage() }
                )
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .overlay {
            if showDeleteConfirmation, let deletionState {
                DeleteAccountDialog(
                    state: deletionState,
                    onManage: {
                        showDeleteConfirmation = false
                        showManageSubscriptions = true
                    },
                    onDelete: {
                        showDeleteConfirmation = false
                        Task {
                            do {
                                try await appSession.deleteAccount()
                            } 
                            catch {
                                if case FunctionsError.httpError(let code, let data) = error {
                                    print("Delete account HTTP \(code):", String(data: data, encoding: .utf8) ?? "unknown")
                                }
                                throw error
                            }
                        }
                    },
                    onCancel: {
                        showDeleteConfirmation = false
                    }
                )
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCancelConfirmation)
        .animation(.easeInOut(duration: 0.2), value: subscriptions.restoreMessager)
        .animation(.easeInOut(duration: 0.2), value: showDeleteConfirmation)
    }

    private var yourPlanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Plan")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(UIColor.tertiarySystemFill))
                    )

                Label(planLabel, systemImage: "crown.fill")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(planDescription)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemGroupedBackground))
            )

            HStack(spacing: 12) {
                planActionButton(
                    title: "Update subscription",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    showUpdatePaywall = true
                }
                planActionButton(
                    title: "Cancel subscription",
                    systemImage: "xmark.circle"
                ) {
                    showCancelConfirmation = true
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            AccountRow(title: "Edit personal info", systemImage: "pencil") {
                showPersonalInfoEditor = true
            }
            Divider().padding(.leading, 56)
            AccountRow(title: "Edit card", systemImage: "creditcard") {
                // TODO: Navigate to payment method editor.
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Security and Privacy")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            AccountRow(title: "Change password", systemImage: "lock.shield") {
                showChangePassword = true
            }
            Divider().padding(.leading, 56)
            AccountRow(
                title: "Delete account",
                systemImage: "trash",
                isDestructive: true
            ) {
                Task {
                    deletionState = await subscriptions.accountDeletionState()
                    showDeleteConfirmation = true
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var displayName: String {
        let first = settings.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = settings.lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = "\(first) \(last)".trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? "Guest" : combined
    }

    private var planLabel: String {
        subscriptions.currentTier == .pro ? "Premium" : "Free"
    }

    private var planDescription: String {
        subscriptions.currentTier == .pro
            ? "You are currently on the Pro plan."
            : "You are currently on the Free plan."
    }

    /// Concise cancellation points covering access retention, the effective
    /// expiry date, billing termination, data safety, and Apple billing.
    private var cancelDialogBullets: [CancelBullet] {
        let until: String
        if let date = subscriptions.proExpirationDate {
            until = date.formatted(date: .abbreviated, time: .omitted)
        } else {
            until = "the end of your billing cycle"
        }
        return [
            CancelBullet(
                symbol: "checkmark.seal",
                text: "Keep all Premium features until \(until)."
            ),
            CancelBullet(
                symbol: "creditcard",
                text: "You won't be charged again unless you resubscribe."
            ),
            CancelBullet(
                symbol: "lock.shield",
                text: "Your saved data and preferences stay safe."
            ),
            CancelBullet(
                symbol: "applelogo",
                text: "Subscriptions are managed through your Apple ID."
            ),
        ]
    }

    private func planActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.medium))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Edit Personal Info

private struct EditPersonalInfoView: View {
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

// MARK: - Change Password

/// Self-contained password-change flow for a signed-in user. Mirrors the
/// "Forgot password" experience (emailed code → verify → set new password)
/// but skips the email entry step (the code is sent automatically to the
/// account email) and never signs the user out. Built independently of the
/// auth flow's private components so the two screens stay decoupled.
private struct ChangePasswordView: View {
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

// MARK: - Cancel Premium Dialog

private struct CancelBullet: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
}

/// Centered, dimmed-overlay confirmation shown when the user taps "Cancel
/// subscription". Lays out the cancellation details as vertically stacked
/// bullet points instead of a single cluttered paragraph.
private struct CancelPremiumDialog: View {
    let bullets: [CancelBullet]
    let onManage: () -> Void
    let onKeep: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onKeep)

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundColor(.orange)
                    Text("Cancel Premium?")
                        .font(.title2.weight(.bold))
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(bullets) { bullet in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: bullet.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                            Text(bullet.text)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }

                VStack(spacing: 10) {
                    Button(action: onManage) {
                        Text("Manage Subscription")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onKeep) {
                        Text("Keep Premium")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
            )
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Restore Result Dialog

/// Centered, dimmed-overlay confirmation shown after "Restore Purchases".
/// Mirrors `CancelPremiumDialog` styling; icon and accent adapt to whether an
/// active subscription was found.
private struct RestoreResultDialog: View {
    let isSuccess: Bool
    let message: String
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onDone)

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: isSuccess ? "checkmark.seal.fill" : "info.circle.fill")
                        .font(.title)
                        .foregroundColor(isSuccess ? .accentColor : .secondary)
                    Text(isSuccess ? "Purchases Restored" : "No Subscription Found")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                }

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
            )
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Delete Account Dialog

/// Centered, dimmed-overlay confirmation shown when the user taps "Delete
/// account". The warning copy — and whether a "Manage Subscriptions" button is
/// offered — adapts to the user's subscription state so we only surface the
/// Apple-required billing warning when a still-renewing subscription exists.
private struct DeleteAccountDialog: View {
    let state: AccountDeletionSubscriptionState
    let onManage: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var message: String {
        switch state {
        case .free:
            return "Are you sure you want to delete your account? All of your saved data, preferences, and profile information will be permanently erased. This cannot be undone."
        case .premiumAutoRenewing:
            return "Deleting your account will permanently erase your data, but it will not cancel your Meigan Premium subscription. You will continue to be billed by Apple unless you cancel."
        case .premiumExpiring:
            return "Your Premium subscription is already set to expire, but deleting your account now will forfeit your remaining Premium access. Your data will be permanently erased."
        }
    }

    private var showsManageButton: Bool {
        state == .premiumAutoRenewing
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundColor(.red)
                    Text("Delete Account?")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                }

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    if showsManageButton {
                        Button(action: onManage) {
                            Text("Manage Subscriptions")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(role: .destructive, action: onDelete) {
                        Text("Delete Account")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
            )
            .padding(.horizontal, 32)
        }
    }
}

private struct AccountRow: View {
    let title: String
    let systemImage: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(UIColor.tertiarySystemFill))
                    )

                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundColor(isDestructive ? .red : .primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(isDestructive ? .red.opacity(0.7) : .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environmentObject(AppSession())
    .environmentObject(SettingsManager())
    .environmentObject(SubscriptionManager())
}
