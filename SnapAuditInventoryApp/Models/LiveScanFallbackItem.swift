import Foundation
import UIKit

// MARK: - Fallback Reason Flags

/// Reasons a live-scan detection was routed to review instead of auto-counted.
enum LiveFallbackReason: String, Codable, CaseIterable, Sendable {
    case lowConfidence        = "LOW_CONFIDENCE"
    case unstableTracking     = "UNSTABLE_TRACKING"
    case closeMatch           = "CLOSE_MATCH"
    case outsideScope         = "OUTSIDE_SCOPE"
    case duplicateUncertain   = "DUPLICATE_UNCERTAIN"
    case rapidGrowthBlocked   = "RAPID_GROWTH_BLOCKED"
    case ambiguousBBox        = "AMBIGUOUS_BBOX"

    var label: String {
        switch self {
        case .lowConfidence:      "Low Confidence"
        case .unstableTracking:   "Unstable Tracking"
        case .closeMatch:         "Close Match"
        case .outsideScope:       "Outside Scope"
        case .duplicateUncertain: "Duplicate Uncertain"
        case .rapidGrowthBlocked: "Rapid Growth Blocked"
        case .ambiguousBBox:      "Ambiguous Region"
        }
    }

    var icon: String {
        switch self {
        case .lowConfidence:      "exclamationmark.triangle.fill"
        case .unstableTracking:   "arrow.triangle.2.circlepath"
        case .closeMatch:         "equal.circle.fill"
        case .outsideScope:       "building.2.slash.fill"
        case .duplicateUncertain: "square.on.square.dashed"
        case .rapidGrowthBlocked: "chart.line.uptrend.xyaxis"
        case .ambiguousBBox:      "viewfinder.trianglebadge.exclamationmark"
        }
    }
}

// MARK: - Product Candidate

/// A recognition candidate from the live-scan engine.
struct LiveProductCandidate: Identifiable, Sendable {
    let id = UUID()
    let skuId: UUID
    let skuName: String
    let confidence: Float
}

// MARK: - Live Scan Fallback Item

/// An uncertain live-scan detection that requires operator review before being counted.
@Observable
final class LiveScanFallbackItem: Identifiable, @unchecked Sendable {

    let id: UUID
    let auditSessionId: UUID
    var candidates: [LiveProductCandidate]   // Ranked by confidence (highest first)
    var bestCropImage: UIImage?
    var bestFrameTimestamp: Date
    var confidenceScore: Float               // Top candidate score
    var reasonFlags: [LiveFallbackReason]
    let sourceType: ScanSourceType
    let createdAt: Date

    /// How many raw detections have been merged into this item (for dedup display).
    var mergeCount: Int

    /// The top candidate's skuId for quick access.
    var suggestedSkuId: UUID? { candidates.first?.skuId }
    var suggestedSkuName: String? { candidates.first?.skuName }

    init(
        auditSessionId: UUID,
        candidates: [LiveProductCandidate],
        cropImage: UIImage?,
        timestamp: Date,
        reasonFlags: [LiveFallbackReason]
    ) {
        self.id = UUID()
        self.auditSessionId = auditSessionId
        self.candidates = candidates
        self.bestCropImage = cropImage
        self.bestFrameTimestamp = timestamp
        self.confidenceScore = candidates.first?.confidence ?? 0
        self.reasonFlags = reasonFlags
        self.sourceType = .liveCamera
        self.createdAt = Date()
        self.mergeCount = 1
    }

    /// Merge a newer detection into this item if it has higher confidence.
    func merge(_ other: LiveScanFallbackItem) {
        mergeCount += 1
        if other.confidenceScore > confidenceScore {
            candidates = other.candidates
            bestCropImage = other.bestCropImage
            bestFrameTimestamp = other.bestFrameTimestamp
            confidenceScore = other.confidenceScore
        }
    }
}
