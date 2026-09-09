//
//  FlattenMeasurementMode+ScanAnalysis.swift
//  Meigan
//
//  PCA / SVD plane fit of the placed corners, canvas fitting, and the image → canvas homography.
//

import Accelerate
import CoreGraphics
import simd
import UIKit

extension FlattenMeasurementMode {
    /// Output of the PCA / SVD-style analysis used by every flatten scan.
    ///
    /// The eigendecomposition of the centered-corner covariance matrix yields singular
    /// values and an orthonormal basis whose third axis is the plane normal. `points2D`
    /// is the projection of the original corners onto `(basisU, basisV)` and is reused
    /// downstream for guards and future homography work.
    struct FlattenScanAnalysis {
        let centroid: SIMD3<Float>
        let basisU: SIMD3<Float>
        let basisV: SIMD3<Float>
        let normal: SIMD3<Float>
        /// sqrt of covariance eigenvalues, sorted descending: σ_U, σ_V, σ_N.
        let singularValues: [Float]
        /// Input corners projected onto `(basisU, basisV)` after subtracting `centroid`.
        let points2D: [SIMD2<Float>]
        /// Input corners projected into the current frame's camera image plane.
        let imagePlanePoints: [SIMD2<Float>]
        /// Destination rect corners on the output canvas (top-left, top-right, bottom-right, bottom-left).
        let destinationCanvasCorners: [SIMD2<Float>]
        /// Output canvas dimensions (full width, height minus footer reservation).
        let outputCanvasSize: SIMD2<Float>
        /// Homography mapping image-plane points into destination canvas coordinates.
        let imageToCanvasHomography: simd_float3x3?
        /// Physical dimensions of the fitted flatten output, in meters.
        let physicalSizeMeters: SIMD2<Float>
        /// Destination rectangle within the output canvas, preserving physical aspect ratio.
        let fittedCanvasRect: CGRect
        /// Uniform pixel density for the flattened output.
        let pixelsPerMeter: Float
        /// Pixel density in the user's selected scale unit.
        let pixelsPerDisplayUnit: Float
        /// User scale units represented by each output pixel.
        let displayUnitsPerPixel: Float
        /// Unit label for scale metadata, e.g. "cm" or "in".
        let displayUnitLabel: String
    }

    static func scanAnalysis(
        for points: [SIMD3<Float>],
        imagePlanePoints: [SIMD2<Float>] = [],
        outputCanvasSize: CGSize? = nil,
        measurementUnit: MeasurementUnit = .metric
    ) -> FlattenScanAnalysis {
        let canvasSize = outputCanvasSize ?? UIScreen.main.bounds.size
        let clampedCanvasSize = SIMD2<Float>(Float(max(1, canvasSize.width)), Float(max(1, canvasSize.height)))
        let fullCanvasRect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(clampedCanvasSize.x),
            height: CGFloat(clampedCanvasSize.y)
        )
        let fallbackDestinationCorners = destinationCorners(for: fullCanvasRect)

        guard !points.isEmpty else {
            return FlattenScanAnalysis(
                centroid: SIMD3<Float>(repeating: 0),
                basisU: SIMD3<Float>(1, 0, 0),
                basisV: SIMD3<Float>(0, 1, 0),
                normal: SIMD3<Float>(0, 0, 1),
                singularValues: [0, 0, 0],
                points2D: [],
                imagePlanePoints: imagePlanePoints,
                destinationCanvasCorners: fallbackDestinationCorners,
                outputCanvasSize: clampedCanvasSize,
                imageToCanvasHomography: nil,
                physicalSizeMeters: SIMD2<Float>(repeating: 0),
                fittedCanvasRect: fullCanvasRect,
                pixelsPerMeter: 0,
                pixelsPerDisplayUnit: 0,
                displayUnitsPerPixel: 0,
                displayUnitLabel: measurementUnit.flattenScaleUnitLabel
            )
        }

        let count = Float(points.count)
        let centroid = points.reduce(SIMD3<Float>(repeating: 0), +) / count
        var covariance = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)

        for point in points {
            let centered = point - centroid
            let v = [Double(centered.x), Double(centered.y), Double(centered.z)]
            for row in 0..<3 {
                for col in 0..<3 {
                    covariance[row][col] += v[row] * v[col]
                }
            }
        }

        let (eigenvalues, eigenvectors) = eigenDecompositionSymmetric3(covariance)
        // dsyev returns eigenvalues in ascending order — reorder so index 0 is the dominant axis.
        let order = [2, 1, 0]
        let sortedValues = order.map { eigenvalues[$0] }
        let sortedVectors = order.map { eigenvectors[$0] }

        let sigmas = sortedValues.map { Float(sqrt(max($0, 0))) }
        let basisU = vectorFromColumn(sortedVectors[0])
        let basisV = vectorFromColumn(sortedVectors[1])
        let normal = vectorFromColumn(sortedVectors[2])

        let points2D = points.map { point -> SIMD2<Float> in
            let centered = point - centroid
            return SIMD2<Float>(simd_dot(centered, basisU), simd_dot(centered, basisV))
        }

        let orderedIndices = imagePlanePoints.count == points.count
            ? (orderedQuadIndices(imagePlanePoints) ?? orderedQuadIndices(points2D) ?? Array(points.indices))
            : (orderedQuadIndices(points2D) ?? Array(points.indices))
        let orderedWorldPoints = orderedIndices.map { points[$0] }
        let orderedImagePlanePoints = imagePlanePoints.count == points.count
            ? orderedIndices.map { imagePlanePoints[$0] }
            : imagePlanePoints
        let physicalSizeMeters = physicalSizeMeters(for: orderedWorldPoints)
        let fittedCanvasRect = fittedCanvasRect(
            canvasSize: clampedCanvasSize,
            physicalSizeMeters: physicalSizeMeters
        )
        let destinationCorners = destinationCorners(for: fittedCanvasRect)
        let homography = computeHomography(from: orderedImagePlanePoints, to: destinationCorners)
        let pixelsPerMeter = pixelsPerMeter(
            fittedCanvasRect: fittedCanvasRect,
            physicalSizeMeters: physicalSizeMeters
        )
        let pixelsPerDisplayUnit = pixelsPerMeter * measurementUnit.metersPerFlattenScaleUnit
        let displayUnitsPerPixel = pixelsPerDisplayUnit > 0 ? 1 / pixelsPerDisplayUnit : 0

        return FlattenScanAnalysis(
            centroid: centroid,
            basisU: basisU,
            basisV: basisV,
            normal: normal,
            singularValues: sigmas,
            points2D: points2D,
            imagePlanePoints: orderedImagePlanePoints,
            destinationCanvasCorners: destinationCorners,
            outputCanvasSize: clampedCanvasSize,
            imageToCanvasHomography: homography,
            physicalSizeMeters: physicalSizeMeters,
            fittedCanvasRect: fittedCanvasRect,
            pixelsPerMeter: pixelsPerMeter,
            pixelsPerDisplayUnit: pixelsPerDisplayUnit,
            displayUnitsPerPixel: displayUnitsPerPixel,
            displayUnitLabel: measurementUnit.flattenScaleUnitLabel
        )
    }

    private static func destinationCorners(for rect: CGRect) -> [SIMD2<Float>] {
        let minX = Float(rect.minX)
        let minY = Float(rect.minY)
        let maxX = Float(rect.maxX)
        let maxY = Float(rect.maxY)
        return [
            SIMD2<Float>(minX, minY),
            SIMD2<Float>(maxX, minY),
            SIMD2<Float>(maxX, maxY),
            SIMD2<Float>(minX, maxY)
        ]
    }

    private static func physicalSizeMeters(for orderedWorldPoints: [SIMD3<Float>]) -> SIMD2<Float> {
        guard orderedWorldPoints.count == 4 else { return SIMD2<Float>(repeating: 0) }
        let topWidth = simd_distance(orderedWorldPoints[0], orderedWorldPoints[1])
        let bottomWidth = simd_distance(orderedWorldPoints[3], orderedWorldPoints[2])
        let leftHeight = simd_distance(orderedWorldPoints[0], orderedWorldPoints[3])
        let rightHeight = simd_distance(orderedWorldPoints[1], orderedWorldPoints[2])
        return SIMD2<Float>(
            (topWidth + bottomWidth) * 0.5,
            (leftHeight + rightHeight) * 0.5
        )
    }

    private static func fittedCanvasRect(
        canvasSize: SIMD2<Float>,
        physicalSizeMeters: SIMD2<Float>
    ) -> CGRect {
        let availableWidth = CGFloat(max(1, canvasSize.x))
        let availableHeight = CGFloat(max(1, canvasSize.y))
        let widthMeters = CGFloat(physicalSizeMeters.x)
        let heightMeters = CGFloat(physicalSizeMeters.y)
        guard widthMeters > 1e-5, heightMeters > 1e-5 else {
            return CGRect(x: 0, y: 0, width: availableWidth, height: availableHeight)
        }

        let physicalAspect = widthMeters / heightMeters
        let availableAspect = availableWidth / availableHeight
        let fittedWidth: CGFloat
        let fittedHeight: CGFloat
        if availableAspect > physicalAspect {
            fittedHeight = availableHeight
            fittedWidth = fittedHeight * physicalAspect
        } else {
            fittedWidth = availableWidth
            fittedHeight = fittedWidth / physicalAspect
        }

        return CGRect(
            x: (availableWidth - fittedWidth) * 0.5,
            y: (availableHeight - fittedHeight) * 0.5,
            width: fittedWidth,
            height: fittedHeight
        )
    }

    private static func pixelsPerMeter(
        fittedCanvasRect: CGRect,
        physicalSizeMeters: SIMD2<Float>
    ) -> Float {
        guard physicalSizeMeters.x > 1e-5, physicalSizeMeters.y > 1e-5 else { return 0 }
        let horizontal = Float(fittedCanvasRect.width) / physicalSizeMeters.x
        let vertical = Float(fittedCanvasRect.height) / physicalSizeMeters.y
        return min(horizontal, vertical)
    }

    private static func computeHomography(from source: [SIMD2<Float>], to destination: [SIMD2<Float>]) -> simd_float3x3? {
        guard source.count == 4, destination.count == 4 else { return nil }
        let src = source
        let dst = destination

        var coefficients = [[Double]]()
        var constants = [Double]()
        coefficients.reserveCapacity(8)
        constants.reserveCapacity(8)

        for i in 0..<4 {
            let x = Double(src[i].x)
            let y = Double(src[i].y)
            let u = Double(dst[i].x)
            let v = Double(dst[i].y)
            coefficients.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
            constants.append(u)
            coefficients.append([0, 0, 0, x, y, 1, -v * x, -v * y])
            constants.append(v)
        }

        guard let h = solveLinearSystem(coefficients, constants) else { return nil }

        return simd_float3x3(
            SIMD3<Float>(Float(h[0]), Float(h[1]), Float(h[2])),
            SIMD3<Float>(Float(h[3]), Float(h[4]), Float(h[5])),
            SIMD3<Float>(Float(h[6]), Float(h[7]), 1)
        )
    }

    private static func solveLinearSystem(_ coefficients: [[Double]], _ constants: [Double]) -> [Double]? {
        let count = constants.count
        guard coefficients.count == count,
              coefficients.allSatisfy({ $0.count == count })
        else { return nil }

        var augmented = zip(coefficients, constants).map { row, constant in
            row + [constant]
        }

        for column in 0..<count {
            guard let pivotRow = (column..<count).max(by: {
                abs(augmented[$0][column]) < abs(augmented[$1][column])
            }),
            abs(augmented[pivotRow][column]) > 1e-10
            else {
                return nil
            }

            if pivotRow != column {
                augmented.swapAt(pivotRow, column)
            }

            let pivot = augmented[column][column]
            for valueIndex in column...count {
                augmented[column][valueIndex] /= pivot
            }

            for row in 0..<count where row != column {
                let factor = augmented[row][column]
                guard abs(factor) > 1e-14 else { continue }
                for valueIndex in column...count {
                    augmented[row][valueIndex] -= factor * augmented[column][valueIndex]
                }
            }
        }

        return augmented.map { $0[count] }
    }

    private static func orderedQuadIndices(_ points: [SIMD2<Float>]) -> [Int]? {
        guard points.count == 4 else { return nil }
        let sum = points.map { $0.x + $0.y }
        let diff = points.map { $0.x - $0.y }

        let topLeft = sum.indices.min(by: { sum[$0] < sum[$1] }) ?? 0
        let bottomRight = sum.indices.max(by: { sum[$0] < sum[$1] }) ?? 0
        let topRight = diff.indices.max(by: { diff[$0] < diff[$1] }) ?? 0
        let bottomLeft = diff.indices.min(by: { diff[$0] < diff[$1] }) ?? 0
        let indices = [topLeft, topRight, bottomRight, bottomLeft]
        guard Set(indices).count == 4 else { return nil }

        return indices
    }

    private static func vectorFromColumn(_ column: [Double]) -> SIMD3<Float> {
        SIMD3<Float>(Float(column[0]), Float(column[1]), Float(column[2]))
    }

    /// LAPACK-backed symmetric eigendecomposition (eigenvalues + eigenvectors), used as the SVD of the centered covariance.
    private static func eigenDecompositionSymmetric3(_ matrix: [[Double]]) -> (eigenvalues: [Double], eigenvectors: [[Double]]) {
        // Flatten to column-major format for LAPACK
        var a = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                a[j * 3 + i] = matrix[i][j]  // Column-major
            }
        }

        var n = 3
        var lda = 3
        var w = [Double](repeating: 0, count: 3)  // Eigenvalues output (ascending)
        var lwork = -1
        var work = [Double](repeating: 0, count: 1)
        var info = 0
        var jobz = Int8(86)  // 'V' = eigenvalues + eigenvectors
        var uplo = Int8(85)  // 'U' = upper triangle

        // Query optimal work size
        dsyev_(&jobz, &uplo, &n, &a, &lda, &w, &work, &lwork, &info)

        lwork = Int(work[0])
        work = [Double](repeating: 0, count: Int(lwork))

        // Compute eigenvalues + eigenvectors. After this, `a` holds the orthonormal
        // eigenvectors as columns (column-major), one per eigenvalue in `w`.
        dsyev_(&jobz, &uplo, &n, &a, &lda, &w, &work, &lwork, &info)

        var eigenvectors: [[Double]] = []
        eigenvectors.reserveCapacity(3)
        for k in 0..<3 {
            eigenvectors.append([a[k * 3 + 0], a[k * 3 + 1], a[k * 3 + 2]])
        }
        return (w, eigenvectors)
    }
}
