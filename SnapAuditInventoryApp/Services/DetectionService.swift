import Foundation
import Vision
import UIKit

nonisolated struct DetectionRegion: Sendable {
    let bbox: BoundingBox
    let cropImage: UIImage
    let isFromRectangle: Bool
    let scaleLevel: Double
    let isClusterSplit: Bool
}

nonisolated struct DetectionCandidate: Sendable {
    let bbox: BoundingBox
    let isFromRectangle: Bool
    let scaleLevel: Double
    let isClusterSplit: Bool
    let proposalScore: Double
}

nonisolated struct DetectionCluster: Sendable {
    let bbox: BoundingBox
    let memberCount: Int
    let meanOverlap: Double
    let scaleLevel: Double
}

nonisolated final class DetectionService: Sendable {
    static let shared = DetectionService()

    private static let scaleLevels: [Double] = [1.0, 0.75, 0.5]
    private static let smallestScaleResolutionThreshold: Int = 1500
    private static let maxProposalsPerScale: Int = 20
    private static let maxTotalProposals: Int = 40
    private static let maxClusterCount: Int = 6
    private static let minCropPixelSide: Double = 22

    private init() {}

    func proposeRegions(from image: UIImage) async -> [DetectionRegion] {
        guard let cgImage = image.cgImage else {
            return Self.gridRegions(from: image)
        }

        return await Self.proposeRegions(from: cgImage)
    }

    /// CVPixelBuffer-first overload. Converts the buffer to CGImage using a caller-supplied
    /// shared CIContext, avoiding per-frame allocation. Preferred path for live scan.
    func proposeRegions(from pixelBuffer: CVPixelBuffer, ciContext: CIContext) async -> [DetectionRegion] {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            // Graceful fallback: apply grid to a dummy size
            return []
        }
        return await Self.proposeRegions(from: cgImage)
    }

    /// Tray / bin-optimised region proposal.
    ///
    /// Uses lower confidence and size thresholds to capture small packed products,
    /// and a more aggressive cluster-split trigger so dense groups are separated
    /// before being handed to the classification pipeline.
    ///
    /// Differences from `proposeRegions`:
    /// - `minimumConfidence` 0.28 (vs 0.35) — accepts weaker rectangle detections
    /// - `minimumSize`       0.018 (vs 0.025) — catches smaller items
    /// - `maxProposalsPerScale` 28 (vs 20) — more candidates per scale
    /// - `maxTotalProposals`    60 (vs 40)
    /// - Cluster split triggers at memberCount≥2 or edgeDensity≥0.12 (vs ≥3/0.16)
    func proposeRegionsForTray(from image: UIImage) async -> [DetectionRegion] {
        guard let cgImage = image.cgImage else { return Self.gridRegions(from: image) }
        return await Self.proposeRegionsForTray(from: cgImage)
    }

    private static func proposeRegionsForTray(from cgImage: CGImage) async -> [DetectionRegion] {
        return await Task.detached(priority: .userInitiated) {
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let scales    = Self.effectiveScaleLevels(for: cgImage)

            var combined: [DetectionCandidate] = []
            for scaleLevel in scales {
                guard let scaled = Self.resizedImage(cgImage: cgImage, scaleLevel: scaleLevel) else { continue }

                // Lower thresholds: more permissive rectangle detection for tray items
                var cands = detectRectangles(
                    cgImage: scaled, scaleLevel: scaleLevel,
                    maximumObservations: 28, minimumSize: 0.018,
                    minimumConfidence: 0.28, isClusterSplit: false
                )
                cands.append(contentsOf: detectSaliencyRegions(
                    cgImage: scaled, scaleLevel: scaleLevel, isClusterSplit: false
                ))
                combined.append(contentsOf: normalizeCandidates(
                    cands, imageSize: imageSize, iouThreshold: 0.38, limit: 28
                ))
            }

            // More aggressive cluster splitting for tray mode
            let splitCands = Self.splitDenseClustersForTray(from: combined, originalImage: cgImage)
            combined.append(contentsOf: splitCands)

            let final = normalizeCandidates(combined, imageSize: imageSize, iouThreshold: 0.42, limit: 60)
            guard !final.isEmpty else { return Self.gridRegions(from: cgImage) }

            let regions = final.compactMap { c -> DetectionRegion? in
                guard let crop = Self.crop(cgImage: cgImage, bbox: c.bbox) else { return nil }
                return DetectionRegion(
                    bbox: c.bbox,
                    cropImage: UIImage(cgImage: crop),
                    isFromRectangle: c.isFromRectangle,
                    scaleLevel: c.scaleLevel,
                    isClusterSplit: c.isClusterSplit
                )
            }
            return regions.isEmpty ? Self.gridRegions(from: cgImage) : regions
        }.value
    }

    /// Cluster splitting tuned for tray mode — fires on memberCount≥2 or edgeDensity≥0.12,
    /// compared with the standard ≥3 / 0.16 / 0.18 thresholds.
    private static func splitDenseClustersForTray(
        from candidates: [DetectionCandidate],
        originalImage: CGImage
    ) -> [DetectionCandidate] {
        guard candidates.count >= 2 else { return [] }

        let clusters = detectClusters(in: candidates)
            .sorted { lhs, rhs in
                lhs.memberCount * 6 + Int(lhs.meanOverlap * 40) >
                rhs.memberCount * 6 + Int(rhs.meanOverlap * 40)
            }
            .prefix(maxClusterCount + 2) // allow more clusters in tray mode

        var split: [DetectionCandidate] = []
        for cluster in clusters {
            let expandedCluster = expand(cluster.bbox, by: 0.04)
            guard let clusterCrop = crop(cgImage: originalImage, bbox: expandedCluster) else { continue }

            let edgeDensity = measureEdgeDensity(in: clusterCrop)
            // Tray mode: trigger on memberCount≥2 OR edgeDensity≥0.12 (vs ≥3 / 0.16)
            guard cluster.memberCount >= 2 || cluster.meanOverlap >= 0.12 || edgeDensity >= 0.12 else { continue }

            var nested = detectRectangles(
                cgImage: clusterCrop, scaleLevel: cluster.scaleLevel,
                maximumObservations: 16, minimumSize: 0.008,
                minimumConfidence: 0.20, isClusterSplit: true
            )
            if edgeDensity >= 0.14 {
                nested.append(contentsOf: detectSaliencyRegions(
                    cgImage: clusterCrop, scaleLevel: cluster.scaleLevel, isClusterSplit: true
                ))
            }
            split.append(contentsOf: nested.map {
                DetectionCandidate(
                    bbox: mapToOriginal($0.bbox, within: expandedCluster),
                    isFromRectangle: $0.isFromRectangle,
                    scaleLevel: $0.scaleLevel,
                    isClusterSplit: true,
                    proposalScore: $0.proposalScore + 0.06
                )
            })
        }
        return split
    }



    private static func proposeRegions(from cgImage: CGImage) async -> [DetectionRegion] {
        return await Task.detached(priority: .userInitiated) {
            let imageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            let scales = Self.effectiveScaleLevels(for: cgImage)

            var combinedCandidates: [DetectionCandidate] = []
            for scaleLevel in scales {
                guard let scaledImage = Self.resizedImage(cgImage: cgImage, scaleLevel: scaleLevel) else { continue }
                let scaleCandidates = Self.primaryCandidates(from: scaledImage, scaleLevel: scaleLevel)
                let normalizedScaleCandidates = Self.normalizeCandidates(
                    scaleCandidates,
                    imageSize: imageSize,
                    iouThreshold: 0.42,
                    limit: Self.maxProposalsPerScale
                )
                combinedCandidates.append(contentsOf: normalizedScaleCandidates)
            }

            let splitCandidates = Self.splitDenseClusters(from: combinedCandidates, originalImage: cgImage)
            combinedCandidates.append(contentsOf: splitCandidates)

            let finalCandidates = Self.normalizeCandidates(
                combinedCandidates,
                imageSize: imageSize,
                iouThreshold: 0.45,
                limit: Self.maxTotalProposals
            )

            guard !finalCandidates.isEmpty else {
                return Self.gridRegions(from: cgImage)
            }

            let regions = finalCandidates.compactMap { candidate -> DetectionRegion? in
                guard let crop = Self.crop(cgImage: cgImage, bbox: candidate.bbox) else { return nil }
                return DetectionRegion(
                    bbox: candidate.bbox,
                    cropImage: UIImage(cgImage: crop),
                    isFromRectangle: candidate.isFromRectangle,
                    scaleLevel: candidate.scaleLevel,
                    isClusterSplit: candidate.isClusterSplit
                )
            }

            return regions.isEmpty ? Self.gridRegions(from: cgImage) : regions
        }.value
    }

    private static func effectiveScaleLevels(for cgImage: CGImage) -> [Double] {
        let maxDimension = max(cgImage.width, cgImage.height)
        return scaleLevels.filter { scaleLevel in
            scaleLevel > 0.5 || maxDimension >= smallestScaleResolutionThreshold
        }
    }

    private static func primaryCandidates(from cgImage: CGImage, scaleLevel: Double) -> [DetectionCandidate] {
        var candidates = detectRectangles(
            cgImage: cgImage,
            scaleLevel: scaleLevel,
            maximumObservations: maxProposalsPerScale,
            minimumSize: 0.025,
            minimumConfidence: 0.35,
            isClusterSplit: false
        )

        let saliencyCandidates = detectSaliencyRegions(
            cgImage: cgImage,
            scaleLevel: scaleLevel,
            isClusterSplit: false
        )
        candidates.append(contentsOf: saliencyCandidates)
        return candidates
    }

    private static func splitDenseClusters(from candidates: [DetectionCandidate], originalImage: CGImage) -> [DetectionCandidate] {
        guard candidates.count >= 2 else { return [] }

        let clusters = detectClusters(in: candidates)
            .sorted { lhs, rhs in
                let lhsScore = Double(lhs.memberCount) * 0.6 + lhs.meanOverlap * 0.4
                let rhsScore = Double(rhs.memberCount) * 0.6 + rhs.meanOverlap * 0.4
                return lhsScore > rhsScore
            }
            .prefix(maxClusterCount)

        var splitCandidates: [DetectionCandidate] = []
        for cluster in clusters {
            let expandedCluster = expand(cluster.bbox, by: 0.05)
            guard let clusterCrop = crop(cgImage: originalImage, bbox: expandedCluster) else { continue }

            let edgeDensity = measureEdgeDensity(in: clusterCrop)
            let shouldSplit = cluster.memberCount >= 3 || cluster.meanOverlap >= 0.18 || edgeDensity >= 0.16
            guard shouldSplit else { continue }

            var nested = detectRectangles(
                cgImage: clusterCrop,
                scaleLevel: cluster.scaleLevel,
                maximumObservations: 14,
                minimumSize: 0.01,
                minimumConfidence: 0.22,
                isClusterSplit: true
            )

            if edgeDensity >= 0.2 {
                nested.append(contentsOf: detectSaliencyRegions(
                    cgImage: clusterCrop,
                    scaleLevel: cluster.scaleLevel,
                    isClusterSplit: true
                ))
            }

            let mappedCandidates = nested.map { candidate in
                DetectionCandidate(
                    bbox: mapToOriginal(candidate.bbox, within: expandedCluster),
                    isFromRectangle: candidate.isFromRectangle,
                    scaleLevel: candidate.scaleLevel,
                    isClusterSplit: true,
                    proposalScore: candidate.proposalScore + 0.06
                )
            }
            splitCandidates.append(contentsOf: mappedCandidates)
        }

        return splitCandidates
    }

    private static func detectClusters(in candidates: [DetectionCandidate]) -> [DetectionCluster] {
        let count = candidates.count
        var visited = Set<Int>()
        var clusters: [DetectionCluster] = []

        for startIndex in 0..<count {
            if visited.contains(startIndex) { continue }

            var queue: [Int] = [startIndex]
            var component: [Int] = []
            visited.insert(startIndex)

            while let currentIndex = queue.first {
                queue.removeFirst()
                component.append(currentIndex)

                for neighborIndex in 0..<count where !visited.contains(neighborIndex) {
                    let lhs = candidates[currentIndex].bbox
                    let rhs = candidates[neighborIndex].bbox
                    if areClusterNeighbors(lhs: lhs, rhs: rhs) {
                        visited.insert(neighborIndex)
                        queue.append(neighborIndex)
                    }
                }
            }

            guard component.count >= 2 else { continue }

            let boxes = component.map { candidates[$0].bbox }
            let unionBox = union(boxes)
            guard unionBox.area <= 0.45 else { continue }

            let meanOverlap = averagePairwiseIoU(boxes)
            let dominantScale = dominantScaleLevel(component.map { candidates[$0].scaleLevel })
            clusters.append(
                DetectionCluster(
                    bbox: unionBox,
                    memberCount: component.count,
                    meanOverlap: meanOverlap,
                    scaleLevel: dominantScale
                )
            )
        }

        return clusters
    }

    private static func areClusterNeighbors(lhs: BoundingBox, rhs: BoundingBox) -> Bool {
        let overlap = lhs.iou(with: rhs)
        if overlap >= 0.12 { return true }

        let expandedLHS = expand(lhs, by: 0.22)
        let expandedRHS = expand(rhs, by: 0.22)
        if intersects(expandedLHS, expandedRHS) { return true }

        let dx = lhs.centerX - rhs.centerX
        let dy = lhs.centerY - rhs.centerY
        let distance = sqrt(dx * dx + dy * dy)
        let sizeThreshold = max(max(lhs.width, lhs.height), max(rhs.width, rhs.height)) * 0.85
        return distance <= sizeThreshold
    }

    private static func dominantScaleLevel(_ levels: [Double]) -> Double {
        let grouped = Dictionary(grouping: levels, by: { $0 })
        return grouped.max { lhs, rhs in
            lhs.value.count < rhs.value.count
        }?.key ?? 1.0
    }

    private static func averagePairwiseIoU(_ boxes: [BoundingBox]) -> Double {
        guard boxes.count >= 2 else { return 0 }
        var total: Double = 0
        var pairCount = 0

        for lhsIndex in 0..<(boxes.count - 1) {
            for rhsIndex in (lhsIndex + 1)..<boxes.count {
                total += boxes[lhsIndex].iou(with: boxes[rhsIndex])
                pairCount += 1
            }
        }

        guard pairCount > 0 else { return 0 }
        return total / Double(pairCount)
    }

    private static func detectRectangles(
        cgImage: CGImage,
        scaleLevel: Double,
        maximumObservations: Int,
        minimumSize: Float,
        minimumConfidence: VNConfidence,
        isClusterSplit: Bool
    ) -> [DetectionCandidate] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = VNAspectRatio(0.15)
        request.maximumAspectRatio = VNAspectRatio(6.0)
        request.minimumSize = minimumSize
        request.maximumObservations = maximumObservations
        request.minimumConfidence = minimumConfidence
        request.quadratureTolerance = 25.0

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results ?? []
        return observations.map { observation in
            let bbox = normalizedBoundingBox(from: observation.boundingBox)
            let baseScore = 0.72 + Double(observation.confidence) * 0.18
            return DetectionCandidate(
                bbox: bbox,
                isFromRectangle: true,
                scaleLevel: scaleLevel,
                isClusterSplit: isClusterSplit,
                proposalScore: isClusterSplit ? baseScore + 0.05 : baseScore
            )
        }
    }

    private static func detectSaliencyRegions(
        cgImage: CGImage,
        scaleLevel: Double,
        isClusterSplit: Bool
    ) -> [DetectionCandidate] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observation = request.results?.first else { return [] }
        let salientObjects = observation.salientObjects ?? []

        return salientObjects.prefix(8).map { salientObject in
            let bbox = normalizedBoundingBox(from: salientObject.boundingBox)
            let baseScore = 0.56
            return DetectionCandidate(
                bbox: bbox,
                isFromRectangle: false,
                scaleLevel: scaleLevel,
                isClusterSplit: isClusterSplit,
                proposalScore: isClusterSplit ? baseScore + 0.04 : baseScore
            )
        }
    }

    private static func normalizeCandidates(
        _ candidates: [DetectionCandidate],
        imageSize: CGSize,
        iouThreshold: Double,
        limit: Int
    ) -> [DetectionCandidate] {
        let filtered = candidates.compactMap { candidate -> DetectionCandidate? in
            let normalizedBox = clamp(candidate.bbox)
            let pixelWidth = normalizedBox.width * Double(imageSize.width)
            let pixelHeight = normalizedBox.height * Double(imageSize.height)
            guard pixelWidth >= minCropPixelSide,
                  pixelHeight >= minCropPixelSide,
                  normalizedBox.area >= 0.0012 else {
                return nil
            }

            let areaBoost = min(0.12, normalizedBox.area * 0.35)
            let splitBoost = candidate.isClusterSplit ? 0.03 : 0
            let scoredCandidate = DetectionCandidate(
                bbox: normalizedBox,
                isFromRectangle: candidate.isFromRectangle,
                scaleLevel: candidate.scaleLevel,
                isClusterSplit: candidate.isClusterSplit,
                proposalScore: candidate.proposalScore + areaBoost + splitBoost
            )
            return scoredCandidate
        }

        let keptIndexes = applyNMS(
            boxes: filtered.map(\.bbox),
            scores: filtered.map(\.proposalScore),
            iouThreshold: iouThreshold
        )

        return keptIndexes.prefix(limit).map { filtered[$0] }
    }

    private static func resizedImage(cgImage: CGImage, scaleLevel: Double) -> CGImage? {
        guard scaleLevel != 1.0 else { return cgImage }

        let width = max(1, Int(Double(cgImage.width) * scaleLevel))
        let height = max(1, Int(Double(cgImage.height) * scaleLevel))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }

    private static func crop(cgImage: CGImage, bbox: BoundingBox) -> CGImage? {
        let imageRect = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let cropRect = CGRect(
            x: CGFloat(bbox.x) * CGFloat(cgImage.width),
            y: CGFloat(bbox.y) * CGFloat(cgImage.height),
            width: CGFloat(bbox.width) * CGFloat(cgImage.width),
            height: CGFloat(bbox.height) * CGFloat(cgImage.height)
        )
        .intersection(imageRect)
        .integral

        guard cropRect.width >= CGFloat(minCropPixelSide),
              cropRect.height >= CGFloat(minCropPixelSide),
              let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        return cropped
    }

    private static func measureEdgeDensity(in cgImage: CGImage) -> Double {
        let size = 48
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let pixelCount = size * size
        var grayscale = [Double](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            let r = Double(pixels[index * 4]) / 255.0
            let g = Double(pixels[index * 4 + 1]) / 255.0
            let b = Double(pixels[index * 4 + 2]) / 255.0
            grayscale[index] = 0.299 * r + 0.587 * g + 0.114 * b
        }

        var strongEdges = 0
        var samples = 0
        for row in 1..<(size - 1) {
            for col in 1..<(size - 1) {
                let left = grayscale[row * size + col - 1]
                let right = grayscale[row * size + col + 1]
                let top = grayscale[(row - 1) * size + col]
                let bottom = grayscale[(row + 1) * size + col]
                let gradient = abs(right - left) + abs(bottom - top)
                if gradient > 0.24 { strongEdges += 1 }
                samples += 1
            }
        }

        guard samples > 0 else { return 0 }
        return Double(strongEdges) / Double(samples)
    }

    private static func normalizedBoundingBox(from rect: CGRect) -> BoundingBox {
        BoundingBox(
            x: Double(rect.origin.x),
            y: Double(1.0 - rect.origin.y - rect.height),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    private static func mapToOriginal(_ localBox: BoundingBox, within clusterBox: BoundingBox) -> BoundingBox {
        clamp(
            BoundingBox(
                x: clusterBox.x + localBox.x * clusterBox.width,
                y: clusterBox.y + localBox.y * clusterBox.height,
                width: localBox.width * clusterBox.width,
                height: localBox.height * clusterBox.height
            )
        )
    }

    private static func clamp(_ bbox: BoundingBox) -> BoundingBox {
        let x = bbox.x.clampedTo01
        let y = bbox.y.clampedTo01
        let maxWidth = max(0, 1 - x)
        let maxHeight = max(0, 1 - y)
        return BoundingBox(
            x: x,
            y: y,
            width: min(bbox.width, maxWidth).clampedTo01,
            height: min(bbox.height, maxHeight).clampedTo01
        )
    }

    private static func expand(_ bbox: BoundingBox, by ratio: Double) -> BoundingBox {
        let widthDelta = bbox.width * ratio
        let heightDelta = bbox.height * ratio
        return clamp(
            BoundingBox(
                x: bbox.x - widthDelta / 2,
                y: bbox.y - heightDelta / 2,
                width: bbox.width + widthDelta,
                height: bbox.height + heightDelta
            )
        )
    }

    private static func union(_ boxes: [BoundingBox]) -> BoundingBox {
        guard let first = boxes.first else {
            return BoundingBox(x: 0, y: 0, width: 0, height: 0)
        }

        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height

        for box in boxes.dropFirst() {
            minX = min(minX, box.x)
            minY = min(minY, box.y)
            maxX = max(maxX, box.x + box.width)
            maxY = max(maxY, box.y + box.height)
        }

        return clamp(
            BoundingBox(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )
        )
    }

    private static func intersects(_ lhs: BoundingBox, _ rhs: BoundingBox) -> Bool {
        let separated = lhs.x + lhs.width < rhs.x ||
            rhs.x + rhs.width < lhs.x ||
            lhs.y + lhs.height < rhs.y ||
            rhs.y + rhs.height < lhs.y
        return !separated
    }

    static func gridRegions(from image: UIImage, cols: Int = 3, rows: Int = 4) -> [DetectionRegion] {
        guard let cgImage = image.cgImage else { return [] }
        return gridRegions(from: cgImage, cols: cols, rows: rows)
    }

    static func gridRegions(from cgImage: CGImage, cols: Int = 3, rows: Int = 4) -> [DetectionRegion] {
        let pixelW = Double(cgImage.width)
        let pixelH = Double(cgImage.height)
        let cellW = 1.0 / Double(cols)
        let cellH = 1.0 / Double(rows)
        var regions: [DetectionRegion] = []

        for row in 0..<rows {
            for col in 0..<cols {
                let x = Double(col) * cellW
                let y = Double(row) * cellH
                let bbox = BoundingBox(x: x, y: y, width: cellW, height: cellH)
                let cropRect = CGRect(
                    x: CGFloat(x * pixelW),
                    y: CGFloat(y * pixelH),
                    width: CGFloat(cellW * pixelW),
                    height: CGFloat(cellH * pixelH)
                )
                guard let cropped = cgImage.cropping(to: cropRect) else { continue }
                regions.append(
                    DetectionRegion(
                        bbox: bbox,
                        cropImage: UIImage(cgImage: cropped),
                        isFromRectangle: false,
                        scaleLevel: 1.0,
                        isClusterSplit: false
                    )
                )
            }
        }
        return regions
    }

    static func applyNMS(regions: [DetectionRegion], scores: [Double], iouThreshold: Double = 0.5) -> [Int] {
        applyNMS(boxes: regions.map(\.bbox), scores: scores, iouThreshold: iouThreshold)
    }

    static func applyNMS(boxes: [BoundingBox], scores: [Double], iouThreshold: Double = 0.5) -> [Int] {
        let sorted = scores.indices.sorted { scores[$0] > scores[$1] }
        var kept: [Int] = []

        for index in sorted {
            var shouldSuppress = false
            for keptIndex in kept {
                if boxes[index].iou(with: boxes[keptIndex]) > iouThreshold {
                    shouldSuppress = true
                    break
                }
            }
            if !shouldSuppress {
                kept.append(index)
            }
        }

        return kept
    }
}
