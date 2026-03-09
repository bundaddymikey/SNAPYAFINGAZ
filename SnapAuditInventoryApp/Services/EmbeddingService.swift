import Foundation
import Vision
import UIKit
import Accelerate

nonisolated struct QualityMetrics: Sendable {
    let blurScore: Float
    let lightScore: Float
    let glareScore: Float

    var qualityScore: Double {
        let sharpness = Double(max(0, 1.0 - blurScore))
        let lighting = Double(lightScore < 0.15 ? lightScore * 4.0 : min(lightScore * 1.1, 1.0))
        let antiGlare = Double(max(0, 1.0 - glareScore))
        return (sharpness * 0.5 + lighting * 0.3 + antiGlare * 0.2).clampedTo01
    }

    var tagsJSON: String {
        "{\"blur\":\(String(format: "%.3f", blurScore)),\"light\":\(String(format: "%.3f", lightScore)),\"glare\":\(String(format: "%.3f", glareScore))}"
    }

    var qualityLabel: String {
        switch qualityScore {
        case 0.7...: "Good"
        case 0.4...: "Fair"
        default: "Poor"
        }
    }
}

nonisolated enum EmbeddingError: Error, LocalizedError, Sendable {
    case invalidImage
    case visionFailed(String)
    case noObservation

    var errorDescription: String? {
        switch self {
        case .invalidImage: "Could not load image data."
        case .visionFailed(let msg): "Vision failed: \(msg)"
        case .noObservation: "No feature print generated."
        }
    }
}

nonisolated final class EmbeddingService: Sendable {
    static let shared = EmbeddingService()
    private init() {}

    func computeEmbedding(for image: UIImage) async throws -> (vector: Data, quality: QualityMetrics) {
        guard let cgImage = image.cgImage else { throw EmbeddingError.invalidImage }
        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNGenerateImageFeaturePrintRequest()
            do {
                try handler.perform([request])
            } catch {
                throw EmbeddingError.visionFailed(error.localizedDescription)
            }
            guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                throw EmbeddingError.noObservation
            }
            let quality = Self.analyzeQuality(cgImage: cgImage)
            return (observation.data, quality)
        }.value
    }

    func cosineSimilarity(vectorA: Data, vectorB: Data) -> Float {
        let a = vectorA.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let b = vectorB.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(a.count))
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? max(0, dot / denom) : 0
    }

    func analyzeQuality(for image: UIImage) -> QualityMetrics {
        guard let cgImage = image.cgImage else {
            return QualityMetrics(blurScore: 0.3, lightScore: 0.5, glareScore: 0.1)
        }
        return Self.analyzeQuality(cgImage: cgImage)
    }

    private static func analyzeQuality(cgImage: CGImage) -> QualityMetrics {
        let size = 64
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * bytesPerPixel,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return QualityMetrics(blurScore: 0.3, lightScore: 0.5, glareScore: 0.1)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let count = size * size
        var gray = [Float](repeating: 0, count: count)
        var totalBrightness: Float = 0
        var glareCount = 0

        for i in 0..<count {
            let r = Float(pixels[i * 4]) / 255.0
            let g = Float(pixels[i * 4 + 1]) / 255.0
            let b = Float(pixels[i * 4 + 2]) / 255.0
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            gray[i] = luma
            totalBrightness += luma
            if r > 0.93 && g > 0.93 && b > 0.93 { glareCount += 1 }
        }

        let meanBrightness = totalBrightness / Float(count)
        let lightScore = min(meanBrightness * 1.4, 1.0)
        let glareScore = min(Float(glareCount) / Float(count) * 8.0, 1.0)

        var lapSum: Float = 0
        for row in 1..<(size - 1) {
            for col in 1..<(size - 1) {
                let c = gray[row * size + col]
                let t = gray[(row - 1) * size + col]
                let bot = gray[(row + 1) * size + col]
                let l = gray[row * size + col - 1]
                let r = gray[row * size + col + 1]
                let lap = abs(4 * c - t - bot - l - r)
                lapSum += lap * lap
            }
        }
        let lapVar = lapSum / Float((size - 2) * (size - 2))
        let blurScore = max(0, 1.0 - min(lapVar * 60.0, 1.0))

        return QualityMetrics(blurScore: blurScore, lightScore: lightScore, glareScore: glareScore)
    }
}

nonisolated extension Double {
    var clampedTo01: Double { min(max(self, 0), 1) }

    func nonZeroOrDefault(_ fallback: Double) -> Double {
        self == 0 ? fallback : self
    }
}
