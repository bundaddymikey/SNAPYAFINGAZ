import Foundation
import SwiftData

nonisolated enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case hybrid
    case realTimeScan

    var displayName: String {
        switch self {
        case .photo: "Photo Burst"
        case .video: "Video Sift"
        case .hybrid: "Hybrid"
        case .realTimeScan: "Real-Time Scan"
        }
    }

    var icon: String {
        switch self {
        case .photo: "camera.fill"
        case .video: "video.fill"
        case .hybrid: "camera.on.rectangle.fill"
        case .realTimeScan: "livephoto.play"
        }
    }

    var description: String {
        switch self {
        case .photo: "Capture 1–8 photos from multiple angles"
        case .video: "Record 5–20s video, auto-sample frames"
        case .hybrid: "1 photo + optional short video clip"
        case .realTimeScan: "Live camera feed with continuous recognition"
        }
    }
}

nonisolated enum AuditStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case paused
    case processing
    case reviewRequired
    case complete

    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .paused: "Paused"
        case .processing: "Processing"
        case .reviewRequired: "Review Required"
        case .complete: "Complete"
        }
    }

    var icon: String {
        switch self {
        case .draft: "doc"
        case .paused: "pause.circle.fill"
        case .processing: "arrow.triangle.2.circlepath"
        case .reviewRequired: "eye.circle.fill"
        case .complete: "checkmark.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .draft: "gray"
        case .paused: "orange"
        case .processing: "blue"
        case .reviewRequired: "purple"
        case .complete: "green"
        }
    }
}

nonisolated enum ReviewWorkflow: String, Codable, CaseIterable, Sendable {
    case reviewAsYouGo
    case reviewLater

    var displayName: String {
        switch self {
        case .reviewAsYouGo: "Review As You Go"
        case .reviewLater: "Review Later"
        }
    }

    var description: String {
        switch self {
        case .reviewAsYouGo: "Pause and review uncertain detections during processing"
        case .reviewLater: "Queue all uncertain items for batch review at the end"
        }
    }

    var icon: String {
        switch self {
        case .reviewAsYouGo: "eye.fill"
        case .reviewLater: "tray.full.fill"
        }
    }
}

nonisolated enum CaptureQualityMode: String, Codable, CaseIterable, Sendable {
    case standard
    case highAccuracy

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .highAccuracy: "High Accuracy"
        }
    }

    var description: String {
        switch self {
        case .standard: "Fast capture for typical shelf or product photos"
        case .highAccuracy: "Guided capture for clean spacing, matte backgrounds, and stronger contrast"
        }
    }

    var badgeTitle: String {
        switch self {
        case .standard: "Standard Capture"
        case .highAccuracy: "High Accuracy Capture"
        }
    }

    var icon: String {
        switch self {
        case .standard: "camera"
        case .highAccuracy: "viewfinder"
        }
    }
}

nonisolated struct CaptureQualityAssessment: Codable, Sendable {
    let clutterOutsideMainArea: Double
    let glareScore: Double
    let backgroundContrast: Double
    let edgeDensity: Double
    let itemsOutsideZoneScore: Double
    let warnings: [CaptureQualityWarning]
    let score: Double

    static let empty = CaptureQualityAssessment(
        clutterOutsideMainArea: 0,
        glareScore: 0,
        backgroundContrast: 0,
        edgeDensity: 0,
        itemsOutsideZoneScore: 0,
        warnings: [],
        score: 0
    )
}

nonisolated enum CaptureQualityWarning: String, Codable, CaseIterable, Sendable, Identifiable {
    case clutterOutsideMainArea
    case lowContrast
    case strongGlare
    case productsOutsideCaptureZone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clutterOutsideMainArea: "Too much clutter outside main area"
        case .lowContrast: "Low contrast"
        case .strongGlare: "Strong glare"
        case .productsOutsideCaptureZone: "Products outside capture zone"
        }
    }

    var actionPrompt: String {
        switch self {
        case .clutterOutsideMainArea: "Use a cleaner background"
        case .lowContrast: "Try a higher contrast surface"
        case .strongGlare: "Reduce glare on packaging"
        case .productsOutsideCaptureZone: "Move products inside the guide frame"
        }
    }

    var icon: String {
        switch self {
        case .clutterOutsideMainArea: "square.stack.3d.up.trianglebadge.exclamationmark"
        case .lowContrast: "circle.lefthalf.filled"
        case .strongGlare: "sun.max.trianglebadge.exclamationmark"
        case .productsOutsideCaptureZone: "viewfinder.trianglebadge.exclamationmark"
        }
    }
}

nonisolated struct CaptureGuidanceTip: Sendable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String

    static let highAccuracyTips: [CaptureGuidanceTip] = [
        CaptureGuidanceTip(id: "background", title: "Plain matte background", subtitle: "Place items on a simple non-reflective surface.", icon: "square.fill"),
        CaptureGuidanceTip(id: "spacing", title: "Spread items slightly", subtitle: "Leave small gaps so packages don’t merge together.", icon: "arrow.left.and.right"),
        CaptureGuidanceTip(id: "glare", title: "Avoid glare and reflections", subtitle: "Tilt lights or camera until shiny highlights are minimized.", icon: "sun.max"),
        CaptureGuidanceTip(id: "frame", title: "Keep products inside frame", subtitle: "Center products within the audit zone before capture.", icon: "viewfinder"),
    ]
}

extension AuditSession {
    var captureQualityAssessment: CaptureQualityAssessment {
        guard let data = captureQualityMetadataJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CaptureQualityAssessment.self, from: data) else {
            return .empty
        }
        return decoded
    }
}

nonisolated extension CaptureQualityAssessment {
    var summaryText: String {
        guard let firstWarning = warnings.first else { return "Capture conditions look good" }
        return firstWarning.actionPrompt
    }

    var qualityBadge: CaptureQualityBadge {
        switch score {
        case 0.75...: return .excellent
        case 0.45...: return .good
        default: return score > 0 ? .needsImprovement : .unrated
        }
    }
}

nonisolated enum CaptureQualityBadge: String, Sendable {
    case excellent = "Excellent Capture"
    case good = "Good Capture"
    case needsImprovement = "Needs Improvement"
    case unrated = ""

    var color: String {
        switch self {
        case .excellent: "green"
        case .good: "yellow"
        case .needsImprovement: "orange"
        case .unrated: "gray"
        }
    }

    var icon: String {
        switch self {
        case .excellent: "checkmark.seal.fill"
        case .good: "checkmark.circle.fill"
        case .needsImprovement: "exclamationmark.triangle.fill"
        case .unrated: "questionmark.circle"
        }
    }
}

nonisolated extension CaptureQualityMode {
    var defaultAssessmentJSON: String { "{}" }
}

nonisolated enum RecognitionScope: String, Codable, CaseIterable, Sendable {
    case all
    case categoryLimited
    case brandLimited

    var displayName: String {
        switch self {
        case .all: "All Inventory"
        case .categoryLimited: "Category Limited"
        case .brandLimited: "Brand Limited"
        }
    }

    var description: String {
        switch self {
        case .all: "Recognize from all products in your catalog"
        case .categoryLimited: "Restrict recognition to a specific product category"
        case .brandLimited: "Restrict recognition to selected brands only"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.grid.3x3.fill"
        case .categoryLimited: "tag.fill"
        case .brandLimited: "building.2.fill"
        }
    }
}

@Model
class AuditSession {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var locationId: UUID
    var locationName: String
    var createdByUserId: UUID
    var createdByUserName: String
    var mode: CaptureMode
    var notes: String
    var status: AuditStatus
    var reviewWorkflow: ReviewWorkflow
    var captureQualityMode: CaptureQualityMode
    var captureQualityMetadataJSON: String
    var selectedLayoutId: UUID?
    var selectedLayoutName: String
    var recognitionScopeRaw: String
    var mainBrand: String
    var secondaryBrand: String
    var strictBrandFilter: Bool
    var allowPossibleStragglers: Bool
    /// Parent category for category-limited recognition scope
    var mainCategory: String
    /// Optional subcategory for category-limited recognition scope
    var mainSubcategory: String
    var pausedAt: Date?
    var presetName: String
    var presetIdRaw: String

    var recognitionScope: RecognitionScope {
        RecognitionScope(rawValue: recognitionScopeRaw) ?? .all
    }

    @Relationship(deleteRule: .cascade) var capturedMedia: [CapturedMedia] = []
    @Relationship(deleteRule: .cascade) var lineItems: [AuditLineItem] = []
    @Relationship(deleteRule: .cascade) var expectedSnapshot: ExpectedSnapshot?
    @Relationship(deleteRule: .cascade) var inventorySnapshot: InventorySystemSnapshot?

    init(
        locationId: UUID,
        locationName: String,
        createdByUserId: UUID,
        createdByUserName: String,
        mode: CaptureMode,
        notes: String = "",
        reviewWorkflow: ReviewWorkflow = .reviewLater,
        captureQualityMode: CaptureQualityMode = .standard,
        captureQualityMetadataJSON: String = "{}",
        selectedLayoutId: UUID? = nil,
        selectedLayoutName: String = "",
        recognitionScope: RecognitionScope = .all,
        mainBrand: String = "",
        secondaryBrand: String = "",
        strictBrandFilter: Bool = true,
        allowPossibleStragglers: Bool = false,
        mainCategory: String = "",
        mainSubcategory: String = "",
        presetName: String = "",
        presetIdRaw: String = ""
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.locationId = locationId
        self.locationName = locationName
        self.createdByUserId = createdByUserId
        self.createdByUserName = createdByUserName
        self.mode = mode
        self.notes = notes
        self.status = .draft
        self.reviewWorkflow = reviewWorkflow
        self.captureQualityMode = captureQualityMode
        self.captureQualityMetadataJSON = captureQualityMetadataJSON
        self.selectedLayoutId = selectedLayoutId
        self.selectedLayoutName = selectedLayoutName
        self.recognitionScopeRaw = recognitionScope.rawValue
        self.mainBrand = mainBrand
        self.secondaryBrand = secondaryBrand
        self.strictBrandFilter = strictBrandFilter
        self.allowPossibleStragglers = allowPossibleStragglers
        self.mainCategory = mainCategory
        self.mainSubcategory = mainSubcategory
        self.presetName = presetName
        self.presetIdRaw = presetIdRaw
    }

    var pendingLineItemCount: Int {
        lineItems.filter { $0.reviewStatus == .pending }.count
    }

    var totalItemCount: Int {
        lineItems.reduce(0) { $0 + $1.visionCount }
    }

    var hasExpectedData: Bool { expectedSnapshot != nil }
    var hasOnHandData: Bool { inventorySnapshot != nil }

    var mismatchCount: Int {
        lineItems.filter { $0.hasMismatch }.count
    }
}
