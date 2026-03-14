import Foundation
import SwiftData

// MARK: - ReferenceViewAngle

/// The perspective/angle from which a training image was captured.
/// Used to ensure coverage across all product faces and to apply
/// angle-specific scoring weights during recognition.
nonisolated enum ReferenceViewAngle: String, Codable, CaseIterable, Sendable {
    case front          = "front"
    case back           = "back"
    case leftSide       = "left_side"
    case rightSide      = "right_side"
    case top            = "top"
    case bottom         = "bottom"
    case angledFront    = "angled_front"
    case labelClose     = "label_close"
    case barcodeClose   = "barcode_close"
    case flavorText     = "flavor_text"
    case general        = "general"     // fallback / untagged

    var displayName: String {
        switch self {
        case .front:        "Front"
        case .back:         "Back"
        case .leftSide:     "Left Side"
        case .rightSide:    "Right Side"
        case .top:          "Top"
        case .bottom:       "Bottom"
        case .angledFront:  "Angled"
        case .labelClose:   "Label Close-Up"
        case .barcodeClose: "Barcode Close-Up"
        case .flavorText:   "Flavor Text"
        case .general:      "General"
        }
    }

    var icon: String {
        switch self {
        case .front:        "rectangle.portrait.fill"
        case .back:         "rectangle.portrait"
        case .leftSide:     "rectangle.lefthalf.inset.filled"
        case .rightSide:    "rectangle.righthalf.inset.filled"
        case .top:          "rectangle.tophalf.inset.filled"
        case .bottom:       "rectangle.bottomhalf.inset.filled"
        case .angledFront:  "rotate.3d"
        case .labelClose:   "text.magnifyingglass"
        case .barcodeClose: "barcode"
        case .flavorText:   "character.cursor.ibeam"
        case .general:      "photo"
        }
    }

    /// Scoring weight applied to embeddings from this angle during classification.
    /// High-information views like the front label close-up are weighted more.
    var recognitionWeight: Double {
        switch self {
        case .front:        1.20
        case .labelClose:   1.30
        case .barcodeClose: 1.10
        case .flavorText:   1.25
        case .angledFront:  1.15
        case .back:         1.05
        case .leftSide:     1.00
        case .rightSide:    1.00
        case .top:          0.95
        case .bottom:       0.90
        case .general:      1.00
        }
    }

    /// Whether this angle is considered a high-priority training view.
    var isHighPriority: Bool {
        switch self {
        case .front, .labelClose, .flavorText, .barcodeClose, .angledFront: true
        default: false
        }
    }
}

// MARK: - ReferenceMediaType

nonisolated enum ReferenceMediaType: String, Codable, CaseIterable, Sendable {
    case photo
    case video

    var icon: String {
        switch self {
        case .photo: "photo"
        case .video: "film"
        }
    }

    var displayName: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        }
    }
}

// MARK: - ReferenceMedia

@Model
class ReferenceMedia {
    @Attribute(.unique) var id: UUID
    var sku: ProductSKU?
    var type: ReferenceMediaType
    var fileURL: String
    var createdAt: Date
    /// The perspective/angle from which this image was captured.
    /// Defaults to .general so existing records keep working with no migration.
    var viewAngleRaw: String

    @Relationship(deleteRule: .cascade) var embeddings: [Embedding] = []

    var viewAngle: ReferenceViewAngle {
        get { ReferenceViewAngle(rawValue: viewAngleRaw) ?? .general }
        set { viewAngleRaw = newValue.rawValue }
    }

    init(sku: ProductSKU, type: ReferenceMediaType, fileURL: String, viewAngle: ReferenceViewAngle = .general) {
        self.id = UUID()
        self.sku = sku
        self.type = type
        self.fileURL = fileURL
        self.createdAt = Date()
        self.viewAngleRaw = viewAngle.rawValue
    }
}

