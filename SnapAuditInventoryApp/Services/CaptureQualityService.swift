import Foundation
import UIKit
import CoreGraphics

nonisolated struct CaptureQualityService: Sendable {
    static let shared = CaptureQualityService()

    private let sampleSize: Int = 72
    private let auditZone = CGRect(x: 0.16, y: 0.16, width: 0.68, height: 0.68)

    func analyze(image: UIImage) -> CaptureQualityAssessment {
        guard let cgImage = image.cgImage,
              let pixels = resizedPixels(from: cgImage, size: sampleSize) else {
            return .empty
        }

        let centerRect = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
        let auditRect = auditZone
        let metrics = pixelMetrics(for: pixels)

        var centerLuma: [Double] = []
        var outerLuma: [Double] = []
        var auditEdgeValues: [Double] = []
        var outsideAuditEdgeValues: [Double] = []
        var brightPixels = 0
        var totalPixels = 0

        for row in 0..<sampleSize {
            for col in 0..<sampleSize {
                let x = Double(col) / Double(sampleSize - 1)
                let y = Double(row) / Double(sampleSize - 1)
                let point = CGPoint(x: x, y: y)
                let index = row * sampleSize + col
                let luma = metrics.luma[index]
                let edge = metrics.edges[index]

                totalPixels += 1
                if luma > 0.96 { brightPixels += 1 }

                if centerRect.contains(point) {
                    centerLuma.append(luma)
                } else {
                    outerLuma.append(luma)
                }

                if auditRect.contains(point) {
                    auditEdgeValues.append(edge)
                } else {
                    outsideAuditEdgeValues.append(edge)
                }
            }
        }

        let centerMean = mean(centerLuma)
        let outerMean = mean(outerLuma)
        let centerStdDev = standardDeviation(centerLuma, mean: centerMean)
        // let outerStdDev = standardDeviation(outerLuma, mean: outerMean) // Removed unused variable

        let clutterOutsideMainArea = normalized(mean(outsideAuditEdgeValues) * 2.6)
        let glareScore = normalized(Double(brightPixels) / Double(max(totalPixels, 1)) * 10.0)
        let backgroundContrast = normalized(abs(centerMean - outerMean) * 2.8 + centerStdDev * 1.1)
        let edgeDensity = normalized(mean(auditEdgeValues) * 2.1)
        let itemsOutsideZoneScore = normalized(max(0, mean(outsideAuditEdgeValues) - mean(auditEdgeValues) * 0.35) * 3.2)

        var warnings: [CaptureQualityWarning] = []
        if clutterOutsideMainArea > 0.42 { warnings.append(.clutterOutsideMainArea) }
        if backgroundContrast < 0.24 || edgeDensity < 0.12 { warnings.append(.lowContrast) }
        if glareScore > 0.18 { warnings.append(.strongGlare) }
        if itemsOutsideZoneScore > 0.34 { warnings.append(.productsOutsideCaptureZone) }

        let score = normalized(
            1.0
            - clutterOutsideMainArea * 0.24
            - glareScore * 0.24
            - itemsOutsideZoneScore * 0.24
            + backgroundContrast * 0.18
            + edgeDensity * 0.14
        )

        return CaptureQualityAssessment(
            clutterOutsideMainArea: clutterOutsideMainArea,
            glareScore: glareScore,
            backgroundContrast: backgroundContrast,
            edgeDensity: edgeDensity,
            itemsOutsideZoneScore: itemsOutsideZoneScore,
            warnings: warnings,
            score: score
        )
    }

    func aggregate(images: [UIImage]) -> CaptureQualityAssessment {
        guard !images.isEmpty else { return .empty }
        let assessments = images.map(analyze(image:))
        let clutterOutsideMainArea = mean(assessments.map(\.clutterOutsideMainArea))
        let glareScore = mean(assessments.map(\.glareScore))
        let backgroundContrast = mean(assessments.map(\.backgroundContrast))
        let edgeDensity = mean(assessments.map(\.edgeDensity))
        let itemsOutsideZoneScore = mean(assessments.map(\.itemsOutsideZoneScore))

        let warnings: [CaptureQualityWarning] = CaptureQualityWarning.allCases.filter { warning in
            assessments.contains { $0.warnings.contains(warning) }
        }

        return CaptureQualityAssessment(
            clutterOutsideMainArea: clutterOutsideMainArea,
            glareScore: glareScore,
            backgroundContrast: backgroundContrast,
            edgeDensity: edgeDensity,
            itemsOutsideZoneScore: itemsOutsideZoneScore,
            warnings: warnings,
            score: mean(assessments.map(\.score))
        )
    }

    func encode(_ assessment: CaptureQualityAssessment) -> String {
        guard let data = try? JSONEncoder().encode(assessment),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func resizedPixels(from cgImage: CGImage, size: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    private func pixelMetrics(for pixels: [UInt8]) -> (luma: [Double], edges: [Double]) {
        let count = sampleSize * sampleSize
        var grayscale = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let r = Double(pixels[index * 4]) / 255.0
            let g = Double(pixels[index * 4 + 1]) / 255.0
            let b = Double(pixels[index * 4 + 2]) / 255.0
            grayscale[index] = 0.299 * r + 0.587 * g + 0.114 * b
        }

        var edges = [Double](repeating: 0, count: count)
        for row in 1..<(sampleSize - 1) {
            for col in 1..<(sampleSize - 1) {
                let index = row * sampleSize + col
                let left = grayscale[row * sampleSize + col - 1]
                let right = grayscale[row * sampleSize + col + 1]
                let top = grayscale[(row - 1) * sampleSize + col]
                let bottom = grayscale[(row + 1) * sampleSize + col]
                let gradient = abs(right - left) + abs(bottom - top)
                edges[index] = normalized(gradient * 1.5)
            }
        }
        return (grayscale, edges)
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let variance = values.reduce(0) { partialResult, value in
            partialResult + pow(value - mean, 2)
        } / Double(values.count)
        return sqrt(variance)
    }

    private func normalized(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
