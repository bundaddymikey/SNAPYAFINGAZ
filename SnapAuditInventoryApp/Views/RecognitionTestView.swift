import SwiftUI
import SwiftData
import PhotosUI

struct RecognitionTestView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allSKUs: [ProductSKU]
    @Query private var allEmbeddings: [Embedding]

    @State private var selectedItem: PhotosPickerItem?
    @State private var testImage: UIImage?
    @State private var isRunning = false
    @State private var candidates: [RecognitionCandidate] = []
    @State private var errorMessage: String?
    @State private var hasRun = false

    private var embeddingRecords: [EmbeddingRecord] {
        allEmbeddings.compactMap { emb -> EmbeddingRecord? in
            guard let mediaURL = emb.sourceMedia?.fileURL else { return nil }
            let angle = emb.viewAngle
            return EmbeddingRecord(
                embeddingId: emb.id,
                skuId: emb.skuId,
                vectorData: emb.vectorData,
                qualityScore: emb.qualityScore,
                sourceMediaURL: mediaURL,
                viewAngle: angle,
                isHighPriority: angle.isHighPriority
            )
        }
    }

    private var skuIndex: [UUID: ProductSKU] {
        Dictionary(uniqueKeysWithValues: allSKUs.map { ($0.id, $0) })
    }

    var body: some View {
        List {
            imagePickerSection
            if testImage != nil {
                runSection
            }
            if hasRun {
                resultsSection
            }
            statsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Test Recognition")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    testImage = image
                    candidates = []
                    hasRun = false
                    errorMessage = nil
                }
            }
        }
    }

    private var imagePickerSection: some View {
        Section("Test Image") {
            PhotosPicker(selection: $selectedItem, matching: .images) {
                if let image = testImage {
                    HStack(spacing: 14) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 72)
                            .clipShape(.rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Image selected")
                                .font(.subheadline.weight(.medium))
                            Text("Tap to change")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Choose a test photo from library")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var runSection: some View {
        Section {
            Button {
                runClassification()
            } label: {
                HStack {
                    if isRunning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.85)
                        Text("Running…")
                            .font(.body.weight(.semibold))
                    } else {
                        Image(systemName: "brain.head.profile")
                            .font(.body.weight(.semibold))
                        Text("Run Classification")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .disabled(isRunning || embeddingRecords.isEmpty)

            if embeddingRecords.isEmpty {
                Label("No embeddings yet. Add training photos to products first.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("Searches \(allSKUs.count) SKUs with \(embeddingRecords.count) embeddings.")
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let error = errorMessage {
            Section("Results") {
                Label(error, systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
        } else if candidates.isEmpty {
            Section("Results") {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "questionmark.circle",
                    description: Text("No candidate SKUs returned a usable score.")
                )
            }
        } else {
            Section("Top \(candidates.count) Results") {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { rank, candidate in
                    CandidateResultRow(
                        rank: rank + 1,
                        candidate: candidate,
                        sku: skuIndex[candidate.skuId]
                    )
                }
            }
        }
    }

    private var statsSection: some View {
        Section("Catalog Stats") {
            LabeledContent("Trained SKUs") {
                Text("\(Set(embeddingRecords.map(\.skuId)).count) / \(allSKUs.count)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Total Embeddings") {
                Text("\(embeddingRecords.count)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Avg Quality") {
                let avg = embeddingRecords.isEmpty ? 0.0 : embeddingRecords.map(\.qualityScore).reduce(0, +) / Double(embeddingRecords.count)
                Text(String(format: "%.0f%%", avg * 100))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runClassification() {
        guard let image = testImage else { return }
        isRunning = true
        hasRun = false
        errorMessage = nil
        candidates = []

        let candidateIds = allSKUs.map(\.id)
        let records = embeddingRecords

        Task {
            do {
                let results = try await OnDeviceEngine.shared.classify(
                    image: image,
                    candidateSkuIds: candidateIds,
                    embeddings: records
                )
                candidates = results
                hasRun = true
            } catch {
                errorMessage = error.localizedDescription
                hasRun = true
            }
            isRunning = false
        }
    }
}

struct CandidateResultRow: View {
    let rank: Int
    let candidate: RecognitionCandidate
    let sku: ProductSKU?

    var body: some View {
        HStack(spacing: 12) {
            rankBadge
            referenceThumb
            VStack(alignment: .leading, spacing: 3) {
                Text(sku?.name ?? "Unknown SKU")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let brand = sku?.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScoreBar(score: candidate.score)
                    .frame(height: 4)
                    .padding(.top, 2)
            }
            Spacer()
            Text("\(Int(candidate.score * 100))%")
                .font(.headline.monospacedDigit())
                .foregroundStyle(scoreColor)
        }
        .padding(.vertical, 4)
    }

    private var rankBadge: some View {
        Text("\(rank)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(rankColor, in: Circle())
    }

    private var rankColor: Color {
        switch rank {
        case 1: .orange
        case 2: Color(.systemGray2)
        default: Color(.systemGray4)
        }
    }

    private var scoreColor: Color {
        switch candidate.score {
        case 0.8...: .green
        case 0.5...: .orange
        default: .red
        }
    }

    private var referenceThumb: some View {
        Group {
            if let url = candidate.nearestReferenceURL,
               let image = ReferenceStorageService.shared.loadImage(at: url) {
                Color(.secondarySystemFill)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
                    }
            } else {
                Color(.secondarySystemFill)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                    .clipShape(.rect(cornerRadius: 8))
            }
        }
    }
}

struct ScoreBar: View {
    let score: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))
                Capsule()
                    .fill(barColor)
                    .frame(width: geo.size.width * CGFloat(score))
            }
        }
    }

    private var barColor: Color {
        switch score {
        case 0.8...: .green
        case 0.5...: .orange
        default: .red
        }
    }
}
