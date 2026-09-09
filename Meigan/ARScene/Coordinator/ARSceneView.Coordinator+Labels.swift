//
//  ARSceneView.Coordinator+Labels.swift
//  Meigan
//
//  3D measurement readout labels: pill + text meshes, fixed-screen-size scaling, and view-aligned orientation.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

// MARK: - Measurement readout (compact black text + white bordered pill)

enum MeasurementLabelStyle {
    /// Slightly larger than text layout so the pill reads as a border around the readout.
    static let pillWidth: Float = 0.084
    static let pillHeight: Float = 0.028
    static let textFrame = CGRect(x: 0, y: 0, width: 0.074, height: 0.02)
    static let fontMeters: CGFloat = 0.016
    /// Prefer Helvetica (stable PostScript name) for extruded text; fall back to SF UI if needed.
    private static let meshFontPostScriptCandidates = ["Helvetica", ".SFUI-Regular"]
    /// Shift readout slightly toward the camera so it sorts in front of the dashed line (avoids z‑fight / line cutting the pill).
    static let labelTowardCameraBiasMeters: Float = 0.007

    /// Font for `MeshResource.generateText` — PostScript names only (avoids CoreText display-name notes).
    static func meshFontForGenerateText() -> MeshResource.Font {
        for psName in meshFontPostScriptCandidates {
            if let font = MeshResource.Font(name: psName, size: fontMeters) {
                return font
            }
        }
        return MeshResource.Font.systemFont(ofSize: fontMeters)
    }

    /// Strips characters that tend to pull in fallback fonts during `generateText` shaping.
    /// `fileprivate` so `Coordinator` call sites in this file can use it (`private` would limit access to this enum only).
    static func meshDisplayText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
    }
    /// At this camera–label distance, world scale is 1.0 (matches previous “natural” size at arm’s length).
    static let labelReferenceCameraDistanceMeters: Float = 0.65
    static let labelDistanceScaleMin: Float = 0.3
    static let labelDistanceScaleMax: Float = 12.0

    static func borderedPillMaterial() -> UnlitMaterial {
        let pixW = 384
        let ratio = CGFloat(pillHeight / pillWidth)
        let pixH = max(64, Int(CGFloat(pixW) * ratio))
        let w = CGFloat(pixW)
        let h = CGFloat(pixH)
        let format = UIGraphicsImageRendererFormat()
        // Transparent outside the pill so the plane isn’t a white rectangle with a rounded stroke inside it.
        format.opaque = false
        format.scale = 2.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let borderWidth: CGFloat = 2.25
        let image = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.cgContext.clear(rect)

            // Tiny inset from texture edge for anti-aliasing.
            let outer = rect.insetBy(dx: 1.0, dy: 1.0)
            let outerR = min(outer.width, outer.height) * 0.5
            let outerPath = UIBezierPath(roundedRect: outer, cornerRadius: outerR)

            // Border = gray “ring”; fill = white inner capsule (same shape, inset).
            UIColor(white: 0.82, alpha: 1).setFill()
            outerPath.fill()

            let inner = outer.insetBy(dx: borderWidth, dy: borderWidth)
            guard inner.width > 2, inner.height > 2 else { return }
            let innerR = min(inner.width, inner.height) * 0.5
            let innerPath = UIBezierPath(roundedRect: inner, cornerRadius: innerR)
            UIColor.white.setFill()
            innerPath.fill()
        }
        guard let cgImage = image.cgImage,
              let texture = try? TextureResource.generate(
                  from: cgImage,
                  options: TextureResource.CreateOptions(semantic: .color)
              )
        else {
            var m = UnlitMaterial()
            m.color = .init(tint: .white)
            return m
        }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        // Required so alpha outside the rounded pill shows as clear (not black / opaque quad).
        m.blending = .transparent(opacity: 1.0)
        return m
    }
}

extension ARSceneView.Coordinator {
    /// Pill + extruded text stack for one segment readout (centroid-aligned like the original single label).
    static func makeMeasurementLabelStack(displayText: String) -> Entity {
        let root = Entity()
        let pillMesh = MeshResource.generatePlane(
            width: MeasurementLabelStyle.pillWidth,
            depth: MeasurementLabelStyle.pillHeight
        )
        let pill = ModelEntity(mesh: pillMesh, materials: [MeasurementLabelStyle.borderedPillMaterial()])
        pill.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        pill.position = SIMD3<Float>(0, 0, -0.0006)
        let font = MeasurementLabelStyle.meshFontForGenerateText()
        let frame = MeasurementLabelStyle.textFrame
        let mesh = MeshResource.generateText(
            MeasurementLabelStyle.meshDisplayText(displayText),
            extrusionDepth: 0.0005,
            font: font,
            containerFrame: frame,
            alignment: .center,
            lineBreakMode: .byClipping
        )
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.black)
        let textEnt = ModelEntity(mesh: mesh, materials: [mat])
        textEnt.position = SIMD3<Float>(repeating: 0)
        root.addChild(pill)
        root.addChild(textEnt)
        let box = textEnt.visualBounds(relativeTo: root)
        let span = box.max - box.min
        if simd_length(span) > 1e-6 {
            let c = (box.min + box.max) * 0.5
            textEnt.position = SIMD3<Float>(-c.x, -c.y, -c.z + 0.001)
        } else {
            textEnt.position = SIMD3<Float>(0, 0, 0.001)
        }
        return root
    }


    func rebuildDraftPreviewLabelMesh(text: String) {
        guard let textEntity = draftLabelTextEntity, let parent = textEntity.parent else { return }
        let font = MeasurementLabelStyle.meshFontForGenerateText()
        let frame = MeasurementLabelStyle.textFrame
        let mesh = MeshResource.generateText(
            MeasurementLabelStyle.meshDisplayText(text),
            extrusionDepth: 0.0005,
            font: font,
            containerFrame: frame,
            alignment: .center,
            lineBreakMode: .byClipping
        )
        var mat = UnlitMaterial()
        mat.color = .init(tint: UIColor.black)
        textEntity.position = SIMD3<Float>(repeating: 0)
        textEntity.model = ModelComponent(mesh: mesh, materials: [mat])
        let box = textEntity.visualBounds(relativeTo: parent)
        let span = box.max - box.min
        if simd_length(span) > 1e-6 {
            let center = (box.min + box.max) * 0.5
            textEntity.position = SIMD3<Float>(-center.x, -center.y, -center.z + 0.001)
        } else {
            textEntity.position = SIMD3<Float>(0, 0, 0.001)
        }
    }

    /// Scale ∝ distance so angular size on screen stays ~constant (RealityKit has no z‑index; this is the usual AR HUD trick).
    static func measurementLabelUniformScaleForFixedScreenSize(
        cameraWorld: SIMD3<Float>,
        labelWorldPosition: SIMD3<Float>
    ) -> Float {
        let d = simd_distance(cameraWorld, labelWorldPosition)
        guard d > 1e-4 else {
            return MeasurementLabelStyle.labelDistanceScaleMax
        }
        let ref = MeasurementLabelStyle.labelReferenceCameraDistanceMeters
        var s = d / ref
        s = min(max(s, MeasurementLabelStyle.labelDistanceScaleMin), MeasurementLabelStyle.labelDistanceScaleMax)
        return s
    }

    /// View‑aligned billboard: +Z toward camera; +X follows **camera right** (projected into the label plane) so the string
    /// stays left‑to‑right on screen. Segment direction is only a fallback when the line is parallel to the view.
    static func measurementLabelViewAlignedQuaternion(
        labelPosition: SIMD3<Float>,
        segmentFrom a: SIMD3<Float>,
        segmentTo b: SIMD3<Float>,
        cameraWorld: SIMD3<Float>?,
        cameraUpWorld: SIMD3<Float>?
    ) -> simd_quatf {
        let delta = b - a
        let dLen = simd_length(delta)
        let worldUp = SIMD3<Float>(0, 1, 0)
        guard dLen > 1e-5 else {
            if let cam = cameraWorld {
                return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
            }
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let dir = delta / dLen

        guard let cam = cameraWorld else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let toCam = cam - labelPosition
        let vLen = simd_length(toCam)
        guard vLen > 1e-5 else {
            return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
        }
        let zAxis = toCam / vLen

        let forwardView = simd_normalize(labelPosition - cam)
        let upGuess = cameraUpWorld.map { simd_normalize($0) } ?? worldUp
        var upCam = upGuess - forwardView * simd_dot(upGuess, forwardView)
        var upCL = simd_length(upCam)
        if upCL < 1e-4 {
            upCam = worldUp - forwardView * simd_dot(worldUp, forwardView)
            upCL = simd_length(upCam)
        }
        guard upCL > 1e-5 else {
            return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
        }
        upCam /= upCL

        var rightView = simd_cross(forwardView, upCam)
        var rvLen = simd_length(rightView)
        if rvLen < 1e-4 {
            rightView = simd_cross(forwardView, SIMD3<Float>(1, 0, 0))
            rvLen = simd_length(rightView)
        }
        guard rvLen > 1e-5 else {
            return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
        }
        rightView /= rvLen

        var xAxis = rightView - zAxis * simd_dot(rightView, zAxis)
        let xLen = simd_length(xAxis)
        if xLen < 1e-4 {
            var t = dir - zAxis * simd_dot(dir, zAxis)
            var tLen = simd_length(t)
            if tLen < 1e-4 {
                t = simd_cross(zAxis, worldUp)
                tLen = simd_length(t)
                if tLen < 1e-4 {
                    t = simd_cross(zAxis, SIMD3<Float>(1, 0, 0))
                    tLen = simd_length(t)
                }
            }
            guard tLen > 1e-5 else {
                return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
            }
            t /= tLen
            xAxis = t
        } else {
            xAxis /= xLen
        }
        if simd_dot(xAxis, rightView) < 0 {
            xAxis = -xAxis
        }

        let yAxis = simd_normalize(simd_cross(zAxis, xAxis))
        guard simd_length(yAxis) > 1e-5 else {
            return quaternionFacingCameraOnly(labelPosition: labelPosition, cameraWorld: cam)
        }

        let rot = simd_float3x3(columns: (xAxis, yAxis, zAxis))
        var q = simd_quatf(rot)
        q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
        q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1)))

        let toC = cam - labelPosition
        if simd_length(toC) > 1e-5 {
            func frontFacesCamera(_ quat: simd_quatf) -> Bool {
                simd_dot(simd_act(quat, SIMD3<Float>(0, 0, 1)), toC) >= 0
            }
            if !frontFacesCamera(q) {
                q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)))
            }
            if !frontFacesCamera(q) {
                q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
            }
        }
        // 90° CCW on screen about the view axis (local +Z). Use −π/2 if you want the other direction.
        q = simd_mul(q, simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
        return q
    }

    private static func quaternionFacingCameraOnly(labelPosition: SIMD3<Float>, cameraWorld: SIMD3<Float>) -> simd_quatf {
        let toCam = cameraWorld - labelPosition
        let vLen = simd_length(toCam)
        guard vLen > 1e-5 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        let zAxis = toCam / vLen
        let worldUp = SIMD3<Float>(0, 1, 0)
        var xAxis = simd_normalize(simd_cross(worldUp, zAxis))
        if simd_length(xAxis) < 1e-5 {
            xAxis = SIMD3<Float>(1, 0, 0)
        }
        let yAxis = simd_normalize(simd_cross(zAxis, xAxis))
        let rot = simd_float3x3(columns: (xAxis, yAxis, zAxis))
        var q = simd_quatf(rot)
        q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
        q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1)))

        let toC = cameraWorld - labelPosition
        if simd_length(toC) > 1e-5 {
            func frontFacesCamera(_ quat: simd_quatf) -> Bool {
                simd_dot(simd_act(quat, SIMD3<Float>(0, 0, 1)), toC) >= 0
            }
            if !frontFacesCamera(q) {
                q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)))
            }
            if !frontFacesCamera(q) {
                q = simd_mul(q, simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
            }
        }
        q = simd_mul(q, simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)))
        return q
    }

    /// World position: segment midpoint, nudged toward `cameraWorld` so the billboard draws in front of the line.
    static func measurementLabelWorldPosition(
        segmentFrom a: SIMD3<Float>,
        segmentTo b: SIMD3<Float>,
        cameraWorld: SIMD3<Float>? = nil
    ) -> SIMD3<Float> {
        let mid = (a + b) * 0.5
        guard let cam = cameraWorld else { return mid }
        let toCam = cam - mid
        let len = simd_length(toCam)
        guard len > 1e-5 else { return mid }
        return mid + (toCam / len) * MeasurementLabelStyle.labelTowardCameraBiasMeters
    }

    /// Rotates +Y to align with `direction` (unit vector).
    static func quatAligningPositiveY(to direction: SIMD3<Float>) -> simd_quatf {
        let y = SIMD3<Float>(0, 1, 0)
        let d = simd_normalize(direction)
        let c = simd_cross(y, d)
        let cl = simd_length(c)
        if cl < 1e-6 {
            return simd_dot(y, d) >= 0 ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) : simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        }
        let axis = c / cl
        let angle = atan2(cl, simd_dot(y, d))
        return simd_quatf(angle: angle, axis: axis)
    }
}
