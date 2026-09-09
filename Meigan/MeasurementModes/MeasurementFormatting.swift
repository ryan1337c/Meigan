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

    var flattenScaleUnitLabel: String {
        switch self {
        case .metric: return "cm"
        case .imperial: return "in"
        }
    }

    var metersPerFlattenScaleUnit: Float {
        switch self {
        case .metric: return 0.01
        case .imperial: return 0.0254
        }
    }

    static func from(storage raw: String) -> MeasurementUnit {
        MeasurementUnit(rawValue: raw) ?? .metric
    }

    /// Narrow no‑break space so on‑screen readouts don’t wrap between the value and unit.
    private static let nbsp = "\u{00A0}"

    /// Same as ``formatDistance`` but uses a normal ASCII space for RealityKit `MeshResource.generateText`.
    /// The narrow no‑break space can trigger CoreText fallback font resolution (and “Times New Roman” performance notes) in the text mesh path.
    static func formatDistanceForMesh3D(meters: Float, unit: MeasurementUnit) -> String {
        let m = Double(meters)
        let sp = " "
        switch unit {
        case .metric:
            if abs(m) < 1.0 {
                return String(format: "%.1f\(sp)cm", m * 100.0)
            }
            return String(format: "%.2f\(sp)m", m)
        case .imperial:
            let inches = m * 39.3700787
            if abs(inches) < 36.0 {
                return String(format: "%.1f\(sp)in", inches)
            }
            let feet = m * 3.28084
            return String(format: "%.2f\(sp)ft", feet)
        }
    }

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

    /// Formats flattened image dimensions in the user's chosen scale unit.
    /// Flatten scans use centimeter / inch scale metadata, so keep final bbox values in those units too.
    static func formatFlattenDistance(meters: Float, unit: MeasurementUnit) -> String {
        let m = Double(meters)
        switch unit {
        case .metric:
            return String(format: "%.1f\(nbsp)cm", m * 100.0)
        case .imperial:
            return String(format: "%.1f\(nbsp)in", m * 39.3700787)
        }
    }
}
