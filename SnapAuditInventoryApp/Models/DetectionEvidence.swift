import Foundation
import SwiftData

nonisolated struct DetectedCandidate: Codable, Sendable {
    let skuId: UUID
    let skuName: String
    let score: Float
}

nonisolated struct DetectionEvidenceMetadata: Codable, Sendable, Equatable {
    let hotspotScores: [FocusHotspotScore]
    let ocrResults: [OCRZoneResult]
    let bestHotspotName: String?
    let bestHotspotCropURL: String?

    static let empty = DetectionEvidenceMetadata(
        hotspotScores: [],
        ocrResults: [],
        bestHotspotName: nil,
        bestHotspotCropURL: nil
    )
}

nonisolated struct BoundingBox: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }

    func iou(with other: BoundingBox) -> Double {
        let x1 = max(x, other.x)
        let y1 = max(y, other.y)
        let x2 = min(x + width, other.x + other.width)
        let y2 = min(y + height, other.y + other.height)
        let interW = max(0.0, x2 - x1)
        let interH = max(0.0, y2 - y1)
        let intersection = interW * interH
        guard intersection > 0 else { return 0 }
        let union = width * height + other.width * other.height - intersection
        return union > 0 ? intersection / union : 0
    }

    var positionBucket: String {
        let col = min(Int(centerX * 3), 2)
        let row = min(Int(centerY * 3), 2)
        return "\(col)-\(row)"
    }

    var touchesEdge: Bool {
        x < 0.02 || y < 0.02 || (x + width) > 0.98 || (y + height) > 0.98
    }

    var area: Double { width * height }

    func encoded() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

@Model
class DetectionEvidence {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var lineItem: AuditLineItem?
    var cropURL: String
    var frameSourceId: UUID
    var bboxJSON: String
    var top3CandidatesJSON: String
    var chosenSkuId: UUID?
    var chosenSkuName: String
    var finalScore: Double
    var reasonsJSON: String
    var reviewStatus: ReviewStatus
    var isSoftAssigned: Bool
    var metadataJSON: String
    var createdAt: Date

    init(
        sessionId: UUID,
        cropURL: String,
        frameSourceId: UUID,
        bbox: BoundingBox,
        top3Candidates: [DetectedCandidate],
        chosenSkuId: UUID?,
        chosenSkuName: String,
        finalScore: Double,
        reasons: [FlagReason],
        reviewStatus: ReviewStatus = .pending,
        isSoftAssigned: Bool = false
    ) {
        self.id = UUID()
        self.sessionId = sessionId
        self.cropURL = cropURL
        self.frameSourceId = frameSourceId
        self.bboxJSON = bbox.encoded()
        let cData = (try? JSONEncoder().encode(top3Candidates)) ?? Data()
        self.top3CandidatesJSON = String(data: cData, encoding: .utf8) ?? "[]"
        self.chosenSkuId = chosenSkuId
        self.chosenSkuName = chosenSkuName
        self.finalScore = finalScore
        let rData = (try? JSONEncoder().encode(reasons)) ?? Data()
        self.reasonsJSON = String(data: rData, encoding: .utf8) ?? "[]"
        self.reviewStatus = reviewStatus
        self.isSoftAssigned = isSoftAssigned
        self.metadataJSON = ""
        self.createdAt = Date()
    }

    var bbox: BoundingBox? {
        guard let data = bboxJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BoundingBox.self, from: data)
    }

    var top3Candidates: [DetectedCandidate] {
        guard let data = top3CandidatesJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DetectedCandidate].self, from: data)) ?? []
    }

    var flagReasons: [FlagReason] {
        guard let data = reasonsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([FlagReason].self, from: data)) ?? []
    }

    var metadata: DetectionEvidenceMetadata {
        guard !metadataJSON.isEmpty, let data = metadataJSON.data(using: .utf8) else { return .empty }
        if let decoded = try? JSONDecoder().decode(DetectionEvidenceMetadata.self, from: data) {
            return decoded
        }
        if let legacyOCR = try? JSONDecoder().decode([OCRZoneResult].self, from: data) {
            return DetectionEvidenceMetadata(
                hotspotScores: [],
                ocrResults: legacyOCR,
                bestHotspotName: nil,
                bestHotspotCropURL: nil
            )
        }
        return .empty
    }

    var ocrResults: [OCRZoneResult] {
        metadata.ocrResults
    }

    var hotspotScores: [FocusHotspotScore] {
        metadata.hotspotScores
    }

    var bestHotspotName: String? {
        metadata.bestHotspotName
    }

    var bestHotspotCropURL: String? {
        metadata.bestHotspotCropURL
    }

    var detectedOCRText: String {
        let parts = ocrResults.compactMap { result -> String? in
            result.rawText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : result.rawText
        }
        return parts.joined(separator: " · ")
    }
}
