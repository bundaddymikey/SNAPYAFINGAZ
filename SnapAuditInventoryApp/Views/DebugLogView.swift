import SwiftUI

/// Debug log viewer — shows recent recognition events, review decisions, and errors.
/// Access via Settings or hidden gesture on Dashboard.
struct DebugLogView: View {
    @State private var logger = AuditLogger.shared
    @State private var selectedCategory: AuditLogger.LogEntry.Category? = nil

    private var filteredEntries: [AuditLogger.LogEntry] {
        if let cat = selectedCategory {
            return logger.entries.filter { $0.category == cat }.reversed()
        }
        return logger.entries.reversed()
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        DebugFilterChip(label: "All", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(AuditLogger.LogEntry.Category.allCases, id: \.rawValue) { cat in
                            DebugFilterChip(
                                label: cat.rawValue,
                                icon: cat.icon,
                                isSelected: selectedCategory == cat
                            ) {
                                selectedCategory = (selectedCategory == cat) ? nil : cat
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No Log Entries",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Recognition and review events will appear here as you use the app.")
                )
            } else {
                Section("Entries (\(filteredEntries.count))") {
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.category.icon)
                                .font(.caption)
                                .foregroundStyle(iconColor(entry.category))
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Text(entry.formattedTimestamp)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { logger.clear() }
                    .foregroundStyle(.red)
            }
        }
    }

    private func iconColor(_ category: AuditLogger.LogEntry.Category) -> Color {
        switch category {
        case .recognition: .blue
        case .review: .green
        case .session: .indigo
        case .error: .red
        case .info: .secondary
        }
    }
}

private struct DebugFilterChip: View {
    let label: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
