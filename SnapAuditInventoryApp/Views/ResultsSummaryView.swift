import SwiftUI

enum LineItemFilter: String, CaseIterable {
    case all = "All"
    case needsReview = "Needs Review"
    case mismatchExpected = "vs Expected"
    case mismatchOnHand = "vs On Hand"
    case lowConfidence = "Low Confidence"
    case outsideSelectedBrand = "Stragglers"
}

struct ResultsSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    let session: AuditSession
    let auditViewModel: AuditViewModel
    let onDismiss: () -> Void

    @State private var filter: LineItemFilter = .all
    @State private var showReviewQueue = false
    @State private var showDoneAlert = false
    @State private var showMismatchReport = false
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var showExportOptions = false
    @State private var showCopiedBanner = false
    @State private var ttsService = TTSService.shared
    private var csvCache: String { CSVExportService.shared.exportSession(session) }

    private var filteredItems: [AuditLineItem] {
        let items = session.lineItems.sorted { $0.createdAt < $1.createdAt }
        switch filter {
        case .all: return items
        case .needsReview: return items.filter { $0.reviewStatus == .pending }
        case .mismatchExpected: return items.filter { mismatchesExpected($0) }
        case .mismatchOnHand: return items.filter { mismatchesOnHand($0) }
        case .lowConfidence: return items.filter { $0.countConfidence < 0.60 && $0.countConfidence > 0 }
        case .outsideSelectedBrand: return items.filter { $0.flagReasons.contains(.outsideSelectedBrand) }
        }
    }

    private var pendingCount: Int { session.pendingLineItemCount }
    private var totalCount: Int { session.totalItemCount }
    private var mismatchCount: Int { session.mismatchCount }

    private func filterCount(_ f: LineItemFilter) -> Int {
        let items = session.lineItems
        switch f {
        case .all: return items.count
        case .needsReview: return items.filter { $0.reviewStatus == .pending }.count
        case .mismatchExpected: return items.filter { mismatchesExpected($0) }.count
        case .mismatchOnHand: return items.filter { mismatchesOnHand($0) }.count
        case .lowConfidence: return items.filter { $0.countConfidence < 0.60 && $0.countConfidence > 0 }.count
        case .outsideSelectedBrand: return items.filter { $0.flagReasons.contains(.outsideSelectedBrand) }.count
        }
    }

    private func mismatchesExpected(_ item: AuditLineItem) -> Bool {
        guard item.expectedQty != nil else { return false }
        return item.flagReasons.contains { [.shortage, .overage, .expectedZeroButFound, .largeVariance].contains($0) }
    }

    private func mismatchesOnHand(_ item: AuditLineItem) -> Bool {
        guard let oh = item.posOnHand, let delta = item.deltaOnHand else { return false }
        return abs(delta) > 0 && oh >= 0
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if session.hasExpectedData || session.hasOnHandData {
                reconciliationBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            filterPicker
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if filteredItems.isEmpty {
                emptyState
            } else {
                lineItemsList
            }

            if pendingCount > 0 {
                reviewBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Audit Results")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 12) {
                    Button {
                        showExportOptions = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Button {
                        if ttsService.isSpeaking {
                            ttsService.stopSpeaking()
                        } else {
                            let items = filteredItems.map { (name: $0.skuNameSnapshot, count: $0.visionCount) }
                            ttsService.speakAllResults(items: items)
                        }
                    } label: {
                        Image(systemName: ttsService.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(ttsService.isSpeaking ? .red : .blue)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { showDoneAlert = true }
                    .fontWeight(.semibold)
            }
        }
        .alert("Finish Audit?", isPresented: $showDoneAlert) {
            Button("Finish") { onDismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if pendingCount > 0 {
                Text("\(pendingCount) item(s) still need review. You can review them later from Audit History.")
            } else {
                Text("All items have been reviewed. The audit will be saved.")
            }
        }
        .sheet(isPresented: $showReviewQueue) {
            ReviewQueueView(session: session, auditViewModel: auditViewModel)
        }
        .sheet(isPresented: $showMismatchReport) {
            MismatchReportView(session: session)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
        .confirmationDialog("Export Audit CSV", isPresented: $showExportOptions, titleVisibility: .visible) {
            Button("Share…") { exportCSV() }
            Button("Copy to Clipboard") { copyCSVToClipboard() }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .top) {
            if showCopiedBanner {
                Label("Copied to Clipboard", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.green, in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35), value: showCopiedBanner)
        .task {
            if session.hasExpectedData || session.hasOnHandData {
                auditViewModel.reReconcile(session: session)
            }
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 12) {
            summaryPill(value: "\(session.lineItems.count)", label: "SKUs", color: .blue)
            summaryPill(value: "\(totalCount)", label: "Items", color: .green)
            summaryPill(value: "\(pendingCount)", label: "Pending", color: pendingCount > 0 ? .orange : .secondary)
            if mismatchCount > 0 {
                summaryPill(value: "\(mismatchCount)", label: "Mismatch", color: .red)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: session.mode.icon)
                        .font(.caption2)
                    Text(session.mode.displayName)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: session.captureQualityMode.icon)
                        .font(.caption2)
                    Text(session.captureQualityMode.badgeTitle)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(session.captureQualityMode == .highAccuracy ? .mint : .secondary)

                let assessment = session.captureQualityAssessment
                if assessment.score > 0 {
                    let badge = assessment.qualityBadge
                    let badgeColor: Color = badge == .excellent ? .green : (badge == .good ? .yellow : .orange)
                    HStack(spacing: 4) {
                        Image(systemName: badge.icon)
                            .font(.caption2)
                        Text(badge.rawValue)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(badgeColor)
                }

                if session.recognitionScope == .brandLimited, !session.mainBrand.isEmpty {
                    let brands = session.secondaryBrand.isEmpty
                        ? session.mainBrand
                        : "\(session.mainBrand) + \(session.secondaryBrand)"
                    HStack(spacing: 4) {
                        Image(systemName: "building.2.fill")
                            .font(.caption2)
                        Text("Brand: \(brands)")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.purple)
                }

                Text(session.locationName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func summaryPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 44)
    }

    private var reconciliationBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if session.hasExpectedData {
                        dataChip(icon: "doc.text.magnifyingglass", label: session.expectedSnapshot?.sourceFilename ?? "Expected", color: .blue)
                    }
                    if session.hasOnHandData {
                        dataChip(icon: "cube.box.fill", label: session.inventorySnapshot?.sourceFilename ?? "On Hand", color: .teal)
                    }
                }
                if mismatchCount > 0 {
                    Text("\(mismatchCount) mismatch\(mismatchCount == 1 ? "" : "es") detected")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            if mismatchCount > 0 {
                Button {
                    showMismatchReport = true
                } label: {
                    Text("Report")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.red, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(mismatchCount > 0 ? .red.opacity(0.25) : .blue.opacity(0.2), lineWidth: 1)
        }
    }

    private func dataChip(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
    }

    private var filterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableFilters, id: \.self) { f in
                    let count = filterCount(f)
                    Button {
                        withAnimation(.spring(response: 0.3)) { filter = f }
                    } label: {
                        HStack(spacing: 4) {
                            Text(f.rawValue)
                                .font(.subheadline.weight(filter == f ? .semibold : .regular))
                            if count > 0 && f != .all {
                                Text("\(count)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(filter == f ? .white.opacity(0.3) : Color(.tertiarySystemGroupedBackground), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(filter == f ? filterColor(f) : Color(.secondarySystemGroupedBackground), in: Capsule())
                        .foregroundStyle(filter == f ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var availableFilters: [LineItemFilter] {
        var filters: [LineItemFilter] = [.all, .needsReview]
        if session.hasExpectedData { filters.append(.mismatchExpected) }
        if session.hasOnHandData { filters.append(.mismatchOnHand) }
        filters.append(.lowConfidence)
        return filters
    }

    private func filterColor(_ f: LineItemFilter) -> Color {
        switch f {
        case .all: .blue
        case .needsReview: .orange
        case .mismatchExpected: .red
        case .mismatchOnHand: .purple
        case .lowConfidence: .red
        case .outsideSelectedBrand: .gray
        }
    }

    private var lineItemsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredItems) { item in
                    LineItemRow(item: item, showReconciliation: session.hasExpectedData || session.hasOnHandData)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            TTSService.shared.speakLineItem(name: item.skuNameSnapshot, count: item.visionCount)
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, pendingCount > 0 ? 100 : 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No items match this filter")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewBanner: some View {
        Button {
            showReviewQueue = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Review \(pendingCount) Pending Item\(pendingCount == 1 ? "" : "s")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to resolve uncertain detections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func exportCSV() {
        let csv = CSVExportService.shared.exportSession(session)
        let filename = "SnapAudit_\(session.locationName)_\(session.createdAt.formatted(.dateTime.year().month().day())).csv"
            .replacingOccurrences(of: " ", with: "_")
        if let url = CSVExportService.shared.writeToTempFile(csv, filename: filename) {
            exportURL = url
            showShareSheet = true
        }
    }

    private func copyCSVToClipboard() {
        let csv = CSVExportService.shared.exportSession(session)
        UIPasteboard.general.string = csv
        withAnimation { showCopiedBanner = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run { withAnimation { showCopiedBanner = false } }
        }
    }
}

struct LineItemRow: View {
    let item: AuditLineItem
    var showReconciliation: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                confidenceIndicator

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.skuNameSnapshot)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        if item.isSoftAssigned {
                            Image(systemName: "wand.and.sparkles")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(visionFlags.prefix(3), id: \.self) { reason in
                            FlagBadge(reason: reason)
                        }
                        if visionFlags.count > 3 {
                            Text("+\(visionFlags.count - 3)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(item.visionCount)")
                        .font(.title3.bold().monospacedDigit())

                    HStack(spacing: 3) {
                        if item.pendingEvidenceCount > 0 {
                            Text("\(item.pendingEvidenceCount) pending")
                                .font(.system(size: 10).weight(.medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.12), in: Capsule())
                        } else {
                            Image(systemName: item.reviewStatus.icon)
                                .font(.caption2)
                                .foregroundStyle(reviewStatusColor)
                            Text(item.reviewStatus.displayName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(reviewStatusColor)
                        }
                    }
                }
            }

            if showReconciliation && (item.expectedQty != nil || item.posOnHand != nil) {
                Divider()
                    .padding(.vertical, 6)
                reconciliationRow
            }

            if !mismatchFlags.isEmpty {
                reconciliationFlags
                    .padding(.top, showReconciliation ? 0 : 6)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var visionFlags: [FlagReason] { item.flagReasons.filter { !$0.isMismatch } }
    private var mismatchFlags: [FlagReason] { item.mismatchFlags }

    private var reconciliationRow: some View {
        HStack(spacing: 12) {
            if let expected = item.expectedQty {
                reconCell(label: "Expected", value: "\(expected)", delta: item.delta, color: .blue)
            }
            if let onHand = item.posOnHand {
                reconCell(label: "On Hand", value: "\(onHand)", delta: item.deltaOnHand, color: .teal)
            }
            Spacer()
        }
    }

    private func reconCell(label: String, value: String, delta: Int?, color: Color) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            if let d = delta, d != 0 {
                Text(d > 0 ? "+\(d)" : "\(d)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(d > 0 ? .orange : .red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background((d > 0 ? Color.orange : Color.red).opacity(0.1), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.07), in: .rect(cornerRadius: 8))
    }

    private var reconciliationFlags: some View {
        HStack(spacing: 6) {
            ForEach(mismatchFlags, id: \.self) { reason in
                FlagBadge(reason: reason)
            }
            Spacer()
        }
    }

    private var confidenceIndicator: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 3)
                .frame(width: 36, height: 36)
            Circle()
                .trim(from: 0, to: item.countConfidence)
                .stroke(item.confidenceTier.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 36, height: 36)
                .rotationEffect(.degrees(-90))
            Text(item.confidenceTier.label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(item.confidenceTier.color)
        }
    }

    private var reviewStatusColor: Color {
        switch item.reviewStatus {
        case .confirmed: .green
        case .pending: .orange
        case .rejected: .red
        }
    }
}

struct FlagBadge: View {
    let reason: FlagReason

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: reason.icon)
                .font(.system(size: 9))
            Text(reason.label)
                .font(.system(size: 10))
        }
        .foregroundStyle(reason.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(reason.color.opacity(0.1), in: Capsule())
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
