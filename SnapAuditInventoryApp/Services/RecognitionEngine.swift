import Foundation
import Vision
import UIKit

nonisolated struct RecognitionCandidate: Identifiable, Sendable {
    let id: UUID
    let skuId: UUID
    let score: Float
    let nearestReferenceURL: String?
}

nonisolated struct EmbeddingRecord: Sendable {
    let embeddingId: UUID
    let skuId: UUID
    let vectorData: Data
    let qualityScore: Double
    let sourceMediaURL: String
    let viewAngle: ReferenceViewAngle
    let isHighPriority: Bool
}

nonisolated struct FocusHotspot: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let weight: Double

    init(name: String, x: Double, y: Double, width: Double, height: Double, weight: Double) {
        self.id = UUID()
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.weight = weight
    }

    var normalizedRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated struct FocusHotspotScore: Identifiable, Codable, Sendable, Equatable {
    let hotspot: FocusHotspot
    let matchedSkuId: UUID?
    let score: Float
    let ocrText: String

    var id: UUID { hotspot.id }
}

nonisolated struct FocusClassificationResult: Sendable {
    let candidates: [RecognitionCandidate]
    let hotspots: [FocusHotspotScore]
    let bestHotspot: FocusHotspot?
}

protocol RecognitionEngine: Sendable {
    func classify(
        image: UIImage,
        candidateSkuIds: [UUID],
        embeddings: [EmbeddingRecord]
    ) async throws -> [RecognitionCandidate]
}

nonisolated final class OnDeviceEngine: RecognitionEngine, Sendable {
    static let shared = OnDeviceEngine()
    private init() {}

    func classify(
        image: UIImage,
        candidateSkuIds: [UUID],
        embeddings: [EmbeddingRecord]
    ) async throws -> [RecognitionCandidate] {
        let (queryVector, _) = try await EmbeddingService.shared.computeEmbedding(for: image)
        return classify(
            queryVector: queryVector,
            candidateSkuIds: candidateSkuIds,
            embeddings: embeddings
        )
    }

    func classifyWithFocusZones(
        image: UIImage,
        candidateSkuIds: [UUID],
        embeddings: [EmbeddingRecord],
        hotspots: [FocusHotspot],
        precomputedQueryVector: Data? = nil
    ) async throws -> FocusClassificationResult {
        let fullCropCandidates: [RecognitionCandidate]
        if let precomputedQueryVector {
            fullCropCandidates = classify(
                queryVector: precomputedQueryVector,
                candidateSkuIds: candidateSkuIds,
                embeddings: embeddings
            )
        } else {
            fullCropCandidates = try await classify(
                image: image,
                candidateSkuIds: candidateSkuIds,
                embeddings: embeddings
            )
        }
        guard !hotspots.isEmpty else {
            return FocusClassificationResult(candidates: fullCropCandidates, hotspots: [], bestHotspot: nil)
        }

        var fusedScores: [UUID: Float] = [:]
        var candidateRefs: [UUID: RecognitionCandidate] = [:]
        for candidate in fullCropCandidates {
            fusedScores[candidate.skuId] = candidate.score
            candidateRefs[candidate.skuId] = candidate
        }

        var hotspotResults: [FocusHotspotScore] = []
        var totalWeight: Float = 1.0

        for hotspot in hotspots {
            guard let cropImage = Self.crop(image: image, normalizedRect: hotspot.normalizedRect) else { continue }
            let cropCandidates = try await classify(
                image: cropImage,
                candidateSkuIds: candidateSkuIds,
                embeddings: embeddings
            )
            totalWeight += Float(hotspot.weight)

            for candidate in cropCandidates {
                fusedScores[candidate.skuId, default: 0] += candidate.score * Float(hotspot.weight)
                if candidateRefs[candidate.skuId] == nil {
                    candidateRefs[candidate.skuId] = candidate
                }
            }

            let bestCropCandidate = cropCandidates.first
            hotspotResults.append(
                FocusHotspotScore(
                    hotspot: hotspot,
                    matchedSkuId: bestCropCandidate?.skuId,
                    score: bestCropCandidate?.score ?? 0,
                    ocrText: ""
                )
            )
        }

        let normalizedCandidates = fusedScores.compactMap { skuId, score -> RecognitionCandidate? in
            guard let base = candidateRefs[skuId] else { return nil }
            return RecognitionCandidate(
                id: base.id,
                skuId: skuId,
                score: min(1.0, score / max(totalWeight, 1.0)),
                nearestReferenceURL: base.nearestReferenceURL
            )
        }
        .sorted { $0.score > $1.score }

        let bestSkuId = normalizedCandidates.first?.skuId
        let bestMatchingHotspot = hotspotResults
            .filter { $0.matchedSkuId == bestSkuId }
            .max { lhs, rhs in lhs.score < rhs.score }
        let bestHotspot = bestMatchingHotspot?.hotspot

        return FocusClassificationResult(
            candidates: Array(normalizedCandidates.prefix(3)),
            hotspots: hotspotResults,
            bestHotspot: bestHotspot
        )
    }

    // MARK: - Core classification with top-K weighted pooling
    //
    // Rather than taking a single best-matching embedding per SKU, this function:
    //   1. Computes cosine similarity against every qualifying embedding.
    //   2. Groups by SKU, keeping up to the top-K matches (default 5).
    //   3. Computes a weighted-average score using each embedding's
    //      angle.recognitionWeight × qualityScore as the weight.
    //   4. Applies a small diversity bonus (+2%) if the top-K set covers
    //      at least 3 distinct angles — rewarding wide training coverage.
    //
    // This means:
    //   • Every additional high-quality training image contributes to the score.
    //   • Products with coverage across front, label, barcode, etc. score higher.
    //   • A single great match is still respected, but many good matches beat it.

    private func classify(
        queryVector: Data,
        candidateSkuIds: [UUID],
        embeddings: [EmbeddingRecord],
        topK: Int = 5
    ) -> [RecognitionCandidate] {
        let candidateSet = Set(candidateSkuIds)
        let relevant = embeddings.filter {
            candidateSet.contains($0.skuId) && $0.qualityScore >= 0.25
        }
        guard !relevant.isEmpty else { return [] }

        // Step 1: Score every embedding
        struct ScoredRecord {
            let record: EmbeddingRecord
            let similarity: Float
            var weightedScore: Float {
                Float(record.viewAngle.recognitionWeight * record.qualityScore) * similarity
            }
        }
        var scoredBySkuId: [UUID: [ScoredRecord]] = [:]
        for record in relevant {
            let sim = EmbeddingService.shared.cosineSimilarity(
                vectorA: queryVector,
                vectorB: record.vectorData
            )
            let sr = ScoredRecord(record: record, similarity: sim)
            scoredBySkuId[record.skuId, default: []].append(sr)
        }

        // Step 2: Per-SKU top-K weighted average
        var candidates: [RecognitionCandidate] = []
        var bestRef: [UUID: String] = [:]

        for (skuId, scored) in scoredBySkuId {
            // Sort by weighted score descending, then pick top-K
            let topKRecords = scored
                .sorted { $0.weightedScore > $1.weightedScore }
                .prefix(topK)

            guard !topKRecords.isEmpty else { continue }

            // Weighted average: Σ(weightedScore) / Σ(weight)
            let totalWeight = topKRecords.reduce(0.0) { $0 + Float($1.record.viewAngle.recognitionWeight * $1.record.qualityScore) }
            let weightedSum = topKRecords.reduce(0.0) { $0 + $1.weightedScore }
            var pooledScore: Float = totalWeight > 0 ? weightedSum / totalWeight : topKRecords[0].similarity

            // Diversity bonus: if top-K contains ≥3 distinct angles, +2%
            let distinctAngles = Set(topKRecords.map { $0.record.viewAngle })
            if distinctAngles.count >= 3 {
                pooledScore = min(1.0, pooledScore * 1.02)
            }

            let best = topKRecords.first!
            bestRef[skuId] = best.record.sourceMediaURL
            candidates.append(
                RecognitionCandidate(
                    id: best.record.embeddingId,
                    skuId: skuId,
                    score: pooledScore,
                    nearestReferenceURL: best.record.sourceMediaURL
                )
            )
        }

        candidates.sort { $0.score > $1.score }
        let top3 = Array(candidates.prefix(3))

        guard let maxScore = top3.first?.score, maxScore > 0 else { return top3 }
        // Normalize relative to the best candidate so scores are comparable
        return top3.map {
            RecognitionCandidate(
                id: $0.id,
                skuId: $0.skuId,
                score: $0.score / maxScore,
                nearestReferenceURL: $0.nearestReferenceURL
            )
        }
    }


    static func defaultFocusHotspots() -> [FocusHotspot] {
        [
            FocusHotspot(name: "Top Band", x: 0.08, y: 0.02, width: 0.84, height: 0.18, weight: 1.5),
            FocusHotspot(name: "Bottom Band", x: 0.08, y: 0.78, width: 0.84, height: 0.18, weight: 1.8),
            FocusHotspot(name: "Left Strip", x: 0.0, y: 0.12, width: 0.22, height: 0.76, weight: 1.3),
            FocusHotspot(name: "Right Strip", x: 0.78, y: 0.12, width: 0.22, height: 0.76, weight: 1.3),
            FocusHotspot(name: "Center Badge", x: 0.28, y: 0.30, width: 0.44, height: 0.28, weight: 1.7),
            FocusHotspot(name: "Top Left Badge", x: 0.02, y: 0.02, width: 0.24, height: 0.22, weight: 1.6),
            FocusHotspot(name: "Top Right Badge", x: 0.74, y: 0.02, width: 0.24, height: 0.22, weight: 1.6),
            FocusHotspot(name: "Bottom Left Badge", x: 0.02, y: 0.74, width: 0.24, height: 0.22, weight: 1.6),
            FocusHotspot(name: "Bottom Right Badge", x: 0.74, y: 0.74, width: 0.24, height: 0.22, weight: 1.6)
        ]
    }

    static func hotspots(from zones: [ZoneRect]) -> [FocusHotspot] {
        zones.map {
            FocusHotspot(
                name: $0.name,
                x: $0.x,
                y: $0.y,
                width: $0.w,
                height: $0.h,
                weight: $0.weight
            )
        }
    }

    static func crop(image: UIImage, normalizedRect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let rect = CGRect(
            x: max(0, normalizedRect.origin.x) * pixelWidth,
            y: max(0, normalizedRect.origin.y) * pixelHeight,
            width: min(normalizedRect.size.width * pixelWidth, pixelWidth),
            height: min(normalizedRect.size.height * pixelHeight, pixelHeight)
        ).intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)).integral
        guard rect.width > 8, rect.height > 8, let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
