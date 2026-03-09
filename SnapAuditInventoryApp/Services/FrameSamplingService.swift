import Foundation
import AVFoundation
import UIKit

nonisolated final class FrameSamplingService: Sendable {
    static let shared = FrameSamplingService()

    func sampleFrames(
        videoPath: String,
        sessionId: UUID,
        mediaId: UUID,
        fps: Double,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> [(index: Int, timestampMs: Int, filePath: String)] {
        let videoURL = URL(fileURLWithPath: videoPath)
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds > 0 else { return [] }

        let totalFrames = Int(durationSeconds * fps)
        guard totalFrames > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 1920, height: 1920)

        var results: [(index: Int, timestampMs: Int, filePath: String)] = []
        let storage = MediaStorageService.shared

        for i in 0..<totalFrames {
            let timeSeconds = Double(i) / fps
            let time = CMTime(seconds: timeSeconds, preferredTimescale: 600)

            let cgImage: CGImage
            do {
                let (img, _) = try await generator.image(at: time)
                cgImage = img
            } catch {
                continue
            }

            let uiImage = UIImage(cgImage: cgImage)
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.85) else { continue }

            let filename = "frame_\(String(format: "%04d", i)).jpg"
            let filePath = try storage.saveFrame(jpegData, sessionId: sessionId, mediaId: mediaId, filename: filename)

            let timestampMs = Int(timeSeconds * 1000)
            results.append((index: i, timestampMs: timestampMs, filePath: filePath))

            progressHandler(Double(i + 1) / Double(totalFrames))
        }

        return results
    }
}
