import Foundation
import UIKit

// MARK: - Tracked Object State

/// The lifecycle state of a tracked physical object.
enum TrackedObjectState {
    /// Seen in fewer than `confirmationFrames` consecutive frames — not yet counted.
    case pending(seenCount: Int)
    /// Confirmed across enough frames and now counted once. Will not increment again
    /// unless the object leaves the frame and re-enters as a new track.
    case counted
    /// No longer visible. Expires after `expirySeconds` and is removed from active tracks.
    case absent(missedFrames: Int)
}

// MARK: - Tracked Object

/// A single persistent tracked object across video frames.
///
/// Spec-compliant fields:
/// - id             → `trackId`
/// - skuId          → `skuId`
/// - firstSeenFrame → `firstSeenAt` (wall-clock) + `observedFrameCount`
/// - lastSeenFrame  → `lastSeenAt`
/// - position       → `lastBBox`
/// - confidence     → `bestConfidence`
/// - confirmedCounted → `confirmedCounted` (alias of isCounted for spec compliance)
struct TrackedObject {
    let trackId: UUID
    var skuId: UUID
    var skuName: String
    /// Last known normalized bounding box (0–1 coords).
    var lastBBox: CGRect
    /// State machine governing count eligibility.
    var state: TrackedObjectState
    /// Wall-clock time this track was first observed (firstSeenFrame equivalent).
    let firstSeenAt: Date
    /// Wall-clock time this track was last matched to a detection.
    var lastSeenAt: Date
    /// Total number of frames this track has been matched across (for diagnostics).
    var observedFrameCount: Int
    /// Confidence of the best matching frame seen so far.
    var bestConfidence: Float

    /// True when this track has already been counted and must not increment again
    /// until it genuinely leaves and re-enters.
    /// Spec alias: `confirmedCounted`
    var confirmedCounted: Bool {
        if case .counted = state { return true }
        return false
    }

    /// Back-compat alias.
    var isCounted: Bool { confirmedCounted }
}

// MARK: - LiveObjectTracker

/// Cross-frame object tracker for live audit mode.
///
/// Algorithm:
/// - Each frame's detections are matched to existing tracks using IoU overlap +
///   class consistency (same skuId) + center-point proximity as tiebreakers.
/// - Matched tracks update their bbox and confidence; unmatched detections create new tracks.
/// - Tracks not matched for `expirySeconds` are pruned — this is the "left frame" signal.
/// - A track transitions to `.counted` after `confirmationFrames` consecutive matches
///   and can then never be re-counted unless it fully expires and a new track is created.
///
/// All state is in-memory and reset when the scan session resets.
///
/// Thread safety: `@MainActor` — all access from `LiveScanViewModel` is already on main actor.
@MainActor
final class LiveObjectTracker {

    // MARK: - Configuration

    /// Minimum IoU overlap between a detection bbox and an existing track bbox
    /// to consider them the same physical object.
    private let minIoUForMatch: Double = 0.30

    /// Maximum normalized center-point distance allowed as a fallback match
    /// when IoU is below `minIoUForMatch` but the object may have shifted slightly.
    private let maxCenterDistanceForMatch: Double = 0.18

    /// Minimum number of consecutive frames a detection must appear before it is
    /// confirmed and its count is incremented.
    ///
    /// **Spec requirement: minimumFramesObserved = 3**
    /// This filters single-frame and double-frame noise from fast cameras.
    private let confirmationFrames: Int = 3

    /// Seconds of absence before a track is considered to have "left the frame".
    /// After expiry the track is removed; the next detection of the same SKU at
    /// a similar location will start a fresh track and can be counted again.
    private let expirySeconds: TimeInterval = 2.5

    /// Hard cap on the number of NEW count confirmations that can be emitted per
    /// one-second window across ALL SKUs. This is the "maximum detections per second"
    /// guardrail from the spec. Excess confirmations in a burst window are blocked
    /// and returned in `rateBlocked` so the caller can route them to review.
    private let maxNewCountsPerSecond: Int = 6

    // MARK: - State

    private(set) var activeTracks: [UUID: TrackedObject] = [:]

    /// Rolling log of wall-clock times at which new count confirmations were emitted
    /// in the current session. Used to enforce `maxNewCountsPerSecond`.
    private var recentConfirmationTimestamps: [Date] = []

    // MARK: - Diagnostics

    /// Total objects confirmed-counted in this session (never decremented).
    private(set) var totalConfirmedThisSession: Int = 0

    // MARK: - Public Interface

    /// Reset all tracking state (call when a new scan session begins or is reset).
    func reset() {
        activeTracks.removeAll()
        recentConfirmationTimestamps.removeAll()
        totalConfirmedThisSession = 0
        print("[LiveObjectTracker] 🔄 Tracker reset — all tracks cleared")
    }

    /// Result of processing a single frame.
    struct FrameProcessingResult {
        /// Detections promoted to confirmed status this frame — call site should count these.
        let newlyCounted: [LiveDetection]
        /// Detections that would have been counted but were blocked by the per-second
        /// rate-cap guardrail. Route these to the review fallback store.
        let rateBlocked: [LiveDetection]
    }

    /// Process a single frame's detections.
    ///
    /// Returns a `FrameProcessingResult` with:
    /// - `newlyCounted`: detections to count (first-time confirmation per physical object).
    /// - `rateBlocked`: detections blocked by the per-second rate cap (route to review).
    ///
    /// A detection is only returned in `newlyCounted` the **first** time its
    /// underlying physical object is confirmed across `confirmationFrames` frames.
    /// Subsequent appearances of the same tracked object are silently blocked.
    ///
    /// - Parameter detections: Raw detections from the recognition engine for this frame.
    func processFrame(_ detections: [LiveDetection]) -> FrameProcessingResult {
        return _processFrame(detections)
    }

    /// Legacy single-value overload kept for call sites that don't need rate-blocked info.
    /// Returns only the `newlyCounted` subset.
    func processFrameLegacy(_ detections: [LiveDetection]) -> [LiveDetection] {
        _processFrame(detections).newlyCounted
    }

    private func _processFrame(_ detections: [LiveDetection]) -> FrameProcessingResult {
        let now = Date()

        // Step 1 — Mark all active tracks as potentially absent this frame.
        // We'll un-mark them below for any that get matched.
        var unmatchedTrackIds = Set(activeTracks.keys)

        var candidateCounts: [LiveDetection] = []   // promoted this frame, pre rate-check
        var rateBlockedDetections: [LiveDetection] = []

        // Step 2 — Match each detection to an existing track or create a new one.
        for detection in detections {
            if let matchId = findBestMatch(for: detection) {
                // --- Matched to existing track ---
                unmatchedTrackIds.remove(matchId)
                var track = activeTracks[matchId]!

                // Update spatial/confidence state
                track.lastBBox = detection.bbox
                track.lastSeenAt = now
                track.observedFrameCount += 1
                if detection.confidence > track.bestConfidence {
                    track.bestConfidence = detection.confidence
                }

                switch track.state {
                case .counted:
                    // Already counted — block re-count silently.
                    print("[LiveObjectTracker] 🔒 BLOCKED '\(detection.skuName)' (trackId=\(matchId.uuidString.prefix(8))) — already counted")
                    activeTracks[matchId] = track

                case .pending(let seenCount):
                    let newCount = seenCount + 1
                    print("[LiveObjectTracker] 📍 MATCHED '\(detection.skuName)' (trackId=\(matchId.uuidString.prefix(8))) seen=\(newCount)/\(confirmationFrames)")

                    if newCount >= confirmationFrames {
                        // Promote to counted
                        track.state = .counted
                        activeTracks[matchId] = track
                        candidateCounts.append(detection)
                        print("[LiveObjectTracker] ✅ PROMOTED '\(detection.skuName)' (trackId=\(matchId.uuidString.prefix(8))) conf=\(String(format: "%.2f", detection.confidence)) frames=\(track.observedFrameCount)")
                    } else {
                        track.state = .pending(seenCount: newCount)
                        activeTracks[matchId] = track
                    }

                case .absent:
                    // Re-appeared before expiry window — treat as re-match, reset to pending(1)
                    track.state = .pending(seenCount: 1)
                    activeTracks[matchId] = track
                    print("[LiveObjectTracker] 🔁 RE-MATCHED (from absent) '\(detection.skuName)' (trackId=\(matchId.uuidString.prefix(8)))")
                }

            } else {
                // --- No match — create a new track ---
                let newTrackId = UUID()
                let newTrack = TrackedObject(
                    trackId: newTrackId,
                    skuId: detection.skuId,
                    skuName: detection.skuName,
                    lastBBox: detection.bbox,
                    state: .pending(seenCount: 1),
                    firstSeenAt: now,
                    lastSeenAt: now,
                    observedFrameCount: 1,
                    bestConfidence: detection.confidence
                )
                activeTracks[newTrackId] = newTrack
                print("[LiveObjectTracker] 🆕 CREATED track '\(detection.skuName)' (trackId=\(newTrackId.uuidString.prefix(8))) conf=\(String(format: "%.2f", detection.confidence))")
            }
        }

        // Step 3 — Age out tracks that were not matched this frame.
        for trackId in unmatchedTrackIds {
            guard var track = activeTracks[trackId] else { continue }

            let absenceAge = now.timeIntervalSince(track.lastSeenAt)
            if absenceAge >= expirySeconds {
                // Track has left the frame — remove it entirely.
                activeTracks.removeValue(forKey: trackId)
                print("[LiveObjectTracker] 💨 EXPIRED '\(track.skuName)' (trackId=\(trackId.uuidString.prefix(8))) after \(String(format: "%.1f", absenceAge))s absence")
            } else {
                // Still within the soft-absent window — just mark as absent so
                // a quick re-appearance doesn't create a new track.
                switch track.state {
                case .counted:
                    // Counted objects stay counted until they fully expire.
                    // No state change needed — they just tick toward expiry.
                    break
                case .pending:
                    // A pending object that goes absent resets — it hadn't
                    // been confirmed yet so we don't want to count it later
                    // if confidence wasn't sustained.
                    track.state = .absent(missedFrames: 1)
                    activeTracks[trackId] = track
                case .absent(let missed):
                    track.state = .absent(missedFrames: missed + 1)
                    activeTracks[trackId] = track
                }
            }
        }

        // Step 4 — Per-second rate-cap guardrail.
        // Flush confirmations older than 1 second, then check how many we've
        // already emitted in this rolling window. Any excess above
        // `maxNewCountsPerSecond` is downgraded to rateBlocked (route to review).
        let rateWindowStart = now.addingTimeInterval(-1.0)
        recentConfirmationTimestamps.removeAll { $0 < rateWindowStart }

        var newlyCounted: [LiveDetection] = []
        for detection in candidateCounts {
            let alreadyEmitted = recentConfirmationTimestamps.count
            if alreadyEmitted < maxNewCountsPerSecond {
                newlyCounted.append(detection)
                recentConfirmationTimestamps.append(now)
                totalConfirmedThisSession += 1
                print("[LiveObjectTracker] ✅ COUNTED '\(detection.skuName)' (rate: \(alreadyEmitted + 1)/\(maxNewCountsPerSecond) per sec)")
            } else {
                rateBlockedDetections.append(detection)
                print("[LiveObjectTracker] 🚦 RATE-BLOCKED '\(detection.skuName)' — \(alreadyEmitted)/\(maxNewCountsPerSecond) per-sec cap reached, routing to review")
            }
        }

        return FrameProcessingResult(newlyCounted: newlyCounted, rateBlocked: rateBlockedDetections)
    }

    // MARK: - Private: Matching

    /// Find the best existing track for a detection.
    ///
    /// Matching priority:
    /// 1. Same SKU + IoU ≥ `minIoUForMatch` (best spatial overlap wins)
    /// 2. Same SKU + center distance ≤ `maxCenterDistanceForMatch` (slight shift fallback)
    ///
    /// Cross-class matches are intentionally not allowed — a Strawberry Vape cannot
    /// match a Green Apple Vape track even if the bboxes overlap.
    private func findBestMatch(for detection: LiveDetection) -> UUID? {
        let detCenter = center(of: detection.bbox)
        var bestId: UUID?
        var bestScore: Double = -1

        for (trackId, track) in activeTracks {
            // Strict class consistency — only match same SKU.
            guard track.skuId == detection.skuId else { continue }

            let iou = computeIoU(detection.bbox, track.lastBBox)
            let dist = distance(detCenter, center(of: track.lastBBox))

            var score: Double = -1
            if iou >= minIoUForMatch {
                score = iou  // Primary: spatial overlap
            } else if dist <= maxCenterDistanceForMatch {
                // Secondary: close center even if boxes shifted (e.g. camera jitter)
                score = 1.0 - (dist / maxCenterDistanceForMatch) * 0.5
            }

            if score > bestScore {
                bestScore = score
                bestId = trackId
            }
        }

        return bestId
    }

    // MARK: - Private: Geometry Helpers

    private func computeIoU(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let interArea = Double(intersection.width * intersection.height)
        let unionArea = Double(a.width * a.height) + Double(b.width * b.height) - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return sqrt(dx * dx + dy * dy)
    }
}
