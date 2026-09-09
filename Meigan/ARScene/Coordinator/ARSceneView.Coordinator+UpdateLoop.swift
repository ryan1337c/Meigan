//
//  ARSceneView.Coordinator+UpdateLoop.swift
//  Meigan
//
//  Per-frame RealityKit scene update: reticle smoothing, validity debounce, mode previews.
//

import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

extension ARSceneView.Coordinator {
    // MARK: - Per-frame update loop

    private func publishFlattenScanCornersReady(_ arView: ARView) {
        let ready: Bool
        if isFlattenMode,
           flattenAdjustingPointIndex == nil,
           committedSegments.count == 3,
           draftSegmentStart == nil {
            ready = flattenMode.scanCornersVisible(in: arView)
        } else {
            ready = false
        }
        guard ready != lastFlattenScanCornersReady else { return }
        lastFlattenScanCornersReady = ready
        DispatchQueue.main.async {
            self.flattenScanCornersReady = ready
        }
    }

    func startUpdateLoop() {
        guard let arView else { return }

        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) {
            [weak self] _ in
            guard let self = self, let arView = self.arView else { return }
            self.publishFlattenScanCornersReady(arView)
            let now = CACurrentMediaTime()

            guard let currentFrame = arView.session.currentFrame else {
                self.consecutiveBadTrackingFrames += 1
                if self.consecutiveBadTrackingFrames >= self.badTrackingThreshold {
                    self.hideRing()
                }
                return
            }

            // Update lighting guidance
            self.updateSmoothedAmbientIntensity(currentFrame.lightEstimate)
            self.updateTooDarkLightingDebounced()

            // Custom motion detection (replaces ARKit's excessive motion)
            let currentTransform = currentFrame.camera.transform
            let currentPos = SIMD3<Float>(
                currentTransform.columns.3.x,
                currentTransform.columns.3.y,
                currentTransform.columns.3.z
            )

            if let lastTransform = self.lastCameraTransform {
                let lastPos = SIMD3<Float>(
                    lastTransform.columns.3.x,
                    lastTransform.columns.3.y,
                    lastTransform.columns.3.z
                )
                let displacement = simd_distance(currentPos, lastPos)
                let rotationDelta = Self.rotationDeltaRadians(from: lastTransform, to: currentTransform)
                let motionScore = self.customExcessiveMotionDisplacementWeight * displacement
                    + self.customExcessiveMotionRotationWeight * rotationDelta

                if motionScore > self.customExcessiveMotionThreshold {
                    self.customExcessiveMotionFrameCount += 1
                    if self.customExcessiveMotionFrameCount >= self.customExcessiveMotionShowThreshold {
                        if !self.customExcessiveMotionActive {
                            self.customExcessiveMotionActive = true
                            self.publishCustomExcessiveMotion(true)
                        }
                    }
                } else {
                    // Decay counter
                    if self.customExcessiveMotionFrameCount > 0 {
                        self.customExcessiveMotionFrameCount -= 1
                    }
                    if self.customExcessiveMotionFrameCount == 0 && self.customExcessiveMotionActive {
                        self.customExcessiveMotionActive = false
                        self.publishCustomExcessiveMotion(false)
                    }
                }
            }
            self.lastCameraTransform = currentTransform

            switch currentFrame.camera.trackingState {
                case .normal:
                    updateARKitTrackingGuide(nil)
                    consecutiveBadTrackingFrames = 0

                case .limited(let reason):
                    consecutiveBadTrackingFrames += 1
                    updateARKitTrackingGuide(reason == .insufficientFeatures ? reason : nil)
                    updatePlacementGuide(.none)
                    if consecutiveBadTrackingFrames >= badTrackingThreshold {
                        hideRing()
                    }
                    return

                case .notAvailable:
                    consecutiveBadTrackingFrames += 1
                    updateARKitTrackingGuide(nil)
                    updatePlacementGuide(.none)
                    if consecutiveBadTrackingFrames >= badTrackingThreshold {
                        hideRing()
                    }
                    return
            }
            // if currentFrame.camera.trackingState != .normal {
            //     self.consecutiveBadTrackingFrames += 1
            //     if self.consecutiveBadTrackingFrames >= self.badTrackingThreshold {
            //         self.hideRing()
            //     }
            //     return
            // }
            // self.consecutiveBadTrackingFrames = 0

            // Hide the ring if coaching is active
            if self.isCoachingActive {
                self.updatePlacementGuide(.none)
                self.hideRing()
                return
            }

            if self.isFlattenScanSnapshotCaptureActive || self.isFlattenScanActive {
                self.ringEntity?.isEnabled = false
                self.updatePlacementGuide(.none)
                self.updatePinAutolockHaptics(pinWorld: nil)
                self.latestPinAutolockWorld = nil
                self.lineMidHoverDotEntity?.isEnabled = false
                DispatchQueue.main.async { self.hasValidTarget = false }
                return
            }

            if self.displayedTrackingGuideIssue != .none {
                self.updatePlacementGuide(.none)
                self.updatePinAutolockHaptics(pinWorld: nil)
                self.latestPinAutolockWorld = nil
                self.lineMidHoverDotEntity?.isEnabled = false
                self.hideRing()
                return
            }

            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            let ct = currentFrame.camera.transform
            let camForLabel = SIMD3<Float>(ct.columns.3.x, ct.columns.3.y, ct.columns.3.z)
            let camUp = simd_normalize(SIMD3<Float>(ct.columns.1.x, ct.columns.1.y, ct.columns.1.z))

            if self.isIdentifyMode {
                self.ringEntity?.isEnabled = false
                self.updatePlacementGuide(.none)
                self.updatePinAutolockHaptics(pinWorld: nil)
                self.latestPinAutolockWorld = nil
                self.lineMidHoverDotEntity?.isEnabled = false
                self.currentMode.updateAfterReticle(
                    reticleWorld: .zero,
                    camWorld: camForLabel,
                    camUp: camUp
                )
                DispatchQueue.main.async { self.hasValidTarget = false }
                return
            }

            self.currentMode.resetAutolockBookkeepingIfNeeded()
            if !self.committedSegments.isEmpty {
                self.updateCommittedSegmentLabelsHoverAndMidDot(
                    arView: arView,
                    screenCenter: center,
                    camForLabel: camForLabel,
                    camUp: camUp
                )
            } else {
                self.lineMidHoverDotEntity?.isEnabled = false
            }

            let camPos = SIMD3<Float>(
                currentFrame.camera.transform.columns.3.x,
                currentFrame.camera.transform.columns.3.y,
                currentFrame.camera.transform.columns.3.z
            )

            // Nearest visible surface across LiDAR mesh + existing planes + estimated planes.
            let hit = self.raycastReticle(from: center, cameraPosition: camPos, in: arView)

            func registerMiss() {
                self.consecutiveHits = 0
                self.consecutiveMisses += 1
                if self.consecutiveMisses >= self.missThreshold {
                    self.hideRing()
                }
            }

            let pinCandidates = self.currentMode.pinCandidates()
            let pinLockWorld = Self.linePinpointScreenAutolockWorld(
                candidates: pinCandidates,
                arView: arView,
                screenCenter: center
            )

            enum AimClassification {
                case tooClose
                case noSurface
                case valid(targetPos: SIMD3<Float>, useCameraFacingNormal: Bool)
            }

            let aimClassification: AimClassification
            if let pin = pinLockWorld {
                let distance = simd_distance(pin, camPos)
                if distance < self.minReticlePlacementDistanceMeters {
                    aimClassification = .tooClose
                } else if distance > 3.0 {
                    aimClassification = .noSurface
                } else {
                    // When snapping to an endpoint/mid off the current raycast plane, orient the ring toward the camera.
                    aimClassification = .valid(targetPos: pin, useCameraFacingNormal: true)
                }
            } else if let h = hit {
                let distance = simd_distance(h.position, camPos)
                if distance < self.minReticlePlacementDistanceMeters {
                    aimClassification = .tooClose
                } else if distance > 3.0 {
                    aimClassification = .noSurface
                } else {
                    aimClassification = .valid(targetPos: h.position, useCameraFacingNormal: false)
                }
            } else {
                aimClassification = .noSurface
            }

            let targetPos: SIMD3<Float>
            let useCameraFacingNormal: Bool
            /// True when this frame is a raycast miss inside the debounce window and the ring is
            /// being held on the center ray at the last depth (cosmetic + placement coherence).
            var isHeldMiss = false
            switch aimClassification {
            case .tooClose:
                self.updatePlacementGuide(.tooClose)
                self.updatePinAutolockHaptics(pinWorld: nil)
                self.latestPinAutolockWorld = nil
                // Too-close is promoted guidance: hide immediately so crosshair/+ reflect invalid aim
                // without waiting for missThreshold debounce.
                self.hideRing()
                return
            case .noSurface:
                self.updatePlacementGuide(.findNearbySurface)
                self.updatePinAutolockHaptics(pinWorld: nil)
                self.latestPinAutolockWorld = nil
                registerMiss()
                // Inside the miss debounce window the ring is still shown. Rather than leaving it
                // parked at a stale world position (which drifts off the dot as the camera moves),
                // hold it on the current center ray at the last known depth. Once the threshold
                // trips, registerMiss() has hidden the ring and we fall out here.
                guard self.ringEntity?.isEnabled == true,
                      let held = self.heldReticleTarget(arView: arView, screenCenter: center) else {
                    return
                }
                targetPos = held
                useCameraFacingNormal = false
                isHeldMiss = true
            case .valid(let classifiedPos, let classifiedUseCameraFacingNormal):
                self.updatePlacementGuide(.none)
                targetPos = classifiedPos
                useCameraFacingNormal = classifiedUseCameraFacingNormal
            }

            if !isHeldMiss {
                self.updatePinAutolockHaptics(pinWorld: pinLockWorld)
                self.latestPinAutolockWorld = pinLockWorld

                // Valid aim (surface raycast and/or line pinpoint autolock)
                self.consecutiveMisses = 0
                let ringWasVisible = self.ringEntity?.isEnabled == true
                if !ringWasVisible {
                    self.consecutiveHits += 1
                    guard self.consecutiveHits >= self.showThreshold else { return }
                }
                self.lastReticleDepthMeters = simd_distance(targetPos, camPos)
            }

            // Stable rotation: low-pass the normal before building basis (reduces visible spin on 3-arc ring).
            var rawNormal: SIMD3<Float>
            if isHeldMiss, let heldNormal = self.smoothNormal {
                // Keep the last surface orientation; don't tilt toward the camera for a few frames.
                rawNormal = heldNormal
            } else if useCameraFacingNormal {
                rawNormal = simd_normalize(camPos - targetPos)
            } else if let h = hit {
                rawNormal = h.normal
            } else {
                rawNormal = simd_normalize(camPos - targetPos)
            }
            // The ring mesh is single-sided (+Y front). ARKit plane normals can point away from the
            // viewer (vertical planes with flipped Y, ceilings/undersides), which would back-face
            // cull the whole ring while the dot stays visible. Always face the camera hemisphere.
            if simd_dot(rawNormal, camPos - targetPos) < 0 {
                rawNormal = -rawNormal
            }
            let normal: SIMD3<Float>
            if let prevN = self.smoothNormal {
                normal = simd_normalize(simd_mix(prevN, rawNormal, SIMD3<Float>(repeating: self.normalSmoothAlpha)))
            } else {
                normal = rawNormal
            }
            self.smoothNormal = normal

            let camFwd = -SIMD3<Float>(
                currentFrame.camera.transform.columns.2.x,
                currentFrame.camera.transform.columns.2.y,
                currentFrame.camera.transform.columns.2.z
            )
            let projected = camFwd - simd_dot(camFwd, normal) * normal
            let ref: SIMD3<Float>
            if simd_length(projected) > 0.001 {
                ref = simd_normalize(projected)
            } else {
                ref = abs(simd_dot(normal, SIMD3<Float>(0, 1, 0))) < 0.99
                    ? SIMD3<Float>(0, 1, 0)
                    : SIMD3<Float>(0, 0, 1)
            }
            let tangentX = simd_normalize(simd_cross(ref, normal))
            let tangentZ = simd_cross(tangentX, normal)
            let targetRot = simd_quatf(simd_float3x3(columns: (tangentX, normal, tangentZ)))

            // Velocity-adaptive delta-time smoothing.
            // Smoothing is cosmetic (ring visuals only). Placement, previews, and
            // readouts use the raw raycast target so committed points land exactly
            // on the detected surface instead of trailing the smoothed reticle.
            let pos: SIMD3<Float>
            let rot: simd_quatf

            if let prevPos = self.smoothPosition, let prevRot = self.smoothRotation, self.lastUpdateTime > 0 {
                let dt = Float(now - self.lastUpdateTime)
                let clampedDt = min(max(dt, 0.001), 0.1)

                let displacement = simd_distance(targetPos, prevPos)

                // Speed of the *raw target* between frames. Using target-vs-smoothed distance here
                // (the old approach) under-reports slow continuous pans and keeps the alpha pinned
                // at its floor, so the ring trails ~12 frames behind the dot.
                let rawTargetStep = self.lastRawTargetPos.map { simd_distance(targetPos, $0) } ?? 0
                let instantSpeed = rawTargetStep / clampedDt
                self.smoothedTargetSpeed = simd_mix(self.smoothedTargetSpeed, instantSpeed, 0.35)

                if displacement > self.reticleSurfaceSnapDistanceMeters {
                    pos = targetPos
                    rot = targetRot
                } else {
                    let speed = max(self.smoothedTargetSpeed, displacement / clampedDt)
                    let velocityFactor = min(speed / 0.5, 1.0)

                    let adaptivePosAlpha: Float = 0.08 + velocityFactor * 0.42
                    // Slower rotation blend at rest = less jitter; still responsive when moving fast.
                    let adaptiveRotAlpha: Float = 0.035 + velocityFactor * 0.22

                    let posT = 1.0 - pow(1.0 - adaptivePosAlpha, clampedDt * 60.0)
                    let rotT = 1.0 - pow(1.0 - adaptiveRotAlpha, clampedDt * 60.0)

                    pos = simd_mix(prevPos, targetPos, SIMD3<Float>(repeating: posT))
                    rot = simd_slerp(prevRot, targetRot, rotT)
                }
            } else {
                pos = targetPos
                rot = targetRot
            }
            self.lastUpdateTime = now
            self.lastRawTargetPos = targetPos

            self.smoothPosition = pos
            self.smoothRotation = rot

            self.ringEntity?.position = pos
            self.ringEntity?.orientation = rot
            self.ringEntity?.isEnabled = true
            self.latestReticleWorldPosition = targetPos

            self.currentMode.updateAfterReticle(
                reticleWorld: targetPos,
                camWorld: camForLabel,
                camUp: camUp
            )

            DispatchQueue.main.async { self.hasValidTarget = true }
        }
    }
}
