//
//  ARMeasurementPreviewOverlays.swift
//  Meigan
//
//  Modal-style overlays presented over the AR scene: screenshot preview, flatten scan
//  progress, detection-mask debug sheet, identify annotations, and the share sheet.
//

import SwiftUI
import UIKit

struct ScreenshotPreviewOverlay: View {
    var title = "Screenshot"
    /// When non-nil, caps image height (points). When nil, the image can use the full screen.
    var imageMaxHeight: CGFloat?
    let image: UIImage
    let onDismiss: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        GeometryReader { geo in
            let imageHeight = min(geo.size.height, imageMaxHeight ?? .infinity)

            ZStack {
                Color.black
                    .ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: imageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    ZStack {
                        Text(title)
                            .font(.headline)

                        HStack {
                            Button(action: onDismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .background {
                                        Circle()
                                            .fill(.thinMaterial)
                                    }
                                    .overlay {
                                        Circle()
                                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                                    }
                            }
                            .accessibilityLabel("Done")

                            Spacer()

                            Menu {
                                Button(action: onSave) {
                                    Label("Save", systemImage: "square.and.arrow.down")
                                }

                                Button(action: onShare) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Divider()

                                Button(role: .destructive, action: onDismiss) {
                                    Label("Delete Screenshot", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 22, weight: .semibold))
                                    .frame(width: 48, height: 48)
                                    .background {
                                        Circle()
                                            .fill(Color.accentColor)
                                            .shadow(color: Color.accentColor.opacity(0.35), radius: 10, y: 4)
                                    }
                            }
                            .accessibilityLabel("Screenshot actions")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, geo.safeAreaInsets.top + 12)
                    .padding(.bottom, 12)
                    .background(.ultraThinMaterial)

                    Spacer()
                        .allowsHitTesting(false)
                }
                .foregroundStyle(.white)
            }
            .ignoresSafeArea()
        }
    }
}

/// Sheet showing the grayscale bitmap passed to `VNDetectContoursRequest`.
struct FlattenDetectionPreviewSheet: View {
    let image: UIImage
    let onSave: (@escaping (Bool) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var showsSaveError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This is the mono + contrast + median image Vision uses for contour detection. If the object boundary is faint or broken here, tuning contrast alone won’t fix bounding boxes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(20)
            }
            .navigationTitle("Vision Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard !isSaving else { return }
                        isSaving = true
                        onSave { success in
                            isSaving = false
                            if success {
                                dismiss()
                            } else {
                                showsSaveError = true
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save to Photos")
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .alert("Unable to Save Photo", isPresented: $showsSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check Meigan's Photos access in Settings, then try again.")
            }
        }
    }
}

struct IdentifyAnnotationOverlay: View {
    let detections: [IdentifyDetection]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(detections) { d in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color.green, lineWidth: 2)
                        .frame(width: d.viewRect.width, height: d.viewRect.height)

                    Text("\(d.label) \(Int(d.confidence * 100))%")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green, ignoresSafeAreaEdges: [])
                        .foregroundColor(.black)
                        .offset(y: -16)
                }
                .position(x: d.viewRect.midX, y: d.viewRect.midY)
            }
        }
        .allowsHitTesting(false)   // so footer/buttons stay tappable
        .ignoresSafeArea()         // match arView.bounds full-screen coords
    }
}


struct FlattenScanPreviewOverlay: View {
    let image: UIImage?
    @State private var scanOffset: CGFloat = -0.45

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let edgeMargin: CGFloat = 16
            let maxCardWidth = min(proxy.size.width - edgeMargin * 2, 460)
            let safeHeight = proxy.size.height - insets.top - insets.bottom
            /// Title + subtitle + `VStack` spacing + card padding — keep preview within visible safe band.
            let verticalChrome: CGFloat = 152
            let previewWidth = max(1, maxCardWidth - 36)
            let previewHeight = min(
                previewWidth * 0.92,
                max(120, safeHeight * 0.88 - verticalChrome)
            )

            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    VStack(spacing: 12) {
                        Text("Scanning surface")
                            .font(.headline.weight(.semibold))
                            .multilineTextAlignment(.center)

                        ZStack {
                            if let image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: previewWidth, height: previewHeight)
                                    .clipped()
                                    .transition(.opacity)
                            } else {
                                // Snapshot not yet ready — keep the chrome visible so the user
                                // sees instant feedback the moment they tap Start Scan.
                                LinearGradient(
                                    colors: [
                                        Color.black.opacity(0.55),
                                        Color.black.opacity(0.35)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(width: previewWidth, height: previewHeight)
                            }

                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.cyan.opacity(0.22),
                                    Color.white.opacity(0.92),
                                    Color.cyan.opacity(0.22),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: min(40, previewHeight * 0.22))
                            .offset(y: scanOffset * previewHeight)
                            .shadow(color: .cyan.opacity(0.55), radius: 14)
                        }
                        .frame(width: previewWidth, height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                        )

                        Text("Analyzing plane geometry…")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                    .frame(width: maxCardWidth)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, edgeMargin)
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                scanOffset = -0.45
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                    scanOffset = 0.45
                }
            }
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
