//
//  ARSceneView.Coordinator+TrackingGuide.swift
//  Meigan
//
//  Placement / ARKit tracking / lighting / motion guidance, merged into one debounced banner.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit
import OSLog

private let arPlacementLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Meigan", category: "ARPlacement")

extension ARSceneView.Coordinator {
    /// Debounce placement issues locally, then re-resolve global tracking guide priority.
    func updatePlacementGuide(_ issue: PlacementGuideIssue) {
        if issue == placementGuideDebounceIssue {
            placementGuideDebounceFrameCount += 1
        } else {
            placementGuideDebounceIssue = issue
            placementGuideDebounceFrameCount = 1
        }

        let threshold = max(1, appliedTrackingGuideShowThreshold)
        guard placementGuideDebounceFrameCount >= threshold else { return }
        guard placementGuidePromotedIssue != issue else { return }
        placementGuidePromotedIssue = issue
        publishMergedTrackingGuideIfNeeded()
    }

    // MARK: - Simplified ARKit tracking (no more excessive motion)
    func updateARKitTrackingGuide(_ reason: ARCamera.TrackingState.Reason?) {
        let issue: ARKitGuideIssue
        switch reason {
        case .insufficientFeatures:
            issue = .findNearbySurface
        default:
            issue = .none
        }

        let threshold: Int
        let frameCount: Int
        switch issue {
        case .findNearbySurface:
            arKitInsufficientFeaturesFrameCount += 1
            arKitNoneFrameCount = 0
            threshold = arKitInsufficientFeaturesShowThreshold
            frameCount = arKitInsufficientFeaturesFrameCount
        case .none:
            arKitNoneFrameCount += 1
            arKitInsufficientFeaturesFrameCount = 0
            threshold = arKitClearShowThreshold
            frameCount = arKitNoneFrameCount
        case .excessiveMotion:
            // No longer handled here - using custom detection
            return
        }

        guard frameCount >= threshold else { return }
        guard arKitGuidePromotedIssue != issue else { return }

        arKitGuidePromotedIssue = issue
        publishMergedTrackingGuideIfNeeded()
    }

    /// True while flatten scan preview/processing hides placement + tracking banner chrome.
    var placementBannerChromeMutedForFlattenCapture: Bool {
        isFlattenScanActive || flattenScanOccludesPlacementChrome
    }

    /// Clears SwiftUI capsules and blocks banner republish until flatten pipeline releases
    /// `flattenScanOccludesPlacementChrome`.
    func suppressPlacementBannerChromeDuringFlattenPipelineHandoff() {
        flattenScanOccludesPlacementChrome = true
        cancelTrackingGuideTransition()
        let flush = { [weak self] in
            guard let self else { return }
            self.placementWarningMessage = ""
            self.trackingGuideMessage = ""
            self.activeTrackingReason = nil
            self.displayedTrackingGuideIssue = .none
            self.trackingGuideDisplayedAt = nil
        }
        if Thread.isMainThread {
            flush()
        } else {
            DispatchQueue.main.sync(execute: flush)
        }
    }

    // MARK: - Lighting guidance
    func updateSmoothedAmbientIntensity(_ lightEstimate: ARLightEstimate?) {
        guard let lightEstimate else { return }
        let newValue = lightEstimate.ambientIntensity
        if let previous = smoothedAmbientIntensity {
            smoothedAmbientIntensity =
                ambientIntensityEMAAlpha * newValue + (1 - ambientIntensityEMAAlpha) * previous
        } else {
            smoothedAmbientIntensity = newValue
        }
    }

    func updateTooDarkLightingDebounced() {
        guard let smoothed = smoothedAmbientIntensity else {
            // No estimate this frame, clear everything
            tooDarkConsecutiveFrames = 0
            isTooDark = false
            return
        }

        // If enough consecutive frames are too dark, set the flag
        if smoothed < tooDarkThreshold {
            tooDarkConsecutiveFrames += 1
            guard tooDarkConsecutiveFrames >= tooDarkConsecutiveFramesThreshold else { return }
            isTooDark = true
        }
        else {
            tooDarkConsecutiveFrames = 0
            isTooDark = false
        }
        publishLightingGuide()
    }

    // Update the lighting guidance publisher
    private func publishLightingGuide() {
        let newIssue: ResolvedTrackingGuideIssue = isTooDark ? .tooDark : .none
        guard lightingGuidePromotedIssue != newIssue else { return }

        lightingGuidePromotedIssue = newIssue
        publishMergedTrackingGuideIfNeeded()
    }


    /// Angle (radians) between previous and current camera orientations (minimal rotation delta).
    static func rotationDeltaRadians(from previous: simd_float4x4, to current: simd_float4x4) -> Float {
        let pr = simd_float3x3(
            SIMD3(previous.columns.0.x, previous.columns.0.y, previous.columns.0.z),
            SIMD3(previous.columns.1.x, previous.columns.1.y, previous.columns.1.z),
            SIMD3(previous.columns.2.x, previous.columns.2.y, previous.columns.2.z)
        )
        let cr = simd_float3x3(
            SIMD3(current.columns.0.x, current.columns.0.y, current.columns.0.z),
            SIMD3(current.columns.1.x, current.columns.1.y, current.columns.1.z),
            SIMD3(current.columns.2.x, current.columns.2.y, current.columns.2.z)
        )
        let delta = simd_mul(cr, simd_transpose(pr))
        let trace =
            delta.columns.0.x + delta.columns.1.y + delta.columns.2.z
        let cosTheta = Float(
            max(-1, min(1, Double((trace - 1) * 0.5)))
        )
        return acos(cosTheta)
    }

    // Update the custom motion publisher
    func publishCustomExcessiveMotion(_ isActive: Bool) {
        let newIssue: ResolvedTrackingGuideIssue = isActive ? .excessiveMotion : .none
        guard customMotionPromotedIssue != newIssue else { return }

        customMotionPromotedIssue = newIssue
        if isActive {
            arPlacementLog.notice("Custom excessive motion: ACTIVE")
        } else {
            arPlacementLog.notice("Custom excessive motion: CLEARED")
        }
        publishMergedTrackingGuideIfNeeded()
    }


    // Update the merge resolution to check BOTH sources
    func resolveMergedTrackingGuideIssue() -> ResolvedTrackingGuideIssue {
        // Priority: tooDark >tooClose > excessiveMotion > findNearbySurface > none

        if lightingGuidePromotedIssue == .tooDark {
            return .tooDark
        }

        if placementGuidePromotedIssue == .tooClose {
            return .tooClose
        }

        // ✅ Check custom motion state separately
        if customMotionPromotedIssue == .excessiveMotion {
            return .excessiveMotion
        }

        // Now check ARKit's promoted issue (which no longer includes excessive motion)
        if placementGuidePromotedIssue == .findNearbySurface || arKitGuidePromotedIssue == .findNearbySurface {
            return .findNearbySurface
        }

        return .none
    }

    /// Single publish point for SwiftUI tracking guide bindings with global priority:
    /// tooDark > tooClose > excessiveMotion > findNearbySurface.
    /// Resolved issue persists while unchanged. Switching to another **non-empty** guide commits
    /// immediately (no minimum-delay wait). Clearing the banner waits out the remainder of
    /// `trackingGuideMinimumDisplayDuration` so short flickers don't hide guidance too soon.
    private func publishMergedTrackingGuideIfNeeded() {
        if placementBannerChromeMutedForFlattenCapture {
            cancelTrackingGuideTransition()
            return
        }
        let resolvedIssue = resolveMergedTrackingGuideIssue()
        if resolvedIssue == displayedTrackingGuideIssue {
            cancelTrackingGuideTransition()
            return
        }
        scheduleTrackingGuideTransition()
    }

    func cancelTrackingGuideTransition() {
        trackingGuideTransitionWorkItem?.cancel()
        trackingGuideTransitionWorkItem = nil
    }

    private func scheduleTrackingGuideTransition() {
        cancelTrackingGuideTransition()

        let resolved = resolveMergedTrackingGuideIssue()

        if displayedTrackingGuideIssue == .none {
            commitTrackingGuideDisplay(resolved)
            return
        }

        // Any change to another concrete guide swaps immediately — no minimum wait between messages.
        if resolved != .none {
            commitTrackingGuideDisplay(resolved)
            return
        }

        // Dismissing: honor minimum elapsed time since this guide appeared.
        let elapsed = trackingGuideDisplayedAt.map { Date().timeIntervalSince($0) }
            ?? Self.trackingGuideMinimumDisplayDuration
        let delay = max(0, Self.trackingGuideMinimumDisplayDuration - elapsed)

        if delay <= 0 {
            commitTrackingGuideDisplay(resolved)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trackingGuideTransitionWorkItem = nil
            let latestIssue = self.resolveMergedTrackingGuideIssue()
            guard latestIssue == .none else { return }
            self.commitTrackingGuideDisplay(latestIssue)
        }
        trackingGuideTransitionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func commitTrackingGuideDisplay(_ issue: ResolvedTrackingGuideIssue) {
        displayedTrackingGuideIssue = issue
        trackingGuideDisplayedAt = issue == .none ? nil : Date()

        let guidance = messageAndReason(for: issue)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeTrackingReason = guidance.reason
            self.trackingGuideMessage = guidance.message
            self.trackingGuideKind = .instruction
        }
    }

    func messageAndReason(for resolvedIssue: ResolvedTrackingGuideIssue) -> (message: String, reason: ARCamera.TrackingState.Reason?) {
        switch resolvedIssue {
        case .tooDark:
            return ("More light is required", nil)
        case .tooClose:
            return ("Move farther away", nil)
        case .excessiveMotion:
            return ("Slow down", .excessiveMotion)
        case .findNearbySurface:
            // Keep reason specific only when ARKit is the sole winner.
            let reason = (arKitGuidePromotedIssue == .findNearbySurface && placementGuidePromotedIssue != .findNearbySurface)
                ? ARCamera.TrackingState.Reason.insufficientFeatures
                : nil
            return ("Find a nearby surface to measure", reason)
        case .none:
            return ("", nil)
        }
    }
}
