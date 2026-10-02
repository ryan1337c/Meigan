//
//  FlattenContourMeasurementTests.swift
//  MeiganTests
//
//  Synthetic-mask checks for the Flatten contour, perimeter, and oriented chord pipeline,
//  plus interior / exterior placement in `FlattenDimensionLayout`.
//

import CoreGraphics
import Foundation
import Testing
@testable import Meigan

struct FlattenContourMeasurementTests {

    // MARK: - Contour and Dimensions

    @Test func circlePerimeterMatchesCircumference() throws {
        let radius: CGFloat = 200
        let center = CGPoint(x: 300, y: 300)
        let candidate = try #require(candidate(width: 600, height: 600) { point in
            radius - hypot(point.x - center.x, point.y - center.y)
        })

        let expected = 2 * .pi * radius
        #expect(abs(candidate.perimeterPixels - expected) / expected < 0.003)
        #expect(candidate.orientationRadians == 0)
        #expect(abs(candidate.widthSegment.length - 2 * radius) <= 1)
        #expect(abs(candidate.heightSegment.length - 2 * radius) <= 1)
    }

    @Test func rotatedRectangleRecoversAngleSidesAndPerimeter() throws {
        let angle: CGFloat = 30 * .pi / 180
        let candidate = try #require(candidate(width: 600, height: 600) { point in
            Self.boxDistance(point, center: CGPoint(x: 300, y: 300), halfSize: CGSize(width: 150, height: 60), angle: angle)
        })

        #expect(abs(candidate.orientationRadians - angle) * 180 / .pi < 0.5)
        #expect(abs(candidate.widthSegment.length - 300) <= 1)
        #expect(abs(candidate.heightSegment.length - 120) <= 1)
        #expect(abs(candidate.perimeterPixels - 840) / 840 < 0.003)
    }

    @Test func tShapeChordsSpanCrossbarAndFullHeight() throws {
        let crossbar = CGRect(x: 100, y: 100, width: 400, height: 60)
        let stem = CGRect(x: 270, y: 150, width: 60, height: 310)
        let candidate = try #require(candidate(width: 600, height: 600) { point in
            max(Self.boxDistance(point, rect: crossbar), Self.boxDistance(point, rect: stem))
        })

        #expect(abs(candidate.orientationRadians) * 180 / .pi < 0.5)
        #expect(abs(candidate.widthSegment.length - crossbar.width) <= 1)
        #expect(abs(candidate.heightSegment.length - (stem.maxY - crossbar.minY)) <= 1)
    }

    /// A horseshoe's widest horizontal chord crosses the arc below the inner hole, which is
    /// narrower than the arms' outer extent.
    @Test func uShapeWidthChordIsShorterThanOuterExtent() throws {
        let center = CGPoint(x: 300, y: 250)
        let outerRadius: CGFloat = 200
        let innerRadius: CGFloat = 120
        let leftArm = CGRect(x: 100, y: 80, width: 80, height: 180)
        let rightArm = CGRect(x: 420, y: 80, width: 80, height: 180)
        let candidate = try #require(candidate(width: 600, height: 600) { point in
            let distance = hypot(point.x - center.x, point.y - center.y)
            let ring = min(outerRadius - distance, distance - innerRadius)
            let lowerHalfRing = min(ring, point.y - center.y)
            return max(lowerHalfRing, Self.boxDistance(point, rect: leftArm), Self.boxDistance(point, rect: rightArm))
        })

        let outerExtent = candidate.boundingRectImage.width
        let expectedChord = 2 * sqrt(outerRadius * outerRadius - innerRadius * innerRadius)
        #expect(abs(outerExtent - 2 * outerRadius) <= 1)
        #expect(candidate.widthSegment.length < outerExtent - 40)
        #expect(abs(candidate.widthSegment.length - expectedChord) <= 2)
    }

    // MARK: - Dimension Layout

    @Test func uprightRectangleDrawsBothAxesInside() throws {
        let finding = try #require(Self.finding(contour: Self.rectangle(
            center: CGPoint(x: 400, y: 400), size: CGSize(width: 300, height: 120), angle: 0
        )))
        let viewBounds = CGRect(x: 0, y: 0, width: 800, height: 800)

        #expect(!placement(.width, of: finding, viewBounds: viewBounds).isExterior)
        #expect(!placement(.height, of: finding, viewBounds: viewBounds).isExterior)
    }

    @Test func thinTiltedStripDrawsHeightOutsideAtChordLength() throws {
        let finding = try #require(Self.finding(contour: Self.rectangle(
            center: CGPoint(x: 400, y: 400), size: CGSize(width: 300, height: 12), angle: 40 * .pi / 180
        )))
        let viewBounds = CGRect(x: 0, y: 0, width: 800, height: 800)

        guard case .exterior(let dimensionLine, _, _) = placement(.height, of: finding, viewBounds: viewBounds) else {
            Issue.record("Expected the 12 px height to be drawn outside the strip")
            return
        }
        #expect(abs(dimensionLine.length - finding.heightSegment.length) < 1e-6)
    }

    @Test func shapeAgainstRightEdgePlacesExteriorLineOnLeft() throws {
        let finding = try #require(Self.finding(contour: Self.rectangle(
            center: CGPoint(x: 775, y: 400), size: CGSize(width: 10, height: 300), angle: 0
        )))
        let viewBounds = CGRect(x: 0, y: 0, width: 800, height: 800)

        guard case .exterior(let dimensionLine, _, _) = placement(.height, of: finding, viewBounds: viewBounds) else {
            Issue.record("Expected the height of a 10 px strip to be drawn outside it")
            return
        }
        let contourMinX = try #require(finding.contourImage.map(\.x).min())
        #expect(dimensionLine.start.x < contourMinX)
        #expect(dimensionLine.end.x < contourMinX)
    }

    @Test func shapeFillingImageFallsBackToInterior() throws {
        let finding = try #require(Self.finding(contour: Self.rectangle(
            center: CGPoint(x: 15, y: 15), size: CGSize(width: 30, height: 30), angle: 0
        )))
        let viewBounds = CGRect(x: 0, y: 0, width: 30, height: 30)

        #expect(placement(.width, of: finding, viewBounds: viewBounds) == .interior(finding.widthSegment))
        #expect(placement(.height, of: finding, viewBounds: viewBounds) == .interior(finding.heightSegment))
    }

    // MARK: - Helpers

    /// Traces a mask whose value ramps linearly from 0 to 1 across the 1 px band around
    /// `signedDistance == 0` (positive inside), sampled at pixel centers.
    private func candidate(
        width: Int,
        height: Int,
        signedDistance: (CGPoint) -> CGFloat
    ) -> FlattenRectifiedEdgeAnalysis.ShapeCandidate? {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let distance = signedDistance(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                values[y * width + x] = Float(min(max(distance + 0.5, 0), 1))
            }
        }
        let mask = FlattenSoftMask(
            imageWidth: width,
            imageHeight: height,
            originX: 0,
            originY: 0,
            width: width,
            height: height,
            values: values
        )
        return FlattenRectifiedEdgeAnalysis.makeCandidate(
            from: mask,
            imageBounds: CGRect(x: 0, y: 0, width: width, height: height),
            tuning: .default
        )
    }

    private func placement(
        _ axis: FlattenDimensionLayout.Axis,
        of finding: FlattenShapeFinding,
        viewBounds: CGRect
    ) -> FlattenDimensionPlacement {
        FlattenDimensionLayout.layout(for: axis, of: finding, imageToView: .identity, viewBounds: viewBounds)
    }

    /// Signed distance to a rotated box, positive inside.
    private static func boxDistance(_ point: CGPoint, center: CGPoint, halfSize: CGSize, angle: CGFloat) -> CGFloat {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let localX = abs(dx * cos(angle) + dy * sin(angle)) - halfSize.width
        let localY = abs(-dx * sin(angle) + dy * cos(angle)) - halfSize.height
        let outside = hypot(max(localX, 0), max(localY, 0))
        let inside = min(max(localX, localY), 0)
        return -(outside + inside)
    }

    private static func boxDistance(_ point: CGPoint, rect: CGRect) -> CGFloat {
        boxDistance(
            point,
            center: CGPoint(x: rect.midX, y: rect.midY),
            halfSize: CGSize(width: rect.width / 2, height: rect.height / 2),
            angle: 0
        )
    }

    /// Closed rotated rectangle with the first corner repeated at the end.
    private static func rectangle(center: CGPoint, size: CGSize, angle: CGFloat) -> [CGPoint] {
        let halfU = CGVector(dx: cos(angle) * size.width / 2, dy: sin(angle) * size.width / 2)
        let halfV = CGVector(dx: -sin(angle) * size.height / 2, dy: cos(angle) * size.height / 2)
        let signs: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let corners = signs.map { (su: CGFloat, sv: CGFloat) -> CGPoint in
            let x: CGFloat = center.x + su * halfU.dx + sv * halfV.dx
            let y: CGFloat = center.y + su * halfU.dy + sv * halfV.dy
            return CGPoint(x: x, y: y)
        }
        return corners + [corners[0]]
    }

    private static func finding(contour: [CGPoint]) -> FlattenShapeFinding? {
        guard let dimensions = FlattenRectifiedEdgeAnalysis.orientedDimensions(of: contour) else { return nil }
        let bounds = FlattenRectifiedEdgeAnalysis.boundingBox(of: contour)
        return FlattenShapeFinding(
            id: UUID(),
            contourImage: contour,
            boundingRectImage: bounds,
            boundingRectNormalized: bounds,
            widthSegment: dimensions.widthSegment,
            heightSegment: dimensions.heightSegment,
            orientationRadians: dimensions.orientationRadians,
            widthMeters: Float(dimensions.widthSegment.length),
            heightMeters: Float(dimensions.heightSegment.length),
            perimeterMeters: 0,
            lengthKind: .outerContour
        )
    }
}
