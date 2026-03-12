import SwiftUI

struct ReviewQueueView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let session: AuditSession
    let auditViewModel: AuditViewModel

    @State private var applyToSimilar = false
    @State private var dragOffset: CGSize = .zero
    @State private var initialPendingCount: Int = 0
    @State private var showCreateProduct = false
    @State private var createProductEvidence: DetectionEvidence? = nil
    @State private var catalogVM = CatalogViewModel()

    private var pendingEvidence: [DetectionEvidence] {
        session.lineItems
            .flatMap(\.evidence)
            .filter { $0.reviewStatus == .pending }
            .sorted { a, b in
                let aFlags = a.flagReasons
                let bFlags = b.flagReasons
                func priority(_ flags: [FlagReason], score: Double) -> Int {
                    if flags.contains(.closeMatch) && !flags.contains(.weakMatch) { return 0 }
                    if flags.contains(.partial) && !flags.contains(.weakMatch) { return 1 }
                    if flags.contains(.weakMatch) { return 3 }
                    return 0
                }
                let pa = priority(aFlags, score: a.finalScore)
                let pb = priority(bFlags, score: b.finalScore)
                if pa != pb { return pa < pb }
                return a.finalScore > b.finalScore
            }
    }

    private var resolvedCount: Int {
        max(0, initialPendingCount - pendingEvidence.count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if pendingEvidence.isEmpty {
                    allReviewedState
                } else {
                    VStack(spacing: 0) {
                        progressHeader
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 16)

                        evidenceCard(pendingEvidence[0])
                            .padding(.horizontal, 20)

                        applyToSimilarToggle
                            .padding(.horizontal, 20)
                            .padding(.top, 12)

                        Spacer()
                    }
                }
            }
            .navigationTitle("Review Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !pendingEvidence.isEmpty {
                        Text("\(pendingEvidence.count) remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear {
                if initialPendingCount == 0 {
                    initialPendingCount = pendingEvidence.count
                }
                catalogVM.setup(context: modelContext)
            }
            .sheet(isPresented: $showCreateProduct) {
                ProductFormView(viewModel: catalogVM)
            }
        }
    }

    private var progressHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Reviewing detections")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                let total = initialPendingCount
                Text("\(resolvedCount) of \(total) resolved")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    let progress: CGFloat = initialPendingCount > 0
                        ? CGFloat(resolvedCount) / CGFloat(initialPendingCount)
                        : 1.0
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: geo.size.width * progress)
                        .animation(.spring(response: 0.4), value: resolvedCount)
                }
            }
            .frame(height: 5)
        }
    }

    private func evidenceCard(_ evidence: DetectionEvidence) -> some View {
        VStack(spacing: 0) {
            cropImageSection(evidence)

            Divider()

            candidateButtonsSection(evidence)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)

            Divider()

            actionRow(evidence)
                .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 18))
        .offset(x: dragOffset.width)
        .rotationEffect(.degrees(Double(dragOffset.width) / 25))
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = CGSize(width: value.translation.width * 0.7, height: 0)
                }
                .onEnded { value in
                    let threshold: CGFloat = 100
                    withAnimation(.spring(response: 0.35)) {
                        if value.translation.width > threshold {
                            confirmCurrentEvidence(evidence)
                        } else if value.translation.width < -threshold {
                            rejectCurrentEvidence(evidence)
                        } else {
                            dragOffset = .zero
                        }
                    }
                }
        )
    }

    private func cropImageSection(_ evidence: DetectionEvidence) -> some View {
        VStack(spacing: 0) {
            Color(.tertiarySystemGroupedBackground)
                .frame(height: 220)
                .overlay {
                    if !evidence.cropURL.isEmpty,
                       let img = MediaStorageService.shared.loadImage(at: evidence.cropURL) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .allowsHitTesting(false)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("No crop available")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    flagChips(for: evidence)
                        .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    swipeHint
                        .padding(10)
                }

            if let bestHotspotCropURL = evidence.bestHotspotCropURL,
               let hotspotImage = MediaStorageService.shared.loadImage(at: bestHotspotCropURL) {
                Divider()
                HStack(spacing: 12) {
                    Color(.secondarySystemBackground)
                        .frame(width: 84, height: 84)
                        .overlay {
                            Image(uiImage: hotspotImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                        }
                        .clipShape(.rect(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "viewfinder.circle.fill")
                                .foregroundStyle(.purple)
                            Text(evidence.bestHotspotName ?? "Best Focus Zone")
                                .font(.subheadline.weight(.semibold))
                        }

                        if let topHotspot = evidence.hotspotScores.max(by: { $0.score < $1.score }) {
                            Text("Match score \(Int(topHotspot.score * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if let highlightedText = evidence.hotspotScores.first(where: { $0.hotspot.name == evidence.bestHotspotName }),
                           !highlightedText.ocrText.isEmpty {
                            Text(highlightedText.ocrText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()
                }
                .padding(12)
                .background(Color(.systemBackground))
            }
        }
        .clipShape(.rect(topLeadingRadius: 18, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 18))
    }

    private var swipeHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left")
                .font(.system(size: 9, weight: .bold))
            Text("Exclude")
                .font(.system(size: 9, weight: .medium))
            Text("·")
            Text("Confirm")
                .font(.system(size: 9, weight: .medium))
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.4), in: Capsule())
    }

    private func flagChips(for evidence: DetectionEvidence) -> some View {
        HStack(spacing: 6) {
            ForEach(evidence.flagReasons, id: \.self) { reason in
                HStack(spacing: 3) {
                    Image(systemName: reason.icon)
                        .font(.system(size: 10))
                    Text(reason.label)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
            }
        }
    }

    private func candidateButtonsSection(_ evidence: DetectionEvidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which product is this?")
                .font(.subheadline.weight(.semibold))

            let ocrText = evidence.detectedOCRText
            if !ocrText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "text.viewfinder")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Text("Detected Text: \(ocrText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cyan.opacity(0.07), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.cyan.opacity(0.2), lineWidth: 1)
                }
            }

            if !evidence.hotspotScores.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(evidence.hotspotScores, id: \.hotspot.id) { hotspot in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hotspot.hotspot.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text("\(Int(hotspot.score * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.purple.opacity(0.08), in: .rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.purple.opacity(0.15), lineWidth: 1)
                            }
                        }
                    }
                }
            }

            if !evidence.contrastiveExplanation.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Contrastive Variant")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(evidence.contrastiveExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.orange.opacity(0.2), lineWidth: 1)
                }
            }

            HStack(spacing: 8) {
                let sourceLabel = evidence.isClusterSplit ? "Cluster Split" :
                    (evidence.scaleLevel >= 0.95 ? "Full Scan" :
                    (evidence.scaleLevel >= 0.70 ? "Medium Scale" : "Fine Scale"))
                let sourceColor: Color = evidence.isClusterSplit ? .red :
                    (evidence.scaleLevel >= 0.95 ? .blue :
                    (evidence.scaleLevel >= 0.70 ? .orange : .purple))
                let sourceIcon = evidence.isClusterSplit ? "rectangle.split.3x3" :
                    (evidence.scaleLevel >= 0.95 ? "viewfinder" :
                    (evidence.scaleLevel >= 0.70 ? "viewfinder.rectangular" : "rectangle.and.text.magnifyingglass"))

                Image(systemName: sourceIcon)
                    .font(.caption2)
                    .foregroundStyle(sourceColor)
                Text(sourceLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(sourceColor)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(String(format: "%.0f", evidence.scaleLevel * 100))% scale")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                ConfidenceBadge(score: evidence.finalScore, reviewStatus: evidence.reviewStatus)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.systemGray6).opacity(0.5), in: Capsule())

            if evidence.flagReasons.contains(.outsideSelectedBrand) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "building.2.slash.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)
                        Text("Possible Straggler")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)
                    }
                    Text("This item may not belong to the selected brand scope. Detected outside selected brand with strong confidence — possible mis-shelved or stray item.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.teal.opacity(0.08), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.teal.opacity(0.25), lineWidth: 1)
                }
            }


            VStack(spacing: 6) {
                ForEach(Array(evidence.top3Candidates.enumerated()), id: \.offset) { rank, candidate in
                    Button {
                        auditViewModel.setup(context: modelContext)
                        if applyToSimilar {
                            let all = pendingEvidence
                            auditViewModel.applyActionToSimilar(like: evidence, allEvidence: all) { similar in
                                auditViewModel.reassignEvidence(similar, toSkuId: candidate.skuId, skuName: candidate.skuName)
                            }
                        }
                        auditViewModel.reassignEvidence(evidence, toSkuId: candidate.skuId, skuName: candidate.skuName)
                        resetDrag()
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(rank + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(rankColor(rank), in: Circle())

                            Text(candidate.skuName)
                                .font(.subheadline.weight(rank == 0 ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            ScoreBar(score: candidate.score)
                                .frame(width: 60, height: 4)

                            Text("\(Int(candidate.score * 100))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(scoreColor(candidate.score))
                                .frame(width: 40, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            rank == 0 ? Color.blue.opacity(0.07) : Color(.tertiarySystemGroupedBackground),
                            in: .rect(cornerRadius: 10)
                        )
                        .overlay {
                            if rank == 0 {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(.blue.opacity(0.25), lineWidth: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if evidence.top3Candidates.isEmpty {
                    Text("No candidates — no trained products found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }

                // Create New Product from this detection
                Button {
                    createProductEvidence = evidence
                    showCreateProduct = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.green)
                        Text("Create New Product")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.07), in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.green.opacity(0.2), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionRow(_ evidence: DetectionEvidence) -> some View {
        HStack(spacing: 8) {
            actionButton(title: "Confirm", icon: "checkmark.circle.fill", color: .green) {
                confirmCurrentEvidence(evidence)
            }
            actionButton(title: "Unknown", icon: "questionmark.circle.fill", color: Color(.systemGray2)) {
                auditViewModel.setup(context: modelContext)
                auditViewModel.markEvidenceUnknown(evidence)
                resetDrag()
            }
            actionButton(title: "Exclude", icon: "xmark.circle.fill", color: .red) {
                rejectCurrentEvidence(evidence)
            }
        }
    }

    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.08), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var applyToSimilarToggle: some View {
        Toggle(isOn: $applyToSimilar) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Apply to similar")
                        .font(.subheadline)
                    Text("Same product + position in remaining items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "wand.and.sparkles")
                    .foregroundStyle(.purple)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var allReviewedState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 6) {
                Text("All Items Reviewed")
                    .font(.title3.weight(.semibold))
                Text("You've resolved all pending detections.\nResults have been updated.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                dismiss()
            } label: {
                Text("Back to Results")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
        }
    }

    private func confirmCurrentEvidence(_ evidence: DetectionEvidence) {
        auditViewModel.setup(context: modelContext)
        if applyToSimilar {
            auditViewModel.applyActionToSimilar(like: evidence, allEvidence: pendingEvidence) { similar in
                auditViewModel.confirmEvidence(similar)
            }
        }
        if let candidate = evidence.top3Candidates.first {
            auditViewModel.reassignEvidence(evidence, toSkuId: candidate.skuId, skuName: candidate.skuName)
        } else {
            auditViewModel.confirmEvidence(evidence)
        }
        resetDrag()
    }

    private func rejectCurrentEvidence(_ evidence: DetectionEvidence) {
        auditViewModel.setup(context: modelContext)
        if applyToSimilar {
            auditViewModel.applyActionToSimilar(like: evidence, allEvidence: pendingEvidence) { similar in
                auditViewModel.rejectEvidence(similar)
            }
        }
        auditViewModel.rejectEvidence(evidence)
        resetDrag()
    }

    private func resetDrag() {
        withAnimation(.spring(response: 0.35)) {
            dragOffset = .zero
        }
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 0: .orange
        case 1: Color(.systemGray2)
        default: Color(.systemGray4)
        }
    }

    private func scoreColor(_ score: Float) -> Color {
        switch score {
        case 0.75...: .green
        case 0.45...: .orange
        default: .red
        }
    }
}

