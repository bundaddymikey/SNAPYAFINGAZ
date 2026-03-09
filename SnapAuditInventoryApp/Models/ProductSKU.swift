import Foundation
import SwiftData

@Model
class ProductSKU {
    @Attribute(.unique) var id: UUID
    var sku: String
    var name: String
    var brand: String
    var category: String
    var variant: String
    var barcode: String?
    var tags: [String]
    var ocrKeywords: [String]
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade) var locationLinks: [ProductLocationLink] = []
    @Relationship(deleteRule: .cascade) var referenceMedia: [ReferenceMedia] = []

    init(
        sku: String,
        name: String,
        brand: String = "",
        category: String = "",
        variant: String = "",
        barcode: String? = nil,
        tags: [String] = [],
        ocrKeywords: [String] = []
    ) {
        self.id = UUID()
        self.sku = sku
        self.name = name
        self.brand = brand
        self.category = category
        self.variant = variant
        self.barcode = barcode
        self.tags = tags
        self.ocrKeywords = ocrKeywords
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
