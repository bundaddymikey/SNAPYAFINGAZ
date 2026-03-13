import SwiftUI
import SwiftData

// MARK: - Live Review Fallback View

/// Lightweight review screen for uncertain live-scan detections.
/// Operator confirms, chooses alternate, marks unknown, or dismisses each item.
struct LiveReviewFallbackView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AuditCountService.self) private var countService

    let session: AuditSession
    let store: LiveReviewFallbackStore

    @State private var showAlternatePicker = false
    @State private var pickerItem: LiveScanFallbackItem? = nil
    @State private var resolvedCount = 0

    private var items: [LiveScanFallbackItem] { store.pendingItems }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if items.isEmpty {
                    allClearState
                } else {
                    VStack(spacing: 0) {
                        progressHeader
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)

                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(items) { item in
                                    fallbackCard(item)
                                        .padding(.horizontal, 16)
                                }
                            }
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationTitle("Review Uncertain Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !items.isEmpty {
                        Text("\(items.count) remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Progress

    private var progressHeader: some View {
        let total = resolvedCount + items.count
        let progress = total > 0 ? Double(resolvedCount) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(resolvedCount) of \(total) resolved")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            ProgressView(value: progress)
                .tint(.blue)
        }
    }

    // MARK: - All Clear

    private var allClearState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("All items reviewed")
                .font(.title3.bold())
            Text("\(resolvedCount) item\(resolvedCount == 1 ? "" : "s") processed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Fallback Card

    private func fallbackCard(_ item: LiveScanFallbackItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header: crop image + top candidate
            HStack(alignment: .top, spacing: 12) {
                cropThumbnail(item.bestCropImage)

                VStack(alignment: .leading, spacing: 4) {
                    if let name = item.suggestedSkuName {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    } else {
                        Text("Unknown product")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    // Confidence bar
                    HStack(spacing: 6) {
                        ProgressView(value: Double(item.confidenceScore))
                            .tint(confidenceColor(item.confidenceScore))
                            .frame(width: 80)
                        Text(String(format: "%.0f%%", item.confidenceScore * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    // Reason flags
                    FlowRow(spacing: 4) {
                        ForEach(item.reasonFlags, id: \.self) { reason in
                            flagBadge(reason)
                        }
                    }

                    if item.mergeCount > 1 {
                        Text("·  \(item.mergeCount) frames merged")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            Divider()

            // Alternate candidates (if any)
            if item.candidates.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Other candidates")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)

                    ForEach(item.candidates.dropFirst()) { candidate in
                        Button {
                            confirmItem(item, skuId: candidate.skuId, skuName: candidate.skuName)
                        } label: {
                            HStack {
                                Text(candidate.skuName)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(String(format: "%.0f%%", candidate.confidence * 100))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 8)
                Divider()
            }

            // Action buttons
            HStack(spacing: 0) {
                // Dismiss
                actionButton(
                    label: "Ignore",
                    icon: "xmark",
                    color: .secondary
                ) {
                    store.dismiss(item: item)
                    resolvedCount += 1
                }

                Divider().frame(height: 44)

                // Confirm suggested
                if let skuId = item.suggestedSkuId, let skuName = item.suggestedSkuName {
                    actionButton(
                        label: "Count It",
                        icon: "plus.circle.fill",
                        color: .blue
                    ) {
                        confirmItem(item, skuId: skuId, skuName: skuName)
                    }
                } else {
                    actionButton(
                        label: "Mark Unknown",
                        icon: "questionmark.circle",
                        color: .orange
                    ) {
                        store.dismiss(item: item)
                        resolvedCount += 1
                    }
                }
            }
            .frame(height: 44)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Confirm helper

    private func confirmItem(_ item: LiveScanFallbackItem, skuId: UUID, skuName: String) {
        let _ = store.confirm(item: item, skuId: skuId, skuName: skuName)
        countService.recordCount(
            session: session,
            skuId: skuId,
            skuName: skuName,
            quantity: 1,
            confidence: Double(item.confidenceScore),
            sourceType: .liveCamera,
            context: modelContext
        )
        resolvedCount += 1
    }

    // MARK: - Components

    private func cropThumbnail(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemGroupedBackground))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private func flagBadge(_ reason: LiveFallbackReason) -> some View {
        HStack(spacing: 3) {
            Image(systemName: reason.icon)
                .font(.system(size: 9))
            Text(reason.label)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .foregroundStyle(.orange)
    }

    private func actionButton(
        label: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func confidenceColor(_ confidence: Float) -> Color {
        if confidence >= 0.55 { return .orange }
        if confidence >= 0.35 { return .yellow }
        return .red
    }
}

// MARK: - Flow Row (simple wrapping HStack)

struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 200
        var height: CGFloat = 0
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                height += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Review Badge (shown during scanning)

/// Compact badge shown in LiveScanView when uncertain items are queued.
struct LiveReviewBadge: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Text("\(count) need\(count == 1 ? "s" : "") review")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}
