import Foundation
import SwiftData

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

@Model
class ReferenceMedia {
    @Attribute(.unique) var id: UUID
    var sku: ProductSKU?
    var type: ReferenceMediaType
    var fileURL: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade) var embeddings: [Embedding] = []

    init(sku: ProductSKU, type: ReferenceMediaType, fileURL: String) {
        self.id = UUID()
        self.sku = sku
        self.type = type
        self.fileURL = fileURL
        self.createdAt = Date()
    }
}
