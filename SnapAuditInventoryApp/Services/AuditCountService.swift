import Foundation
import SwiftData

/// Unified service for all quantity updates across every input method.
///
/// Every input (barcode, voice, photo, video, live camera, multi-device) should
/// funnel count changes through this service so that `AuditLineItem.visionCount`,
/// deltas, flags, and ScanEvent broadcasting are always handled consistently.
@Observable
@MainActor
final class AuditCountService {

    /// Optional sync service for multi-device broadcast.
    var syncService: SessionSyncService?

    // MARK: - Single Count Entry Point

    /// Increment (or decrement) the actual count for a given SKU in the session.
    ///
    /// - Parameters:
    ///   - session: The active `AuditSession`.
    ///   - skuId: The `ProductSKU.id` (nil for unrecognized items).
    ///   - skuName: Display name for the product.
    ///   - quantity: Units to add (positive) or remove (negative). Default 1.
    ///   - confidence: Recognition confidence. Default 1.0 for manual/barcode.
    ///   - sourceType: Which input method produced this count.
    ///   - context: The SwiftData `ModelContext` for persistence.
    /// - Returns: The updated (or newly created) `AuditLineItem`.
    @discardableResult
    func recordCount(
        session: AuditSession,
        skuId: UUID?,
        skuName: String,
        quantity: Int = 1,
        confidence: Double = 1.0,
        sourceType: ScanSourceType,
        context: ModelContext,
        skipBroadcast: Bool = false
    ) -> AuditLineItem {

        // 1. Find or create AuditLineItem
        let lineItem: AuditLineItem
        if let existing = session.lineItems.first(where: { item in
            if let id = skuId, let itemId = item.skuId {
                return id == itemId
            }
            return item.skuNameSnapshot == skuName
        }) {
            existing.visionCount += quantity
            // Clamp at zero
            if existing.visionCount < 0 { existing.visionCount = 0 }
            lineItem = existing
        } else {
            let newItem = AuditLineItem(
                session: session,
                skuId: skuId,
                skuNameSnapshot: skuName,
                visionCount: max(quantity, 0),
                countConfidence: confidence,
                reviewStatus: .confirmed
            )
            context.insert(newItem)
            session.lineItems.append(newItem)
            lineItem = newItem
        }

        // 2. Recompute deltas and flags (unified logic)
        recomputeDeltas(lineItem)
        recomputeMismatchFlags(lineItem)

        // 3. Persist
        try? context.save()

        // 4. Broadcast to multi-device session (if active and not suppressed)
        if !skipBroadcast {
            broadcastIfNeeded(
                session: session,
                skuId: skuId,
                skuName: skuName,
                quantity: quantity,
                confidence: confidence,
                sourceType: sourceType
            )
        }

        return lineItem
    }

    // MARK: - Delta Recomputation (unified)

    /// Recompute all delta fields for a line item based on current visionCount.
    func recomputeDeltas(_ item: AuditLineItem) {
        // Expected qty delta
        if let expected = item.expectedQty {
            item.delta = item.visionCount - expected
            item.deltaPercent = expected > 0
                ? Double(item.visionCount - expected) / Double(expected) * 100
                : nil
        } else {
            item.delta = nil
            item.deltaPercent = nil
        }

        // On-hand delta
        if let onHand = item.posOnHand {
            item.deltaOnHand = item.visionCount - onHand
            item.deltaOnHandPercent = onHand > 0
                ? Double(item.visionCount - onHand) / Double(onHand) * 100
                : nil
        } else {
            item.deltaOnHand = nil
            item.deltaOnHandPercent = nil
        }
    }

    /// Recompute mismatch flags (shortage, overage, largeVariance, expectedZeroButFound).
    /// Preserves non-mismatch flags (lowLight, blur, closeMatch, etc.) and pipeline-set flags
    /// (.unexpectedItem, .suspiciousOvercount) that require operator review to resolve.
    func recomputeMismatchFlags(_ item: AuditLineItem) {
        // Preserve: quality flags (non-mismatch) + pipeline-flagged unexpected/suspicious items
        // Those require operator action to dismiss — not cleared simply by a count change.
        let flagsToPreserve: Set<FlagReason> = [.unexpectedItem, .suspiciousOvercount]
        var flags = item.flagReasons.filter { !$0.isMismatch || flagsToPreserve.contains($0) }

        if let expected = item.expectedQty {
            if expected == 0 && item.visionCount > 0 {
                flags.appendIfNotContains(.expectedZeroButFound)
            } else if item.visionCount < expected {
                flags.appendIfNotContains(.shortage)
            } else if item.visionCount > expected {
                flags.appendIfNotContains(.overage)
            }

            if let delta = item.delta, expected > 0 {
                let pct = abs(Double(delta)) / Double(expected)
                if abs(delta) > 1 && pct > 0.10 {
                    flags.appendIfNotContains(.largeVariance)
                }
            }
        }

        item.flagReasons = flags
    }

    // MARK: - Evidence-Based Count Recomputation

    /// Recompute visionCount from evidence review status, then refresh deltas + flags.
    /// Used by the photo/video pipeline where count is derived from evidence, not incremented.
    func recomputeFromEvidence(_ item: AuditLineItem) {
        let nonRejected = item.evidence.filter { $0.reviewStatus != .rejected }
        let confirmed = nonRejected.filter { $0.reviewStatus == .confirmed }
        item.visionCount = max(confirmed.count, nonRejected.count > 0 ? 1 : 0)
        recomputeDeltas(item)
        recomputeMismatchFlags(item)
    }

    // MARK: - Multi-Device Broadcast

    private func broadcastIfNeeded(
        session: AuditSession,
        skuId: UUID?,
        skuName: String,
        quantity: Int,
        confidence: Double,
        sourceType: ScanSourceType
    ) {
        guard let syncService, syncService.isInSharedSession else { return }
        guard quantity > 0 else { return } // Don't broadcast decrements

        let event = ScanEvent(
            sessionId: session.id,
            skuId: skuId,
            skuName: skuName,
            confidence: confidence,
            originDeviceId: syncService.multipeerService.deviceId,
            originDeviceRole: syncService.deviceRole,
            quantity: quantity,
            sourceType: sourceType
        )
        syncService.sendScanEvent(event)
    }
}
