//
//  CameraAccessGateView.swift
//  Meigan
//
//  Pre-prompt, loading, and denied states before AR measurement starts.
//

import SwiftUI

struct CameraAccessGateView: View {
    let phase: CameraAccessGatePhase
    let onRequestAccess: () -> Void
    let onOpenSettings: () -> Void
    let onGoBack: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            switch phase {
            case .prePrompt:
                CameraAccessPrePromptView(onContinue: onRequestAccess)
            case .requesting:
                CameraAccessRequestingView()
            case .denied:
                CameraAccessDeniedView(
                    onOpenSettings: onOpenSettings,
                    onGoBack: onGoBack
                )
            case .ready:
                EmptyView()
            }
        }
    }
}

// MARK: - Shared card

private struct CameraAccessCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 16) {
            content()
        }
        .padding(24)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 24)
    }
}

// MARK: - Pre-prompt

private struct CameraAccessPrePromptView: View {
    let onContinue: () -> Void

    var body: some View {
        CameraAccessCard {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)

            Text("Camera access needed")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Meigan uses your camera to measure distances in 3D space. iOS will ask for permission when you continue.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Requesting

private struct CameraAccessRequestingView: View {
    var body: some View {
        CameraAccessCard {
            ProgressView()
                .controlSize(.large)

            Text("Waiting for camera access")
                .font(.headline)

            Text("Respond to the system prompt to continue.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Denied

private struct CameraAccessDeniedView: View {
    let onOpenSettings: () -> Void
    let onGoBack: () -> Void

    var body: some View {
        CameraAccessCard {
            Image(systemName: "camera.fill")
                .font(.system(size: 44, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text("Camera access required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Meigan needs camera access to measure in AR. Enable it in Settings, then return here.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(action: onOpenSettings) {
                Text("Open Settings")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Button(action: onGoBack) {
                Text("Go Back")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview("Pre-prompt") {
    CameraAccessGateView(
        phase: .prePrompt,
        onRequestAccess: {},
        onOpenSettings: {},
        onGoBack: {}
    )
}

#Preview("Denied") {
    CameraAccessGateView(
        phase: .denied,
        onRequestAccess: {},
        onOpenSettings: {},
        onGoBack: {}
    )
}
