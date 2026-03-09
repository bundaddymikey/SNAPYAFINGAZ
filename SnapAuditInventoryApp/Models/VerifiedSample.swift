import Foundation
import SwiftData

@Model
class VerifiedSample {
    @Attribute(.unique) var id: UUID
    var skuId: UUID
    var cropURL: String
    var vectorData: Data
    var createdAt: Date
    var metadataJSON: String

    init(
        skuId: UUID,
        cropURL: String,
        vectorData: Data,
        metadataJSON: String = "{}"
    ) {
        self.id = UUID()
        self.skuId = skuId
        self.cropURL = cropURL
        self.vectorData = vectorData
        self.createdAt = Date()
        self.metadataJSON = metadataJSON
    }
}
