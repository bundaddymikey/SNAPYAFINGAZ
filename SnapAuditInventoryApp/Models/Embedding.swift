import Foundation
import SwiftData

@Model
class Embedding {
    @Attribute(.unique) var id: UUID
    var skuId: UUID
    var sourceMedia: ReferenceMedia?
    var vectorData: Data
    var createdAt: Date
    var qualityScore: Double
    var tagsJSON: String
    /// The view angle of the source image. Stored as raw string for SwiftData compatibility.
    var viewAngleRaw: String

    var viewAngle: ReferenceViewAngle {
        get { ReferenceViewAngle(rawValue: viewAngleRaw) ?? .general }
        set { viewAngleRaw = newValue.rawValue }
    }

    init(
        skuId: UUID,
        sourceMedia: ReferenceMedia,
        vectorData: Data,
        qualityScore: Double,
        tagsJSON: String = "{}",
        viewAngle: ReferenceViewAngle = .general
    ) {
        self.id = UUID()
        self.skuId = skuId
        self.sourceMedia = sourceMedia
        self.vectorData = vectorData
        self.createdAt = Date()
        self.qualityScore = qualityScore
        self.tagsJSON = tagsJSON
        self.viewAngleRaw = viewAngle.rawValue
    }
}

