import SwiftUI
import SwiftData

/// Bag Audit Scan View — displays expected vs actual quantities per SKU.
/// Accepts barcode input from external hardware scanners (HID keyboard mode)
/// to increment the matching AuditLineItem.visionCount (actual quantity).
/// Also supports manual +/- buttons for each row.
///
/// Footer shows live totals: expected items, actual items, difference.
struct BagAuditScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ScannerConnectionService.self) private var scannerConnection
    @Environment(SessionSyncService.self) private var syncService
    @Environment(AuditCountService.self) private var countService
    let session: AuditSession

    // Barcode input router — auto-selects SDK or HID
    @State private var inputRouter: BarcodeInputRouter?

    // UI state
    @State private var lastScanResult: ScanResult? = nil
    @State private var showUnknown = false
    @State private var unknownCode = ""
    @State private var flashRowId: UUID? = nil

    private struct ScanResult: Identifiable {
        let id = UUID()
        let productName: String
        let newCount: Int
        let matched: Bool
    }

    // MARK: - Computed Totals

    /// All line items that have an expected qty set (from ExpectedSnapshot)
    private var rows: [AuditLineItem] {
        session.lineItems.sorted { a, b in
            let aName = a.skuNameSnapshot.lowercased()
            let bName = b.skuNameSnapshot.lowercased()
            return aName < bName
        }
    }

    private var totalExpected: Int {
        rows.reduce(0) { $0 + ($1.expectedQty ?? 0) }
    }

    private var totalActual: Int {
        rows.reduce(0) { $0 + $1.visionCount }
    }

    private var totalDiff: Int { totalActual - totalExpected }

    private var matchedCount: Int {
        rows.filter { item in
            guard let exp = item.expectedQty, exp > 0 else { return false }
            return item.visionCount == exp
        }.count
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    if rows.isEmpty {
                        emptyState
                    } else {
                        rowList
                    }

                    footerTotals
                }

                // Hidden UIKit host for barcode input (SDK or HID)
                if let router = inputRouter {
                    BarcodeInputHostView(router: router)
                        .frame(width: 0, height: 0)
                }
            }
            .navigationTitle("Bag Audit Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    scannerStatusBadge
                }
            }
            .overlay(alignment: .top) {
                scanFeedbackBanner
            }
            .onAppear {
                let router = BarcodeInputRouter(connectionService: scannerConnection)
                router.onBarcodeScanned = { code in
                    handleBarcode(code)
                }
                inputRouter = router
            }
            .onDisappear {
                inputRouter?.deactivate()
            }
            .animation(.spring(response: 0.35), value: lastScanResult?.id)
            .animation(.spring(response: 0.35), value: showUnknown)
        }
    }

    // MARK: - Row List

    private var rowList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Column header
                    columnHeader
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))

                    Divider()

                    ForEach(rows) { item in
                        BagAuditRow(
                            item: item,
                            isFlashing: flashRowId == item.id,
                            onIncrement: {
                                incrementItem(item)
                            },
                            onDecrement: {
                                decrementItem(item)
                            }
                        )
                        .id(item.id)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .onChange(of: flashRowId) { _, newId in
                if let newId {
                    withAnimation { proxy.scrollTo(newId, anchor: .center) }
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Product")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Exp")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .center)
            Text("Act")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .center)
            Text("Diff")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .center)
            // +/- buttons space
            Spacer().frame(width: 72)
        }
    }

    // MARK: - Footer Totals

    private var footerTotals: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                totalChip(label: "Expected", value: totalExpected, color: .secondary)
                totalChip(label: "Actual", value: totalActual, color: totalActual > 0 ? .blue : .secondary)
                Spacer()
                diffChip(diff: totalDiff)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground))
        }
    }

    private func totalChip(label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func diffChip(diff: Int) -> some View {
        let color: Color = diff == 0 ? .green : (diff > 0 ? .orange : .red)
        let icon = diff == 0 ? "checkmark.circle.fill" : (diff > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(diff == 0 ? "Match" : (diff > 0 ? "+\(diff)" : "\(diff)"))
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Scan Feedback Banner

    @ViewBuilder
    private var scanFeedbackBanner: some View {
        if let result = lastScanResult, result.matched {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.productName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Count → \(result.newCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if showUnknown {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Unknown Barcode")
                        .font(.subheadline.weight(.semibold))
                    Text(unknownCode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Scanner Status Badge

    private var scannerStatusBadge: some View {
        let mode = inputRouter?.activeMode ?? .none
        let isOn = mode != .none
        let label = isOn ? (mode == .sdk ? "SDK" : "HID") : "Off"
        return HStack(spacing: 4) {
            Circle()
                .fill(isOn ? .cyan : .gray)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isOn ? .cyan : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isOn ? Color.cyan : Color.gray).opacity(0.1), in: Capsule())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("No Audit Rows Yet")
                    .font(.title3.weight(.semibold))
                Text("Run an audit or import expected quantities\nto populate this view.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Barcode Handling

    private func handleBarcode(_ code: String) {
        // 1. Look up ProductSKU by barcode field
        let descriptor = FetchDescriptor<ProductSKU>()
        let allSKUs = (try? modelContext.fetch(descriptor)) ?? []
        guard let matchedSKU = allSKUs.first(where: { $0.barcode == code }) else {
            // Unknown barcode
            unknownCode = code
            showUnknown = true
            lastScanResult = nil
            TTSService.shared.speakUnknownBarcode(code)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                showUnknown = false
            }
            return
        }

        // 2. Record count via unified service
        let lineItem = countService.recordCount(
            session: session,
            skuId: matchedSKU.id,
            skuName: matchedSKU.productName,
            quantity: 1,
            sourceType: .barcode,
            context: modelContext
        )

        flashRowId = lineItem.id
        showUnknown = false
        lastScanResult = ScanResult(
            productName: lineItem.skuNameSnapshot,
            newCount: lineItem.visionCount,
            matched: true
        )
        TTSService.shared.speakBarcodeScan(productName: lineItem.skuNameSnapshot)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if lastScanResult?.matched == true { lastScanResult = nil }
            try? await Task.sleep(for: .milliseconds(200))
            flashRowId = nil
        }
    }

    // MARK: - Manual Increment / Decrement

    private func incrementItem(_ item: AuditLineItem) {
        countService.recordCount(
            session: session,
            skuId: item.skuId,
            skuName: item.skuNameSnapshot,
            quantity: 1,
            sourceType: .barcode,
            context: modelContext
        )
    }

    private func decrementItem(_ item: AuditLineItem) {
        guard item.visionCount > 0 else { return }
        countService.recordCount(
            session: session,
            skuId: item.skuId,
            skuName: item.skuNameSnapshot,
            quantity: -1,
            sourceType: .barcode,
            context: modelContext
        )
    }
}

// MARK: - Bag Audit Row

struct BagAuditRow: View {
    @Bindable var item: AuditLineItem
    let isFlashing: Bool
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    private var diff: Int? {
        guard let expected = item.expectedQty else { return nil }
        return item.visionCount - expected
    }

    private var diffColor: Color {
        guard let d = diff else { return .secondary }
        if d == 0 { return .green }
        return d > 0 ? .orange : .red
    }

    var body: some View {
        HStack(spacing: 0) {
            // Product name
            VStack(alignment: .leading, spacing: 2) {
                Text(item.skuNameSnapshot)
                    .font(.subheadline)
                    .lineLimit(2)
                if item.reviewStatus == .pending {
                    Label("Pending", systemImage: "clock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Expected qty
            Text(item.expectedQty.map { "\($0)" } ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .center)

            // Actual qty (visionCount)
            Text("\(item.visionCount)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 44, alignment: .center)

            // Difference
            Group {
                if let d = diff {
                    Text(d == 0 ? "✓" : (d > 0 ? "+\(d)" : "\(d)"))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(diffColor)
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, alignment: .center)

            // +/- buttons
            HStack(spacing: 4) {
                Button(action: onDecrement) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(item.visionCount == 0)
                .opacity(item.visionCount == 0 ? 0.3 : 1)

                Button(action: onIncrement) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 72, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isFlashing ? Color.cyan.opacity(0.12) : Color.clear)
        .animation(.easeOut(duration: 0.3), value: isFlashing)
    }
}
