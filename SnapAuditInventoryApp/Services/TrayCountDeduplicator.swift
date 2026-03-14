import Foundation
import UIKit

// MARK: - TrayDetection

/// A single detection from one image source, tagged with its source index
/// so we can track which image it came from during cross-frame clustering.
nonisolated struct TrayDetection: Sendable {
    let sourceIndex: Int        // Which photo/frame this came from (0-based)
    let skuId: UUID?
    let skuName: String
    let bbox: BoundingBox       // Normalised 0–1 coords within its source image
    let confidence: Double
    let isSoftAssigned: Bool
    let flagReasons: [FlagReason]
    let reviewStatus: ReviewStatus
    let cropPath: String
    let queryEmbeddingData: Data
    let top3: [DetectedCandidate]
    var metadataJSON: String = ""
}

// MARK: - TrayItemCluster

/// One physical object's cluster — the canonical "counted once" unit.
/// Contains all raw detections from different images that were merged into it.
nonisolated struct TrayItemCluster: Sendable {
    let representative: TrayDetection   // Best-confidence detection in this cluster
    var members: [TrayDetection]        // All merged sightings (including representative)

    var skuId: UUID?   { representative.skuId }
    var skuName: String { representative.skuName }

    /// The merged/average confidence across all sightings.
    var confidence: Double {
        let sum = members.reduce(0.0) { $0 + $1.confidence }
        return sum / Double(max(members.count, 1))
    }

    /// Number of distinct source images this cluster was seen in.
    var sourceCount: Int {
        Set(members.map(\.sourceIndex)).count
    }

    /// Union of all flag reasons across members.
    var allFlagReasons: [FlagReason] {
        var flags: [FlagReason] = []
        for m in members {
            for r in m.flagReasons where !flags.contains(r) {
                flags.append(r)
            }
        }
        return flags
    }

    /// Worst-case review status: if any member is pending, the cluster is pending.
    var reviewStatus: ReviewStatus {
        members.contains { $0.reviewStatus == .pending } ? .pending : .confirmed
    }

    var isSoftAssigned: Bool {
        members.contains { $0.isSoftAssigned }
    }
}

// MARK: - TrayPileReviewGroup

/// A spatial group of low-confidence detections from a dense pile region.
///
/// Instead of presenting every individual uncertain detection to the operator,
/// the deduplicator groups nearby review items into a single `TrayPileReviewGroup`.
/// The operator sees one review entry per *pile zone* and can confirm the estimated
/// count for that zone, rather than reviewing dozens of individual crops.
///
/// Used by `buildTrayCountLineItems` to create spatially-grouped pending items.
nonisolated struct TrayPileReviewGroup: Sendable {
    /// Human-readable label, e.g. "Pile A", "Pile B" (assigned after grouping)
    var label: String
    /// All review detections that fall within this pile zone.
    let members: [TrayDetection]
    /// Centroid of the group's member bboxes (normalised 0–1 coords).
    let centroid: CGPoint
    /// Average confidence across members.
    var averageConfidence: Double {
        members.reduce(0.0) { $0 + $1.confidence } / Double(max(members.count, 1))
    }
    /// Most common SKU in this group (majority vote).
    var majoritySkuId: UUID? {
        let counts = Dictionary(grouping: members.compactMap(\.skuId), by: { $0 })
            .map { ($0.key, $0.value.count) }
        return counts.max(by: { $0.1 < $1.1 })?.0
    }
    var majoritySkuName: String {
        let counts = Dictionary(grouping: members, by: { $0.skuName })
            .map { ($0.key, $0.value.count) }
        return counts.max(by: { $0.1 < $1.1 })?.0 ?? "Unknown"
    }
    /// Estimated item count — heuristic based on member count and spatial spread.
    var estimatedCount: Int {
        max(1, Int((Double(members.count) * 0.6).rounded()))
    }
    var allFlagReasons: [FlagReason] {
        var flags: [FlagReason] = []
        for m in members { for r in m.flagReasons where !flags.contains(r) { flags.append(r) } }
        return flags
    }
    var bestRepresentative: TrayDetection? {
        members.max(by: { $0.confidence < $1.confidence })
    }
}


/// Cross-frame spatial deduplication for Tray Count mode.
///
/// Algorithm:
/// 1. Detections are processed one source at a time.
/// 2. Each new detection is matched against existing clusters that share the same
///    SKU, using IoU overlap + center-point proximity as matching signals.
/// 3. If a match is found → merge into the existing cluster (do NOT create a new count).
/// 4. If no match → create a new cluster (counts as one new physical object).
///
/// The key insight: the same physical item photographed from slightly different angles
/// will have similar center positions and overlapping bounding boxes. We exploit this
/// to avoid counting it twice across the multi-photo/video-frame set.
///
/// Low-confidence detections (below `lowConfidenceThreshold`) are separated into a
/// "needs review" bucket rather than being silently merged or silently rejected.
nonisolated final class TrayCountDeduplicator: Sendable {

    // MARK: - Thresholds

    /// Minimum IoU for two same-SKU detections to be considered the same physical object.
    private static let iouMergeThreshold: Double = 0.20

    /// Maximum center-to-center distance (normalised 0–1) as a fallback when IoU is low
    /// but the object may have shifted between shots.
    private static let centerDistanceMergeThreshold: Double = 0.15

    /// Detections below this confidence are flagged for review rather than auto-merged.
    private static let lowConfidenceThreshold: Double = 0.42

    /// Maximum multiplier over expected quantity before excess clusters are demoted to review.
    /// Matches the threshold used in `ExpectedSheetContext.sanityCheck` for consistency.
    private static let overcountMultiplierThreshold: Double = 3.0

    /// Minimum absolute excess before the multiplier cap is applied.
    /// Prevents over-sensitive capping when expected qty is very small (e.g. expected=1, count=2).
    private static let minimumAbsoluteExcessForCheck: Int = 2

    // MARK: - Public Interface

    /// Deduplicate a flat list of `TrayDetection` records (all images combined).
    ///
    /// - Parameters:
    ///   - detections: All raw detections from every photo/frame, in source order.
    ///   - expectedQtyMap: Optional SKU → expected quantity map loaded from the expected
    ///     sheet. When provided, clusters whose count dramatically exceeds the expected
    ///     quantity are re-routed to the review bucket instead of being auto-confirmed.
    ///     Pass `nil` (or leave empty) when no expected sheet is active.
    /// - Returns: `(confirmed: [TrayItemCluster], review: [TrayDetection])`
    ///   - `confirmed`: Clusters that confidently represent one physical object each.
    ///   - `review`: Low-confidence or excess-count detections for operator review.
    static func deduplicate(
        _ detections: [TrayDetection],
        expectedQtyMap: [UUID: Int] = [:]
    ) -> (confirmed: [TrayItemCluster], review: [TrayDetection]) {

        var clusters: [TrayItemCluster] = []
        var reviewQueue: [TrayDetection] = []

        // Sort by confidence descending — highest-confidence detections seed clusters first.
        let sorted = detections.sorted { $0.confidence > $1.confidence }

        for detection in sorted {
            // Low-confidence detections go straight to review, never seed a cluster.
            if detection.confidence < lowConfidenceThreshold {
                reviewQueue.append(detection)
                continue
            }

            // Try to find an existing cluster to merge into.
            if let matchIndex = bestClusterMatch(for: detection, in: clusters) {
                clusters[matchIndex].members.append(detection)
            } else {
                // New physical object — start a fresh cluster.
                clusters.append(TrayItemCluster(representative: detection, members: [detection]))
            }
        }

        // ── Expected-sheet cluster cap ────────────────────────────────────────────
        // After clustering, check each SKU's confirmed cluster count against its
        // expected quantity. If a SKU has dramatically more confirmed clusters than
        // expected, the excess clusters are demoted to the review queue.
        //
        // This is the "if counts exceed expected quantities dramatically" guardrail
        // from the spec. It prevents runaway tray counts when the camera sees the
        // same physical item from many angles across a multi-photo tray.
        //
        // Rule:   excess = count - expectedQty
        //         if excess >= minimumAbsoluteExcessForCheck
        //           AND count / expectedQty >= overcountMultiplierThreshold
        //         → move excess clusters to reviewQueue
        if !expectedQtyMap.isEmpty {
            // Group confirmed clusters by skuId for per-SKU capping.
            var clustersBySkuId: [UUID: [Int]] = [:] // skuId → indices into `clusters`
            for (idx, cluster) in clusters.enumerated() {
                if let skuId = cluster.skuId {
                    clustersBySkuId[skuId, default: []].append(idx)
                }
            }

            var indicesToDemote = Set<Int>()
            for (skuId, indices) in clustersBySkuId {
                guard let expected = expectedQtyMap[skuId], expected > 0 else { continue }
                let count = indices.count
                let excess = count - expected
                guard excess >= minimumAbsoluteExcessForCheck else { continue }
                let multiplier = Double(count) / Double(expected)
                guard multiplier >= overcountMultiplierThreshold else { continue }

                // Sort indices by confidence ascending so we demote the weakest clusters first.
                let sortedByConfidence = indices.sorted {
                    clusters[$0].confidence < clusters[$1].confidence
                }
                // Demote excess clusters (keep the `expected` highest-confidence ones).
                let demoteCount = min(excess, sortedByConfidence.count)
                for i in 0..<demoteCount {
                    indicesToDemote.insert(sortedByConfidence[i])
                }

                print("[TrayDeduplicator] \u{1F6A6} EXPECTED-CAP '\(clusters[indices[0]].skuName)' expected=\(expected) actual=\(count) \(String(format: "%.1f", multiplier))× — demoting \(demoteCount) excess clusters to review")
            }

            if !indicesToDemote.isEmpty {
                // Move demoted clusters' representative detections to reviewQueue.
                let demotedRepresentatives = indicesToDemote.map { clusters[$0].representative }
                reviewQueue.append(contentsOf: demotedRepresentatives)
                // Rebuild clusters without the demoted entries.
                clusters = clusters.enumerated()
                    .filter { !indicesToDemote.contains($0.offset) }
                    .map { $0.element }
            }
        }
        // ─────────────────────────────────────────────────────────────────────────

        return (confirmed: clusters, review: reviewQueue)
    }

    // MARK: - Matching Logic

    /// Returns the index of the best existing cluster match for a given detection, or nil.
    private static func bestClusterMatch(
        for detection: TrayDetection,
        in clusters: [TrayItemCluster]
    ) -> Int? {

        var bestIndex: Int? = nil
        var bestScore: Double = -1

        for (i, cluster) in clusters.enumerated() {
            // SKU must agree (or both unknown)
            guard cluster.skuId == detection.skuId else { continue }

            // Must not already have seen this SKU from the same source image
            // (prevents treating two different items in the same photo as one cluster)
            if cluster.members.contains(where: { $0.sourceIndex == detection.sourceIndex }) { continue }

            let repBBox = cluster.representative.bbox
            let detBBox = detection.bbox

            let iou = computeIoU(repBBox, detBBox)
            let cx = (repBBox.centerX - detBBox.centerX)
            let cy = (repBBox.centerY - detBBox.centerY)
            let centerDist = sqrt(cx * cx + cy * cy)

            let overlaps = iou >= iouMergeThreshold
            let isNearby = centerDist <= centerDistanceMergeThreshold

            guard overlaps || isNearby else { continue }

            // Score: higher IoU + lower center distance = better match.
            let score = iou * 0.7 + (1.0 - min(centerDist / centerDistanceMergeThreshold, 1.0)) * 0.3
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }

        return bestIndex
    }

    // MARK: - IoU

    private static func computeIoU(_ a: BoundingBox, _ b: BoundingBox) -> Double {
        let interX1 = max(a.x, b.x)
        let interY1 = max(a.y, b.y)
        let interX2 = min(a.x + a.width, b.x + b.width)
        let interY2 = min(a.y + a.height, b.y + b.height)

        let interW = max(0, interX2 - interX1)
        let interH = max(0, interY2 - interY1)
        let interArea = interW * interH

        guard interArea > 0 else { return 0 }

        let aArea = a.width * a.height
        let bArea = b.width * b.height
        let unionArea = aArea + bArea - interArea

        return unionArea > 0 ? interArea / unionArea : 0
    }

    // MARK: - Grouped Pile Review

    /// Group low-confidence review detections into spatial pile clusters.
    ///
    /// Instead of routing every uncertain detection individually to the review queue,
    /// this method merges spatially-close detections into `TrayPileReviewGroup`s.
    /// The operator then reviews *one entry per pile zone* and confirms an estimated
    /// count, rather than one review per detection.
    ///
    /// Grouping criterion: two detections join the same group when their bbox centroids
    /// are within `proximityThreshold` of each other (normalised coords).
    ///
    /// - Parameter reviewItems: Flat list from `deduplicate(_:expectedQtyMap:).review`.
    /// - Parameter proximityThreshold: Max centroid distance to merge into one group.
    /// - Returns: Labelled pile groups, sorted by centroid position (left-to-right, top-to-bottom).
    static func groupReviewItemsIntoPileClusters(
        _ reviewItems: [TrayDetection],
        proximityThreshold: Double = 0.22
    ) -> [TrayPileReviewGroup] {
        guard !reviewItems.isEmpty else { return [] }

        // Greedy single-linkage clustering on centroid distance
        var groups: [(centroid: CGPoint, members: [TrayDetection])] = []

        for item in reviewItems {
            let center = CGPoint(x: item.bbox.centerX, y: item.bbox.centerY)

            // Find closest existing group
            var bestIdx: Int? = nil
            var bestDist = Double.infinity
            for (i, group) in groups.enumerated() {
                let dx = Double(group.centroid.x) - item.bbox.centerX
                let dy = Double(group.centroid.y) - item.bbox.centerY
                let dist = sqrt(dx*dx + dy*dy)
                if dist < bestDist && dist <= proximityThreshold {
                    bestDist = dist
                    bestIdx = i
                }
            }

            if let idx = bestIdx {
                groups[idx].members.append(item)
                // Update centroid (running average)
                let n = Double(groups[idx].members.count)
                let prevC = groups[idx].centroid
                groups[idx] = (
                    centroid: CGPoint(
                        x: (prevC.x * CGFloat((n - 1)) + center.x) / CGFloat(n),
                        y: (prevC.y * CGFloat((n - 1)) + center.y) / CGFloat(n)
                    ),
                    members: groups[idx].members
                )
            } else {
                groups.append((centroid: center, members: [item]))
            }
        }

        // Sort groups left-to-right, top-to-bottom
        let sorted = groups.sorted {
            if abs(Double($0.centroid.y) - Double($1.centroid.y)) > 0.15 {
                return $0.centroid.y < $1.centroid.y
            }
            return $0.centroid.x < $1.centroid.x
        }

        // Assign labels and build result
        let alphabet = ["A","B","C","D","E","F","G","H","I","J","K","L"]
        return sorted.enumerated().map { (i, group) in
            TrayPileReviewGroup(
                label: "Pile \(alphabet[min(i, alphabet.count - 1)])",
                members: group.members,
                centroid: group.centroid
            )
        }
    }
}

