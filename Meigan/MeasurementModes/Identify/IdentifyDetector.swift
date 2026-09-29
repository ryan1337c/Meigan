import Vision
import CoreML
import CoreVideo
import ImageIO
import OSLog

final class IdentifyDetector {
    // MARK: - Properties

    private struct LoadedModel {
        let request: VNCoreMLRequest
        /// Square input side length in pixels; model output coordinates are in this space.
        let inputSize: CGFloat
    }

    private let queue = DispatchQueue(label: "identify.detector", qos: .userInitiated)
    private var isBusy = false
    // Low enough to keep existing tracks alive; new tracks need IdentifyTracker's higher spawn threshold.
    private let confidenceThreshold: Float = 0.35
    private let inputFeatureName = "image"
    // Must match DETECTION_OUTPUT_NAME in ml/export_yoloe26n.py.
    private let detectionOutputName = "detections"
    // x1, y1, x2, y2, confidence, class index
    private let detectionColumnCount = 6

    // Lazy state is only touched on `queue`, so loading never races between `prepare` and `detect`.
    private lazy var classNames: [String] = IdentifyClassNames.yoloeTextPrompt
    private lazy var loadedModel: LoadedModel? = loadModel()

    // MARK: - Actions

    /// Loads the model and class names, then runs one inference on a blank frame so Core ML
    /// compiles for the Neural Engine before the first camera frame arrives.
    func prepare() {
        guard !isBusy else { return }
        isBusy = true
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            _ = self.classNames
            guard let loadedModel = self.loadedModel else { return }
            self.warmUp(loadedModel)
        }
    }

    // Drops current frame while a previous frame is being processed so the 60Hz scene loop
    // never blocks.
    func detect(pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation,
                debugFrameID: Int,
                completion: @escaping ([RawDetection]) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            guard let loadedModel = self.loadedModel else { return }
            let request = loadedModel.request
            let modelSize = loadedModel.inputSize
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
                let results = self.parse(
                    request.results,
                    modelSize: modelSize,
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

    // MARK: - Helpers

    private func loadModel() -> LoadedModel? {
        do {
            let config = MLModelConfiguration()
            // Keeps inference off the GPU that RealityKit renders the AR scene with.
            config.computeUnits = .cpuAndNeuralEngine
            // Generated class from yoloe26n_text.mlpackage
            let model = try yoloe26n_text(configuration: config).model
            guard let imageConstraint = model.modelDescription
                .inputDescriptionsByName[inputFeatureName]?.imageConstraint,
                  imageConstraint.pixelsWide == imageConstraint.pixelsHigh else {
                assertionFailure("yoloe26n_text is missing a square '\(inputFeatureName)' image input")
                return nil
            }
            let vnModel = try VNCoreMLModel(for: model)
            let request = VNCoreMLRequest(model: vnModel)
            // Keep the full camera image in model input; boxes are un-letterboxed in `parse`.
            request.imageCropAndScaleOption = .scaleFit
            return LoadedModel(request: request, inputSize: CGFloat(imageConstraint.pixelsWide))
        } catch {
            assertionFailure("Failed to load yoloe26n_text: \(error)")
            return nil
        }
    }

    private func warmUp(_ loadedModel: LoadedModel) {
        let side = Int(loadedModel.inputSize)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            side,
            side,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            assertionFailure("Failed to create warm-up pixel buffer: \(status)")
            return
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([loadedModel.request])
        } catch {
            // Non-fatal: the first real frame just pays the compile cost instead.
            #if DEBUG
            IdentifyPipelineDebug.log.error("Warm-up inference failed: \(error, privacy: .public)")
            #endif
        }
    }

    // Parses the raw Vision results into a list of `RawDetection` objects.
    private func parse(
        _ results: [VNObservation]?,
        modelSize: CGFloat,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        debugFrameID: Int
    ) -> [RawDetection] {
        // NMS-free export => Vision returns a raw feature value, not VNRecognizedObjectObservation.
        guard let observation = results?
            .compactMap({ $0 as? VNCoreMLFeatureValueObservation })
            .first(where: { $0.featureName == detectionOutputName }),
              let array = observation.featureValue.multiArrayValue else { return [] }

        // Expecting shape [1, N, 6]: x1, y1, x2, y2, conf, cls (coords in model input space)
        let shape = array.shape.map { $0.intValue }
        guard shape.count == 3, shape[2] == detectionColumnCount else { return [] }
        let rowCount = shape[1]
        let orientedSize = IdentifyLetterbox.orientedSize(
            pixelBuffer: pixelBuffer,
            orientation: orientation
        )

        // Quantized exports may return Float16; read in place instead of converting a copy.
        let element: (Int) -> Float
        switch array.dataType {
        case .float16:
            let ptr = array.dataPointer.assumingMemoryBound(to: Float16.self)
            element = { Float(ptr[$0]) }
        case .float32:
            let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
            element = { ptr[$0] }
        default:
            assertionFailure("Unexpected detection output type: \(array.dataType)")
            return []
        }
        let strides = array.strides.map { $0.intValue }
        func value(row: Int, col: Int) -> Float { element(row * strides[1] + col * strides[2]) }
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
        for i in 0..<rowCount {
            let conf = value(row: i, col: 4)
            guard conf >= confidenceThreshold else { continue }
            let cls = Int(value(row: i, col: 5))
            guard cls >= 0, cls < classNames.count else { continue }
            let modelX1 = CGFloat(value(row: i, col: 0))
            let modelY1 = CGFloat(value(row: i, col: 1))
            let modelX2 = CGFloat(value(row: i, col: 2))
            let modelY2 = CGFloat(value(row: i, col: 3))
            guard let rect = IdentifyLetterbox.normalizedImageRect(
                modelX1: modelX1,
                modelY1: modelY1,
                modelX2: modelX2,
                modelY2: modelY2,
                modelSize: modelSize,
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
            let (scaledSize, pad) = IdentifyLetterbox.geometry(for: orientedSize, modelSize: modelSize)
            IdentifyPipelineDebug.log.notice(
                """
                frame=\(debugFrameID, privacy: .public) \(bestPipelineLog.label, privacy: .public) conf=\(bestPipelineLog.confidence, privacy: .public)
                1 raw model (\(modelSize, privacy: .public)): x1=\(bestPipelineLog.modelX1, privacy: .public) y1=\(bestPipelineLog.modelY1, privacy: .public) x2=\(bestPipelineLog.modelX2, privacy: .public) y2=\(bestPipelineLog.modelY2, privacy: .public)
                letterbox: oriented=\(orientedSize.width, privacy: .public)x\(orientedSize.height, privacy: .public) scaled=\(scaledSize.width, privacy: .public)x\(scaledSize.height, privacy: .public) pad=(\(pad.x, privacy: .public),\(pad.y, privacy: .public))
                2 boxNormalized: x=\(r.minX, privacy: .public) y=\(r.minY, privacy: .public) w=\(r.width, privacy: .public) h=\(r.height, privacy: .public)
                """
            )
        }
        #endif

        return out
    }
}
