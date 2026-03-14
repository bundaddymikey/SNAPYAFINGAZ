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
    @State private var showCameraPicker = false
    /// The view angle the user has selected before capturing / uploading
    @State private var pendingAngle: ReferenceViewAngle = .general

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        Section {
            healthBadge
            coverageGrid
            anglePickerRow

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
            Text(trainingVM.trainingHealth.description +
                 " · \(trainingVM.referenceMedia.count) files · " +
                 "\(trainingVM.coveredAnglesCount) / \(ReferenceViewAngle.allCases.count) angles covered")
                .font(.caption)
        }
        .onAppear {
            trainingVM.setup(context: modelContext, sku: sku)
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            let angle = pendingAngle
            Task {
                var dataItems: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        dataItems.append(data)
                    }
                }
                selectedPhotoItems = []
                if !dataItems.isEmpty {
                    await trainingVM.addPhotos(dataItems: dataItems, viewAngle: angle)
                }
            }
        }
        .onChange(of: selectedVideoItem) { _, item in
            guard let item else { return }
            let angle = pendingAngle
            Task {
                if let video = try? await item.loadTransferable(type: VideoTransferable.self) {
                    selectedVideoItem = nil
                    await trainingVM.addVideoFrames(videoURL: video.url, viewAngle: angle)
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
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraCapturePicker { image in
                showCameraPicker = false
                guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                let angle = pendingAngle
                Task {
                    await trainingVM.addPhotos(dataItems: [data], viewAngle: angle)
                }
            } onCancel: {
                showCameraPicker = false
            }
        }
    }

    // MARK: - Health badge

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

    // MARK: - View angle coverage grid (11 angles × dot)

    private var coverageGrid: some View {
        let coverage = trainingVM.angleCoverage()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Angle Coverage")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 90), spacing: 6)],
                spacing: 6
            ) {
                ForEach(ReferenceViewAngle.allCases, id: \.self) { angle in
                    let covered = coverage[angle] ?? false
                    HStack(spacing: 4) {
                        Image(systemName: angle.icon)
                            .font(.caption2)
                            .foregroundStyle(covered ? .green : .secondary)
                        Text(angle.displayName)
                            .font(.caption2.weight(covered ? .semibold : .regular))
                            .foregroundStyle(covered ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        covered
                            ? Color.green.opacity(0.10)
                            : Color(.secondarySystemFill),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay {
                        if pendingAngle == angle {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                    .onTapGesture { pendingAngle = angle }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Angle picker strip (compact horizontal chips)

    private var anglePickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Capturing as: \(pendingAngle.displayName)")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("Tap grid above to change")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Media grid

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

    // MARK: - Processing row

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

    // MARK: - Add buttons (limit raised to 50)

    private var addButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 50,
                    matching: .images
                ) {
                    Label("Library", systemImage: "photo.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemFill))
                        .clipShape(.rect(cornerRadius: 10))
                }

                Button {
                    showCameraPicker = true
                } label: {
                    Label("Camera", systemImage: "camera.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemFill))
                        .clipShape(.rect(cornerRadius: 10))
                }
            }
            .buttonStyle(.plain)

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
            .buttonStyle(.plain)

            Text("Select angle in grid above, then capture. Multiple angles improve recognition accuracy.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Camera Capture Picker

struct CameraCapturePicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
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
            .overlay(alignment: .topTrailing) {
                // View angle badge
                if media.viewAngle != .general {
                    Text(media.viewAngle.displayName)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                        .lineLimit(1)
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

