import SwiftUI

enum CSVImportType {
    case expected
    case onHand

    var title: String {
        switch self {
        case .expected: "Import Expected Counts"
        case .onHand: "Import Inventory On Hand"
        }
    }

    var qtyLabel: String {
        switch self {
        case .expected: "Expected Qty Column"
        case .onHand: "On-Hand Qty Column"
        }
    }

    var icon: String {
        switch self {
        case .expected: "doc.text.magnifyingglass"
        case .onHand: "cube.box.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .expected: .blue
        case .onHand: .teal
        }
    }
}

struct CSVImportDraft: Sendable {
    let filename: String
    let rawCSVText: String
    let parseResult: CSVParseResult
    let mapping: CSVColumnMapping
    let matchedCount: Int
    let unmatchedCount: Int
    let importType: CSVImportType
}

struct CSVColumnMapperView: View {
    let parseResult: CSVParseResult
    let skus: [ParsedSKUInfo]
    let importType: CSVImportType
    let onConfirm: (CSVImportDraft) -> Void
    let onCancel: () -> Void

    @State private var keyColumn: String = ""
    @State private var qtyColumn: String = ""
    @State private var locationColumn: String = ""
    @State private var zoneColumn: String = ""

    private var headers: [String] { parseResult.headers }
    private let noneOption = "— None —"

    private var allOptions: [String] { [noneOption] + headers }

    private var currentMapping: CSVColumnMapping {
        CSVColumnMapping(
            keyColumn: keyColumn,
            qtyColumn: qtyColumn,
            locationColumn: locationColumn.isEmpty || locationColumn == noneOption ? nil : locationColumn,
            zoneColumn: zoneColumn.isEmpty || zoneColumn == noneOption ? nil : zoneColumn
        )
    }

    private var previewMatches: [CSVRowMatch] {
        guard !keyColumn.isEmpty && keyColumn != noneOption,
              !qtyColumn.isEmpty && qtyColumn != noneOption else { return [] }
        let previewRows = Array(parseResult.rows.prefix(5))
        return CSVImportService.shared.applyMapping(rows: previewRows, mapping: currentMapping, skus: skus)
    }

    private var fullMatches: [CSVRowMatch] {
        guard !keyColumn.isEmpty && keyColumn != noneOption,
              !qtyColumn.isEmpty && qtyColumn != noneOption else { return [] }
        return CSVImportService.shared.applyMapping(rows: parseResult.rows, mapping: currentMapping, skus: skus)
    }

    private var matchedCount: Int { fullMatches.filter { $0.isMatched }.count }
    private var unmatchedCount: Int { fullMatches.filter { !$0.isMatched }.count }

    private var canConfirm: Bool {
        !keyColumn.isEmpty && keyColumn != noneOption &&
        !qtyColumn.isEmpty && qtyColumn != noneOption
    }

    var body: some View {
        NavigationStack {
            List {
                fileInfoSection
                columnMappingSection
                if canConfirm {
                    matchSummarySection
                }
                if canConfirm && !previewMatches.isEmpty {
                    previewSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(importType.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { confirm() }
                        .fontWeight(.semibold)
                        .disabled(!canConfirm)
                }
            }
            .onAppear { autoDetectColumns() }
        }
    }

    private var fileInfoSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: importType.icon)
                    .font(.title2)
                    .foregroundStyle(importType.accentColor)
                    .frame(width: 40, height: 40)
                    .background(importType.accentColor.opacity(0.12))
                    .clipShape(.rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(parseResult.filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(parseResult.rows.count) rows · \(headers.count) columns")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("File")
        }
    }

    private var columnMappingSection: some View {
        Section {
            columnPicker(title: "Key Column", subtitle: "SKU code or product name", icon: "key.fill", color: .orange, selection: $keyColumn, required: true)
            columnPicker(title: importType.qtyLabel, subtitle: "Numeric quantity", icon: "number.circle.fill", color: importType.accentColor, selection: $qtyColumn, required: true)
            columnPicker(title: "Shelf Column", subtitle: "Optional shelf filter", icon: "mappin.circle.fill", color: .purple, selection: $locationColumn, required: false)
            columnPicker(title: "Zone Column", subtitle: "Optional zone/section", icon: "square.grid.2x2.fill", color: .indigo, selection: $zoneColumn, required: false)
        } header: {
            Text("Map Columns")
        } footer: {
            Text("Key and Qty columns are required. Match SKU codes or product names to catalog items.")
                .font(.caption2)
        }
    }

    private func columnPicker(title: String, subtitle: String, icon: String, color: Color, selection: Binding<String>, required: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                    if required {
                        Text("*")
                            .foregroundStyle(.red)
                            .font(.caption.weight(.bold))
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("", selection: selection) {
                if !required {
                    Text(noneOption).tag(noneOption)
                }
                ForEach(headers, id: \.self) { h in
                    Text(h).tag(h)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var matchSummarySection: some View {
        Section {
            HStack(spacing: 16) {
                matchPill(value: matchedCount, label: "Matched", color: .green, icon: "checkmark.circle.fill")
                Divider().frame(height: 36)
                matchPill(value: unmatchedCount, label: "Unmatched", color: unmatchedCount > 0 ? .orange : .secondary, icon: "questionmark.circle.fill")
                Divider().frame(height: 36)
                matchPill(value: fullMatches.count, label: "Total Rows", color: .secondary, icon: "list.number")
            }
            .padding(.vertical, 4)
        } header: {
            Text("Catalog Match")
        } footer: {
            if unmatchedCount > 0 {
                Text("Unmatched rows are imported but won't guide classification. You can still proceed.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func matchPill(value: Int, label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewSection: some View {
        Section {
            ForEach(previewMatches.indices, id: \.self) { i in
                let match = previewMatches[i]
                HStack(spacing: 10) {
                    Image(systemName: match.isMatched ? "checkmark.circle.fill" : "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(match.isMatched ? .green : .orange)

                    Text(match.skuOrNameKey)
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()

                    Text("×\(match.qty)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Preview (first \(previewMatches.count) rows)")
        }
    }

    private func autoDetectColumns() {
        let lower = headers.map { $0.lowercased() }

        let keyHints = ["sku", "item", "product", "name", "key", "barcode", "upc", "code"]
        let qtyHints = ["qty", "quantity", "count", "expected", "on hand", "onhand", "units", "amount"]

        if keyColumn.isEmpty || keyColumn == noneOption {
            for hint in keyHints {
                if let idx = lower.firstIndex(where: { $0.contains(hint) }) {
                    keyColumn = headers[idx]
                    break
                }
            }
            if (keyColumn.isEmpty || keyColumn == noneOption), let first = headers.first {
                keyColumn = first
            }
        }

        if qtyColumn.isEmpty || qtyColumn == noneOption {
            for hint in qtyHints {
                if let idx = lower.firstIndex(where: { $0.contains(hint) }) {
                    if headers[idx] != keyColumn {
                        qtyColumn = headers[idx]
                        break
                    }
                }
            }
            if (qtyColumn.isEmpty || qtyColumn == noneOption), let second = headers.dropFirst().first {
                qtyColumn = second
            }
        }
    }

    private func confirm() {
        let matches = fullMatches
        let draft = CSVImportDraft(
            filename: parseResult.filename,
            rawCSVText: parseResult.rawText,
            parseResult: parseResult,
            mapping: currentMapping,
            matchedCount: matches.filter { $0.isMatched }.count,
            unmatchedCount: matches.filter { !$0.isMatched }.count,
            importType: importType
        )
        onConfirm(draft)
    }
}
