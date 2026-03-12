import SwiftUI
import SwiftData

@Observable
@MainActor
class CatalogViewModel {
    var products: [ProductSKU] = []
    var searchText = ""
    var saveError: String? = nil

    // Parent category filter ("All" = no filter)
    var selectedParentCategory = "All"
    // Subcategory filter — only meaningful when selectedParentCategory != "All"
    var selectedSubcategory = "All"
    // Brand filter
    var selectedBrand = "All"

    // Backward-compat alias used by existing callers (e.g. CatalogListView)
    var selectedCategory: String {
        get { selectedParentCategory }
        set { selectedParentCategory = newValue; selectedSubcategory = "All" }
    }

    private var modelContext: ModelContext?

    func setup(context: ModelContext) {
        self.modelContext = context
        fetchProducts()
    }

    func fetchProducts() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ProductSKU>(sortBy: [SortDescriptor(\.productName)])
        products = (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Filter sources

    var brands: [String] {
        let unique = Set(products.map(\.brand)).filter { !$0.isEmpty }
        return ["All"] + unique.sorted()
    }

    /// All known parent categories (union of catalog + live SKU data)
    var parentCategories: [String] {
        let predefined = InventoryCategory.allCases.map(\.rawValue)
        let fromProducts = products.map(\.parentCategory).filter { !$0.isEmpty }
        let combined = Set(predefined + fromProducts)
        return ["All"] + combined.sorted()
    }

    /// Backward-compat alias — same as parentCategories
    var categories: [String] { parentCategories }

    /// Subcategories available under the currently selected parent category.
    var subcategories: [String] {
        guard selectedParentCategory != "All" else { return [] }
        let fromHierarchy = InventoryCategory.subcategories(for: selectedParentCategory)
        let fromProducts = products
            .filter { $0.parentCategory == selectedParentCategory }
            .map(\.subcategory)
            .filter { !$0.isEmpty }
        let combined = Set(fromHierarchy + fromProducts)
        return ["All"] + combined.sorted()
    }

    // MARK: - Filtered products

    var filteredProducts: [ProductSKU] {
        products.filter { product in
            // Search: SKU, product name, brand, barcode, tags
            let matchesSearch = searchText.isEmpty || product.matches(query: searchText)

            // Parent category filter
            let matchesParent = selectedParentCategory == "All"
                || product.parentCategory == selectedParentCategory

            // Subcategory filter (only applied when a parent is selected)
            let matchesSub = selectedParentCategory == "All"
                || selectedSubcategory == "All"
                || product.subcategory == selectedSubcategory

            // Brand filter
            let matchesBrand = selectedBrand == "All" || product.brand == selectedBrand

            return matchesSearch && matchesParent && matchesSub && matchesBrand
        }
    }

    // MARK: - Catalog mutations

    func deleteProduct(_ product: ProductSKU) {
        guard let modelContext else { return }
        modelContext.delete(product)
        try? modelContext.save()
        fetchProducts()
    }

    /// Full-featured save used by the expanded ProductFormView.
    func saveProduct(
        existing: ProductSKU? = nil,
        sku: String,
        productName: String,
        brand: String,
        parentCategory: String,
        subcategory: String,
        variant: String,
        sizeOrWeight: String?,
        barcode: String?,
        tags: [String],
        lookAlikeGroupId: UUID? = nil,
        isActive: Bool = true
    ) {
        guard let modelContext else { return }
        saveError = nil

        if let existing {
            // When editing, check if another product already uses this SKU
            let trimmedSku = sku.trimmingCharacters(in: .whitespaces)
            if existing.sku != trimmedSku {
                if products.contains(where: { $0.id != existing.id && $0.sku == trimmedSku }) {
                    saveError = "A product with SKU \"\(trimmedSku)\" already exists."
                    return
                }
            }
            existing.sku = sku
            existing.productName = productName
            existing.brand = brand
            existing.parentCategory = parentCategory
            existing.subcategory = subcategory
            existing.variant = variant
            existing.sizeOrWeight = sizeOrWeight
            existing.barcode = barcode
            existing.tags = tags
            existing.lookAlikeGroupId = lookAlikeGroupId
            existing.isActive = isActive
            existing.updatedAt = Date()
        } else {
            // Prevent duplicate SKU on creation
            let trimmedSku = sku.trimmingCharacters(in: .whitespaces)
            if products.contains(where: { $0.sku == trimmedSku }) {
                saveError = "A product with SKU \"\(trimmedSku)\" already exists."
                return
            }
            let product = ProductSKU(
                sku: sku,
                productName: productName,
                brand: brand,
                parentCategory: parentCategory,
                subcategory: subcategory,
                variant: variant,
                sizeOrWeight: sizeOrWeight,
                barcode: barcode,
                tags: tags,
                lookAlikeGroupId: lookAlikeGroupId,
                isActive: isActive
            )
            modelContext.insert(product)
        }
        try? modelContext.save()
        fetchProducts()
    }

    // MARK: - Backward-compat overload (used by older callsites)

    func saveProduct(
        existing: ProductSKU? = nil,
        sku: String,
        name: String,
        brand: String,
        category: String,
        variant: String,
        barcode: String?,
        tags: [String]
    ) {
        saveProduct(
            existing: existing,
            sku: sku,
            productName: name,
            brand: brand,
            parentCategory: category,
            subcategory: "",
            variant: variant,
            sizeOrWeight: nil,
            barcode: barcode,
            tags: tags,
            isActive: true
        )
    }

    // MARK: - ParsedSKUInfo helper (for import pipeline)

    func parsedSKUInfos() -> [ParsedSKUInfo] {
        products.map { ParsedSKUInfo(id: $0.id, sku: $0.sku, name: $0.productName) }
    }
}
