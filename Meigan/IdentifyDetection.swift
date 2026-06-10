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
    /// Consecutive inference frames this track went unmatched. Tracks "coast" at their
    /// last known rect while this is below the grace threshold, then are removed.
    var missFrames: Int = 0
    var centralityNormalized: CGFloat = 0
    var proximityNormalized: CGFloat = 0
    var score: CGFloat = 0
}

struct IdentifyDetection: Identifiable, Equatable {
    let id: UUID
    let label: String
    let confidence: Float
    let viewRect: CGRect
    let centralityNormalized: CGFloat // Distance from center of camerframe to bounding box center
    let proximityNormalized: CGFloat // Distance from camera frame to target
    let score: CGFloat
}

// Raw, framework-only results from the detector (no AR/coordinate knowledge)
struct RawDetection {
    let label: String
    let confidence: Float
    let boxNormalized: CGRect // top-left origin, normalized 0…1 in the oriented image
}

enum IdentifyScoring {
    static let wConfidence: CGFloat = 0.5
    static let wCentrality: CGFloat = 0.3
    static let wProximity: CGFloat = 0.2

    // Distance from center of bounding box to center of viewport normalized.
    static func centrality(viewRect: CGRect, drawableRect: CGRect) -> CGFloat {
        let boxCenter = CGPoint(x: viewRect.midX, y: viewRect.midY)
        let focus = CGPoint(x: drawableRect.midX, y: drawableRect.midY)
        let dist = hypot(boxCenter.x - focus.x, boxCenter.y - focus.y)
        let maxDist = hypot(drawableRect.width, drawableRect.height) / 2
        guard maxDist > 0 else { return 0 }
        return max(0, 1 - dist / maxDist)
    }

    // Distance from camera frame to target normalized.
    static func proximity(distanceMeters: Float) -> CGFloat {
        let minDist: Float = 0.15
        let maxDist: Float = 3.0
        let t = (distanceMeters - minDist) / (maxDist - minDist)
        return CGFloat(max(0, min(1, 1 - t)))
    }

    static func score(confidence: Float, centrality: CGFloat, proximity: CGFloat) -> CGFloat {
        let confidenceTerm = CGFloat(confidence) * wConfidence
        let centralityTerm = centrality * wCentrality
        let proximityTerm = proximity * wProximity
        return confidenceTerm + centralityTerm + proximityTerm
    }
}

