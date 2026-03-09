import SwiftUI
import SwiftData
import PhotosUI

nonisolated struct VideoTransferable: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: tmp)
            return VideoTransferable(url: tmp)
        }
    }
}

struct TrainingMediaView: View {
    let sku: ProductSKU
    @Environment(\.modelContext) private var modelContext
    @State private var trainingVM = TrainingViewModel()
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var mediaToDelete: ReferenceMedia?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        Section {
            healthBadge

            if !trainingVM.referenceMedia.isEmpty {
                mediaGrid
            }

            if trainingVM.isProcessing {
                processingRow
            } else {
                addButtons
            }

            if let err = trainingVM.errorMessage {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Training Media")
        } footer: {
            Text(trainingVM.trainingHealth.description)
                .font(.caption)
        }
        .onAppear {
            trainingVM.setup(context: modelContext, sku: sku)
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var dataItems: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        dataItems.append(data)
                    }
                }
                selectedPhotoItems = []
                if !dataItems.isEmpty {
                    await trainingVM.addPhotos(dataItems: dataItems)
                }
            }
        }
        .onChange(of: selectedVideoItem) { _, item in
            guard let item else { return }
            Task {
                if let video = try? await item.loadTransferable(type: VideoTransferable.self) {
                    selectedVideoItem = nil
                    await trainingVM.addVideoFrames(videoURL: video.url)
                } else {
                    selectedVideoItem = nil
                }
            }
        }
        .confirmationDialog(
            "Delete this training image?",
            isPresented: Binding(
                get: { mediaToDelete != nil },
                set: { if !$0 { mediaToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let m = mediaToDelete { trainingVM.deleteMedia(m) }
                mediaToDelete = nil
            }
            Button("Cancel", role: .cancel) { mediaToDelete = nil }
        }
    }

    private var healthBadge: some View {
        HStack(spacing: 10) {
            let health = trainingVM.trainingHealth
            Image(systemName: health.icon)
                .font(.title3)
                .foregroundStyle(healthColor(health))

            VStack(alignment: .leading, spacing: 2) {
                Text("Training: \(health.label)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(healthColor(health))
                Text("\(trainingVM.goodEmbeddingCount) quality embedding\(trainingVM.goodEmbeddingCount == 1 ? "" : "s") · \(trainingVM.referenceMedia.count) media file\(trainingVM.referenceMedia.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func healthColor(_ health: TrainingHealth) -> Color {
        switch health {
        case .weak: .orange
        case .ok: .blue
        case .strong: .green
        }
    }

    private var mediaGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(trainingVM.referenceMedia, id: \.id) { media in
                ReferenceMediaThumbnail(media: media)
                    .onLongPressGesture {
                        mediaToDelete = media
                    }
            }
        }
        .padding(.vertical, 4)
    }

    private var processingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trainingVM.processingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(trainingVM.processingProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: trainingVM.processingProgress)
                .tint(.accentColor)
        }
        .padding(.vertical, 4)
    }

    private var addButtons: some View {
        HStack(spacing: 12) {
            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: 20,
                matching: .images
            ) {
                Label("Add Photos", systemImage: "photo.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemFill))
                    .clipShape(.rect(cornerRadius: 10))
            }

            PhotosPicker(
                selection: $selectedVideoItem,
                matching: .videos
            ) {
                Label("Add Video", systemImage: "video.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemFill))
                    .clipShape(.rect(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
    }
}

struct ReferenceMediaThumbnail: View {
    let media: ReferenceMedia

    var body: some View {
        Color(.secondarySystemFill)
            .frame(height: 80)
            .overlay {
                if let image = ReferenceStorageService.shared.loadImage(at: media.fileURL) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: media.type == .video ? "film" : "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                qualityDot
                    .padding(4)
            }
            .overlay(alignment: .topLeading) {
                if media.type == .video {
                    Image(systemName: "film")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.5), in: .rect(cornerRadius: 4))
                        .padding(4)
                }
            }
    }

    private var qualityDot: some View {
        let bestScore = media.embeddings.map(\.qualityScore).max() ?? 0
        let color: Color = bestScore >= 0.7 ? .green : bestScore >= 0.4 ? .yellow : .red
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay { Circle().strokeBorder(.white, lineWidth: 1) }
    }
}
