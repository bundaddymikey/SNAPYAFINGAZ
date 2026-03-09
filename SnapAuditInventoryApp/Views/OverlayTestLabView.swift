import SwiftUI
import SwiftData

struct OverlayTestLabView: View {
    let isAdmin: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ShelfLayout.name) private var layouts: [ShelfLayout]

    @State private var selectedLayout: ShelfLayout?
    @State private var overlayEnabled = true
    @State private var opacity: Double = 0.35
    @State private var showLabels = true
    @State private var tappedZone: ShelfZone?
    @State private var showZoneSheet = false
    @State private var canvasSize: CGSize = .zero

    private var activeZones: [ShelfZone] {
        selectedLayout?.sortedZones ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    canvasSection
                    controlsSection
                    if isAdmin { layoutPickerSection }
                    zoneListSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Overlay Test Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showZoneSheet) {
            if let zone = tappedZone {
                ZoneQuickEditSheet(zone: zone, isAdmin: isAdmin)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Preview Canvas", systemImage: "viewfinder")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            ZStack {
                gridCanvas

                if overlayEnabled && !activeZones.isEmpty {
                    ZoneOverlayView(
                        zones: activeZones,
                        showLabels: showLabels,
                        opacity: opacity,
                        onTapZone: isAdmin ? { zone in
                            tappedZone = zone
                            showZoneSheet = true
                        } : nil
                    )
                }

                if activeZones.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.dashed")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text(layouts.isEmpty ? "No layouts available" : "Select a layout above")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !overlayEnabled && !activeZones.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Overlay hidden")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(height: 280)
            .clipShape(.rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            )

            if isAdmin && !activeZones.isEmpty {
                Text("Tap a zone to quick-edit (Admin)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var gridCanvas: some View {
        Canvas { ctx, size in
            let gridColor = Color.white.opacity(0.08)
            let cols = 8
            let rows = 6
            let cellW = size.width / CGFloat(cols)
            let cellH = size.height / CGFloat(rows)
            for c in 0...cols {
                let x = CGFloat(c) * cellW
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(gridColor), lineWidth: 0.5)
            }
            for r in 0...rows {
                let y = CGFloat(r) * cellH
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }, with: .color(gridColor), lineWidth: 0.5)
            }
        }
        .background(
            LinearGradient(
                colors: [Color(.darkGray).opacity(0.9), Color(.darkGray).opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var controlsSection: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $overlayEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Overlay Enabled")
                        Text("Show zone rectangles on canvas")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.grid.3x3.topleft.filled")
                        .foregroundStyle(.cyan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().padding(.leading, 52)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        Text("Opacity")
                    } icon: {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(.cyan)
                    }
                    Spacer()
                    Text("\(Int(opacity * 100))%")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.cyan)
                        .frame(width: 40, alignment: .trailing)
                }
                Slider(value: $opacity, in: 0.1...0.8, step: 0.05)
                    .tint(.cyan)
                    .disabled(!overlayEnabled)
                    .opacity(overlayEnabled ? 1 : 0.4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().padding(.leading, 52)

            Toggle(isOn: $showLabels) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show Zone Labels")
                        Text("Display zone names and SKU assignments")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "tag.fill")
                        .foregroundStyle(.cyan)
                }
            }
            .disabled(!overlayEnabled)
            .opacity(overlayEnabled ? 1 : 0.4)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var layoutPickerSection: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Shelf Layout", systemImage: "rectangle.3.group")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedLayout != nil {
                    Button("Clear") { selectedLayout = nil }
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            if layouts.isEmpty {
                HStack {
                    Text("No shelf layouts created yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            } else {
                ForEach(layouts) { layout in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            selectedLayout = selectedLayout?.id == layout.id ? nil : layout
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(layout.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text("\(layout.zones.count) zone\(layout.zones.count == 1 ? "" : "s") · \(layout.assignedZoneCount) assigned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedLayout?.id == layout.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if layout.id != layouts.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }

            Spacer(minLength: 0)
                .frame(height: 4)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var zoneListSection: some View {
        Group {
            if !activeZones.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Label("Zones", systemImage: "list.bullet.rectangle")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(activeZones.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    Divider()

                    ForEach(Array(activeZones.enumerated()), id: \.element.id) { idx, zone in
                        let color = overlayZoneColorFor(idx)
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(color, lineWidth: 1.5)
                                )
                                .frame(width: 28, height: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(zone.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(zone.isAssigned ? zone.assignmentLabel : "Unassigned")
                                    .font(.caption)
                                    .foregroundStyle(zone.isAssigned ? .secondary : .tertiary)
                            }

                            Spacer()

                            let r = zone.rect
                            Text("\(Int(r.x * 100))%,\(Int(r.y * 100))%")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                        if zone.id != activeZones.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }

                    Spacer(minLength: 0).frame(height: 4)
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 14))
            }
        }
    }

    private func overlayZoneColorFor(_ idx: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .cyan]
        return colors[idx % colors.count]
    }
}

private struct ZoneQuickEditSheet: View {
    @Bindable var zone: ShelfZone
    let isAdmin: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ProductSKU.name) private var skus: [ProductSKU]
    @Query(sort: \LookAlikeGroup.name) private var groups: [LookAlikeGroup]
    @State private var showSkuPicker = false
    @State private var showGroupPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("Zone Info") {
                    LabeledContent("Name", value: zone.name)
                    let r = zone.rect
                    LabeledContent("Position") {
                        Text("x:\(String(format: "%.2f", r.x)) y:\(String(format: "%.2f", r.y)) w:\(String(format: "%.2f", r.w)) h:\(String(format: "%.2f", r.h))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Assignment") {
                    if zone.isAssigned {
                        LabeledContent("Assigned To", value: zone.assignmentLabel)

                        if isAdmin {
                            Button(role: .destructive) {
                                zone.assignedSkuId = nil
                                zone.assignedGroupId = nil
                                zone.assignedSkuName = ""
                                zone.assignedGroupName = ""
                                try? modelContext.save()
                            } label: {
                                Label("Mark as Unassigned", systemImage: "xmark.circle")
                            }
                        }
                    } else {
                        Text("Unassigned")
                            .foregroundStyle(.secondary)
                    }

                    if isAdmin {
                        Button {
                            showSkuPicker = true
                        } label: {
                            Label("Assign SKU", systemImage: "shippingbox")
                        }

                        Button {
                            showGroupPicker = true
                        } label: {
                            Label("Assign Look-Alike Group", systemImage: "square.on.square")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(zone.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSkuPicker) {
                ZoneSkuPickerView(zone: zone, skus: skus)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showGroupPicker) {
                ZoneGroupPickerView(zone: zone, groups: groups)
                    .presentationDetents([.medium])
            }
        }
    }
}

private struct ZoneSkuPickerView: View {
    @Bindable var zone: ShelfZone
    let skus: [ProductSKU]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [ProductSKU] {
        guard !search.isEmpty else { return skus }
        return skus.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.sku.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { sku in
                Button {
                    zone.assignedSkuId = sku.id
                    zone.assignedSkuName = "\(sku.name) (\(sku.sku))"
                    zone.assignedGroupId = nil
                    zone.assignedGroupName = ""
                    try? modelContext.save()
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sku.name)
                            Text(sku.sku)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if zone.assignedSkuId == sku.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.cyan)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .searchable(text: $search, prompt: "Search SKUs")
            .navigationTitle("Assign SKU")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct ZoneGroupPickerView: View {
    @Bindable var zone: ShelfZone
    let groups: [LookAlikeGroup]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(groups) { group in
                Button {
                    zone.assignedGroupId = group.id
                    zone.assignedGroupName = group.name
                    zone.assignedSkuId = nil
                    zone.assignedSkuName = ""
                    try? modelContext.save()
                    dismiss()
                } label: {
                    HStack {
                        Text(group.name)
                        Spacer()
                        if zone.assignedGroupId == group.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.cyan)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Assign Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
