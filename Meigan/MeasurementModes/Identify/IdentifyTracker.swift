import CoreGraphics
import Foundation

/// Associates per-frame detections with persistent tracks so boxes and labels stay stable
/// even when the open-vocabulary model alternates between synonyms (table / vanity / counter).
final class IdentifyTracker {
    // MARK: - Properties

    private var tracks: [IdentifyTrack] = []
    private let matchIoUThreshold: CGFloat = 0.3
    /// Looser IoU used when matching a coasting track (one that missed recent frames),
    /// so a re-detected object re-attaches to its existing track instead of spawning a new one.
    private let coastingMatchIoUThreshold: CGFloat = 0.1
    /// A coasting track and a fresh detection are treated as the same object when their
    /// centers are within this fraction of the larger box dimension (used to suppress duplicates).
    private let coastingCenterDistanceFactor: CGFloat = 0.75
    /// Number of consecutive missed inference frames a track survives before removal
    /// (~0.3 s at the ~10 Hz detection cadence).
    private let maxMissFrames = 3
    /// Same-frame detections overlapping a more confident one by more than this IoU are the
    /// same object reported under another label.
    private let duplicateIoUThreshold: CGFloat = 0.6
    /// Confidence needed to start a new track. Existing tracks are sustained by anything the
    /// detector emits (its lower threshold), so objects don't blink out near the cutoff.
    private let spawnConfidenceThreshold: Float = 0.55
    /// Matched frames required before a track is shown, so one-frame noise never appears.
    private let minHitsToDisplay = 2
    /// Per-frame decay applied to each label's accumulated confidence on a track.
    private let labelScoreDecay: Float = 0.7
    /// A competing label must exceed the displayed label's accumulated score by this factor
    /// before the displayed label switches (~3 consecutive frames of a steady new label).
    private let labelSwitchMargin: Float = 1.25
    private let minLabelScore: Float = 0.01

    // MARK: - Actions

    func reset() {
        tracks = []
    }

    /// Keeps only the most confident detection among heavily overlapping ones, regardless of label.
    func suppressOverlaps(_ detections: [IdentifyDetection]) -> [IdentifyDetection] {
        var kept: [IdentifyDetection] = []
        for det in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let isDuplicate = kept.contains { Self.iou($0.viewRect, det.viewRect) > duplicateIoUThreshold }
            if !isDuplicate { kept.append(det) }
        }
        return kept
    }

    /// Updates tracks with this frame's detections and returns the confirmed tracks for display.
    func update(with detections: [IdentifyDetection]) -> [IdentifyDetection] {
        let matches = matchTracks(to: detections)
        var matchedDetectionIndices = Set<Int>()
        var updatedTracks: [IdentifyTrack] = []
        // Tracks kept this frame without a match (coasting). Used to suppress duplicate
        // boxes when an unmatched detection is plausibly one of these same objects.
        var coastingTracks: [IdentifyTrack] = []

        for (trackIndex, var track) in tracks.enumerated() {
            if let detectionIndex = matches[trackIndex] {
                apply(detections[detectionIndex], to: &track)
                matchedDetectionIndices.insert(detectionIndex)
                updatedTracks.append(track)
            } else {
                // Unmatched track → coast at its last rect. Drop once it exceeds the grace period.
                track.missFrames += 1
                if track.missFrames <= maxMissFrames {
                    updatedTracks.append(track)
                    coastingTracks.append(track)
                }
            }
        }

        for (detectionIndex, det) in detections.enumerated()
        where !matchedDetectionIndices.contains(detectionIndex) {
            guard det.confidence >= spawnConfidenceThreshold else { continue }
            let isPlausiblyExisting = coastingTracks.contains { couldBeSameObject($0.viewRect, det.viewRect) }
            guard !isPlausiblyExisting else { continue }
            updatedTracks.append(IdentifyTrack(
                id: UUID(),
                label: det.label,
                confidence: det.confidence,
                viewRect: det.viewRect,
                labelScores: [det.label: det.confidence],
                centralityNormalized: det.centralityNormalized,
                proximityNormalized: det.proximityNormalized,
                score: det.score
            ))
        }

        tracks = updatedTracks

        return tracks
            .filter { $0.hitCount >= minHitsToDisplay }
            .map {
                IdentifyDetection(id: $0.id, label: $0.label,
                                  confidence: $0.confidence, viewRect: $0.viewRect,
                                  centralityNormalized: $0.centralityNormalized,
                                  proximityNormalized: $0.proximityNormalized,
                                  score: $0.score)
            }
    }

    // MARK: - Helpers

    /// Greedy one-to-one assignment by descending IoU. Labels are ignored so a track keeps
    /// following its object when the model's label changes. Returns track index → detection index.
    private func matchTracks(to detections: [IdentifyDetection]) -> [Int: Int] {
        var candidates: [(track: Int, detection: Int, overlap: CGFloat)] = []
        for (trackIndex, track) in tracks.enumerated() {
            let threshold = track.missFrames > 0 ? coastingMatchIoUThreshold : matchIoUThreshold
            for (detectionIndex, det) in detections.enumerated() {
                let overlap = Self.iou(track.viewRect, det.viewRect)
                if overlap > threshold {
                    candidates.append((trackIndex, detectionIndex, overlap))
                }
            }
        }

        var matches: [Int: Int] = [:]
        var usedDetectionIndices = Set<Int>()
        for candidate in candidates.sorted(by: { $0.overlap > $1.overlap }) {
            guard matches[candidate.track] == nil,
                  !usedDetectionIndices.contains(candidate.detection) else { continue }
            matches[candidate.track] = candidate.detection
            usedDetectionIndices.insert(candidate.detection)
        }
        return matches
    }

    private func apply(_ det: IdentifyDetection, to track: inout IdentifyTrack) {
        track.labelScores = track.labelScores
            .mapValues { $0 * labelScoreDecay }
            .filter { $0.value >= minLabelScore }
        track.labelScores[det.label, default: 0] += det.confidence

        if let leader = track.labelScores.max(by: { $0.value < $1.value }),
           leader.key != track.label,
           leader.value > (track.labelScores[track.label] ?? 0) * labelSwitchMargin {
            track.label = leader.key
        }
        // Only report confidence for the label actually shown on the box.
        if det.label == track.label {
            track.confidence = det.confidence
        }

        track.viewRect = det.viewRect
        track.missFrames = 0
        track.hitCount += 1
        track.centralityNormalized = det.centralityNormalized
        track.proximityNormalized = det.proximityNormalized
        track.score = det.score
    }

    /// Looser-than-IoU sameness test used only to suppress duplicate new tracks against a
    /// coasting track: any overlap, or centers within `coastingCenterDistanceFactor` of the
    /// larger box dimension, counts as "could be the same object".
    private func couldBeSameObject(_ a: CGRect, _ b: CGRect) -> Bool {
        if Self.iou(a, b) > 0 { return true }
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        let reference = max(a.width, a.height, b.width, b.height)
        guard reference > 0 else { return false }
        return distance < reference * coastingCenterDistanceFactor
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let interArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }
}
