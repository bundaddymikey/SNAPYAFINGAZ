import SwiftUI

struct SessionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let session: AuditSession
    let auditViewModel: AuditViewModel
    let isAdmin: Bool

    @State private var showDeleteAlert = false
    @State private var showReviewQueue = false
    @State private var selectedTab: SessionTab = .results
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var showExportOptions = false
    @State private var showCopiedBanner = false
    @Environment(\.dismiss) private var dismiss

    enum SessionTab: String, CaseIterable {
        case results = "Results"
        case media = "Media"
        case frames = "Frames"
    }

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sessionHeader

                if !session.lineItems.isEmpty {
                    tabPicker
                }

                switch selectedTab {
                case .results:
                    if session.lineItems.isEmpty {
                        noResultsState
                    } else {
                        resultsSection
                    }
                case .media:
                    if session.capturedMedia.isEmpty {
                        emptyMediaState
                    } else {
                        mediaSection
                    }
                case .frames:
                    let allFrames = session.capturedMedia.flatMap { $0.sampledFrames }
                    if allFrames.isEmpty {
                        emptyFramesState
                    } else {
                        framesSection(allFrames)
                    }
                }

                if isAdmin {
                    deleteButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Session Detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.status == .complete && !session.lineItems.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showExportOptions = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .confirmationDialog("Export Session CSV", isPresented: $showExportOptions, titleVisibility: .visible) {
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
        .alert("Delete Session?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                auditViewModel.setup(context: modelContext)
                auditViewModel.deleteSession(session)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the session and all captured media.")
        }
        .sheet(isPresented: $showReviewQueue) {
            ReviewQueueView(session: session, auditViewModel: auditViewModel)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
        .onAppear {
            if !session.lineItems.isEmpty { selectedTab = .results }
            else if !session.capturedMedia.isEmpty { selectedTab = .media }
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.locationName)
                        .font(.title2.weight(.bold))
                    Text(session.createdAt.formatted(.dateTime.month(.wide).day().year().hour().minute()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    infoChip(icon: session.mode.icon, label: session.mode.displayName)
                    infoChip(
                        icon: session.captureQualityMode.icon,
                        label: session.captureQualityMode.badgeTitle,
                        accent: session.captureQualityMode == .highAccuracy ? .mint : .secondary
                    )
                    infoChip(icon: "photo.stack", label: "\(session.capturedMedia.count) media")
                    let frames = session.capturedMedia.reduce(0) { $0 + $1.sampledFrames.count }
                    if frames > 0 {
                        infoChip(icon: "film.stack", label: "\(frames) frames")
                    }
                    if !session.lineItems.isEmpty {
                        infoChip(icon: "chart.bar.fill", label: "\(session.lineItems.count) SKUs")
                        infoChip(icon: "number", label: "\(session.totalItemCount) items")
                    }
                    if session.pendingLineItemCount > 0 {
                        infoChip(icon: "clock.fill", label: "\(session.pendingLineItemCount) pending", accent: .orange)
                    }
                }
                .padding(.horizontal, 1)
            }

            HStack(spacing: 4) {
                Image(systemName: "person")
                    .font(.caption)
                Text(session.createdByUserName)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var tabPicker: some View {
        let tabs = availableTabs
        return HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.3)) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedTab == tab
                                ? Color(.secondarySystemGroupedBackground)
                                : Color.clear
                        )
                        .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var availableTabs: [SessionTab] {
        var tabs: [SessionTab] = []
        if !session.lineItems.isEmpty { tabs.append(.results) }
        if !session.capturedMedia.isEmpty { tabs.append(.media) }
        let frames = session.capturedMedia.flatMap { $0.sampledFrames }
        if !frames.isEmpty { tabs.append(.frames) }
        return tabs.isEmpty ? [.media] : tabs
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Audit Results")
                    .font(.headline)
                Spacer()
                if session.pendingLineItemCount > 0 {
                    Button {
                        showReviewQueue = true
                    } label: {
                        Label("Review \(session.pendingLineItemCount)", systemImage: "clock.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.orange, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 6) {
                ForEach(session.lineItems.sorted(by: { $0.visionCount > $1.visionCount })) { item in
                    CompactLineItemRow(item: item)
                }
            }
        }
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No Results Yet")
                .font(.subheadline.weight(.medium))
            Text("Results appear after the audit is processed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var emptyMediaState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No media captured")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var emptyFramesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No sampled frames")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Captured Media")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(session.capturedMedia) { media in
                    mediaThumbnail(media)
                }
            }
        }
    }

    private func mediaThumbnail(_ media: CapturedMedia) -> some View {
        Color(.tertiarySystemGroupedBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if media.type == .photo, let image = MediaStorageService.shared.loadImage(at: media.fileURL) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: media.type.icon)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(media.type.displayName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 8))
    }

    private func framesSection(_ frames: [SampledFrame]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sampled Frames")
                    .font(.headline)
                Spacer()
                Text("\(frames.count) frames")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(frames) { frame in
                    frameThumbnail(frame)
                }
            }
        }
    }

    private func frameThumbnail(_ frame: SampledFrame) -> some View {
        Color(.tertiarySystemGroupedBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = MediaStorageService.shared.loadImage(at: frame.fileURL) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "film")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("#\(frame.frameIndex)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                Text("\(frame.timestampMs)ms")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                    .padding(3)
            }
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

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteAlert = true
        } label: {
            Label("Delete Session", systemImage: "trash")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: session.status.icon)
                .font(.caption2)
            Text(session.status.displayName)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusColor: Color {
        switch session.status {
        case .draft: .gray
        case .processing: .orange
        case .complete: .green
        }
    }

    private func infoChip(icon: String, label: String, accent: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accent == .secondary ? Color(.tertiarySystemGroupedBackground) : accent.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct CompactLineItemRow: View {
    let item: AuditLineItem

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(item.confidenceTier.color.opacity(0.15))
                .frame(width: 8, height: 8)
                .overlay {
                    Circle().fill(item.confidenceTier.color)
                        .frame(width: 6, height: 6)
                }

            Text(item.skuNameSnapshot)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            if item.pendingEvidenceCount > 0 {
                Image(systemName: "clock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text("\(item.visionCount)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(item.confidenceTier.color)

            Text("\(Int(item.countConfidence * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }
}
