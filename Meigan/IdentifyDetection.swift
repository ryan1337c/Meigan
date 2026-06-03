import CoreGraphics

struct IdentifyDetection: Identifiable, Equatable {
    let id: Int // Index within the current cycle, for SwiftUI diffing
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