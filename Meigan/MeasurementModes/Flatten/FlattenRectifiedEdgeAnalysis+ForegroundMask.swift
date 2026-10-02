//
//  FlattenRectifiedEdgeAnalysis+ForegroundMask.swift
//  Meigan
//
//  iOS 17+ subject masks: runs `VNGenerateForegroundInstanceMaskRequest` on the full-resolution
//  warped bitmap and reads one soft (0–1) `Float32` mask per foreground instance, cropped to
//  the instance's nonzero bounds. An instance can cover several disconnected objects, so each
//  is split into one mask per connected region. A second pass on overlapping crops adds objects
//  the full-image pass skipped. Also renders the debug "Vision Input" preview.
//

import CoreGraphics
import CoreVideo
import OSLog
import Vision

/// Soft foreground mask for a single instance, in warped pixel space (origin top-left).
///
/// Only the instance's nonzero bounding box is stored. Samples outside it, including
/// outside the image, read as 0 so contours touching the frame still close.
struct FlattenSoftMask: Sendable {
    /// Size of the full warped image the mask was generated for.
    let imageWidth: Int
    let imageHeight: Int
    /// Pixel rect of the stored region (the instance's nonzero bounds) within the image.
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    /// Row-major soft values in `0...1`, `width * height` entries.
    let values: [Float]

    var bounds: CGRect {
        CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Mask value at warped pixel `(x, y)`; 0 outside the stored region.
    @inline(__always)
    func value(atX x: Int, y: Int) -> Float {
        let lx = x - originX
        let ly = y - originY
        guard lx >= 0, ly >= 0, lx < width, ly < height else { return 0 }
        return values[ly * width + lx]
    }

    /// One mask per 8-connected region at or above `threshold` with at least
    /// `minimumPixelCount` pixels. Each region keeps its own pixels plus any below-threshold
    /// fringe within `fringe` px of its bounds, so its soft edge survives; pixels of other
    /// regions read as 0. Returns `[self]` when there is at most one region.
    func splitIntoRegions(threshold: Float, minimumPixelCount: Int, fringe: Int) -> [FlattenSoftMask] {
        let inside = values.map { $0 >= threshold }
        let (labels, count) = FlattenRectifiedEdgeAnalysis.componentLabels(of: inside, width: width, height: height)
        guard count > 1 else { return [self] }

        var pixelCounts = [Int](repeating: 0, count: count + 1)
        var minXs = [Int](repeating: width, count: count + 1)
        var minYs = [Int](repeating: height, count: count + 1)
        var maxXs = [Int](repeating: -1, count: count + 1)
        var maxYs = [Int](repeating: -1, count: count + 1)
        for y in 0..<height {
            for x in 0..<width {
                let label = Int(labels[y * width + x])
                guard label > 0 else { continue }
                pixelCounts[label] += 1
                minXs[label] = min(minXs[label], x)
                maxXs[label] = max(maxXs[label], x)
                minYs[label] = min(minYs[label], y)
                maxYs[label] = max(maxYs[label], y)
            }
        }

        return (1...count).compactMap { label in
            guard pixelCounts[label] >= minimumPixelCount else { return nil }
            let x0 = max(0, minXs[label] - fringe)
            let y0 = max(0, minYs[label] - fringe)
            let x1 = min(width - 1, maxXs[label] + fringe)
            let y1 = min(height - 1, maxYs[label] + fringe)
            let regionWidth = x1 - x0 + 1
            let regionHeight = y1 - y0 + 1
            var regionValues = [Float](repeating: 0, count: regionWidth * regionHeight)
            for ly in 0..<regionHeight {
                for lx in 0..<regionWidth {
                    let index = (y0 + ly) * width + x0 + lx
                    let owner = Int(labels[index])
                    if owner == 0 || owner == label {
                        regionValues[ly * regionWidth + lx] = values[index]
                    }
                }
            }
            return FlattenSoftMask(
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                originX: originX + x0,
                originY: originY + y0,
                width: regionWidth,
                height: regionHeight,
                values: regionValues
            )
        }
    }
}

extension FlattenRectifiedEdgeAnalysis {

    /// Regions smaller than this (warped px at or above the contour iso level) are specks, not objects.
    private static let minimumRegionPixelCount = 64
    /// Soft fringe (px) kept around each split region so its iso crossing stays interpolated.
    private static let regionFringePixels = 2

    private static let foregroundMaskLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Meigan",
        category: "FlattenForegroundMask"
    )

    /// A tile region counts as an object already found when more than this fraction of it is
    /// covered by kept regions.
    private static let tileRegionMaximumOverlap = 0.2

    /// Runs the foreground instance request on the full-resolution `cgImage` and returns one
    /// soft mask per connected region of each instance. With `includeTiles`, a second pass on
    /// overlapping crops adds objects the full-image pass skipped: the request lifts only the
    /// most prominent subjects, so faint objects next to bold ones go missing. Returns nil when
    /// the full-image request fails or nothing usable is found.
    @available(iOS 17.0, *)
    static func makeForegroundInstanceMasks(from cgImage: CGImage, includeTiles: Bool) -> [FlattenSoftMask]? {
        guard let full = instanceRegions(in: cgImage) else { return nil }
        guard includeTiles else { return full.regions.isEmpty ? nil : full.regions }

        let tiles = detectionTiles(imageWidth: cgImage.width, imageHeight: cgImage.height)
        var tileRegions = [[FlattenSoftMask]](repeating: [], count: tiles.count)
        tileRegions.withUnsafeMutableBufferPointer { buffer in
            // Each iteration writes only its own slot, so the buffer needs no locking.
            DispatchQueue.concurrentPerform(iterations: buffer.count) { index in
                let tile = tiles[index]
                guard let crop = cgImage.cropping(to: tile),
                      let regions = instanceRegions(in: crop)?.regions
                else { return }
                buffer[index] = regions.map {
                    FlattenSoftMask(
                        imageWidth: cgImage.width,
                        imageHeight: cgImage.height,
                        originX: $0.originX + Int(tile.minX),
                        originY: $0.originY + Int(tile.minY),
                        width: $0.width,
                        height: $0.height,
                        values: $0.values
                    )
                }
            }
        }

        let merged = mergingTileRegions(
            Array(zip(tiles, tileRegions)),
            into: full.regions,
            imageWidth: cgImage.width,
            imageHeight: cgImage.height
        )
        let regionSummary = merged
            .map { "\($0.width)x\($0.height)@(\($0.originX),\($0.originY))" }
            .joined(separator: ", ")
        foregroundMaskLog.debug(
            "Vision returned \(full.instanceCount) instances -> \(full.regions.count) regions; tiles added \(merged.count - full.regions.count): \(regionSummary, privacy: .public)"
        )
        return merged.isEmpty ? nil : merged
    }

    /// One soft mask per connected region of each instance Vision finds in `cgImage`, in that
    /// image's pixel space. Returns nil when the request fails.
    @available(iOS 17.0, *)
    private static func instanceRegions(in cgImage: CGImage) -> (instanceCount: Int, regions: [FlattenSoftMask])? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return (0, []) }

        var regions: [FlattenSoftMask] = []
        for instance in observation.allInstances {
            guard let buffer = try? observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instance),
                from: handler
            ),
                let mask = readSoftMask(buffer, imageWidth: cgImage.width, imageHeight: cgImage.height)
            else { continue }
            regions.append(contentsOf: mask.splitIntoRegions(
                threshold: 0.5,
                minimumPixelCount: minimumRegionPixelCount,
                fringe: regionFringePixels
            ))
        }
        return (observation.allInstances.count, regions)
    }

    /// A 2x2 grid of crops, each two thirds of the image along both axes, so every object up to
    /// a third of the image across lies wholly inside at least one tile.
    static func detectionTiles(imageWidth: Int, imageHeight: Int) -> [CGRect] {
        let tileWidth = (2 * imageWidth + 2) / 3
        let tileHeight = (2 * imageHeight + 2) / 3
        let xs = [0, imageWidth - tileWidth]
        let ys = [0, imageHeight - tileHeight]
        return ys.flatMap { y in
            xs.map { x in CGRect(x: x, y: y, width: tileWidth, height: tileHeight) }
        }
    }

    /// `existing` plus each tile region that is a new object: not cut by a tile edge inside the
    /// image (an overlapping tile holds that object whole), and not more than
    /// `tileRegionMaximumOverlap` covered by a region already kept. Tiles are taken in order, so
    /// an object seen by several tiles is added once.
    static func mergingTileRegions(
        _ tiles: [(rect: CGRect, regions: [FlattenSoftMask])],
        into existing: [FlattenSoftMask],
        imageWidth: Int,
        imageHeight: Int
    ) -> [FlattenSoftMask] {
        var isCovered = [Bool](repeating: false, count: imageWidth * imageHeight)
        func forEachInsidePixel(of mask: FlattenSoftMask, _ body: (Int) -> Void) {
            for ly in 0..<mask.height {
                let y = mask.originY + ly
                guard y >= 0, y < imageHeight else { continue }
                for lx in 0..<mask.width where mask.values[ly * mask.width + lx] >= 0.5 {
                    let x = mask.originX + lx
                    guard x >= 0, x < imageWidth else { continue }
                    body(y * imageWidth + x)
                }
            }
        }

        for mask in existing {
            forEachInsidePixel(of: mask) { isCovered[$0] = true }
        }

        var merged = existing
        for (rect, regions) in tiles {
            let tileMinX = Int(rect.minX)
            let tileMinY = Int(rect.minY)
            let tileMaxX = Int(rect.maxX)
            let tileMaxY = Int(rect.maxY)
            for region in regions {
                let isCut = (tileMinX > 0 && region.originX <= tileMinX)
                    || (tileMinY > 0 && region.originY <= tileMinY)
                    || (tileMaxX < imageWidth && region.originX + region.width >= tileMaxX)
                    || (tileMaxY < imageHeight && region.originY + region.height >= tileMaxY)
                guard !isCut else { continue }

                var insideCount = 0
                var coveredCount = 0
                forEachInsidePixel(of: region) { index in
                    insideCount += 1
                    if isCovered[index] { coveredCount += 1 }
                }
                guard insideCount > 0,
                      Double(coveredCount) / Double(insideCount) <= tileRegionMaximumOverlap
                else { continue }

                forEachInsidePixel(of: region) { isCovered[$0] = true }
                merged.append(region)
            }
        }
        return merged
    }

    /// Copies the soft mask out of `buffer`, cropped to its nonzero bounds. Accepts the
    /// `OneComponent32Float` format Vision produces, and 8-bit as a defensive fallback.
    /// Returns nil for an empty mask or a size that doesn't match the warped image.
    private static func readSoftMask(_ buffer: CVPixelBuffer, imageWidth: Int, imageHeight: Int) -> FlattenSoftMask? {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard w == imageWidth, h == imageHeight else { return nil }

        let format = CVPixelBufferGetPixelFormatType(buffer)
        let is32Float = format == kCVPixelFormatType_OneComponent32Float
        let is8Bit = format == kCVPixelFormatType_OneComponent8
        guard is32Float || is8Bit else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        @inline(__always)
        func sample(_ row: UnsafeRawPointer, _ x: Int) -> Float {
            if is32Float {
                return row.load(fromByteOffset: x * MemoryLayout<Float>.stride, as: Float.self)
            }
            return Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255
        }

        var minX = w
        var minY = h
        var maxX = -1
        var maxY = -1
        for y in 0..<h {
            let row = UnsafeRawPointer(base + y * bytesPerRow)
            var rowHasForeground = false
            for x in 0..<w where sample(row, x) > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                rowHasForeground = true
            }
            if rowHasForeground {
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let cropW = maxX - minX + 1
        let cropH = maxY - minY + 1
        var values = [Float](repeating: 0, count: cropW * cropH)
        values.withUnsafeMutableBufferPointer { out in
            for ly in 0..<cropH {
                let row = UnsafeRawPointer(base + (minY + ly) * bytesPerRow)
                let outBase = ly * cropW
                for lx in 0..<cropW {
                    out[outBase + lx] = min(1, max(0, sample(row, minX + lx)))
                }
            }
        }

        return FlattenSoftMask(
            imageWidth: w,
            imageHeight: h,
            originX: minX,
            originY: minY,
            width: cropW,
            height: cropH,
            values: values
        )
    }

    /// Debug preview on white: pixels at or above the contour iso level in `masks` are black.
    /// An object that is white here was never found by Vision. On older systems this preview
    /// is the grayscale contour-detection image instead.
    static func detectionPreview(
        of masks: [FlattenSoftMask],
        imageWidth: Int,
        imageHeight: Int
    ) -> CGImage? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        var pixels = [UInt8](repeating: 255, count: imageWidth * imageHeight)
        for mask in masks where mask.imageWidth == imageWidth && mask.imageHeight == imageHeight {
            for ly in 0..<mask.height {
                let y = mask.originY + ly
                guard y >= 0, y < imageHeight else { continue }
                for lx in 0..<mask.width where mask.values[ly * mask.width + lx] >= 0.5 {
                    let x = mask.originX + lx
                    guard x >= 0, x < imageWidth else { continue }
                    pixels[y * imageWidth + x] = 0
                }
            }
        }

        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress,
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bytesPerRow: imageWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )?.makeImage()
        }
    }

    /// 8-connected component labels of `mask`: 0 outside, `1...count` inside, numbered in
    /// row-major order of each component's first pixel.
    static func componentLabels(of mask: [Bool], width: Int, height: Int) -> (labels: [Int32], count: Int) {
        var labels = [Int32](repeating: 0, count: mask.count)
        var count: Int32 = 0
        var stack: [Int] = []

        for start in mask.indices where mask[start] && labels[start] == 0 {
            count += 1
            labels[start] = count
            stack.append(start)

            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let neighbor = ny * width + nx
                        if mask[neighbor], labels[neighbor] == 0 {
                            labels[neighbor] = count
                            stack.append(neighbor)
                        }
                    }
                }
            }
        }
        return (labels, Int(count))
    }
}
