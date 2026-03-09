import Foundation
import SwiftData

nonisolated enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case hybrid

    var displayName: String {
        switch self {
        case .photo: "Photo Burst"
        case .video: "Video Sift"
        case .hybrid: "Hybrid"
        }
    }

    var icon: String {
        switch self {
        case .photo: "camera.fill"
        case .video: "video.fill"
        case .hybrid: "camera.on.rectangle.fill"
        }
    }

    var description: String {
        switch self {
        case .photo: "Capture 1–8 photos from multiple angles"
        case .video: "Record 5–20s video, auto-sample frames"
        case .hybrid: "1 photo + optional short video clip"
        }
    }
}

nonisolated enum AuditStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case processing
    case complete

    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .processing: "Processing"
        case .complete: "Complete"
        }
    }

    var icon: String {
        switch self {
        case .draft: "doc"
        case .processing: "arrow.triangle.2.circlepath"
        case .complete: "checkmark.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .draft: "gray"
        case .processing: "orange"
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
        return firstWarning.title
    }
}

nonisolated extension CaptureQualityMode {
    var defaultAssessmentJSON: String { "{}" }
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
        selectedLayoutName: String = ""
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
