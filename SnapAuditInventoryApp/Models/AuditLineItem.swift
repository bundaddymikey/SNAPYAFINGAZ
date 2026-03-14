import Foundation
import SwiftData

nonisolated enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case confirmed
    case rejected

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .confirmed: "Confirmed"
        case .rejected: "Rejected"
        }
    }

    var icon: String {
        switch self {
        case .pending: "clock.fill"
        case .confirmed: "checkmark.circle.fill"
        case .rejected: "xmark.circle.fill"
        }
    }
}

nonisolated enum FlagReason: String, Codable, CaseIterable, Sendable {
    case lowLight = "LOW_LIGHT"
    case blur = "BLUR"
    case glare = "GLARE"
    case partial = "PARTIAL"
    case closeMatch = "CLOSE_MATCH"
    case weakMatch = "WEAK_MATCH"
    case expectedZeroButFound = "EXPECTED_ZERO_BUT_FOUND"
    case shortage = "SHORTAGE"
    case overage = "OVERAGE"
    case largeVariance = "LARGE_VARIANCE"
    case lookAlikeGroup = "LOOK_ALIKE_GROUP"
    case outsideSelectedBrand = "OUTSIDE_SELECTED_BRAND"
    /// Detected product is not listed on the expected sheet at all.
    case unexpectedItem = "UNEXPECTED_ITEM"
    /// Count exceeds expected quantity by a suspicious amount — possible duplicate scan.
    case suspiciousOvercount = "SUSPICIOUS_OVERCOUNT"

    var label: String {
        switch self {
        case .lowLight: "Low Light"
        case .blur: "Blur"
        case .glare: "Glare"
        case .partial: "Partial View"
        case .closeMatch: "Close Match"
        case .weakMatch: "Weak Match"
        case .expectedZeroButFound: "Unexpected"
        case .shortage: "Shortage"
        case .overage: "Overage"
        case .largeVariance: "Large Variance"
        case .lookAlikeGroup: "Look-Alike"
        case .outsideSelectedBrand: "Possible Straggler"
        case .unexpectedItem: "Not on Sheet"
        case .suspiciousOvercount: "Suspicious Count"
        }
    }

    var icon: String {
        switch self {
        case .lowLight: "moon.fill"
        case .blur: "drop.fill"
        case .glare: "sun.max.fill"
        case .partial: "rectangle.on.rectangle.angled"
        case .closeMatch: "equal.circle.fill"
        case .weakMatch: "questionmark.circle.fill"
        case .expectedZeroButFound: "exclamationmark.triangle.fill"
        case .shortage: "arrow.down.circle.fill"
        case .overage: "arrow.up.circle.fill"
        case .largeVariance: "chart.line.uptrend.xyaxis"
        case .lookAlikeGroup: "square.on.square.dashed"
        case .outsideSelectedBrand: "building.2.slash.fill"
        case .unexpectedItem: "questionmark.square.dashed"
        case .suspiciousOvercount: "exclamationmark.2"
        }
    }

    var color: Color {
        switch self {
        case .lowLight: .orange
        case .blur: .blue
        case .glare: .yellow
        case .partial: .purple
        case .closeMatch: .orange
        case .weakMatch: .red
        case .expectedZeroButFound: .red
        case .shortage: .red
        case .overage: .orange
        case .largeVariance: .purple
        case .lookAlikeGroup: .cyan
        case .outsideSelectedBrand: .teal
        case .unexpectedItem: .indigo
        case .suspiciousOvercount: .orange
        }
    }

    var isMismatch: Bool {
        switch self {
        case .expectedZeroButFound, .shortage, .overage, .largeVariance,
             .unexpectedItem, .suspiciousOvercount: true
        default: false
        }
    }
}

@Model
class AuditLineItem {
    @Attribute(.unique) var id: UUID
    var session: AuditSession?
    var sessionId: UUID
    var skuId: UUID?
    var skuNameSnapshot: String
    var visionCount: Int
    var countConfidence: Double
    var flagReasonsJSON: String
    var inferredFromPrior: Bool
    var isSoftAssigned: Bool
    var reviewStatus: ReviewStatus
    var posOnHand: Int?
    var expectedQty: Int?
    var delta: Int?
    var deltaPercent: Double?
    var deltaOnHand: Int?
    var deltaOnHandPercent: Double?
    var reviewedByUserId: UUID?
    var notes: String
    var createdAt: Date
    var shelfZoneName: String

    @Relationship(deleteRule: .cascade) var evidence: [DetectionEvidence] = []

    init(
        session: AuditSession,
        skuId: UUID?,
        skuNameSnapshot: String,
        visionCount: Int = 0,
        countConfidence: Double = 0,
        flagReasonsJSON: String = "[]",
        inferredFromPrior: Bool = false,
        isSoftAssigned: Bool = false,
        reviewStatus: ReviewStatus = .pending
    ) {
        self.id = UUID()
        self.session = session
        self.sessionId = session.id
        self.skuId = skuId
        self.skuNameSnapshot = skuNameSnapshot
        self.visionCount = visionCount
        self.countConfidence = countConfidence
        self.flagReasonsJSON = flagReasonsJSON
        self.inferredFromPrior = inferredFromPrior
        self.isSoftAssigned = isSoftAssigned
        self.reviewStatus = reviewStatus
        self.notes = ""
        self.createdAt = Date()
        self.shelfZoneName = ""
    }

    var flagReasons: [FlagReason] {
        get {
            guard let data = flagReasonsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([FlagReason].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            flagReasonsJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    var pendingEvidenceCount: Int {
        evidence.filter { $0.reviewStatus == .pending }.count
    }

    var confirmedEvidenceCount: Int {
        evidence.filter { $0.reviewStatus == .confirmed }.count
    }

    var confidenceTier: ConfidenceTier {
        ConfidenceTier(confidence: countConfidence)
    }

    var hasMismatch: Bool {
        flagReasons.contains { $0.isMismatch }
    }

    var mismatchFlags: [FlagReason] {
        flagReasons.filter { $0.isMismatch }
    }
}

nonisolated enum ConfidenceTier: Sendable {
    case autoAccept
    case needsReview
    case manual
    case none

    init(confidence: Double) {
        let autoAcceptSetting: Double = UserDefaults.standard.double(forKey: "autoAcceptConfidence")
        let reviewMinSetting: Double = UserDefaults.standard.double(forKey: "reviewBandMin")
        let autoAccept: Double = autoAcceptSetting > 0 ? autoAcceptSetting : 0.85
        let reviewMin: Double = reviewMinSetting > 0 ? reviewMinSetting : 0.60
        if confidence >= autoAccept {
            self = .autoAccept
        } else if confidence >= reviewMin {
            self = .needsReview
        } else if confidence > 0 {
            self = .manual
        } else {
            self = .none
        }
    }

    var label: String {
        switch self {
        case .autoAccept: "High"
        case .needsReview: "Medium"
        case .manual: "Low"
        case .none: "—"
        }
    }

    var color: Color {
        switch self {
        case .autoAccept: .green
        case .needsReview: .orange
        case .manual: .red
        case .none: .secondary
        }
    }
}

import SwiftUI

extension Array where Element == FlagReason {
    mutating func appendIfNotContains(_ reason: FlagReason) {
        if !contains(reason) { append(reason) }
    }
}
