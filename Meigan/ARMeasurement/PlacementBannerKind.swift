import Foundation

/// Styling for the transient placement banner in `ARMeasurementView` / `OverlaysView`.
enum PlacementBannerKind: String, Equatable {
    /// Subtle, neutral capsule for guidance (e.g. corner relocate instructions).
    case instruction
    /// High-contrast banner for blocking errors (e.g. invalid placement surface).
    case alert
}
