import Foundation
import SwiftData

@Model
class OnHandRow {
    @Attribute(.unique) var id: UUID
    var snapshot: InventorySystemSnapshot?
    var skuOrNameKey: String
    var onHandQty: Int
    var matchedSkuId: UUID?
    var isMatched: Bool

    init(skuOrNameKey: String, onHandQty: Int) {
        self.id = UUID()
        self.skuOrNameKey = skuOrNameKey
        self.onHandQty = onHandQty
        self.isMatched = false
    }
}
