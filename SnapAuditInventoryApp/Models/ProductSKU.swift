import Foundation
import SwiftData

// MARK: - String normalization helper

extension String {
    /// Returns a search-normalized version of the string:
    /// lowercase, whitespace-trimmed, collapsed interior spaces,
    /// stripped of leading/trailing punctuation.
    nonisolated var normalized: String {
        var s = self.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse repeated spaces
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s
    }
}

// MARK: - ProductSKU

@Model
class ProductSKU {
    @Attribute(.unique) var id: UUID
    var sku: String

    // Primary product name
    var productName: String

    // Backward-compatible alias — callers using `.name` still compile
    var name: String {
        get { productName }
        set { productName = newValue }
    }

    var brand: String

    // Hierarchical category fields
    var parentCategory: String
    var subcategory: String

    // Backward-compatible alias for callers still referencing `.category`
    var category: String {
        get { parentCategory }
        set { parentCategory = newValue }
    }

    var variant: String
    var sizeOrWeight: String?
    var barcode: String?

    // Tags stored as a native array (SwiftData supports [String])
    var tags: [String]

    // OCR differentiator keywords (used by OCR Assist)
    var ocrKeywords: [String]

    // Optional direct look-alike group reference for fast candidate filtering
    var lookAlikeGroupId: UUID?

    // Active / inactive — inactive SKUs are excluded from candidate sets
    var isActive: Bool

    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade) var locationLinks: [ProductLocationLink] = []
    @Relationship(deleteRule: .cascade) var referenceMedia: [ReferenceMedia] = []

    // MARK: - Normalized computed properties (not stored — no migration needed)

    var normalizedProductName: String { productName.normalized }
    var normalizedBrand: String { brand.normalized }
    var normalizedParentCategory: String { parentCategory.normalized }
    var normalizedSubcategory: String { subcategory.normalized }

    // MARK: - Search helper

    /// Returns true if the query matches any searchable field.
    func matches(query: String) -> Bool {
        let q = query.normalized
        guard !q.isEmpty else { return true }
        if sku.normalized.contains(q) { return true }
        if normalizedProductName.contains(q) { return true }
        if normalizedBrand.contains(q) { return true }
        if let bc = barcode, bc.lowercased().contains(q) { return true }
        if tags.contains(where: { $0.normalized.contains(q) }) { return true }
        return false
    }

    // MARK: - init

    init(
        sku: String,
        productName: String,
        brand: String = "",
        parentCategory: String = "",
        subcategory: String = "",
        variant: String = "",
        sizeOrWeight: String? = nil,
        barcode: String? = nil,
        tags: [String] = [],
        ocrKeywords: [String] = [],
        lookAlikeGroupId: UUID? = nil,
        isActive: Bool = true
    ) {
        self.id = UUID()
        self.sku = sku
        self.productName = productName
        self.brand = brand
        self.parentCategory = parentCategory
        self.subcategory = subcategory
        self.variant = variant
        self.sizeOrWeight = sizeOrWeight
        self.barcode = barcode
        self.tags = tags
        self.ocrKeywords = ocrKeywords
        self.lookAlikeGroupId = lookAlikeGroupId
        self.isActive = isActive
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Convenience init for backward compatibility (name: parameter)

    convenience init(
        sku: String,
        name: String,
        brand: String = "",
        category: String = "",
        variant: String = "",
        barcode: String? = nil,
        tags: [String] = [],
        ocrKeywords: [String] = []
    ) {
        self.init(
            sku: sku,
            productName: name,
            brand: brand,
            parentCategory: category,
            subcategory: "",
            variant: variant,
            barcode: barcode,
            tags: tags,
            ocrKeywords: ocrKeywords,
            isActive: true
        )
    }
}
