import Foundation
import SwiftData

@Model
class ProductLocationLink {
    @Attribute(.unique) var id: UUID
    var product: ProductSKU?
    var location: Location?

    init(product: ProductSKU, location: Location) {
        self.id = UUID()
        self.product = product
        self.location = location
    }
}
