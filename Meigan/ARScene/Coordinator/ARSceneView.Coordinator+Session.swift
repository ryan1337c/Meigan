//
//  ARSceneView.Coordinator+Session.swift
//  Meigan
//
//  ARKit session lifecycle and delegate callbacks.
//

import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

extension ARSceneView.Coordinator {
    /// Stops the per-frame loop, pauses ARKit, and detaches delegates so navigating away from the
    /// AR view doesn't keep camera capture, plane detection, or scene mesh generation running.
    func teardownSession() {
        appliedSessionPaused = false
        pauseSession()
        flattenScanOccludesPlacementChrome = false

        if let arView {
            arView.session.delegate = nil
        }

        if let overlay = coachingOverlay {
            overlay.delegate = nil
            overlay.session = nil
        }
    }

    /// Pauses capture and per-frame work while keeping the AR view alive (settings, paywall, etc.).
    func pauseSession() {
        updateSubscription?.cancel()
        updateSubscription = nil
        cancelTrackingGuideTransition()
        hideRingForSessionReset()
        arView?.session.pause()
    }

    /// Resumes a paused session without resetting world tracking or measurements.
    func resumeSession() {
        guard let arView else { return }

        hideRingForSessionReset()

        if arView.session.delegate == nil {
            arView.session.delegate = self
        }

        if let overlay = coachingOverlay {
            if overlay.session == nil {
                overlay.session = arView.session
            }
            if overlay.delegate == nil {
                overlay.delegate = self
            }
        }

        let configuration = ARSceneView.makeWorldTrackingConfiguration()
        arView.session.run(configuration)

        if updateSubscription == nil {
            startUpdateLoop()
        }
    }

    func syncSessionPausedIfNeeded(_ paused: Bool) {
        guard paused != appliedSessionPaused else { return }
        appliedSessionPaused = paused
        if paused {
            pauseSession()
        } else {
            resumeSession()
        }
    }

    // MARK: - Coaching overlay delegate

    func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView) {
        isCoachingActive = true
    }

    func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
        isCoachingActive = false
        if !hasCompletedCoachingOnce {
            hasCompletedCoachingOnce = true
            coachingOverlayView.activatesAutomatically = false
        }
    }

    // MARK: - Session delegate

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.isRelocalizing = true
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        let configuration = ARSceneView.makeWorldTrackingConfiguration()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        hideRing()
        clearAllMeasurements()

        DispatchQueue.main.async {
            self.isRelocalizing = false
        }
    }

    /// Hide crosshair and clear smoothing so the next valid aim snaps cleanly (no freeze-then-jump).
    private func hideRingForSessionReset() {
        ringEntity?.isEnabled = false
        smoothPosition = nil
        smoothRotation = nil
        smoothNormal = nil
        lastUpdateTime = 0
        lastRawTargetPos = nil
        smoothedTargetSpeed = 0
        lastReticleDepthMeters = nil
        consecutiveMisses = 0
        consecutiveHits = 0
        lastAutolockedPinWorld = nil
        latestPinAutolockWorld = nil
        // Keep the SwiftUI dot in lockstep with the ring: whenever the ring is force-hidden,
        // the dot (and the + button) must not claim a valid target.
        DispatchQueue.main.async { self.hasValidTarget = false }
    }

    func hideRing() {
        hideRingForSessionReset()
        if self.draftSegmentStart != nil {
            self.clearSingleMarkPreviewVisuals()
        }
    }
}
