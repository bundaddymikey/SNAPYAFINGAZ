import SwiftUI

struct MismatchReportView: View {
    let session: AuditSession
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var showExportOptions = false
    @State private var showCopiedBanner = false

    private var shortages: [AuditLineItem] {
        session.lineItems.filter { $0.flagReasons.contains(.shortage) }
            .sorted { ($0.delta ?? 0) < ($1.delta ?? 0) }
    }

    private var overages: [AuditLineItem] {
        session.lineItems.filter { $0.flagReasons.contains(.overage) }
            .sorted { ($0.delta ?? 0) > ($1.delta ?? 0) }
    }

    private var unexpected: [AuditLineItem] {
        session.lineItems.filter { $0.flagReasons.contains(.expectedZeroButFound) }
    }

    private var largeVariance: [AuditLineItem] {
        session.lineItems.filter {
            $0.flagReasons.contains(.largeVariance) &&
            !$0.flagReasons.contains(.shortage) &&
            !$0.flagReasons.contains(.overage)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if !shortages.isEmpty {
                        MismatchSectionHeader(
                            title: "Shortages",
                            subtitle: "Vision count below expected",
                            icon: "arrow.down.circle.fill",
                            color: .red,
                            count: shortages.count
                        )
                        .padding(.horizontal, 16)

                        VStack(spacing: 6) {
                            ForEach(shortages) { item in
                                ShortageRow(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    if !overages.isEmpty {
                        MismatchSectionHeader(
                            title: "Overages",
                            subtitle: "Vision count above expected",
                            icon: "arrow.up.circle.fill",
                            color: .orange,
                            count: overages.count
                        )
                        .padding(.horizontal, 16)

                        VStack(spacing: 6) {
                            ForEach(overages) { item in
                                OverageRow(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    if !unexpected.isEmpty {
                        MismatchSectionHeader(
                            title: "Unexpected Items",
                            subtitle: "Not expected but found",
                            icon: "exclamationmark.triangle.fill",
                            color: .red,
                            count: unexpected.count
                        )
                        .padding(.horizontal, 16)

                        VStack(spacing: 6) {
                            ForEach(unexpected) { item in
                                UnexpectedRow(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    if !largeVariance.isEmpty {
                        MismatchSectionHeader(
                            title: "Large Variance",
                            subtitle: "Abs delta > 1 and > 10%",
                            icon: "chart.line.uptrend.xyaxis",
                            color: .purple,
                            count: largeVariance.count
                        )
                        .padding(.horizontal, 16)

                        VStack(spacing: 6) {
                            ForEach(largeVariance) { item in
                                VarianceRow(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    if shortages.isEmpty && overages.isEmpty && unexpected.isEmpty && largeVariance.isEmpty {
                        noMismatchState
                    }

                    Spacer(minLength: 24)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mismatch Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showExportOptions = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .confirmationDialog("Export Mismatch Report", isPresented: $showExportOptions, titleVisibility: .visible) {
                Button("Share…") { exportReport() }
                Button("Copy to Clipboard") { copyToClipboard() }
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
        }
    }

    private var headerCard: some View {
        HStack(spacing: 0) {
            statPill(value: shortages.count, label: "Shortages", color: .red)
            statPill(value: overages.count, label: "Overages", color: .orange)
            statPill(value: unexpected.count, label: "Unexpected", color: .red)
            statPill(value: largeVariance.count, label: "Variance", color: .purple)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func statPill(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(value > 0 ? color : .secondary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var noMismatchState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("No Mismatches")
                .font(.title3.weight(.semibold))
            Text("All detected counts match expectations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func exportReport() {
        let csv = CSVExportService.shared.exportSession(session)
        let filename = "SnapAudit_Mismatch_\(session.locationName)_\(session.createdAt.formatted(.dateTime.year().month().day())).csv"
            .replacingOccurrences(of: " ", with: "_")
        if let url = CSVExportService.shared.writeToTempFile(csv, filename: filename) {
            exportURL = url
            showShareSheet = true
        }
    }

    private func copyToClipboard() {
        let csv = CSVExportService.shared.exportSession(session)
        UIPasteboard.general.string = csv
        withAnimation { showCopiedBanner = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run { withAnimation { showCopiedBanner = false } }
        }
    }
}

private struct MismatchSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.body.weight(.medium))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(count)")
                .font(.subheadline.bold())
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.12), in: Capsule())
        }
    }
}

private struct ShortageRow: View {
    let item: AuditLineItem

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.skuNameSnapshot)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let exp = item.expectedQty {
                            statLabel("Exp", value: "\(exp)", color: .blue)
                        }
                        statLabel("Found", value: "\(item.visionCount)", color: .secondary)
                        ConfidencePill(item: item)
                    }
                }
                Spacer()
                if let d = item.delta {
                    Text("\(d)")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.red.opacity(0.1), in: Capsule())
                }
            }
            let extraFlags = item.flagReasons.filter { ![$0].allSatisfy { $0 == .shortage } }
            if !extraFlags.isEmpty {
                MismatchFlagsRow(flags: item.flagReasons)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func statLabel(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label + ":")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

private struct OverageRow: View {
    let item: AuditLineItem

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.skuNameSnapshot)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let exp = item.expectedQty {
                            statLabel("Exp", value: "\(exp)", color: .blue)
                        }
                        statLabel("Found", value: "\(item.visionCount)", color: .secondary)
                        ConfidencePill(item: item)
                    }
                }
                Spacer()
                if let d = item.delta, d > 0 {
                    Text("+\(d)")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.1), in: Capsule())
                }
            }
            let extraFlags = item.flagReasons.filter { $0 != .overage }
            if !extraFlags.isEmpty {
                MismatchFlagsRow(flags: item.flagReasons)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func statLabel(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label + ":")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

private struct UnexpectedRow: View {
    let item: AuditLineItem

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.skuNameSnapshot)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("Not in expected list")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        ConfidencePill(item: item)
                    }
                }
                Spacer()
                Text("×\(item.visionCount)")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.1), in: Capsule())
            }
            let extraFlags = item.flagReasons.filter { $0 != .expectedZeroButFound }
            if !extraFlags.isEmpty {
                MismatchFlagsRow(flags: extraFlags)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

private struct VarianceRow: View {
    let item: AuditLineItem

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.skuNameSnapshot)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let pct = item.deltaPercent {
                            Text("\(String(format: "%.0f", abs(pct) * 100))% variance")
                                .font(.system(size: 10))
                                .foregroundStyle(.purple)
                        }
                        ConfidencePill(item: item)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Found")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("\(item.visionCount)")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                    }
                    if let exp = item.expectedQty {
                        HStack(spacing: 4) {
                            Text("Exp")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text("\(exp)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.blue)
                        }
                    }
                    if let d = item.delta {
                        Text(d > 0 ? "+\(d)" : "\(d)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(d > 0 ? .orange : .red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((d > 0 ? Color.orange : Color.red).opacity(0.1), in: Capsule())
                    }
                }
            }
            let extraFlags = item.flagReasons.filter { $0 != .largeVariance }
            if !extraFlags.isEmpty {
                MismatchFlagsRow(flags: extraFlags)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

private struct ConfidencePill: View {
    let item: AuditLineItem

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(item.confidenceTier.color)
                .frame(width: 5, height: 5)
            Text("\(Int(item.countConfidence * 100))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(item.confidenceTier.color)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(item.confidenceTier.color.opacity(0.1), in: Capsule())
    }
}

private struct MismatchFlagsRow: View {
    let flags: [FlagReason]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(flags.prefix(4), id: \.self) { flag in
                HStack(spacing: 3) {
                    Image(systemName: flag.icon)
                        .font(.system(size: 9))
                    Text(flag.label)
                        .font(.system(size: 9))
                }
                .foregroundStyle(flag.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(flag.color.opacity(0.1), in: Capsule())
            }
            Spacer()
        }
    }
}
