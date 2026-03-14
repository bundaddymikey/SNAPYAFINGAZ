import SwiftUI
import SwiftData

// MARK: - AuditPreset SwiftData Model

@Model
class AuditPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var presetDescription: String
    var icon: String

    // Recognition
    var recognitionScopeRaw: String
    var mainBrand: String
    var secondaryBrand: String
    var strictBrandFilter: Bool
    var allowPossibleStragglers: Bool
    var mainCategory: String
    var secondaryCategory: String

    // Capture
    var captureQualityModeRaw: String

    // Features
    var enableAuditTrayMode: Bool
    var enableMultiScaleDetection: Bool
    var enableContrastiveVariantTraining: Bool
    var enableOCRVariantAssist: Bool
    var enableExpectedInventoryBias: Bool

    // Review
    var reviewModeRaw: String  // "reviewLater" | "reviewAsYouGo"

    var isBuiltIn: Bool
    var createdAt: Date
    var lastUsedAt: Date?

    var recognitionScope: RecognitionScope {
        RecognitionScope(rawValue: recognitionScopeRaw) ?? .all
    }
    var captureQualityMode: CaptureQualityMode {
        CaptureQualityMode(rawValue: captureQualityModeRaw) ?? .standard
    }
    var reviewWorkflow: ReviewWorkflow {
        ReviewWorkflow(rawValue: reviewModeRaw) ?? .reviewLater
    }

    init(
        name: String,
        description: String,
        icon: String,
        recognitionScope: RecognitionScope = .all,
        mainBrand: String = "",
        secondaryBrand: String = "",
        strictBrandFilter: Bool = true,
        allowPossibleStragglers: Bool = false,
        mainCategory: String = "",
        secondaryCategory: String = "",
        captureQualityMode: CaptureQualityMode = .standard,
        enableAuditTrayMode: Bool = false,
        enableMultiScaleDetection: Bool = false,
        enableContrastiveVariantTraining: Bool = false,
        enableOCRVariantAssist: Bool = false,
        enableExpectedInventoryBias: Bool = false,
        reviewWorkflow: ReviewWorkflow = .reviewLater,
        isBuiltIn: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.presetDescription = description
        self.icon = icon
        self.recognitionScopeRaw = recognitionScope.rawValue
        self.mainBrand = mainBrand
        self.secondaryBrand = secondaryBrand
        self.strictBrandFilter = strictBrandFilter
        self.allowPossibleStragglers = allowPossibleStragglers
        self.mainCategory = mainCategory
        self.secondaryCategory = secondaryCategory
        self.captureQualityModeRaw = captureQualityMode.rawValue
        self.enableAuditTrayMode = enableAuditTrayMode
        self.enableMultiScaleDetection = enableMultiScaleDetection
        self.enableContrastiveVariantTraining = enableContrastiveVariantTraining
        self.enableOCRVariantAssist = enableOCRVariantAssist
        self.enableExpectedInventoryBias = enableExpectedInventoryBias
        self.reviewModeRaw = reviewWorkflow.rawValue
        self.isBuiltIn = isBuiltIn
        self.createdAt = Date()
        self.lastUsedAt = nil
    }
}

// MARK: - Built-In Presets

struct BuiltInPreset {
    let id: String          // stable key stored on AuditSession for built-ins
    let name: String
    let description: String
    let icon: String
    let accentColor: Color

    // Config
    let captureMode: CaptureMode
    let recognitionScope: RecognitionScope
    let strictBrandFilter: Bool
    let allowPossibleStragglers: Bool
    let captureQualityMode: CaptureQualityMode
    let enableAuditTrayMode: Bool
    let enableMultiScaleDetection: Bool
    let enableContrastiveVariantTraining: Bool
    let enableOCRVariantAssist: Bool
    let reviewWorkflow: ReviewWorkflow

    static let all: [BuiltInPreset] = [
        BuiltInPreset(
            id: "brand_shelf_audit",
            name: "Brand Shelf Audit",
            description: "Restrict recognition to one brand. Detects stragglers.",
            icon: "building.2.fill",
            accentColor: .purple,
            captureMode: .photo,
            recognitionScope: .brandLimited,
            strictBrandFilter: false,
            allowPossibleStragglers: true,
            captureQualityMode: .standard,
            enableAuditTrayMode: false,
            enableMultiScaleDetection: true,
            enableContrastiveVariantTraining: true,
            enableOCRVariantAssist: false,
            reviewWorkflow: .reviewLater
        ),
        BuiltInPreset(
            id: "category_section_audit",
            name: "Category Section",
            description: "Limit recognition to a product category.",
            icon: "tag.fill",
            accentColor: .blue,
            captureMode: .photo,
            recognitionScope: .categoryLimited,
            strictBrandFilter: true,
            allowPossibleStragglers: false,
            captureQualityMode: .standard,
            enableAuditTrayMode: false,
            enableMultiScaleDetection: true,
            enableContrastiveVariantTraining: false,
            enableOCRVariantAssist: false,
            reviewWorkflow: .reviewLater
        ),
        BuiltInPreset(
            id: "tray_count_high_accuracy",
            name: "Tray Count",
            description: "Multi-photo/video with cross-frame dedup. Counts each item once.",
            icon: "tray.and.arrow.down.fill",
            accentColor: .orange,
            captureMode: .trayCount,
            recognitionScope: .all,
            strictBrandFilter: true,
            allowPossibleStragglers: false,
            captureQualityMode: .highAccuracy,
            enableAuditTrayMode: true,
            enableMultiScaleDetection: true,
            enableContrastiveVariantTraining: false,
            enableOCRVariantAssist: true,
            reviewWorkflow: .reviewLater
        ),
        BuiltInPreset(
            id: "variant_verification",
            name: "Variant Verification",
            description: "Identify similar-looking variants. Prioritizes review queue.",
            icon: "square.on.square.badge.person.crop",
            accentColor: .orange,
            captureMode: .photo,
            recognitionScope: .all,
            strictBrandFilter: false,
            allowPossibleStragglers: false,
            captureQualityMode: .standard,
            enableAuditTrayMode: false,
            enableMultiScaleDetection: false,
            enableContrastiveVariantTraining: true,
            enableOCRVariantAssist: true,
            reviewWorkflow: .reviewAsYouGo
        ),
        BuiltInPreset(
            id: "mixed_bin_audit",
            name: "Mixed Bin Audit",
            description: "Full catalog scan. Best for unsorted bins or piles.",
            icon: "shippingbox.fill",
            accentColor: .indigo,
            captureMode: .photo,
            recognitionScope: .all,
            strictBrandFilter: false,
            allowPossibleStragglers: false,
            captureQualityMode: .standard,
            enableAuditTrayMode: false,
            enableMultiScaleDetection: true,
            enableContrastiveVariantTraining: false,
            enableOCRVariantAssist: false,
            reviewWorkflow: .reviewLater
        )
    ]
}
