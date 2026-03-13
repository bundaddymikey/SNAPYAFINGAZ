import Foundation
import UIKit

/// Accumulates uncertain live-scan detections, merges duplicates, and provides
/// a review queue for operator confirmation.
///
/// All state is in-memory — cleared when the scan session ends. Does not persist
/// to SwiftData directly; confirmed items are written via AuditCountService.
@Observable
@MainActor
final class LiveReviewFallbackStore {

    // MARK: - Public State

    var pendingItems: [LiveScanFallbackItem] = []

    var pendingCount: Int { pendingItems.count }
    var isEmpty: Bool { pendingItems.isEmpty }

    // MARK: - Configuration

    /// Seconds within which two similar candidates are considered the same physical item.
    private let mergingWindowSeconds: TimeInterval = 3.0
    /// Minimum confidence gap between top 2 candidates to avoid "closeMatch" routing.
    private let closeMatchGap: Float = 0.08
    /// Max detections per SKU per 5-second window before rapidGrowth kicks in.
    private let rapidGrowthLimit = 8
    private let rapidGrowthWindow: TimeInterval = 5.0

    // MARK: - Private Tracking

    private var recentAutoCounts: [(skuId: UUID, timestamp: Date)] = []

    // MARK: - Route or Count

    /// Evaluate a detection and return whether it should be auto-counted by the caller.
    ///
    /// - Returns: `true` if the caller can safely auto-count; `false` if it was routed
    ///   to this store for operator review.
    func evaluateAndRoute(
        candidates: [LiveProductCandidate],
        cropImage: UIImage?,
        timestamp: Date,
        auditSessionId: UUID
    ) -> Bool {
        guard let top = candidates.first else { return false }

        var reasonFlags: [LiveFallbackReason] = []

        // --- Guardrail 1: Low confidence ---
        if top.confidence < 0.55 {
            reasonFlags.append(.lowConfidence)
        }

        // --- Guardrail 2: Close match between top candidates ---
        if candidates.count >= 2 {
            let second = candidates[1]
            let gap = top.confidence - second.confidence
            if gap < closeMatchGap {
                reasonFlags.append(.closeMatch)
            }
        }

        // --- Guardrail 3: Ambiguous bounding box (very small confidence region) ---
        if top.confidence < 0.42 {
            reasonFlags.append(.ambiguousBBox)
        }

        // --- Guardrail 4: Rapid growth check ---
        let now = Date()
        pruneRecentCounts(before: now.addingTimeInterval(-rapidGrowthWindow))
        let recentForSku = recentAutoCounts.filter { $0.skuId == top.skuId }.count
        if recentForSku >= rapidGrowthLimit {
            reasonFlags.append(.rapidGrowthBlocked)
        }

        // --- Auto-count if all guardrails passed ---
        if reasonFlags.isEmpty {
            recentAutoCounts.append((skuId: top.skuId, timestamp: now))
            return true
        }

        // --- Route to review fallback ---
        routeToReview(
            candidates: candidates,
            cropImage: cropImage,
            timestamp: timestamp,
            auditSessionId: auditSessionId,
            reasonFlags: reasonFlags
        )

        #if DEBUG
        let reasons = reasonFlags.map(\.rawValue).joined(separator: ", ")
        let name = top.skuName
        print("[LiveReviewFallback] Routed '\(name)' (conf=\(String(format: "%.2f", top.confidence))) → reasons: \(reasons)")
        #endif

        return false
    }

    // MARK: - Private: Route and Merge

    private func routeToReview(
        candidates: [LiveProductCandidate],
        cropImage: UIImage?,
        timestamp: Date,
        auditSessionId: UUID,
        reasonFlags: [LiveFallbackReason]
    ) {
        let newItem = LiveScanFallbackItem(
            auditSessionId: auditSessionId,
            candidates: candidates,
            cropImage: cropImage,
            timestamp: timestamp,
            reasonFlags: reasonFlags
        )

        // Smart merge: if an existing item has the same top skuId within the merging window
        let topSkuId = candidates.first?.skuId
        if let idx = pendingItems.firstIndex(where: { existing in
            guard existing.suggestedSkuId == topSkuId else { return false }
            let age = timestamp.timeIntervalSince(existing.bestFrameTimestamp)
            return abs(age) <= mergingWindowSeconds
        }) {
            pendingItems[idx].merge(newItem)

            #if DEBUG
            let name = candidates.first?.skuName ?? "?"
            print("[LiveReviewFallback] Merged into existing item for '\(name)' (total merges: \(pendingItems[idx].mergeCount))")
            #endif
        } else {
            pendingItems.append(newItem)
        }
    }

    // MARK: - Confirm / Dismiss Actions

    /// Operator confirmed a fallback item with the given skuId.
    /// Returns the confirmed skuId and name so the caller can update counts.
    func confirm(item: LiveScanFallbackItem, skuId: UUID, skuName: String) -> (UUID, String) {
        remove(item)
        return (skuId, skuName)
    }

    /// Operator dismissed this item — remove without counting.
    func dismiss(item: LiveScanFallbackItem) {
        remove(item)
    }

    /// Clear all pending items (e.g. when session ends).
    func clear() {
        pendingItems.removeAll()
        recentAutoCounts.removeAll()
    }

    // MARK: - Private helpers

    private func remove(_ item: LiveScanFallbackItem) {
        pendingItems.removeAll { $0.id == item.id }
    }

    private func pruneRecentCounts(before cutoff: Date) {
        recentAutoCounts.removeAll { $0.timestamp < cutoff }
    }
}
