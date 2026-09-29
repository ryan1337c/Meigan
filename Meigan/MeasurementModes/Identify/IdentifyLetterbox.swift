import CoreGraphics
import CoreVideo
import ImageIO

/// Maps between the camera image and the square, aspect-fit (`.scaleFit`) model input.
enum IdentifyLetterbox {
    static func orientedSize(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: height, height: width)
        default:
            return CGSize(width: width, height: height)
        }
    }

    /// Returns the size of the image once scaled into the model input, and the padding
    /// added on each side to center it.
    static func geometry(
        for orientedSize: CGSize,
        modelSize: CGFloat
    ) -> (scaledSize: CGSize, pad: CGPoint) {
        let scale = min(modelSize / orientedSize.width, modelSize / orientedSize.height)
        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let pad = CGPoint(
            x: (modelSize - scaledSize.width) / 2,
            y: (modelSize - scaledSize.height) / 2
        )
        return (scaledSize, pad)
    }

    static func normalizedImageRect(
        modelX1: CGFloat,
        modelY1: CGFloat,
        modelX2: CGFloat,
        modelY2: CGFloat,
        modelSize: CGFloat,
        orientedSize: CGSize
    ) -> CGRect? {
        guard orientedSize.width > 0, orientedSize.height > 0 else { return nil }

        let (scaledSize, pad) = geometry(for: orientedSize, modelSize: modelSize)
        let scaledWidth = scaledSize.width
        let scaledHeight = scaledSize.height

        let rawMinX = min(modelX1, modelX2) - pad.x
        let rawMinY = min(modelY1, modelY2) - pad.y
        let rawMaxX = max(modelX1, modelX2) - pad.x
        let rawMaxY = max(modelY1, modelY2) - pad.y

        guard rawMaxX > 0,
              rawMaxY > 0,
              rawMinX < scaledWidth,
              rawMinY < scaledHeight else { return nil }

        let minX = max(0, min(scaledWidth, rawMinX))
        let minY = max(0, min(scaledHeight, rawMinY))
        let maxX = max(0, min(scaledWidth, rawMaxX))
        let maxY = max(0, min(scaledHeight, rawMaxY))
        let width = maxX - minX
        let height = maxY - minY

        guard width > 0, height > 0 else { return nil }

        return CGRect(
            x: minX / scaledWidth,
            y: minY / scaledHeight,
            width: width / scaledWidth,
            height: height / scaledHeight
        )
    }
}
