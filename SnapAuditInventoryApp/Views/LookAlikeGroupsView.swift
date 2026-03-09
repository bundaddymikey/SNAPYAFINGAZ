import SwiftUI
import SwiftData

struct LookAlikeGroupsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = LookAlikeViewModel()
    @State private var showCreate = false
    @State private var selectedGroup: LookAlikeGroup? = nil
    @State private var newGroupName = ""
    @State private var newGroupNotes = ""

    var body: some View {
        List {
            if viewModel.groups.isEmpty {
                emptyState
            } else {
                ForEach(viewModel.groups, id: \.id) { group in
                    Button { selectedGroup = group } label: {
                        LookAlikeGroupRow(group: group, viewModel: viewModel)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.deleteGroup(group)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Look-Alike Groups")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            createGroupSheet
        }
        .sheet(item: $selectedGroup) { group in
            LookAlikeGroupDetailView(group: group, viewModel: viewModel)
        }
        .onAppear { viewModel.setup(context: modelContext) }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary.opacity(0.6))
                VStack(spacing: 4) {
                    Text("No Look-Alike Groups")
                        .font(.headline)
                    Text("Group products with similar packaging so the engine applies stricter differentiation rules.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    showCreate = true
                } label: {
                    Label("Create First Group", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
        .listRowBackground(Color.clear)
    }

    private var createGroupSheet: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    TextField("e.g. Soda Cans 12oz", text: $newGroupName)
                }
                Section("Notes (optional)") {
                    TextField("Describe what makes these look-alike…", text: $newGroupNotes, axis: .vertical)
                        .lineLimit(3...5)
                }
            }
            .navigationTitle("New Look-Alike Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        newGroupName = ""
                        newGroupNotes = ""
                        showCreate = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        viewModel.createGroup(name: newGroupName, notes: newGroupNotes)
                        newGroupName = ""
                        newGroupNotes = ""
                        showCreate = false
                    }
                    .fontWeight(.semibold)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct LookAlikeGroupRow: View {
    let group: LookAlikeGroup
    let viewModel: LookAlikeViewModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "square.on.square.dashed")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if viewModel.zoneProfile(for: group) != nil {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Label("Zone profile", systemImage: "rectangle.dashed.and.paperclip")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct LookAlikeGroupDetailView: View {
    let group: LookAlikeGroup
    @Bindable var viewModel: LookAlikeViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showProductPicker = false
    @State private var showZoneEditor = false
    @State private var editingName: String = ""
    @State private var editingNotes: String = ""
    @State private var isEditingInfo = false
    @State private var allProducts: [ProductSKU] = []
    @State private var zones: [ZoneRect] = []

    var body: some View {
        NavigationStack {
            List {
                infoSection
                membersSection
                zoneProfileSection
                policySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showProductPicker) {
                ProductPickerForGroup(
                    group: group,
                    viewModel: viewModel,
                    allProducts: allProducts
                )
            }
            .sheet(isPresented: $showZoneEditor) {
                zoneEditorSheet
            }
            .onAppear {
                viewModel.setup(context: modelContext)
                editingName = group.name
                editingNotes = group.notes
                loadProducts()
                loadZones()
            }
        }
    }

    private var infoSection: some View {
        Section("Group Info") {
            if isEditingInfo {
                TextField("Group Name", text: $editingName)
                    .font(.body.weight(.medium))
                TextField("Notes", text: $editingNotes, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2...4)
                HStack {
                    Button("Cancel", role: .cancel) {
                        editingName = group.name
                        editingNotes = group.notes
                        isEditingInfo = false
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") {
                        viewModel.updateGroup(group, name: editingName, notes: editingNotes)
                        isEditingInfo = false
                    }
                    .fontWeight(.semibold)
                    .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.body.weight(.medium))
                        if !group.notes.isEmpty {
                            Text(group.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { isEditingInfo = true } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    private var membersSection: some View {
        Section {
            if group.members.isEmpty {
                HStack {
                    Image(systemName: "cube.box")
                        .foregroundStyle(.secondary)
                    Text("No products added yet")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(group.members, id: \.id) { member in
                    MemberRow(member: member, allProducts: allProducts)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel.removeMember(member)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                }
            }
            Button {
                showProductPicker = true
            } label: {
                Label("Add Product", systemImage: "plus.circle.fill")
                    .foregroundStyle(.blue)
            }
        } header: {
            HStack {
                Text("Members")
                Spacer()
                Text("\(group.members.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Products in the same group must clear a stricter close-match margin during recognition.")
                .font(.caption2)
        }
    }

    private var zoneProfileSection: some View {
        Section {
            let profile = viewModel.zoneProfile(for: group)
            let currentZones = profile?.zones ?? []

            if currentZones.isEmpty {
                Button {
                    zones = ZonePreset.bottomLabel.zones
                    showZoneEditor = true
                } label: {
                    Label("Configure Zone Profile", systemImage: "rectangle.dashed.and.paperclip")
                        .foregroundStyle(.cyan)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(currentZones.count) zone\(currentZones.count == 1 ? "" : "s") configured")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Edit") {
                            zones = currentZones
                            showZoneEditor = true
                        }
                        .font(.subheadline)
                    }

                    ForEach(currentZones) { zone in
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.cyan.opacity(0.7))
                            Text(zone.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("×\(String(format: "%.1f", zone.weight))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Zone Profile")
        } footer: {
            Text("Define weighted image regions that help discriminate look-alike packaging. Zone embeddings are combined with full-crop scores during classification.")
                .font(.caption2)
        }
    }

    private var policySection: some View {
        Section("Recognition Policy") {
            PolicyRow(
                icon: "arrow.up.circle.fill",
                color: .orange,
                title: "Strict Close-Match Margin",
                detail: "1.5× standard margin required"
            )
            PolicyRow(
                icon: "clock.badge.exclamationmark.fill",
                color: .indigo,
                title: "Low Margin → Pending Review",
                detail: "Automatically queued if margin is insufficient"
            )
            PolicyRow(
                icon: "camera.2.fill",
                color: .cyan,
                title: "Second Angle Recommended",
                detail: "Flag shown in capture UI when uncertainty is high"
            )
        }
    }

    private var zoneEditorSheet: some View {
        NavigationStack {
            ScrollView {
                ZoneProfileEditorView(zones: $zones)
                    .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Zone Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showZoneEditor = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        viewModel.setZones(zones, for: group)
                        showZoneEditor = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func loadProducts() {
        let descriptor = FetchDescriptor<ProductSKU>(sortBy: [SortDescriptor(\.name)])
        allProducts = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func loadZones() {
        zones = viewModel.zoneProfile(for: group)?.zones ?? []
    }
}

struct MemberRow: View {
    let member: LookAlikeGroupMember
    let allProducts: [ProductSKU]

    private var product: ProductSKU? {
        allProducts.first { $0.id == member.skuId }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let product {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name)
                        .font(.subheadline.weight(.medium))
                    Text(product.sku)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Unknown Product")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PolicyRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProductPickerForGroup: View {
    let group: LookAlikeGroup
    @Bindable var viewModel: LookAlikeViewModel
    let allProducts: [ProductSKU]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredProducts: [ProductSKU] {
        if searchText.isEmpty { return allProducts }
        return allProducts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.sku.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredProducts, id: \.id) { product in
                let isMember = group.members.contains { $0.skuId == product.id }
                Button {
                    if !isMember {
                        viewModel.addMember(skuId: product.id, to: group)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name)
                                .font(.subheadline.weight(.medium))
                            Text(product.sku)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isMember {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(isMember ? .secondary : .primary)
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search products…")
            .navigationTitle("Add Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
