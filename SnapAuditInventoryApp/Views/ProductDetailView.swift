import SwiftUI
import SwiftData

struct ProductDetailView: View {
    let product: ProductSKU
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var showEdit = false
    @State private var lookAlikeVM = LookAlikeViewModel()
    @State private var showGroupPicker = false
    @State private var showKeywordsEditor = false
    @State private var keywordsText = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(product.name)
                            .font(.title2.bold())
                        Spacer()
                    }
                    if !product.variant.isEmpty {
                        Text(product.variant)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section("Details") {
                DetailRow(label: "SKU", value: product.sku, icon: "number")
                DetailRow(label: "Brand", value: product.brand.isEmpty ? "—" : product.brand, icon: "tag")
                DetailRow(label: "Category", value: product.category.isEmpty ? "—" : product.category, icon: "square.grid.2x2")
                if let barcode = product.barcode, !barcode.isEmpty {
                    DetailRow(label: "Barcode", value: barcode, icon: "barcode")
                }
            }

            if !product.tags.isEmpty {
                Section("Tags") {
                    FlowLayout(spacing: 6) {
                        ForEach(product.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            lookAlikeSection

            TrainingMediaView(sku: product)

            Section("Timestamps") {
                DetailRow(label: "Created", value: product.createdAt.formatted(date: .abbreviated, time: .shortened), icon: "clock")
                DetailRow(label: "Updated", value: product.updatedAt.formatted(date: .abbreviated, time: .shortened), icon: "arrow.clockwise")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Product")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            ProductFormView(viewModel: viewModel, product: product)
        }
        .sheet(isPresented: $showGroupPicker) {
            LookAlikeGroupPickerView(skuId: product.id, viewModel: lookAlikeVM)
        }
        .sheet(isPresented: $showKeywordsEditor) {
            KeywordsEditorSheet(product: product, keywordsText: $keywordsText)
        }
        .onAppear {
            lookAlikeVM.setup(context: modelContext)
        }
    }

    private var lookAlikeSection: some View {
        Section {
            let currentGroup = lookAlikeVM.groupFor(skuId: product.id)

            if let group = currentGroup {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "square.on.square.dashed")
                            .font(.subheadline)
                            .foregroundStyle(.cyan)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.subheadline.weight(.medium))
                        Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s") · Strict matching active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showGroupPicker = true } label: {
                        Text("Change")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                }
                Button(role: .destructive) {
                    lookAlikeVM.removeFromAnyGroup(skuId: product.id)
                } label: {
                    Label("Remove from Group", systemImage: "minus.circle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    showGroupPicker = true
                } label: {
                    HStack {
                        Image(systemName: "square.on.square.dashed")
                            .foregroundStyle(.cyan)
                        Text("Assign to Look-Alike Group")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
    
            focusZoneRow(currentGroup: currentGroup)

            if currentGroup != nil {
                keywordsRow
            }
        } header: {
            Text("Look-Alike Group")
        } footer: {
            Text("Grouping near-identical products activates zone-weighted scoring, OCR assist, stricter margin requirements, and Smart Focus Zones during recognition.")
                .font(.caption2)
        }
    }

    private func focusZoneRow(currentGroup: LookAlikeGroup?) -> some View {
        let zoneProfile = currentGroup.flatMap { lookAlikeVM.zoneProfile(for: $0) }
        let usesCustomFocusZones = zoneProfile?.zones.isEmpty == false

        return HStack(spacing: 12) {
            Image(systemName: usesCustomFocusZones ? "viewfinder.circle.fill" : "viewfinder.circle")
                .font(.title3)
                .foregroundStyle(usesCustomFocusZones ? .cyan : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Focus Zones")
                    .font(.subheadline.weight(.medium))
                Text(usesCustomFocusZones ? "Custom focus zones from Look-Alike Group" : "Default focus zones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if usesCustomFocusZones, let zoneCount = zoneProfile?.zones.count {
                Text("\(zoneCount) zones")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.12), in: Capsule())
            } else {
                Text("Presets")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var keywordsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "text.viewfinder")
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                    Text("Differentiator Keywords")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                Button {
                    keywordsText = product.ocrKeywords.joined(separator: ", ")
                    showKeywordsEditor = true
                } label: {
                    Text(product.ocrKeywords.isEmpty ? "Add" : "Edit")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                }
            }

            if product.ocrKeywords.isEmpty {
                Text("Used by OCR Assist to differentiate look-alike variants (e.g. cartridge, all-in-one, 12oz)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(product.ocrKeywords, id: \.self) { kw in
                        Text(kw)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.12))
                            .foregroundStyle(.cyan)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct LookAlikeGroupPickerView: View {
    let skuId: UUID
    @Bindable var viewModel: LookAlikeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCreateSheet = false
    @State private var newGroupName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.groups, id: \.id) { group in
                        let isCurrent = group.members.contains { $0.skuId == skuId }
                        Button {
                            viewModel.addMember(skuId: skuId, to: group)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.cyan.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "square.on.square.dashed")
                                        .font(.subheadline)
                                        .foregroundStyle(.cyan)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isCurrent {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("New Look-Alike Group…", systemImage: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Assign Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                NavigationStack {
                    Form {
                        Section("Group Name") {
                            TextField("e.g. Soda Cans 12oz", text: $newGroupName)
                        }
                    }
                    .navigationTitle("New Group")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") {
                                newGroupName = ""
                                showCreateSheet = false
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Create & Assign") {
                                viewModel.createGroup(name: newGroupName)
                                if let newGroup = viewModel.groups.first {
                                    viewModel.addMember(skuId: skuId, to: newGroup)
                                }
                                newGroupName = ""
                                showCreateSheet = false
                                dismiss()
                            }
                            .fontWeight(.semibold)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }
}

struct KeywordsEditorSheet: View {
    let product: ProductSKU
    @Binding var keywordsText: String
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. cartridge, all-in-one, 12oz", text: $keywordsText, axis: .vertical)
                        .lineLimit(3...6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Differentiator Keywords")
                } footer: {
                    Text("Comma-separated words or phrases. OCR Assist matches these against text detected in the product's zone regions during recognition — giving a small score boost to candidates whose keywords appear in the image.")
                }

                if !parsedKeywords.isEmpty {
                    Section("Preview") {
                        FlowLayout(spacing: 6) {
                            ForEach(parsedKeywords, id: \.self) { kw in
                                Text(kw)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.cyan.opacity(0.12))
                                    .foregroundStyle(.cyan)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("OCR Keywords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        product.ocrKeywords = parsedKeywords
                        try? modelContext.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var parsedKeywords: [String] {
        keywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let point = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
