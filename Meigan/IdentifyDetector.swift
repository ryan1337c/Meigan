import Vision
import CoreML
import CoreVideo
import ImageIO
import OSLog

private enum IdentifyLetterbox {
    static let modelSize: CGFloat = 640

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

    static func normalizedImageRect(
        modelX1: CGFloat,
        modelY1: CGFloat,
        modelX2: CGFloat,
        modelY2: CGFloat,
        orientedSize: CGSize
    ) -> CGRect? {
        guard orientedSize.width > 0, orientedSize.height > 0 else { return nil }

        let scale = min(modelSize / orientedSize.width, modelSize / orientedSize.height)
        let scaledWidth = orientedSize.width * scale
        let scaledHeight = orientedSize.height * scale
        let padX = (modelSize - scaledWidth) / 2
        let padY = (modelSize - scaledHeight) / 2

        let rawMinX = min(modelX1, modelX2) - padX
        let rawMinY = min(modelY1, modelY2) - padY
        let rawMaxX = max(modelX1, modelX2) - padX
        let rawMaxY = max(modelY1, modelY2) - padY

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

final class IdentifyDetector {
    private let queue = DispatchQueue(label: "identify.detector", qos: .userInitiated)
    private var isBusy = false
    private let confidenceThreshold: Float = 0.4
    static let cocoNames = ["person","bicycle","car","motorcycle","airplane","bus","train","truck","boat","traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat","dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack","umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball","kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket","bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple","sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair","couch","potted plant","bed","dining table","toilet","tv","laptop","mouse","remote","keyboard","cell phone","microwave","oven","toaster","sink","refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"]
    // 80 COCO class names, in model index order
    private let classNames: [String] = IdentifyDetector.cocoNames

    private lazy var request: VNCoreMLRequest? = {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            // Generated class from yolo26n.mlpackage
            let model = try yolo26n(configuration: config).model
            let vnModel = try VNCoreMLModel(for: model)
            let req = VNCoreMLRequest(model: vnModel)
            // Keep the full camera image in model input; boxes are un-letterboxed in `parse`.
            req.imageCropAndScaleOption = .scaleFit
            return req
        }
        catch {
            assertionFailure("Failed to load yolo26n: \(error)")
            return nil
        }
    }()

    // Drops current frame while a previous frame is being processed so the 60Hz scene loop 
    // never blocks.
    func detect(pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation,
                debugFrameID: Int,
                completion: @escaping([RawDetection]) -> Void) {
        guard !isBusy, let request else { return}
        isBusy = true
        queue.async { [weak self] in 
            guard let self else { return }
            defer { self.isBusy = false }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
                let results = self.parse(
                    request.results,
                    pixelBuffer: pixelBuffer,
                    orientation: orientation,
                    debugFrameID: debugFrameID
                )
                completion(results)
            } catch {
                completion([])
            }
        }
    }

    // Parses the raw Vision results into a list of `RawDetection` objects.
    private func parse(
        _ results: [VNObservation]?,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        debugFrameID: Int
    ) -> [RawDetection] {
        // NMS-free export => Vision returns a raw feature value, not VNRecognizedObjectObservation.
        guard let obs = results?.first as? VNCoreMLFeatureValueObservation,
        let array = obs.featureValue.multiArrayValue else { return [] }

        // Expecting shape [1, N, 6]: x1, y1, x2, y2, conf,cls (coords in 640 space)
        let shape = array.shape.map { $0.intValue }
        guard shape.count == 3, shape[2] == 6 else { return [] }
        let n = shape[1]
        let orientedSize = IdentifyLetterbox.orientedSize(
            pixelBuffer: pixelBuffer,
            orientation: orientation
        )
        let letterboxScale = min(
            IdentifyLetterbox.modelSize / orientedSize.width,
            IdentifyLetterbox.modelSize / orientedSize.height
        )
        let scaledWidth = orientedSize.width * letterboxScale
        let scaledHeight = orientedSize.height * letterboxScale
        let padX = (IdentifyLetterbox.modelSize - scaledWidth) / 2
        let padY = (IdentifyLetterbox.modelSize - scaledHeight) / 2

        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let s = array.strides.map { $0.intValue }
        func val(_ row: Int, _ col: Int) -> Float { Float(ptr[row * s[1] + col * s[2]]) }
        var out: [RawDetection] = []
        var bestPipelineLog: (
            label: String,
            confidence: Float,
            modelX1: CGFloat,
            modelY1: CGFloat,
            modelX2: CGFloat,
            modelY2: CGFloat,
            boxNormalized: CGRect
        )?
        // Loop through each estimated bounding box, filter by confidence, and append to output.
        for i in 0..<n {
            let conf = val(i, 4)
            guard conf >= confidenceThreshold else { continue }
            let cls = Int(val(i, 5))
            guard cls >= 0, cls < classNames.count else { continue }
            let modelX1 = CGFloat(val(i, 0))
            let modelY1 = CGFloat(val(i, 1))
            let modelX2 = CGFloat(val(i, 2))
            let modelY2 = CGFloat(val(i, 3))
            guard let rect = IdentifyLetterbox.normalizedImageRect(
                modelX1: modelX1,
                modelY1: modelY1,
                modelX2: modelX2,
                modelY2: modelY2,
                orientedSize: orientedSize
            ) else { continue }

            let label = classNames[cls]
            out.append(RawDetection(label: label, confidence: conf, boxNormalized: rect))
            if bestPipelineLog == nil || conf > bestPipelineLog!.confidence {
                bestPipelineLog = (label, conf, modelX1, modelY1, modelX2, modelY2, rect)
            }
        }

        #if DEBUG
        if let bestPipelineLog {
            let r = bestPipelineLog.boxNormalized
            IdentifyPipelineDebug.log.notice(
                """
                frame=\(debugFrameID, privacy: .public) \(bestPipelineLog.label, privacy: .public) conf=\(bestPipelineLog.confidence, privacy: .public)
                1 raw model (640): x1=\(bestPipelineLog.modelX1, privacy: .public) y1=\(bestPipelineLog.modelY1, privacy: .public) x2=\(bestPipelineLog.modelX2, privacy: .public) y2=\(bestPipelineLog.modelY2, privacy: .public)
                letterbox: oriented=\(orientedSize.width, privacy: .public)x\(orientedSize.height, privacy: .public) scaled=\(scaledWidth, privacy: .public)x\(scaledHeight, privacy: .public) pad=(\(padX, privacy: .public),\(padY, privacy: .public))
                2 boxNormalized: x=\(r.minX, privacy: .public) y=\(r.minY, privacy: .public) w=\(r.width, privacy: .public) h=\(r.height, privacy: .public)
                """
            )
        }
        #endif

        return out
    }
}