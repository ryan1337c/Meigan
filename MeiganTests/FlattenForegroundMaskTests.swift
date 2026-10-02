//
//  FlattenForegroundMaskTests.swift
//  MeiganTests
//
//  Vision subject-mask helpers: splitting one instance into per-object regions, and merging
//  extra objects found by the overlapping-tile pass.
//

import CoreGraphics
import Testing
@testable import Meigan

struct FlattenForegroundMaskTests {

    // MARK: - Region Split

    /// One Vision instance covering an L-shaped object, a second object inside the L's bounding
    /// box, and a speck becomes one mask per object. The speck is dropped, and the L's mask
    /// doesn't carry the other object's pixels even though their bounds overlap.
    @Test func splitSeparatesDisconnectedObjectsAndDropsSpecks() throws {
        let barTop = CGRect(x: 40, y: 40, width: 300, height: 40)
        let barLeft = CGRect(x: 40, y: 40, width: 40, height: 220)
        let inner = CGRect(x: 150, y: 120, width: 120, height: 100)
        let speck = CGRect(x: 360, y: 280, width: 4, height: 4)
        let scene = SyntheticMaskScene(width: 400, height: 300)
        let mask = scene.softMask { point in
            max(
                Self.boxDistance(point, rect: barTop),
                Self.boxDistance(point, rect: barLeft),
                Self.boxDistance(point, rect: inner),
                Self.boxDistance(point, rect: speck)
            )
        }

        let regions = mask.splitIntoRegions(threshold: 0.5, minimumPixelCount: 64, fringe: 2)
        #expect(regions.count == 2)
        let lRegion = try #require(regions.first { $0.value(atX: 60, y: 200) >= 0.5 })
        let innerRegion = try #require(regions.first { $0.value(atX: Int(inner.midX), y: Int(inner.midY)) >= 0.5 })

        #expect(lRegion.value(atX: Int(inner.midX), y: Int(inner.midY)) == 0)
        #expect(innerRegion.value(atX: 60, y: 200) == 0)
        expectEdges(of: try #require(scene.candidate(from: lRegion)).boundingRectImage, match: barTop.union(barLeft), tolerance: 1)
        expectEdges(of: try #require(scene.candidate(from: innerRegion)).boundingRectImage, match: inner, tolerance: 1)
    }

    @Test func splitKeepsSingleRegionMaskUnchanged() {
        let scene = SyntheticMaskScene(width: 400, height: 300)
        let mask = scene.softMask { Self.boxDistance($0, rect: CGRect(x: 120, y: 90, width: 160, height: 120)) }

        let regions = mask.splitIntoRegions(threshold: 0.5, minimumPixelCount: 64, fringe: 2)
        #expect(regions.count == 1)
        #expect(regions.first?.bounds == mask.bounds)
        #expect(regions.first?.values == mask.values)
    }

    // MARK: - Tiled Detection

    @Test func detectionTilesOverlapByAThirdAndCoverTheImage() {
        let tiles = FlattenRectifiedEdgeAnalysis.detectionTiles(imageWidth: 400, imageHeight: 300)
        #expect(tiles == [
            CGRect(x: 0, y: 0, width: 267, height: 200),
            CGRect(x: 133, y: 0, width: 267, height: 200),
            CGRect(x: 0, y: 100, width: 267, height: 200),
            CGRect(x: 133, y: 100, width: 267, height: 200),
        ])
    }

    /// Tile regions add only new, whole objects: a repeat of a full-image region is dropped, an
    /// object cut by a tile edge inside the image is dropped in favor of the tile that holds it
    /// whole, and an object seen by two tiles is added once.
    @Test func tileMergeAddsOnlyNewWholeObjects() throws {
        let scene = SyntheticMaskScene(width: 400, height: 300)
        func mask(_ rect: CGRect) -> FlattenSoftMask {
            scene.softMask { Self.boxDistance($0, rect: rect) }
        }
        let found = CGRect(x: 40, y: 40, width: 60, height: 50)
        let missed = CGRect(x: 150, y: 60, width: 50, height: 40)
        let straddling = CGRect(x: 230, y: 150, width: 60, height: 40)
        let tiles = FlattenRectifiedEdgeAnalysis.detectionTiles(imageWidth: 400, imageHeight: 300)

        let merged = FlattenRectifiedEdgeAnalysis.mergingTileRegions(
            [
                (tiles[0], [mask(found), mask(missed), mask(straddling.intersection(tiles[0]))]),
                (tiles[1], [mask(missed), mask(straddling)]),
            ],
            into: [mask(found)],
            imageWidth: 400,
            imageHeight: 300
        )

        #expect(merged.count == 3)
        #expect(merged.filter { $0.value(atX: Int(missed.midX), y: Int(missed.midY)) >= 0.5 }.count == 1)
        let whole = try #require(merged.first { $0.value(atX: Int(straddling.midX), y: Int(straddling.midY)) >= 0.5 })
        expectEdges(of: try #require(scene.candidate(from: whole)).boundingRectImage, match: straddling, tolerance: 1)
    }

    // MARK: - Helpers

    private func expectEdges(
        of rect: CGRect,
        match expected: CGRect,
        tolerance: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(rect.minX - expected.minX) <= tolerance, "minX \(rect.minX)", sourceLocation: sourceLocation)
        #expect(abs(rect.maxX - expected.maxX) <= tolerance, "maxX \(rect.maxX)", sourceLocation: sourceLocation)
        #expect(abs(rect.minY - expected.minY) <= tolerance, "minY \(rect.minY)", sourceLocation: sourceLocation)
        #expect(abs(rect.maxY - expected.maxY) <= tolerance, "maxY \(rect.maxY)", sourceLocation: sourceLocation)
    }

    /// Signed distance to an axis-aligned rect, positive inside.
    private static func boxDistance(_ point: CGPoint, rect: CGRect) -> CGFloat {
        let localX = abs(point.x - rect.midX) - rect.width / 2
        let localY = abs(point.y - rect.midY) - rect.height / 2
        let outside = hypot(max(localX, 0), max(localY, 0))
        let inside = min(max(localX, localY), 0)
        return -(outside + inside)
    }
}

/// Soft-mask builder over a fixed canvas, cropped to nonzero bounds the way Vision instances are.
private struct SyntheticMaskScene {
    let width: Int
    let height: Int

    var imageBounds: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    func softMask(signedDistance: (CGPoint) -> CGFloat) -> FlattenSoftMask {
        var values = [Float](repeating: 0, count: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let distance = signedDistance(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                let value = Float(min(max(distance + 0.5, 0), 1))
                values[y * width + x] = value
                if value > 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        var cropped = [Float](repeating: 0, count: cropWidth * cropHeight)
        for y in 0..<cropHeight {
            for x in 0..<cropWidth {
                cropped[y * cropWidth + x] = values[(minY + y) * width + minX + x]
            }
        }
        return FlattenSoftMask(
            imageWidth: width,
            imageHeight: height,
            originX: minX,
            originY: minY,
            width: cropWidth,
            height: cropHeight,
            values: cropped
        )
    }

    func candidate(from mask: FlattenSoftMask) -> FlattenRectifiedEdgeAnalysis.ShapeCandidate? {
        FlattenRectifiedEdgeAnalysis.makeCandidate(from: mask, imageBounds: imageBounds, tuning: .default)
    }
}
