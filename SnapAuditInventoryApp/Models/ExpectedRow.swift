import Foundation
import SwiftData

@Model
class ExpectedRow {
    @Attribute(.unique) var id: UUID
    var snapshot: ExpectedSnapshot?
    var skuOrNameKey: String
    var expectedQty: Int
    var locationNameOptional: String
    var zoneOptional: String
    var matchedSkuId: UUID?
    var isMatched: Bool

    init(
        skuOrNameKey: String,
        expectedQty: Int,
        locationName: String = "",
        zone: String = ""
    ) {
        self.id = UUID()
        self.skuOrNameKey = skuOrNameKey
        self.expectedQty = expectedQty
        self.locationNameOptional = locationName
        self.zoneOptional = zone
        self.isMatched = false
    }
}
