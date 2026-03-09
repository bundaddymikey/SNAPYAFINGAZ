import SwiftUI
import SwiftData

private let shelfZoneColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .cyan]

struct ShelfLayoutEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var layout: ShelfLayout

    @Query private var allSKUs: [ProductSKU]
    @Query private var allGroups: [LookAlikeGroup]

    @State private var selectedZoneIndex: Int? = nil
    @State private var showZoneAssigner = false
    @State private var showAddZoneAlert = false
    @State private var newZoneName = ""

    private var sortedZones: [ShelfZone] { layout.sortedZones }

    var body: some View {
        List {
            canvasSection
            zonesListSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(layout.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newZoneName = "Zone \(sortedZones.count + 1)"
                    showAddZoneAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New Zone", isPresented: $showAddZoneAlert) {
            TextField("Zone name", text: $newZoneName)
            Button("Add") { addZone() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new zone (e.g. \"Top Shelf\", \"Bay 1\")")
        }
        .sheet(isPresented: $showZoneAssigner) {
            if let idx = selectedZoneIndex, sortedZones.indices.contains(idx) {
                ZoneAssignerSheet(
                    zone: sortedZones[idx],
                    allSKUs: allSKUs,
                    allGroups: allGroups
                ) {
                    try? modelContext.save()
                }
            }
        }
    }

    // MARK: - Canvas Section

    private var canvasSection: some View {
        Section {
            ShelfCanvasView(
                zones: sortedZones,
                selectedIndex: $selectedZoneIndex
            )
            .frame(height: 240)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color(.systemGroupedBackground))
        } header: {
            Text("Shelf Face Preview")
        } footer: {
            Text("Tap a zone to select it. Zones show assigned SKUs by color.")
                .font(.caption2)
        }
    }

    // MARK: - Zones List Section

    private var zonesListSection: some View {
        Section {
            if sortedZones.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.dashed")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No zones yet")
                            .font(.subheadline.weight(.medium))
                        Text("Tap + to add a zone to this layout")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(Array(sortedZones.enumerated()), id: \.element.id) { idx, zone in
                    ZoneRow(
                        zone: zone,
                        color: shelfZoneColors[idx % shelfZoneColors.count],
                        isSelected: selectedZoneIndex == idx
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedZoneIndex = idx
                        showZoneAssigner = true
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteZone(zone)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            selectedZoneIndex = idx
                            showZoneAssigner = true
                        } label: {
                            Label("Assign", systemImage: "tag.fill")
                        }
                        .tint(.blue)
                    }
                }
            }
        } header: {
            HStack {
                Text("Zones")
                Spacer()
                Text("\(sortedZones.filter { $0.isAssigned }.count)/\(sortedZones.count) assigned")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Swipe left to assign a SKU or group to a zone. During audits, only the assigned SKU is considered for that zone.")
                .font(.caption2)
        }
    }

    // MARK: - Actions

    private func addZone() {
        let trimName = newZoneName.trimmingCharacters(in: .whitespaces)
        guard !trimName.isEmpty else { return }
        let count = sortedZones.count
        let cols = 2
        let rows = max(1, (count / cols) + 1)
        let col = count % cols
        let row = count / cols
        let w = 1.0 / Double(cols)
        let h = 1.0 / Double(rows)
        let rect = ShelfRect(x: Double(col) * w, y: Double(row) * h, w: w, h: h)
        let zone = ShelfZone(layoutId: layout.id, name: trimName, rect: rect, sortOrder: count)
        zone.layout = layout
        layout.zones.append(zone)
        modelContext.insert(zone)
        try? modelContext.save()
        selectedZoneIndex = sortedZones.count - 1
    }

    private func deleteZone(_ zone: ShelfZone) {
        if let idx = layout.zones.firstIndex(where: { $0.id == zone.id }) {
            layout.zones.remove(at: idx)
        }
        modelContext.delete(zone)
        try? modelContext.save()
        selectedZoneIndex = nil
    }
}

// MARK: - Canvas

private struct ShelfCanvasView: View {
    let zones: [ShelfZone]
    @Binding var selectedIndex: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.secondarySystemGroupedBackground)

                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(.separator), lineWidth: 1)
                    .padding(12)

                ForEach(Array(zones.enumerated()), id: \.element.id) { idx, zone in
                    let rect = zone.rect
                    let canvas = CGRect(
                        x: 12 + rect.x * (geo.size.width - 24),
                        y: 12 + rect.y * (geo.size.height - 24),
                        width: rect.w * (geo.size.width - 24),
                        height: rect.h * (geo.size.height - 24)
                    )
                    let color = shelfZoneColors[idx % shelfZoneColors.count]
                    let isSelected = selectedIndex == idx

                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color.opacity(isSelected ? 0.30 : 0.15))
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(color, lineWidth: isSelected ? 2.5 : 1.5)
                        VStack(spacing: 2) {
                            Text(zone.name)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(color)
                                .lineLimit(1)
                            if zone.isAssigned {
                                Text(zone.assignmentLabel)
                                    .font(.system(size: 8))
                                    .foregroundStyle(color.opacity(0.8))
                                    .lineLimit(1)
                            } else {
                                Text("Unassigned")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(3)
                    }
                    .frame(width: canvas.width, height: canvas.height)
                    .position(x: canvas.midX, y: canvas.midY)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.2)) {
                            selectedIndex = idx
                        }
                    }
                }

                if zones.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No zones defined")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 12))
        }
    }
}

// MARK: - Zone Row

private struct ZoneRow: View {
    let zone: ShelfZone
    let color: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color.opacity(0.20))
                .frame(width: 34, height: 34)
                .overlay {
                    Circle()
                        .strokeBorder(color, lineWidth: isSelected ? 2 : 1)
                    Text(zone.name.prefix(1).uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(zone.name)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    if zone.isAssigned {
                        Image(systemName: zone.assignedSkuId != nil ? "shippingbox.fill" : "square.on.square.dashed")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text(zone.assignmentLabel)
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else {
                        Image(systemName: "tag.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Tap to assign SKU or group")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            let r = zone.rect
            Text("\(Int(r.w * 100))×\(Int(r.h * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Zone Assigner Sheet

private struct ZoneAssignerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var zone: ShelfZone
    let allSKUs: [ProductSKU]
    let allGroups: [LookAlikeGroup]
    let onSave: () -> Void

    @State private var assignmentMode: AssignmentMode = .sku
    @State private var searchText = ""
    @State private var rectX: Double
    @State private var rectY: Double
    @State private var rectW: Double
    @State private var rectH: Double

    enum AssignmentMode: String, CaseIterable {
        case sku = "SKU"
        case group = "Look-Alike Group"
        case none = "Unassigned"
    }

    init(zone: ShelfZone, allSKUs: [ProductSKU], allGroups: [LookAlikeGroup], onSave: @escaping () -> Void) {
        self.zone = zone
        self.allSKUs = allSKUs
        self.allGroups = allGroups
        self.onSave = onSave
        let r = zone.rect
        _rectX = State(initialValue: r.x)
        _rectY = State(initialValue: r.y)
        _rectW = State(initialValue: r.w)
        _rectH = State(initialValue: r.h)
        if zone.assignedSkuId != nil {
            _assignmentMode = State(initialValue: .sku)
        } else if zone.assignedGroupId != nil {
            _assignmentMode = State(initialValue: .group)
        } else {
            _assignmentMode = State(initialValue: .none)
        }
    }

    private var filteredSKUs: [ProductSKU] {
        if searchText.isEmpty { return allSKUs.sorted { $0.name < $1.name } }
        return allSKUs.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.sku.localizedCaseInsensitiveContains(searchText)
        }.sorted { $0.name < $1.name }
    }

    private var filteredGroups: [LookAlikeGroup] {
        if searchText.isEmpty { return allGroups.sorted { $0.name < $1.name } }
        return allGroups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                positionSection
                assignmentSection
            }
            .navigationTitle("Edit Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        }
    }

    private var nameSection: some View {
        Section("Zone Name") {
            TextField("Zone name", text: $zone.name)
        }
    }

    private var positionSection: some View {
        Section {
            LabeledContent("Left edge") {
                Slider(value: $rectX, in: 0...0.9, step: 0.05)
                    .labelsHidden()
                Text("\(Int(rectX * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }
            LabeledContent("Top edge") {
                Slider(value: $rectY, in: 0...0.9, step: 0.05)
                    .labelsHidden()
                Text("\(Int(rectY * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }
            LabeledContent("Width") {
                Slider(value: $rectW, in: 0.1...1.0, step: 0.05)
                    .labelsHidden()
                Text("\(Int(rectW * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }
            LabeledContent("Height") {
                Slider(value: $rectH, in: 0.1...1.0, step: 0.05)
                    .labelsHidden()
                Text("\(Int(rectH * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
            }
        } header: {
            Text("Position (% of shelf face)")
        } footer: {
            Text("Define the zone's area as a percentage of the shelf face image.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var assignmentSection: some View {
        Section("Assignment Type") {
            Picker("Assign to", selection: $assignmentMode) {
                ForEach(AssignmentMode.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
        }

        switch assignmentMode {
        case .none:
            Section {
                HStack {
                    Image(systemName: "tag.slash")
                        .foregroundStyle(.secondary)
                    Text("Zone will accept any SKU during audits")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .sku:
            Section("Select SKU") {
                if filteredSKUs.isEmpty {
                    Text("No products match").foregroundStyle(.secondary)
                } else {
                    ForEach(filteredSKUs) { sku in
                        Button {
                            zone.assignedSkuId = sku.id
                            zone.assignedSkuName = sku.name
                            zone.assignedGroupId = nil
                            zone.assignedGroupName = ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sku.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(sku.sku)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if zone.assignedSkuId == sku.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
        case .group:
            Section("Select Look-Alike Group") {
                if filteredGroups.isEmpty {
                    Text("No groups match").foregroundStyle(.secondary)
                } else {
                    ForEach(filteredGroups) { group in
                        Button {
                            zone.assignedGroupId = group.id
                            zone.assignedGroupName = group.name
                            zone.assignedSkuId = nil
                            zone.assignedSkuName = ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if zone.assignedGroupId == group.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func save() {
        zone.rect = ShelfRect(x: rectX, y: rectY, w: rectW, h: rectH)
        if assignmentMode == .none {
            zone.assignedSkuId = nil
            zone.assignedSkuName = ""
            zone.assignedGroupId = nil
            zone.assignedGroupName = ""
        }
        onSave()
        dismiss()
    }
}
