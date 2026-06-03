import Vision
import CoreML 
import CoreVideo
import ImageIO 

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
            // Scale fill ensures the input image is scaled to the model's input size while maintaining aspect ratio.
            req.imageCropAndScaleOption = .scaleFill
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
                completion: @escaping([RawDetection]) -> Void) {
        guard !isBusy, let request else { return}
        isBusy = true
        queue.async { [weak self] in 
            guard let self else { return }
            defer { self.isBusy = false }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
                let results = self.parse(request.results)
                completion(results)
            } catch {
                completion([])
            }
        }
    }

    // Parses the raw Vision results into a list of `RawDetection` objects.
    private func parse(_ results: [VNObservation]? ) -> [RawDetection] {
        // NMS-free export => Vision returns a raw feature value, not VNRecognizedObjectObservation.
        guard let obs = results?.first as? VNCoreMLFeatureValueObservation,
        let array = obs.featureValue.multiArrayValue else { return [] }

        // Expecting shape [1, N, 6]: x1, y1, x2, y2, conf,cls (coords in 640 space)
        let shape = array.shape.map { $0.intValue }
        guard shape.count == 3, shape[2] == 6 else { return [] }
        let n = shape[1]
        let imgSize: Float = 640

        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let s = array.strides.map { $0.intValue }
        func val(_ row: Int, _ col: Int) -> Float { Float(ptr[row * s[1] + col * s[2]]) }
        var out: [RawDetection] = []
        // Loop through each estimated bounding box, filter by confidence, and append to output.
        for i in 0..<n {
            let conf = val(i, 4)
            guard conf >= confidenceThreshold else { continue }
            let cls = Int(val(i, 5))
            guard cls >= 0, cls < classNames.count else { continue }
            // 
            let x1 = val(i, 0) / imgSize, y1 = val(i, 1) / imgSize
            let x2 = val(i, 2) / imgSize, y2 = val(i, 3) / imgSize
            let rect = CGRect(x: CGFloat(min(x1, x2)),
                              y: CGFloat(min(y1, y2)),
                              width: CGFloat(abs(x2 - x1)),
                              height: CGFloat(abs(y2 - y1)))
            out.append(RawDetection(label: classNames[cls], confidence: conf, boxNormalized: rect))
        }
        return out
    }
}