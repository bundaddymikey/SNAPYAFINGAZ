import Foundation

// MARK: - Match Result

/// A candidate product match produced by VoiceCatalogMatcher.
struct VoiceMatchResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let sku: ProductSKUSnapshot
    let score: Double        // 0.0 – 1.0 (higher = better)
    let matchedField: String // Which field drove the match (for debug)

    var isHighConfidence: Bool { score >= 0.72 }
}

/// Lightweight sendable copy of ProductSKU — avoids crossing MainActor with SwiftData models.
struct ProductSKUSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let sku: String
    let productName: String
    let brand: String
    let variant: String
    let sizeOrWeight: String?
    let tags: [String]
    let ocrKeywords: [String]

    init(from model: ProductSKU) {
        self.id = model.id
        self.sku = model.sku
        self.productName = model.productName
        self.brand = model.brand
        self.variant = model.variant
        self.sizeOrWeight = model.sizeOrWeight
        self.tags = model.tags
        self.ocrKeywords = model.ocrKeywords
    }
}

// MARK: - VoiceCatalogMatcher

/// Matches a short spoken phrase against the product catalog.
///
/// Scoring strategy:
///  - Exact substring match on productName → 0.90 base
///  - Exact substring match on brand       → 0.70 base
///  - Exact substring match on variant     → bonus +0.15
///  - Exact substring match on size        → bonus +0.10
///  - Tag / ocrKeyword hit                 → bonus +0.12 each
///  - Word-level partial token score (Jaccard over words) → fallback
///  - Results trimmed to top 3, confidence threshold 0.35
enum VoiceCatalogMatcher {

    static let highConfidenceThreshold = 0.72
    static let minimumThreshold = 0.35

    /// Score all active SKUs against the spoken query.
    /// Returns up to 3 candidates sorted by score descending.
    static func match(query: String, against snapshots: [ProductSKUSnapshot]) -> [VoiceMatchResult] {
        let q = query.normalized
        guard !q.isEmpty else { return [] }

        let qTokens = tokens(q)

        var results: [VoiceMatchResult] = []

        for snapshot in snapshots {
            let (score, field) = scoreSnapshot(snapshot, query: q, queryTokens: qTokens)
            if score >= minimumThreshold {
                results.append(VoiceMatchResult(
                    id: UUID(),
                    sku: snapshot,
                    score: score,
                    matchedField: field
                ))
            }
        }

        return results
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - Scoring

    private static func scoreSnapshot(
        _ s: ProductSKUSnapshot,
        query: String,
        queryTokens: Set<String>
    ) -> (Double, String) {
        var score = 0.0
        var topField = "none"

        // --- Exact substring matches ---

        let name = s.productName.normalized
        let brand = s.brand.normalized
        let variant = s.variant.normalized
        let size = s.sizeOrWeight?.normalized ?? ""

        // Full query contained in name (strong signal)
        if name.contains(query) {
            score = max(score, 0.90)
            topField = "productName"
        }

        // Query starts with brand and rest matches name
        if !brand.isEmpty, query.hasPrefix(brand) {
            let remainder = query.dropFirst(brand.count).trimmingCharacters(in: .whitespaces)
            if name.contains(remainder) || remainder.isEmpty {
                score = max(score, 0.88)
                topField = "brand+name"
            }
        }

        // Brand substring alone
        if !brand.isEmpty, brand.contains(query) || query.contains(brand) {
            score = max(score, 0.70)
            topField = topField == "none" ? "brand" : topField
        }

        // Variant bonus
        if !variant.isEmpty, (query.contains(variant) || variant.contains(query)) {
            score += 0.15
            topField = topField == "none" ? "variant" : topField
        }

        // Size bonus
        if !size.isEmpty, query.contains(size) {
            score = max(score, score + 0.10)
        }

        // Tags / ocrKeywords
        for tag in s.tags where !tag.isEmpty {
            if query.contains(tag.normalized) || tag.normalized.contains(query) {
                score += 0.12
                topField = topField == "none" ? "tag" : topField
            }
        }
        for kw in s.ocrKeywords where !kw.isEmpty {
            if query.contains(kw.normalized) {
                score += 0.10
                topField = topField == "none" ? "keyword" : topField
            }
        }

        // --- Token Jaccard fallback (for partial word overlaps) ---
        if score < minimumThreshold {
            let nameTokens = tokens(name)
            let combinedTokens = nameTokens.union(tokens(brand)).union(tokens(variant))
            let j = jaccard(queryTokens, combinedTokens)
            if j > score {
                score = j
                topField = "token-jaccard"
            }
        }

        return (min(score, 1.0), topField)
    }

    // MARK: - Helpers

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.normalized }
            .filter { !$0.isEmpty && !stopWords.contains($0) })
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = Double(a.intersection(b).count)
        let union = Double(a.union(b).count)
        return intersection / union
    }

    // Common words to ignore in matching
    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "with", "and", "or", "pack", "ct", "count",
        "oz", "ml", "g", "kg", "lb", "lbs", "fl"
    ]
}
