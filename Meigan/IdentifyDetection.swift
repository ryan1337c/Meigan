import CoreGraphics
import OSLog

enum IdentifyPipelineDebug {
    static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Meigan",
        category: "IdentifyPipeline"
    )
}

struct IdentifyTrack {
    let id: UUID 
    var label: String
    var confidence: Float
    var viewRect: CGRect
}

struct IdentifyDetection: Identifiable, Equatable {
    let id: UUID
    let label: String
    let confidence: Float
    let viewRect: CGRect
}

// Raw, framework-only results from the detector (no AR/coordinate knowledge)
struct RawDetection {
    let label: String
    let confidence: Float
    let boxNormalized: CGRect // top-left origin, normalized 0…1 in the oriented image
}