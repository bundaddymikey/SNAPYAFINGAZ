import SwiftUI
import SwiftData

struct LocationDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let location: Location

    @Query private var allLayouts: [ShelfLayout]
    @State private var showAddLayout = false
    @State private var showDeleteAlert = false
    @State private var layoutToDelete: ShelfLayout?

    private var layouts: [ShelfLayout] {
        allLayouts
            .filter { $0.locationId == location.id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            locationInfoSection
            layoutsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddLayout = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddLayout) {
            ShelfLayoutFormView(locationId: location.id)
        }
        .navigationDestination(for: ShelfLayout.self) { layout in
            ShelfDetailView(layout: layout)
        }
        .alert("Delete Layout?", isPresented: $showDeleteAlert, presenting: layoutToDelete) { layout in
            Button("Delete", role: .destructive) { deleteLayout(layout) }
            Button("Cancel", role: .cancel) {}
        } message: { layout in
            Text("This will permanently delete \"\(layout.name)\" and all its zones.")
        }
    }

    private var locationInfoSection: some View {
        Section("Shelf") {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(location.name)
                        .font(.body.weight(.semibold))
                    if !location.notes.isEmpty {
                        Text(location.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(location.productLinks.count) linked product\(location.productLinks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var layoutsSection: some View {
        Section {
            if layouts.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No Shelf Layouts")
                            .font(.subheadline.weight(.medium))
                        Text("Tap + to define zones for faster, focused audits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            } else {
                ForEach(layouts) { layout in
                    NavigationLink(value: layout) {
                        LayoutSummaryRow(layout: layout)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            layoutToDelete = layout
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Shelf Layouts")
        } footer: {
            Text("Layouts define zones on a shelf face. Assign a SKU or Look-Alike Group to each zone to narrow classification during audits.")
                .font(.caption2)
        }
    }

    private func deleteLayout(_ layout: ShelfLayout) {
        modelContext.delete(layout)
        try? modelContext.save()
    }
}

private struct LayoutSummaryRow: View {
    let layout: ShelfLayout

    private var zoneCount: Int { layout.zones.count }
    private var assignedCount: Int { layout.zones.filter { $0.isAssigned }.count }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "rectangle.split.3x1")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(layout.name)
                    .font(.body.weight(.medium))
                if !layout.notes.isEmpty {
                    Text(layout.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Label("\(zoneCount) zone\(zoneCount == 1 ? "" : "s")", systemImage: "square.grid.2x2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if assignedCount > 0 {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(assignedCount) assigned")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
