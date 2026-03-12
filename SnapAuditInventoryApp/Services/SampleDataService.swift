import Foundation
import SwiftData

/// Provides sample product data for testing recognition and audit flows.
/// Admin-only, accessible via Settings.
@MainActor
struct SampleDataService {

    /// Insert sample products into the catalog for testing.
    /// Returns the count of inserted products.
    @discardableResult
    static func loadSampleProducts(context: ModelContext) -> Int {
        let sampleProducts: [(sku: String, name: String, brand: String, category: String, subcategory: String, variant: String)] = [
            ("SMPL-001", "Classic Cola 12oz", "Sample Brand", "Beverages", "Soft Drinks", "Regular"),
            ("SMPL-002", "Diet Cola 12oz", "Sample Brand", "Beverages", "Soft Drinks", "Diet"),
            ("SMPL-003", "Lemon-Lime Soda 12oz", "Sample Brand", "Beverages", "Soft Drinks", "Citrus"),
            ("SMPL-004", "BBQ Kettle Chips 8oz", "Snack Co", "Snacks", "Chips", "BBQ"),
            ("SMPL-005", "Sea Salt Chips 8oz", "Snack Co", "Snacks", "Chips", "Sea Salt"),
            ("SMPL-006", "Chocolate Bar 3.5oz", "Cocoa Works", "Snacks", "Candy", "Milk Chocolate"),
            ("SMPL-007", "Dark Chocolate Bar 3.5oz", "Cocoa Works", "Snacks", "Candy", "Dark Chocolate"),
            ("SMPL-008", "Spring Water 16oz", "Pure H2O", "Beverages", "Water", "Still"),
            ("SMPL-009", "Sparkling Water 16oz", "Pure H2O", "Beverages", "Water", "Sparkling"),
            ("SMPL-010", "Energy Drink 8oz", "Bolt Energy", "Beverages", "Energy", "Original"),
        ]

        // Check for existing sample SKUs to avoid duplicates
        let descriptor = FetchDescriptor<ProductSKU>()
        let existingProducts = (try? context.fetch(descriptor)) ?? []
        let existingSkus = Set(existingProducts.map(\.sku))

        var insertedCount = 0
        for sample in sampleProducts {
            guard !existingSkus.contains(sample.sku) else { continue }
            let product = ProductSKU(
                sku: sample.sku,
                productName: sample.name,
                brand: sample.brand,
                parentCategory: sample.category,
                subcategory: sample.subcategory,
                variant: sample.variant,
                sizeOrWeight: nil,
                barcode: nil,
                tags: ["sample"],
                isActive: true
            )
            context.insert(product)
            insertedCount += 1
        }

        if insertedCount > 0 {
            try? context.save()
            AuditLogger.shared.logSession("Loaded \(insertedCount) sample products")
        }

        return insertedCount
    }

    /// Remove all sample products (those tagged with "sample").
    static func removeSampleProducts(context: ModelContext) {
        let descriptor = FetchDescriptor<ProductSKU>()
        guard let allProducts = try? context.fetch(descriptor) else { return }
        var removedCount = 0
        for product in allProducts where product.tags.contains("sample") {
            context.delete(product)
            removedCount += 1
        }
        if removedCount > 0 {
            try? context.save()
            AuditLogger.shared.logSession("Removed \(removedCount) sample products")
        }
    }
}
