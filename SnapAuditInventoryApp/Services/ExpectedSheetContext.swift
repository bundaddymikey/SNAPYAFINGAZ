import Foundation

// MARK: - Expected Sheet Context

/// A compiled, read-only view of an audit session's expected inventory sheet.
///
/// Built once per audit from either:
///  - `ShelfExpectedRow` records attached to a `ShelfLayout` (per-shelf expected CSV)
///  - `ExpectedRow` records inside a session's `ExpectedSnapshot` (per-session CSV upload)
///
/// Thread safety: `nonisolated struct` — fully Sendable, safe to pass to background tasks.
///
/// Usage:
/// ```swift
/// let ctx = ExpectedSheetContext(shelfRows: layout.expectedRows)
/// let candidateIds = ctx.candidateSkuIds   // narrow recognition to expected
/// ctx.sanityCheck(skuId: id, proposedCount: n) // detect unrealistic overcounts
/// ```
nonisolated struct ExpectedSheetContext: Sendable {

    // MARK: - Nested Types

    /// Lightweight snapshot of a single expected row — Sendable, no SwiftData references.
    struct ExpectedEntry: Sendable {
        let skuId: UUID?          // nil if the CSV row was not matched to any catalog SKU
        let productName: String
        let brand: String
        let barcode: String
        let expectedQty: Int
    }

    /// Result of a count sanity check.
    enum SanityResult: Sendable {
        /// Count is within acceptable bounds.
        case ok
        /// Count exceeds expected by a suspicious margin — route to review.
        /// `multiplier` is how many times over expected the count is.
        case suspiciousOvercount(expectedQty: Int, actualCount: Int, multiplier: Double)
        /// This SKU is not on the expected sheet at all.
        case unexpectedItem(productName: String)
    }

    // MARK: - Core Data

    /// All entries from the expected sheet. May include unmatched rows (skuId == nil).
    let entries: [ExpectedEntry]

    /// SKU IDs that have been matched to the catalog (resolved rows only).
    let candidateSkuIds: [UUID]

    /// Quick lookup: skuId → expected quantity.
    let expectedQtyMap: [UUID: Int]

    /// Whether this context is empty (no expected sheet loaded).
    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Initializers

    /// Initialize from `ShelfExpectedRow` records (layout-attached CSV).
    init(shelfRows: [ShelfExpectedRowSnapshot]) {
        let allEntries = shelfRows.map { row in
            ExpectedEntry(
                skuId: row.matchedSkuId,
                productName: row.productName,
                brand: row.brand,
                barcode: row.barcode,
                expectedQty: row.expectedQty
            )
        }
        self.entries = allEntries
        self.candidateSkuIds = allEntries.compactMap { $0.skuId }
        self.expectedQtyMap = Dictionary(
            uniqueKeysWithValues: allEntries.compactMap { e -> (UUID, Int)? in
                guard let id = e.skuId else { return nil }
                return (id, e.expectedQty)
            }
        )
    }

    /// Initialize from `ExpectedRowSnapshot` records (session-level uploaded CSV).
    init(sessionRows: [ExpectedRowSnapshot]) {
        let allEntries = sessionRows.map { row in
            ExpectedEntry(
                skuId: row.matchedSkuId,
                productName: row.skuOrNameKey,
                brand: "",
                barcode: "",
                expectedQty: row.expectedQty
            )
        }
        self.entries = allEntries
        self.candidateSkuIds = allEntries.compactMap { $0.skuId }
        self.expectedQtyMap = Dictionary(
            uniqueKeysWithValues: allEntries.compactMap { e -> (UUID, Int)? in
                guard let id = e.skuId else { return nil }
                return (id, e.expectedQty)
            }
        )
    }

    /// Initialize from both shelf rows and session rows merged together.
    init(shelfRows: [ShelfExpectedRowSnapshot], sessionRows: [ExpectedRowSnapshot]) {
        let shelf = ExpectedSheetContext(shelfRows: shelfRows)
        let session = ExpectedSheetContext(sessionRows: sessionRows)
        // Merge; session rows override shelf rows for the same skuId
        var merged: [UUID: ExpectedEntry] = [:]
        for entry in shelf.entries { if let id = entry.skuId { merged[id] = entry } }
        for entry in session.entries { if let id = entry.skuId { merged[id] = entry } }
        // Also include unmatched entries (those without skuId)
        let unmatchedShelf = shelf.entries.filter { $0.skuId == nil }
        let unmatchedSession = session.entries.filter { $0.skuId == nil }
        self.entries = Array(merged.values) + unmatchedShelf + unmatchedSession
        self.candidateSkuIds = Array(merged.keys)
        self.expectedQtyMap = merged.mapValues { $0.expectedQty }
    }

    /// Empty context — no expected sheet available.
    static let empty = ExpectedSheetContext(shelfRows: [], sessionRows: [])

    // MARK: - Query Interface

    /// Whether a given SKU is listed in the expected sheet.
    func isExpected(skuId: UUID) -> Bool {
        expectedQtyMap[skuId] != nil
    }

    /// Expected quantity for a SKU, or nil if not on the sheet.
    func expectedQty(for skuId: UUID) -> Int? {
        expectedQtyMap[skuId]
    }

    // MARK: - Sanity Checking

    /// Maximum multiplier over expected quantity before a count is considered suspicious.
    ///
    /// Example: if expected == 2 and `overcountMultiplierThreshold` == 3.0,
    /// then a proposed count of 7 (3.5× expected) is flagged as `.suspiciousOvercount`.
    private let overcountMultiplierThreshold: Double = 3.0

    /// Minimum absolute excess before the multiplier check is applied.
    /// Prevents flagging small absolute counts (e.g. expected=1, actual=3 would be 3×).
    private let minimumAbsoluteExcessForCheck: Int = 2

    /// Evaluate whether a proposed count for a SKU is realistic given the expected sheet.
    ///
    /// - Parameters:
    ///   - skuId: The recognized product's catalog ID.
    ///   - productName: Human-readable name (used in the result for logging).
    ///   - proposedCount: The total count that would be recorded if approved.
    /// - Returns: `.ok`, `.suspiciousOvercount`, or `.unexpectedItem`.
    func sanityCheck(skuId: UUID, productName: String, proposedCount: Int) -> SanityResult {
        guard !isEmpty else { return .ok } // No expected sheet — no sanity check possible

        guard let expected = expectedQtyMap[skuId] else {
            return .unexpectedItem(productName: productName)
        }

        // expected == 0 means it's listed but not expected; any detection triggers review
        if expected == 0 && proposedCount > 0 {
            return .suspiciousOvercount(expectedQty: 0, actualCount: proposedCount, multiplier: Double.infinity)
        }

        guard proposedCount > expected else { return .ok }

        let excess = proposedCount - expected
        guard excess >= minimumAbsoluteExcessForCheck else { return .ok }

        let multiplier = Double(proposedCount) / Double(max(expected, 1))
        if multiplier >= overcountMultiplierThreshold {
            return .suspiciousOvercount(
                expectedQty: expected,
                actualCount: proposedCount,
                multiplier: multiplier
            )
        }

        return .ok
    }

    // MARK: - Candidate Restriction Helper

    /// Returns the effective candidate SKU IDs for recognition.
    ///
    /// If the expected sheet is non-empty and has at least one matched SKU,
    /// the expected-sheet SKUs are returned as the primary candidate set.
    /// Otherwise, returns `nil` to indicate the caller should use the full catalog.
    ///
    /// - Parameter fullCatalogIds: Full catalog as a fallback when no expected sheet exists.
    /// - Returns: Narrowed candidate IDs, or `fullCatalogIds` if no sheet is loaded.
    func effectiveCandidateIds(fullCatalogIds: [UUID]) -> [UUID] {
        guard !candidateSkuIds.isEmpty else { return fullCatalogIds }
        return candidateSkuIds
    }

    // MARK: - Prior Factor Computation

    /// Build a map of SKU ID → recognition score multiplier based on the expected sheet.
    ///
    /// - Expected products: boosted by `expectedBoost` (they're likely to be present).
    /// - Non-expected products: penalized by `unexpectedPenalty` (less likely).
    ///
    /// These factors are applied to raw classification scores before thresholding,
    /// so expected products win close matches more often than unexpected ones.
    ///
    /// - Parameter allCandidateIds: All SKU IDs in the current recognition candidate set.
    func priorFactors(
        for allCandidateIds: [UUID],
        expectedBoost: Double = 1.15,
        unexpectedPenalty: Double = 0.80
    ) -> [UUID: Double] {
        guard !isEmpty else { return [:] }
        var factors: [UUID: Double] = [:]
        let expectedSet = Set(candidateSkuIds)
        for skuId in allCandidateIds {
            if let expectedQty = expectedQtyMap[skuId] {
                // Products expected with qty > 0 are boosted; expected with qty = 0 are penalized
                factors[skuId] = expectedQty > 0 ? expectedBoost : 0.80
            } else if !expectedSet.isEmpty {
                // Product not on the sheet — apply penalty if we have a non-empty sheet
                factors[skuId] = unexpectedPenalty
            }
        }
        return factors
    }
}

// MARK: - Sendable Snapshot Types
// These are plain structs that mirror the SwiftData models for safe cross-concurrency use.

/// Sendable snapshot mirroring `ShelfExpectedRow`.
nonisolated struct ShelfExpectedRowSnapshot: Sendable {
    let productName: String
    let brand: String
    let barcode: String
    let expectedQty: Int
    let matchedSkuId: UUID?

    init(from row: ShelfExpectedRow) {
        self.productName = row.productName
        self.brand = row.brand
        self.barcode = row.barcode
        self.expectedQty = row.expectedQty
        self.matchedSkuId = row.matchedSkuId
    }
}

/// Sendable snapshot mirroring `ExpectedRow`.
nonisolated struct ExpectedRowSnapshot: Sendable {
    let skuOrNameKey: String
    let expectedQty: Int
    let matchedSkuId: UUID?

    init(from row: ExpectedRow) {
        self.skuOrNameKey = row.skuOrNameKey
        self.expectedQty = row.expectedQty
        self.matchedSkuId = row.matchedSkuId
    }
}
