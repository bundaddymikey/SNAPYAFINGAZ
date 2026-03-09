import SwiftUI

struct ProductFormView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: CatalogViewModel
    let product: ProductSKU?

    @State private var sku: String
    @State private var name: String
    @State private var brand: String
    @State private var category: String
    @State private var variant: String
    @State private var barcode: String
    @State private var tagsText: String

    init(viewModel: CatalogViewModel, product: ProductSKU? = nil) {
        self.viewModel = viewModel
        self.product = product
        _sku = State(initialValue: product?.sku ?? "")
        _name = State(initialValue: product?.name ?? "")
        _brand = State(initialValue: product?.brand ?? "")
        _category = State(initialValue: product?.category ?? "")
        _variant = State(initialValue: product?.variant ?? "")
        _barcode = State(initialValue: product?.barcode ?? "")
        _tagsText = State(initialValue: product?.tags.joined(separator: ", ") ?? "")
    }

    private var isEditing: Bool { product != nil }
    private var isValid: Bool { !sku.trimmingCharacters(in: .whitespaces).isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Required") {
                    TextField("SKU", text: $sku)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Product Name", text: $name)
                }

                Section("Details") {
                    TextField("Brand", text: $brand)
                    TextField("Category", text: $category)
                    TextField("Variant", text: $variant)
                    TextField("Barcode (optional)", text: $barcode)
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                }

                Section(header: Text("Tags"), footer: Text("Comma-separated (e.g. food, protein, organic)")) {
                    TextField("Tags", text: $tagsText)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(isEditing ? "Edit Product" : "New Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        viewModel.saveProduct(
            existing: product,
            sku: sku.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            brand: brand.trimmingCharacters(in: .whitespaces),
            category: category.trimmingCharacters(in: .whitespaces),
            variant: variant.trimmingCharacters(in: .whitespaces),
            barcode: barcode.isEmpty ? nil : barcode.trimmingCharacters(in: .whitespaces),
            tags: tags
        )
    }
}
