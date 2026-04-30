//
//  MeasurementFormatting.swift
//  Meigan
//

import Foundation

enum MeasurementUnit: String, CaseIterable {
    case metric = "Metric"
    case imperial = "Imperial"

    var subtitle: String {
        switch self {
        case .metric: return "cm, m"
        case .imperial: return "in, ft"
        }
    }

    static func from(storage raw: String) -> MeasurementUnit {
        MeasurementUnit(rawValue: raw) ?? .metric
    }

    /// Narrow no‑break space so 3D `generateText` doesn’t word‑wrap between the value and unit (which clipped “cm” / “m”).
    private static let nbsp = "\u{00A0}"

    /// Formats a length in meters for display (matches Settings “Metric” / “Imperial”).
    static func formatDistance(meters: Float, unit: MeasurementUnit) -> String {
        let m = Double(meters)
        switch unit {
        case .metric:
            if abs(m) < 1.0 {
                return String(format: "%.1f\(nbsp)cm", m * 100.0)
            }
            return String(format: "%.2f\(nbsp)m", m)
        case .imperial:
            let inches = m * 39.3700787
            if abs(inches) < 36.0 {
                return String(format: "%.1f\(nbsp)in", inches)
            }
            let feet = m * 3.28084
            return String(format: "%.2f\(nbsp)ft", feet)
        }
    }
}
