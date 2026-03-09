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

    init(
        skuId: UUID,
        sourceMedia: ReferenceMedia,
        vectorData: Data,
        qualityScore: Double,
        tagsJSON: String = "{}"
    ) {
        self.id = UUID()
        self.skuId = skuId
        self.sourceMedia = sourceMedia
        self.vectorData = vectorData
        self.createdAt = Date()
        self.qualityScore = qualityScore
        self.tagsJSON = tagsJSON
    }
}
