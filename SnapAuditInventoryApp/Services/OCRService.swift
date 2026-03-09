import Foundation
import Vision
import UIKit

nonisolated struct OCRZoneResult: Codable, Sendable, Equatable {
    let zoneName: String
    let rawText: String
    let normalizedText: String
}

nonisolated final class OCRService: Sendable {
    static let shared = OCRService()
    private init() {}

    func recognizeZones(in image: UIImage, zones: [ZoneRect]) async -> [OCRZoneResult] {
        guard let cgImage = image.cgImage, !zones.isEmpty else { return [] }

        return await Task.detached(priority: .utility) {
            let pixelW = Double(cgImage.width)
            let pixelH = Double(cgImage.height)
            var results: [OCRZoneResult] = []

            for zone in zones {
                let cropX = max(0, zone.x) * pixelW
                let cropY = max(0, zone.y) * pixelH
                let cropW = min(zone.w * pixelW, pixelW - cropX)
                let cropH = min(zone.h * pixelH, pixelH - cropY)

                guard cropW > 8, cropH > 8,
                      let zoneCG = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
                else { continue }

                let handler = VNImageRequestHandler(cgImage: zoneCG, options: [:])
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.04

                guard (try? handler.perform([request])) != nil,
                      let observations = request.results, !observations.isEmpty
                else { continue }

                let rawText = observations.compactMap {
                    $0.topCandidates(1).first?.string
                }.joined(separator: " ")

                guard !rawText.isEmpty else { continue }

                results.append(OCRZoneResult(
                    zoneName: zone.name,
                    rawText: rawText,
                    normalizedText: Self.normalize(rawText)
                ))
            }

            return results
        }.value
    }

    func computeBoosts(
        ocrResults: [OCRZoneResult],
        candidates: [RecognitionCandidate],
        skuKeywords: [UUID: [String]]
    ) -> [UUID: Float] {
        guard !ocrResults.isEmpty else { return [:] }

        let allNormalized = ocrResults.map(\.normalizedText).joined(separator: " ")
        var boosts: [UUID: Float] = [:]

        for candidate in candidates {
            guard let keywords = skuKeywords[candidate.skuId], !keywords.isEmpty else { continue }
            var matchCount = 0
            for keyword in keywords {
                let normalized = Self.normalize(keyword)
                guard !normalized.isEmpty else { continue }
                if allNormalized.contains(normalized) {
                    matchCount += 1
                }
            }
            if matchCount > 0 {
                boosts[candidate.skuId] = min(Float(matchCount) * 0.04, 0.12)
            }
        }

        return boosts
    }

    static func normalize(_ text: String) -> String {
        let noPunct = text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(noPunct)
            .lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
