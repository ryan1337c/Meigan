//
//  FlattenMeasurementMode+ScanQuality.swift
//  Meigan
//
//  Post-analysis validation of the 4-corner quad (size, planarity, collinearity, convexity).
//

import Foundation
import simd

extension FlattenMeasurementMode {
    enum FlattenScanOutcome {
        case success
        case failure(String)
    }

    struct FlattenScanQuality {
        private enum Thresholds {
            /// Reject very small selections where corner noise dominates the geometry.
            static let minimumPrimarySigma: Float = 0.03
            /// Reject if any neighboring corner pair is effectively clustered together.
            static let minimumEdgeLengthMeters: Float = 0.02
            /// A flat quad should have very little variance along the third singular axis.
            static let maximumPlanarityRatio: Float = 0.08
            /// A usable quad needs real spread along two axes, not just one line.
            static let minimumCollinearityRatio: Float = 0.08
        }

        /// Evaluates the completed quad using the SVD-based plane analysis and world-space corners.
        static func evaluate(analysis: FlattenScanAnalysis, points: [SIMD3<Float>]) -> FlattenScanOutcome {
            let sigmas = analysis.singularValues
            guard sigmas.count == 3, points.count == 4, analysis.points2D.count == 4 else {
                return .failure("Scan failed. Complete all 4 corners and try again.")
            }

            let primary = sigmas[0]
            let secondary = sigmas[1]
            let tertiary = sigmas[2]

            // Guards against points that are too close together, too collinear, or not planar enough
            guard primary >= Thresholds.minimumPrimarySigma else {
                return .failure("Scan failed. The selected corners are too close together.")
            }

            if minimumNeighborDistance(points) < Thresholds.minimumEdgeLengthMeters {
                return .failure("Scan failed. Move corners farther apart, then scan again.")
            }

            guard secondary / primary >= Thresholds.minimumCollinearityRatio else {
                return .failure("Scan failed. The selected corners are too close to a straight line.")
            }

            guard tertiary / primary <= Thresholds.maximumPlanarityRatio else {
                return .failure("Scan failed. The selected corners are not planar enough.")
            }

            guard isConvex(analysis.points2D) else {
                return .failure("Scan failed. The 4 corners must form a convex quad (no bow-tie overlap).")
            }

            guard analysis.imagePlanePoints.count == 4,
                  analysis.destinationCanvasCorners.count == 4,
                  analysis.imageToCanvasHomography != nil,
                  analysis.physicalSizeMeters.x > 0,
                  analysis.physicalSizeMeters.y > 0,
                  analysis.pixelsPerMeter > 0
            else {
                return .failure("Scan failed. Could not map corners to the scan canvas.")
            }

            return .success
        }

        private static func minimumNeighborDistance(_ points: [SIMD3<Float>]) -> Float {
            guard points.count > 1 else { return 0 }
            var minimum = Float.greatestFiniteMagnitude
            for index in points.indices {
                let nextIndex = points.index(after: index) == points.endIndex ? points.startIndex : points.index(after: index)
                minimum = min(minimum, simd_distance(points[index], points[nextIndex]))
            }
            return minimum
        }

        /// Operates on the in-plane 2D coordinates produced by `scanAnalysis` so the
        /// same projection can be reused later (e.g. homography to image pixels).
        private static func isConvex(_ projected: [SIMD2<Float>]) -> Bool {
            guard projected.count == 4 else { return false }
            let epsilon: Float = 1e-6

            // Bow-tie / self-intersection rejection.
            if segmentsIntersect(projected[0], projected[1], projected[2], projected[3], epsilon: epsilon) {
                return false
            }
            if segmentsIntersect(projected[1], projected[2], projected[3], projected[0], epsilon: epsilon) {
                return false
            }

            // Convexity: all consecutive turns must keep the same sign.
            var turnSign: Float = 0
            for index in projected.indices {
                let a = projected[index]
                let b = projected[(index + 1) % projected.count]
                let c = projected[(index + 2) % projected.count]
                let turn = crossZ(a, b, c)
                if abs(turn) <= epsilon { return false }
                if turnSign == 0 {
                    turnSign = turn
                } else if turnSign * turn < 0 {
                    return false
                }
            }
            return true
        }

        private static func crossZ(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            let ab = b - a
            let ac = c - a
            return ab.x * ac.y - ab.y * ac.x
        }

        private static func segmentsIntersect(
            _ p1: SIMD2<Float>,
            _ q1: SIMD2<Float>,
            _ p2: SIMD2<Float>,
            _ q2: SIMD2<Float>,
            epsilon: Float
        ) -> Bool {
            let o1 = crossZ(p1, q1, p2)
            let o2 = crossZ(p1, q1, q2)
            let o3 = crossZ(p2, q2, p1)
            let o4 = crossZ(p2, q2, q1)

            if abs(o1) <= epsilon, onSegment(p1, p2, q1, epsilon: epsilon) { return true }
            if abs(o2) <= epsilon, onSegment(p1, q2, q1, epsilon: epsilon) { return true }
            if abs(o3) <= epsilon, onSegment(p2, p1, q2, epsilon: epsilon) { return true }
            if abs(o4) <= epsilon, onSegment(p2, q1, q2, epsilon: epsilon) { return true }

            return (o1 > 0 && o2 < 0 || o1 < 0 && o2 > 0) &&
                   (o3 > 0 && o4 < 0 || o3 < 0 && o4 > 0)
        }

        private static func onSegment(
            _ start: SIMD2<Float>,
            _ point: SIMD2<Float>,
            _ end: SIMD2<Float>,
            epsilon: Float
        ) -> Bool {
            point.x <= max(start.x, end.x) + epsilon &&
            point.x >= min(start.x, end.x) - epsilon &&
            point.y <= max(start.y, end.y) + epsilon &&
            point.y >= min(start.y, end.y) - epsilon
        }
    }
}
