import SwiftUI
import SwiftData

@Observable
@MainActor
class CatalogViewModel {
    var products: [ProductSKU] = []
    var searchText = ""
    var selectedBrand = "All"
    var selectedCategory = "All"

    private var modelContext: ModelContext?

    func setup(context: ModelContext) {
        self.modelContext = context
        fetchProducts()
    }

    func fetchProducts() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ProductSKU>(sortBy: [SortDescriptor(\.name)])
        products = (try? modelContext.fetch(descriptor)) ?? []
    }

    var brands: [String] {
        let unique = Set(products.map(\.brand)).filter { !$0.isEmpty }
        return ["All"] + unique.sorted()
    }

    var categories: [String] {
        let unique = Set(products.map(\.category)).filter { !$0.isEmpty }
        return ["All"] + unique.sorted()
    }

    var filteredProducts: [ProductSKU] {
        products.filter { product in
            let matchesSearch = searchText.isEmpty ||
                product.name.localizedStandardContains(searchText) ||
                product.sku.localizedStandardContains(searchText) ||
                product.brand.localizedStandardContains(searchText)
            let matchesBrand = selectedBrand == "All" || product.brand == selectedBrand
            let matchesCategory = selectedCategory == "All" || product.category == selectedCategory
            return matchesSearch && matchesBrand && matchesCategory
        }
    }

    func deleteProduct(_ product: ProductSKU) {
        guard let modelContext else { return }
        modelContext.delete(product)
        try? modelContext.save()
        fetchProducts()
    }

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
        guard let modelContext else { return }
        if let existing {
            existing.sku = sku
            existing.name = name
            existing.brand = brand
            existing.category = category
            existing.variant = variant
            existing.barcode = barcode
            existing.tags = tags
            existing.updatedAt = Date()
        } else {
            let product = ProductSKU(
                sku: sku,
                name: name,
                brand: brand,
                category: category,
                variant: variant,
                barcode: barcode,
                tags: tags
            )
            modelContext.insert(product)
        }
        try? modelContext.save()
        fetchProducts()
    }
}
