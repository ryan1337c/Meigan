//
//  OnboardingView.swift
//  Meigan
//
//  First-launch intro; persistence is controlled by `ContentView` (see `alwaysShowOnboardingAtLaunch`).
//

import SwiftUI

struct OnboardingView: View {
    /// Called when the user taps Skip or Continue on the last page.
    let onFinished: () -> Void

    @State private var page = 0

    private let pages: [(symbol: String, title: String, detail: String)] = [
        ("camera.metering.center.weighted", "Measure the real world", "Place points in AR and read distances with clarity — built for rooms, furniture, and quick checks."),
        ("cube.transparent", "True 3D, not flat", "Meigan understands depth so your measurements stay trustworthy as you move."),
        ("lock.shield", "Your space, your data", "Sign in when you’re ready. We designed the flow around secure email — simple and modern."),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.secondarySystemBackground),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") {
                        onFinished()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                VStack(spacing: 8) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                    Text("Meigan")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        OnboardingPage(
                            symbolName: item.symbol,
                            title: item.title,
                            detail: item.detail
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.28), value: page)

                VStack(spacing: 18) {
                    OnboardingPageDots(
                        count: pages.count,
                        currentPage: page
                    ) { index in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            page = index
                        }
                    }

                    HStack(spacing: 12) {
                        if page > 0 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    page -= 1
                                }
                            } label: {
                                Text("Back")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }

                        Button {
                            if page < pages.count - 1 {
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    page += 1
                                }
                            } else {
                                onFinished()
                            }
                        } label: {
                            Text(page < pages.count - 1 ? "Next" : "Continue")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .background(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Page dots

private struct OnboardingPageDots: View {
    let count: Int
    let currentPage: Int
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0 ..< count, id: \.self) { index in
                Button {
                    onSelect(index)
                } label: {
                    Capsule()
                        .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: index == currentPage ? 22 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.22), value: currentPage)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(index + 1) of \(count)")
                .accessibilityAddTraits(index == currentPage ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 4)
    }
}

private struct OnboardingPage: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 140, height: 140)
                Image(systemName: symbolName)
                    .font(.system(size: 56, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 12) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
    }
}

#Preview {
    OnboardingView(onFinished: {})
}
