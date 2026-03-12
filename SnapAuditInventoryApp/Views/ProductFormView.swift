import SwiftUI

struct ProductFormView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: CatalogViewModel
    let product: ProductSKU?

    @State private var sku: String
    @State private var productName: String
    @State private var brand: String
    @State private var parentCategory: String
    @State private var subcategory: String
    @State private var variant: String
    @State private var sizeOrWeight: String
    @State private var barcode: String
    @State private var tagsText: String
    @State private var isActive: Bool

    init(viewModel: CatalogViewModel, product: ProductSKU? = nil) {
        self.viewModel = viewModel
        self.product = product
        _sku = State(initialValue: product?.sku ?? "")
        _productName = State(initialValue: product?.productName ?? "")
        _brand = State(initialValue: product?.brand ?? "")
        _parentCategory = State(initialValue: product?.parentCategory ?? "")
        _subcategory = State(initialValue: product?.subcategory ?? "")
        _variant = State(initialValue: product?.variant ?? "")
        _sizeOrWeight = State(initialValue: product?.sizeOrWeight ?? "")
        _barcode = State(initialValue: product?.barcode ?? "")
        _tagsText = State(initialValue: product?.tags.joined(separator: ", ") ?? "")
        _isActive = State(initialValue: product?.isActive ?? true)
    }

    private var isEditing: Bool { product != nil }
    private var isValid: Bool {
        !sku.trimmingCharacters(in: .whitespaces).isEmpty &&
        !productName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Subcategories available for the currently selected parent category.
    private var subcategoryOptions: [String] {
        InventoryCategory.subcategories(for: parentCategory)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Required") {
                    TextField("SKU", text: $sku)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Product Name", text: $productName)
                }

                Section("Classification") {
                    TextField("Brand", text: $brand)

                    Picker("Parent Category", selection: $parentCategory) {
                        Text("Select Category").tag("")
                        ForEach(InventoryCategory.allCases, id: \.self) { cat in
                            Text(cat.displayName).tag(cat.rawValue)
                        }
                    }
                    .onChange(of: parentCategory) { _, _ in subcategory = "" }

                    if !parentCategory.isEmpty && !subcategoryOptions.isEmpty {
                        Picker("Subcategory", selection: $subcategory) {
                            Text("None").tag("")
                            ForEach(subcategoryOptions, id: \.self) { sub in
                                Text(sub).tag(sub)
                            }
                        }
                    }
                }

                Section("Details") {
                    TextField("Variant", text: $variant)
                    TextField("Size / Weight (optional)", text: $sizeOrWeight)
                    TextField("Barcode (optional)", text: $barcode)
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                }

                Section(header: Text("Tags"), footer: Text("Comma-separated (e.g. sativa, indica, hybrid)")) {
                    TextField("Tags", text: $tagsText)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("Active", isOn: $isActive)
                } footer: {
                    Text("Inactive products are excluded from recognition candidate sets.")
                        .font(.caption2)
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
                        if viewModel.saveError == nil {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
            .alert("Cannot Save", isPresented: Binding(
                get: { viewModel.saveError != nil },
                set: { if !$0 { viewModel.saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.saveError ?? "")
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
            productName: productName.trimmingCharacters(in: .whitespaces),
            brand: brand.trimmingCharacters(in: .whitespaces),
            parentCategory: parentCategory,
            subcategory: subcategory,
            variant: variant.trimmingCharacters(in: .whitespaces),
            sizeOrWeight: sizeOrWeight.isEmpty ? nil : sizeOrWeight.trimmingCharacters(in: .whitespaces),
            barcode: barcode.isEmpty ? nil : barcode.trimmingCharacters(in: .whitespaces),
            tags: tags,
            isActive: isActive
        )
    }
}
