import SwiftUI
import SwiftData

/// Displays the details of a ShelfLayout:
/// - Shelf metadata (name, last expected sheet update, last audit date)
/// - Searchable, sortable list of expected inventory rows
///
/// Navigation: LocationDetailView → ShelfDetailView → ShelfLayoutEditorView
struct ShelfDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var layout: ShelfLayout

    // AuditSession query to find the last audit date for this layout
    @Query(sort: \AuditSession.createdAt, order: .reverse)
    private var allSessions: [AuditSession]

    // Search + Sort
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .productName

    enum SortOrder: String, CaseIterable, Identifiable {
        case brand = "Brand"
        case productName = "Product Name"
        case expectedQty = "Expected Qty"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .brand: "building.2"
            case .productName: "a.circle"
            case .expectedQty: "number.circle"
            }
        }
    }

    // MARK: - Derived

    private var lastAuditDate: Date? {
        allSessions.first { $0.selectedLayoutId == layout.id }?.createdAt
    }

    private var filteredRows: [ShelfExpectedRow] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let base: [ShelfExpectedRow] = q.isEmpty
            ? layout.expectedRows
            : layout.expectedRows.filter {
                $0.productName.localizedCaseInsensitiveContains(q) ||
                $0.brand.localizedCaseInsensitiveContains(q) ||
                $0.barcode.localizedCaseInsensitiveContains(q) ||
                $0.productId.localizedCaseInsensitiveContains(q)
            }

        return base.sorted { a, b in
            switch sortOrder {
            case .brand:
                let bc = a.brand.localizedCaseInsensitiveCompare(b.brand)
                if bc != .orderedSame { return bc == .orderedAscending }
                return a.productName.localizedCaseInsensitiveCompare(b.productName) == .orderedAscending
            case .productName:
                return a.productName.localizedCaseInsensitiveCompare(b.productName) == .orderedAscending
            case .expectedQty:
                return a.expectedQty > b.expectedQty
            }
        }
    }

    // MARK: - Body

    var body: some View {
        List {
            metaSection
            inventorySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(layout.name)
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search product, brand, barcode…"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Label(order.rawValue, systemImage: order.icon).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                        .labelStyle(.iconOnly)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ShelfLayoutEditorView(layout: layout)
                } label: {
                    Label("Edit Zones", systemImage: "rectangle.split.3x1")
                        .labelStyle(.iconOnly)
                }
            }
        }
    }

    // MARK: - Meta Section

    private var metaSection: some View {
        Section {
            // Shelf name + zone summary
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "rectangle.split.3x1")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(layout.name)
                        .font(.body.weight(.semibold))
                    Text("\(layout.zones.count) zone\(layout.zones.count == 1 ? "" : "s") · \(layout.assignedZoneCount) assigned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !layout.notes.isEmpty {
                        Text(layout.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 3)

            // Last expected sheet update
            HStack {
                Label("Expected Sheet", systemImage: "tablecells")
                    .foregroundStyle(.secondary)
                Spacer()
                if let updated = layout.lastExpectedSheetUpdatedAt {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(updated, style: .date)
                            .font(.caption.weight(.medium))
                        Text(updated, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Not uploaded")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)

            // Last audit date
            HStack {
                Label("Last Audit", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastAudit = lastAuditDate {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(lastAudit, style: .date)
                            .font(.caption.weight(.medium))
                        Text(lastAudit, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("No audits yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
        } header: {
            Text("Shelf Info")
        }
    }

    // MARK: - Inventory Section

    @ViewBuilder
    private var inventorySection: some View {
        Section {
            if layout.expectedRows.isEmpty {
                // Empty state
                HStack(spacing: 14) {
                    Image(systemName: "tablecells.badge.ellipsis")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No Expected Inventory")
                            .font(.subheadline.weight(.medium))
                        Text("Upload a CSV to define expected counts for this shelf.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            } else if filteredRows.isEmpty {
                Text("No results for \"\(searchText)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                // Column header
                columnHeader

                ForEach(filteredRows) { row in
                    ExpectedInventoryRow(row: row)
                }
            }
        } header: {
            HStack {
                Text("Expected Inventory")
                Spacer()
                if !layout.expectedRows.isEmpty {
                    Text("\(filteredRows.count) of \(layout.expectedRows.count) items · \(layout.totalExpectedQty) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if let filename = layout.expectedInventoryFilename, !filename.isEmpty {
                Text("Source: \(filename)")
                    .font(.caption2)
            }
        }
    }

    // MARK: - Column Header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Product")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Barcode")
                .frame(width: 110, alignment: .leading)
            Text("Qty")
                .frame(width: 40, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }
}

// MARK: - Expected Inventory Row

private struct ExpectedInventoryRow: View {
    let row: ShelfExpectedRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Brand + match badge
            HStack(spacing: 6) {
                if !row.brand.isEmpty {
                    Text(row.brand)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1), in: Capsule())
                }
                if row.isMatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Expected Qty — prominent
                Text("\(row.expectedQty)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            // Product Name
            Text(row.productName.isEmpty ? "Unknown Product" : row.productName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(row.productName.isEmpty ? .secondary : .primary)

            // Product ID + Barcode metadata row
            HStack(spacing: 12) {
                if !row.productId.isEmpty {
                    Label(row.productId, systemImage: "tag")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !row.barcode.isEmpty {
                    Label(row.barcode, systemImage: "barcode")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
