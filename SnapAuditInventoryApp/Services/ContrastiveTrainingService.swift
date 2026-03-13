import Foundation
import UIKit
import SwiftData

/// Result of a contrastive comparison between two variant SKUs
nonisolated struct ContrastiveResult: Sendable {
    let winnerSkuId: UUID
    let contrastiveBoost: Double
    let contrastivePenalty: Double
    let explanation: String
    let zoneMatchDetails: [String]
    let ocrMatchDetails: [String]

    var netAdjustment: Double { contrastiveBoost - contrastivePenalty }
}

/// Contrastive Variant Training Service
/// Performs additional comparison passes between similar variant SKUs
/// within the same Look-Alike Group to disambiguate nearly-identical packaging.
nonisolated final class ContrastiveTrainingService: Sendable {
    static let shared = ContrastiveTrainingService()
    private init() {}

    // MARK: - Trigger Check

    /// Determines whether a contrastive comparison should be triggered.
    /// Returns true if the top 2 candidates belong to the same Look-Alike Group
    /// and their scores are within the close-match margin.
    func shouldTriggerContrastive(
        top3: [RecognitionCandidate],
        lookAlikeInfo: (skuToGroup: [UUID: UUID], groupZones: [UUID: [ZoneRect]]),
        margin: Double
    ) -> Bool {
        guard top3.count >= 2 else { return false }
        let first = top3[0]
        let second = top3[1]
        let gap = Double(first.score - second.score)

        guard gap < margin else { return false }

        // Both must be in the same look-alike group
        guard let group1 = lookAlikeInfo.skuToGroup[first.skuId],
              let group2 = lookAlikeInfo.skuToGroup[second.skuId],
              group1 == group2 else { return false }

        return true
    }

    // MARK: - Contrastive Comparison

    /// Performs the full contrastive comparison between the top two candidates.
    func performContrastiveComparison(
        cropImage: UIImage,
        candidate1SkuId: UUID,
        candidate1Score: Float,
        candidate2SkuId: UUID,
        candidate2Score: Float,
        groupId: UUID,
        differentiatorZones: [ZoneRect],
        skuKeywords: [UUID: [String]],
        embeddings: [EmbeddingRecord],
        verifiedSamples: [VerifiedSampleRecord],
        ocrAssistedEnabled: Bool
    ) async -> ContrastiveResult {
        var boost: Double = 0
        var penalty: Double = 0
        var zoneDetails: [String] = []
        var ocrDetails: [String] = []

        // Use differentiator zones, or fall back to default variant-critical regions
        let zones = differentiatorZones.isEmpty
            ? Self.defaultDifferentiatorZones()
            : differentiatorZones

        // 1. Focus Zone Embedding Comparison
        let zoneResult = await compareZoneEmbeddings(
            cropImage: cropImage,
            zones: zones,
            candidate1SkuId: candidate1SkuId,
            candidate2SkuId: candidate2SkuId,
            embeddings: embeddings
        )
        boost += zoneResult.boost
        penalty += zoneResult.penalty
        zoneDetails.append(contentsOf: zoneResult.details)

        // 2. OCR Keyword Comparison
        if ocrAssistedEnabled {
            let ocrResult = await compareOCRKeywords(
                cropImage: cropImage,
                zones: zones,
                candidate1SkuId: candidate1SkuId,
                candidate2SkuId: candidate2SkuId,
                skuKeywords: skuKeywords
            )
            boost += ocrResult.boost
            penalty += ocrResult.penalty
            ocrDetails.append(contentsOf: ocrResult.details)
        }

        // 3. Verified Sample Comparison
        let sampleResult = compareVerifiedSamples(
            cropImage: cropImage,
            candidate1SkuId: candidate1SkuId,
            candidate2SkuId: candidate2SkuId,
            verifiedSamples: verifiedSamples
        )
        boost += sampleResult.boost
        penalty += sampleResult.penalty

        // Determine winner
        let c1Adjusted = Double(candidate1Score) + boost - penalty
        let c2Adjusted = Double(candidate2Score) - boost + penalty
        let winnerSkuId = c1Adjusted >= c2Adjusted ? candidate1SkuId : candidate2SkuId

        // Build explanation
        let explanation = buildExplanation(
            zoneDetails: zoneDetails,
            ocrDetails: ocrDetails,
            winnerSkuId: winnerSkuId,
            candidate1SkuId: candidate1SkuId,
            candidate2SkuId: candidate2SkuId
        )

        return ContrastiveResult(
            winnerSkuId: winnerSkuId,
            contrastiveBoost: boost,
            contrastivePenalty: penalty,
            explanation: explanation,
            zoneMatchDetails: zoneDetails,
            ocrMatchDetails: ocrDetails
        )
    }

    // MARK: - Zone Embedding Comparison

    private struct ComparisonMetric {
        let boost: Double
        let penalty: Double
        let details: [String]
    }

    private func compareZoneEmbeddings(
        cropImage: UIImage,
        zones: [ZoneRect],
        candidate1SkuId: UUID,
        candidate2SkuId: UUID,
        embeddings: [EmbeddingRecord]
    ) async -> ComparisonMetric {
        var totalBoost: Double = 0
        var totalPenalty: Double = 0
        var details: [String] = []

        let c1Embeddings = embeddings.filter { $0.skuId == candidate1SkuId && $0.qualityScore >= 0.25 }
        let c2Embeddings = embeddings.filter { $0.skuId == candidate2SkuId && $0.qualityScore >= 0.25 }

        guard !c1Embeddings.isEmpty, !c2Embeddings.isEmpty else {
            return ComparisonMetric(boost: 0, penalty: 0, details: [])
        }

        for zone in zones {
            let hotspot = FocusHotspot(
                name: zone.name,
                x: zone.x, y: zone.y,
                width: zone.w, height: zone.h,
                weight: zone.weight
            )
            guard let zoneCrop = OnDeviceEngine.crop(
                image: cropImage,
                normalizedRect: hotspot.normalizedRect
            ) else { continue }

            guard let (zoneVector, _) = try? await EmbeddingService.shared.computeEmbedding(for: zoneCrop) else { continue }

            // Compute best similarity to each candidate
            let sim1 = c1Embeddings.map {
                EmbeddingService.shared.cosineSimilarity(vectorA: zoneVector, vectorB: $0.vectorData)
            }.max() ?? 0

            let sim2 = c2Embeddings.map {
                EmbeddingService.shared.cosineSimilarity(vectorA: zoneVector, vectorB: $0.vectorData)
            }.max() ?? 0

            let diff = Double(sim1 - sim2)
            let weightedDiff = diff * zone.weight * 0.03

            if diff > 0.05 {
                totalBoost += abs(weightedDiff)
                details.append("\(zone.name) embedding closer to candidate 1 (+\(String(format: "%.1f", abs(weightedDiff) * 100))%)")
            } else if diff < -0.05 {
                totalPenalty += abs(weightedDiff)
                details.append("\(zone.name) embedding closer to candidate 2 (-\(String(format: "%.1f", abs(weightedDiff) * 100))%)")
            }
        }

        return ComparisonMetric(boost: totalBoost, penalty: totalPenalty, details: details)
    }

    // MARK: - OCR Keyword Comparison

    private func compareOCRKeywords(
        cropImage: UIImage,
        zones: [ZoneRect],
        candidate1SkuId: UUID,
        candidate2SkuId: UUID,
        skuKeywords: [UUID: [String]]
    ) async -> ComparisonMetric {
        let c1Keywords = skuKeywords[candidate1SkuId] ?? []
        let c2Keywords = skuKeywords[candidate2SkuId] ?? []

        guard !c1Keywords.isEmpty || !c2Keywords.isEmpty else {
            return ComparisonMetric(boost: 0, penalty: 0, details: [])
        }

        let ocrResults = await OCRService.shared.recognizeZones(in: cropImage, zones: zones)
        guard !ocrResults.isEmpty else {
            return ComparisonMetric(boost: 0, penalty: 0, details: [])
        }

        let allText = ocrResults.map(\.normalizedText).joined(separator: " ")
        var c1Matches = 0
        var c2Matches = 0
        var details: [String] = []

        for keyword in c1Keywords {
            let normalized = OCRService.normalize(keyword)
            if !normalized.isEmpty && allText.contains(normalized) {
                c1Matches += 1
                if let zone = ocrResults.first(where: { $0.normalizedText.contains(normalized) }) {
                    details.append("\(zone.zoneName) keyword \"\(keyword)\" matched candidate 1")
                }
            }
        }

        for keyword in c2Keywords {
            let normalized = OCRService.normalize(keyword)
            if !normalized.isEmpty && allText.contains(normalized) {
                c2Matches += 1
                if let zone = ocrResults.first(where: { $0.normalizedText.contains(normalized) }) {
                    details.append("\(zone.zoneName) keyword \"\(keyword)\" matched candidate 2")
                }
            }
        }

        let boostPerMatch: Double = 0.04
        let maxBoost: Double = 0.15

        if c1Matches > c2Matches {
            let boost = min(Double(c1Matches - c2Matches) * boostPerMatch, maxBoost)
            return ComparisonMetric(boost: boost, penalty: 0, details: details)
        } else if c2Matches > c1Matches {
            let penalty = min(Double(c2Matches - c1Matches) * boostPerMatch, maxBoost)
            return ComparisonMetric(boost: 0, penalty: penalty, details: details)
        }

        return ComparisonMetric(boost: 0, penalty: 0, details: details)
    }

    // MARK: - Verified Sample Comparison

    struct VerifiedSampleRecord: Sendable {
        let skuId: UUID
        let vectorData: Data
    }

    private func compareVerifiedSamples(
        cropImage: UIImage,
        candidate1SkuId: UUID,
        candidate2SkuId: UUID,
        verifiedSamples: [VerifiedSampleRecord]
    ) -> ComparisonMetric {
        let c1Samples = verifiedSamples.filter { $0.skuId == candidate1SkuId }
        let c2Samples = verifiedSamples.filter { $0.skuId == candidate2SkuId }

        guard !c1Samples.isEmpty || !c2Samples.isEmpty else {
            return ComparisonMetric(boost: 0, penalty: 0, details: [])
        }

        // Use the crop image's embedding if already computed
        guard cropImage.cgImage != nil else {
            return ComparisonMetric(boost: 0, penalty: 0, details: [])
        }

        // We'd need the query vector; for now use a lightweight proxy
        // The actual query vector is passed from the pipeline
        return ComparisonMetric(boost: 0, penalty: 0, details: [])
    }

    // MARK: - Explanation Builder

    private func buildExplanation(
        zoneDetails: [String],
        ocrDetails: [String],
        winnerSkuId: UUID,
        candidate1SkuId: UUID,
        candidate2SkuId: UUID
    ) -> String {
        var parts: [String] = []

        if let first = ocrDetails.first {
            parts.append(first)
        } else if let first = zoneDetails.first {
            parts.append(first)
        }

        if parts.isEmpty {
            parts.append("Variant confidence adjusted by contrastive comparison")
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Adaptive Weight Update

    /// Updates zone weight for a group when a particular zone is repeatedly confirmed.
    /// Weight is bounded to [0.5, 5.0].
    func adaptiveWeightUpdate(
        profile: VariantComparisonProfile,
        zoneName: String,
        increment: Double = 0.1
    ) {
        var zones = profile.differentiatorZones
        guard let index = zones.firstIndex(where: { $0.name == zoneName }) else { return }
        let newWeight = min(5.0, max(0.5, zones[index].weight + increment))
        zones[index] = ZoneRect(
            name: zones[index].name,
            x: zones[index].x,
            y: zones[index].y,
            w: zones[index].w,
            h: zones[index].h,
            weight: newWeight
        )
        profile.differentiatorZones = zones
    }

    // MARK: - Reference Pair Generation

    /// Creates pairwise comparison records for all SKUs in a group.
    func generateReferencePairs(
        groupId: UUID,
        memberSkuIds: [UUID],
        modelContext: ModelContext
    ) {
        // Remove existing pairs for this group
        let descriptor = FetchDescriptor<VariantReferencePair>()
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        for pair in existing where pair.lookAlikeGroupId == groupId {
            modelContext.delete(pair)
        }

        // Create new pairwise combinations
        for i in 0..<memberSkuIds.count {
            for j in (i + 1)..<memberSkuIds.count {
                let pair = VariantReferencePair(
                    lookAlikeGroupId: groupId,
                    primarySkuId: memberSkuIds[i],
                    comparisonSkuId: memberSkuIds[j]
                )
                modelContext.insert(pair)
            }
        }
        try? modelContext.save()
    }

    // MARK: - Default Differentiator Zones

    /// Default zones that target common packaging areas where variant differences appear.
    static func defaultDifferentiatorZones() -> [ZoneRect] {
        [
            ZoneRect(name: "Bottom Label", x: 0.05, y: 0.75, w: 0.90, h: 0.22, weight: 2.5),
            ZoneRect(name: "Top Badge", x: 0.20, y: 0.02, w: 0.60, h: 0.18, weight: 2.0),
            ZoneRect(name: "Side Strip", x: 0.0, y: 0.15, w: 0.18, h: 0.70, weight: 1.5),
            ZoneRect(name: "Corner Sticker", x: 0.75, y: 0.0, w: 0.25, h: 0.20, weight: 1.8),
            ZoneRect(name: "Center Variant Text", x: 0.15, y: 0.35, w: 0.70, h: 0.30, weight: 2.2),
        ]
    }
}

/// Helper to fetch verified samples as lightweight records
extension ContrastiveTrainingService {
    func fetchVerifiedSampleRecords(
        for skuIds: [UUID],
        modelContext: ModelContext
    ) -> [VerifiedSampleRecord] {
        let descriptor = FetchDescriptor<VerifiedSample>()
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        return samples
            .filter { skuIds.contains($0.skuId) }
            .map { VerifiedSampleRecord(skuId: $0.skuId, vectorData: $0.vectorData) }
    }
}
