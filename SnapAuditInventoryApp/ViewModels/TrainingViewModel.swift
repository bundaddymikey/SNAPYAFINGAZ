import SwiftUI
import SwiftData
import AVFoundation
import UIKit

nonisolated enum TrainingHealth: Sendable {
    case weak
    case ok
    case strong

    var label: String {
        switch self {
        case .weak: "Weak"
        case .ok: "OK"
        case .strong: "Strong"
        }
    }

    var icon: String {
        switch self {
        case .weak: "exclamationmark.triangle.fill"
        case .ok: "checkmark.circle.fill"
        case .strong: "star.circle.fill"
        }
    }

    var description: String {
        switch self {
        case .weak: "Add at least 5 photos for reliable recognition"
        case .ok: "Recognition is functional. More photos improve accuracy."
        case .strong: "Excellent training coverage"
        }
    }
}

@Observable
@MainActor
class TrainingViewModel {
    var referenceMedia: [ReferenceMedia] = []
    var isProcessing = false
    var processingProgress: Double = 0
    var processingStatus: String = ""
    var errorMessage: String?

    private var modelContext: ModelContext?
    private var currentSKU: ProductSKU?

    func setup(context: ModelContext, sku: ProductSKU) {
        self.modelContext = context
        self.currentSKU = sku
        fetchMedia()
    }

    func fetchMedia() {
        guard let modelContext, let sku = currentSKU else { return }
        let skuId = sku.id
        let descriptor = FetchDescriptor<ReferenceMedia>(
            predicate: #Predicate { $0.sku?.id == skuId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        referenceMedia = (try? modelContext.fetch(descriptor)) ?? []
    }

    var goodEmbeddingCount: Int {
        referenceMedia.reduce(0) { total, media in
            total + media.embeddings.filter { $0.qualityScore >= 0.35 }.count
        }
    }

    var trainingHealth: TrainingHealth {
        let good = goodEmbeddingCount
        let allEmb = referenceMedia.flatMap(\.embeddings)
        let avgQuality = allEmb.isEmpty ? 0.0 : allEmb.map(\.qualityScore).reduce(0, +) / Double(allEmb.count)
        if good >= 8 && avgQuality >= 0.55 { return .strong }
        if good >= 3 { return .ok }
        return .weak
    }

    func addPhotos(dataItems: [Data]) async {
        guard let modelContext, let sku = currentSKU else { return }
        isProcessing = true
        processingProgress = 0
        errorMessage = nil

        for (index, data) in dataItems.enumerated() {
            processingStatus = "Processing photo \(index + 1) of \(dataItems.count)…"
            guard let image = UIImage(data: data) else { continue }
            do {
                let path = try ReferenceStorageService.shared.savePhoto(data, skuId: sku.id)
                let media = ReferenceMedia(sku: sku, type: .photo, fileURL: path)
                modelContext.insert(media)
                try? modelContext.save()

                let (vector, quality) = try await EmbeddingService.shared.computeEmbedding(for: image)
                let embedding = Embedding(
                    skuId: sku.id,
                    sourceMedia: media,
                    vectorData: vector,
                    qualityScore: quality.qualityScore,
                    tagsJSON: quality.tagsJSON
                )
                modelContext.insert(embedding)
                try? modelContext.save()
            } catch {
                errorMessage = "Failed to process photo \(index + 1): \(error.localizedDescription)"
            }
            processingProgress = Double(index + 1) / Double(dataItems.count)
        }

        processingStatus = "Done"
        isProcessing = false
        fetchMedia()
    }

    func addVideoFrames(videoURL: URL) async {
        guard let modelContext, let sku = currentSKU else { return }
        isProcessing = true
        processingProgress = 0
        processingStatus = "Saving video…"
        errorMessage = nil

        do {
            let path = try ReferenceStorageService.shared.saveVideoFromTemp(videoURL, skuId: sku.id)
            let media = ReferenceMedia(sku: sku, type: .video, fileURL: path)
            modelContext.insert(media)
            try? modelContext.save()

            processingStatus = "Sampling frames…"
            let frames = try await sampleFrames(videoPath: path, fps: 2.0) { [weak self] p in
                Task { @MainActor [weak self] in self?.processingProgress = p * 0.65 }
            }

            processingStatus = "Computing embeddings…"
            for (i, frameURL) in frames.enumerated() {
                guard let image = UIImage(contentsOfFile: frameURL) else { continue }
                do {
                    let (vector, quality) = try await EmbeddingService.shared.computeEmbedding(for: image)
                    let embedding = Embedding(
                        skuId: sku.id,
                        sourceMedia: media,
                        vectorData: vector,
                        qualityScore: quality.qualityScore,
                        tagsJSON: quality.tagsJSON
                    )
                    modelContext.insert(embedding)
                } catch { }
                processingProgress = 0.65 + Double(i + 1) / Double(max(frames.count, 1)) * 0.35
            }
            try? modelContext.save()
        } catch {
            errorMessage = "Video processing failed: \(error.localizedDescription)"
        }

        processingStatus = "Done"
        isProcessing = false
        fetchMedia()
    }

    func deleteMedia(_ media: ReferenceMedia) {
        guard let modelContext else { return }
        ReferenceStorageService.shared.deleteFile(at: media.fileURL)
        modelContext.delete(media)
        try? modelContext.save()
        fetchMedia()
    }

    private func sampleFrames(
        videoPath: String,
        fps: Double,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> [String] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0 else { return [] }

        let totalFrames = max(1, Int(durationSeconds * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        let baseDir = URL(fileURLWithPath: videoPath).deletingLastPathComponent()
        var paths: [String] = []

        for i in 0..<totalFrames {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: time) else { continue }
            let uiImage = UIImage(cgImage: cgImage)
            guard let data = uiImage.jpegData(compressionQuality: 0.8) else { continue }
            let filePath = baseDir.appendingPathComponent("ref_frame_\(String(format: "%04d", i)).jpg").path
            try? data.write(to: URL(fileURLWithPath: filePath))
            paths.append(filePath)
            progressHandler(Double(i + 1) / Double(totalFrames))
        }
        return paths
    }
}
