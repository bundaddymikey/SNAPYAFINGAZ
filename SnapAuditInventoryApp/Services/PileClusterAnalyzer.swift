import Foundation
import UIKit

// MARK: - PileClusterAnalyzer

/// Tray and bin-specific cluster analyzer that augments standard region proposals
/// with additional candidate crops for densely packed product arrangements.
///
/// Pipeline position: called AFTER `DetectionService.proposeRegionsForTray()`,
/// BEFORE the recognition/embedding pipeline.
///
/// Algorithm (device-friendly, no trained model required):
/// 1. **Oversized bbox split** — any region whose area >> one typical item is
///    treated as a candidate cluster. Edge-profile valley analysis finds natural
///    gap lines; adaptive grid tiling is the fallback.
/// 2. **Uncovered area overlay** — generates coarse grid tiles for image zones
///    not covered by any existing proposal (items the detector completely missed).
/// 3. **NMS merge** — de-duplicates the augmented list before handing it to
///    the recognition pipeline.
///
/// Thread safety: `nonisolated Sendable` — pure stateless value semantics.
nonisolated final class PileClusterAnalyzer: Sendable {

    static let shared = PileClusterAnalyzer()
    private init() {}

    // MARK: - Configuration

    /// Fraction of total image area that one typical product occupies in a tray photo.
    private static let estimatedItemAreaFraction: Double = 0.080

    /// A region is treated as a cluster when its area exceeds this multiple of one item.
    private static let clusterAreaMultiple: Double = 1.8

    /// Maximum sub-regions emitted from any single oversized bbox.
    private static let maxSubRegionsPerCluster: Int = 12

    /// Cell-to-cell overlap for grid splitting (avoids missing items on cell edges).
    private static let gridOverlapRatio: Double = 0.12

    /// Minimum pixel side for a generated sub-crop (dropped if smaller).
    private static let minSubCropPx: CGFloat = 26

    /// IoU threshold for NMS when merging sub-regions with existing proposals.
    private static let nmsIoU: Double = 0.42

    /// Minimum bbox area (normalised) to include in output.
    private static let minBBoxArea: Double = 0.004

    // MARK: - Public API

    /// Augment `existingRegions` with cluster-split candidates for tray / bin mode.
    ///
    /// - Parameters:
    ///   - existingRegions: Proposals from `DetectionService.proposeRegionsForTray`.
    ///   - cgImage: Full-resolution source CGImage.
    ///   - expectedItemCount: Total expected items (from expected sheet) used to
    ///     bound proposal generation and tune grid granularity.
    /// - Returns: Merged, NMS-deduplicated region list.
    func augmentRegions(
        _ existingRegions: [DetectionRegion],
        in cgImage: CGImage,
        expectedItemCount: Int? = nil
    ) async -> [DetectionRegion] {

        let imageW   = Double(cgImage.width)
        let imageH   = Double(cgImage.height)
        let imageArea = imageW * imageH
        let estItem   = Self.estimatedItemAreaFraction * imageArea
        let cap       = expectedItemCount.map { min($0 + 6, Self.maxSubRegionsPerCluster * 3) } ?? 40

        return await Task.detached(priority: .userInitiated) {
            var additional: [DetectionRegion] = []

            // ── Pass 1: Split oversized bboxes ───────────────────────────────────
            for region in existingRegions {
                let pixelArea = region.bbox.area * imageArea
                let estCount  = Int((pixelArea / estItem).rounded())
                guard estCount >= 2, region.bbox.area < 0.72 else { continue }

                let target = min(estCount, Self.maxSubRegionsPerCluster)
                let edgeSubs = Self.edgeGuidedSplit(cgImage: cgImage, within: region.bbox, estimatedCount: target)
                let bboxes   = edgeSubs.count >= 2 ? edgeSubs : Self.gridSplit(region.bbox, count: target)

                for bbox in bboxes {
                    guard let crop = Self.safeCrop(cgImage, bbox: bbox) else { continue }
                    additional.append(DetectionRegion(
                        bbox: bbox,
                        cropImage: UIImage(cgImage: crop),
                        isFromRectangle: false,
                        scaleLevel: region.scaleLevel,
                        isClusterSplit: true
                    ))
                }
            }

            // ── Pass 2: Uncovered area grid overlay ──────────────────────────────
            let allSoFar = existingRegions + additional
            if allSoFar.count < cap {
                for bbox in Self.uncoveredGridTiles(existing: allSoFar, cap: cap - allSoFar.count) {
                    guard let crop = Self.safeCrop(cgImage, bbox: bbox) else { continue }
                    additional.append(DetectionRegion(
                        bbox: bbox,
                        cropImage: UIImage(cgImage: crop),
                        isFromRectangle: false,
                        scaleLevel: 1.0,
                        isClusterSplit: true
                    ))
                }
            }

            guard !additional.isEmpty else { return existingRegions }

            // ── NMS merge ────────────────────────────────────────────────────────
            let merged = existingRegions + additional
            let scores: [Double] = merged.map { $0.isClusterSplit ? 0.68 : 0.88 }
            let kept = DetectionService.applyNMS(
                boxes: merged.map(\.bbox),
                scores: scores,
                iouThreshold: Self.nmsIoU
            )
            return kept.map { merged[$0] }
        }.value
    }

    // MARK: - Edge-guided splitting

    /// Analyse a cluster crop at low resolution and find horizontal / vertical
    /// "valley lines" (local minima of edge energy) that correspond to gaps between
    /// packed items. Returns sub-bboxes in full-image normalised coordinates.
    private static func edgeGuidedSplit(
        cgImage: CGImage,
        within bbox: BoundingBox,
        estimatedCount: Int
    ) -> [BoundingBox] {

        guard let cropCG = safeCrop(cgImage, bbox: bbox) else { return [] }

        let sz  = 80           // analysis resolution (fast on device)
        let bpp = 4
        var px  = [UInt8](repeating: 0, count: sz * sz * bpp)
        let cs  = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: sz, height: sz,
            bitsPerComponent: 8, bytesPerRow: sz * bpp,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cropCG, in: CGRect(x: 0, y: 0, width: sz, height: sz))

        // Greyscale
        var gray = [Double](repeating: 0, count: sz * sz)
        for i in 0 ..< sz * sz {
            gray[i] = 0.299 * Double(px[i*4]) / 255
                    + 0.587 * Double(px[i*4+1]) / 255
                    + 0.114 * Double(px[i*4+2]) / 255
        }

        // Horizontal + vertical edge-energy profiles
        var hProf = [Double](repeating: 0, count: sz)
        var vProf = [Double](repeating: 0, count: sz)
        for r in 1 ..< (sz - 1) {
            for c in 1 ..< (sz - 1) {
                let gx = abs(gray[r*sz + c+1] - gray[r*sz + c-1])
                let gy = abs(gray[(r+1)*sz + c] - gray[(r-1)*sz + c])
                hProf[r] += gx + gy
                vProf[c] += gx + gy
            }
        }

        let sqrtN  = max(1, Int(ceil(sqrt(Double(estimatedCount)))))
        let nSplit = sqrtN - 1
        let hSplits = valleyLines(in: hProf, target: nSplit)
        let vSplits = valleyLines(in: vProf, target: nSplit)
        guard !hSplits.isEmpty || !vSplits.isEmpty else { return [] }

        let hB = ([0.0] + hSplits + [1.0]).sorted()
        let vB = ([0.0] + vSplits + [1.0]).sorted()

        var result: [BoundingBox] = []
        for r in 0 ..< (hB.count - 1) {
            for c in 0 ..< (vB.count - 1) {
                let sub = clamp(BoundingBox(
                    x: bbox.x + vB[c]   * bbox.width,
                    y: bbox.y + hB[r]   * bbox.height,
                    width:  (vB[c+1] - vB[c])   * bbox.width,
                    height: (hB[r+1] - hB[r])   * bbox.height
                ))
                if sub.area >= minBBoxArea { result.append(sub) }
            }
        }
        return result
    }

    /// Find up to `target` valley positions (local edge-energy minima) in a 1-D profile.
    /// Returns normalised positions in [0, 1], sorted ascending.
    private static func valleyLines(in profile: [Double], target: Int) -> [Double] {
        guard target > 0, profile.count > 6 else { return [] }
        let n      = profile.count
        let minSep = max(2, n / ((target + 1) * 2))
        var cands: [(pos: Int, val: Double)] = []
        for i in minSep ..< (n - minSep) {
            if profile[i] <= profile[i - 1] && profile[i] <= profile[i + 1] {
                cands.append((i, profile[i]))
            }
        }
        cands.sort { $0.val < $1.val }
        var selected: [Int] = []
        for c in cands {
            if selected.allSatisfy({ abs($0 - c.pos) >= minSep }) {
                selected.append(c.pos)
                if selected.count >= target { break }
            }
        }
        return selected.map { Double($0) / Double(n) }.sorted()
    }

    // MARK: - Adaptive grid splitting

    /// Split `bbox` into an aspect-ratio-aware grid of `count` overlapping cells.
    private static func gridSplit(_ bbox: BoundingBox, count: Int) -> [BoundingBox] {
        let n     = min(max(count, 2), maxSubRegionsPerCluster)
        let ar    = bbox.width / max(bbox.height, 0.001)
        let cols  = max(1, Int(ceil(sqrt(Double(n) * ar))))
        let rows  = max(1, Int(ceil(Double(n) / Double(cols))))
        let cW    = bbox.width  / Double(cols)
        let cH    = bbox.height / Double(rows)
        let ovW   = cW * gridOverlapRatio
        let ovH   = cH * gridOverlapRatio
        var result: [BoundingBox] = []
        for r in 0 ..< rows {
            for c in 0 ..< cols {
                let x = bbox.x + Double(c) * cW - (c > 0 ? ovW : 0)
                let y = bbox.y + Double(r) * cH - (r > 0 ? ovH : 0)
                let w = cW + (c > 0 ? ovW : 0) + (c < cols-1 ? ovW : 0)
                let h = cH + (r > 0 ? ovH : 0) + (r < rows-1 ? ovH : 0)
                let sub = clamp(BoundingBox(x: x, y: y, width: w, height: h))
                if sub.area >= minBBoxArea { result.append(sub) }
            }
        }
        return result
    }

    // MARK: - Uncovered area tiles

    /// Generate 3×3 and 4×4 grid tiles for image zones not covered by existing proposals.
    private static func uncoveredGridTiles(existing: [DetectionRegion], cap: Int) -> [BoundingBox] {
        var result: [BoundingBox] = []
        for (cols, rows) in [(3, 3), (4, 4)] {
            let cW = 1.0 / Double(cols), cH = 1.0 / Double(rows)
            for r in 0 ..< rows {
                for c in 0 ..< cols {
                    guard result.count < cap else { return result }
                    let tile = BoundingBox(x: Double(c)*cW, y: Double(r)*cH, width: cW, height: cH)
                    let covered = existing.contains { $0.bbox.iou(with: tile) > 0.30 }
                    if !covered { result.append(tile) }
                }
            }
        }
        return result
    }

    // MARK: - Geometry helpers

    private static func safeCrop(_ cgImage: CGImage, bbox: BoundingBox) -> CGImage? {
        let iR = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let cr = CGRect(
            x: CGFloat(bbox.x)      * CGFloat(cgImage.width),
            y: CGFloat(bbox.y)      * CGFloat(cgImage.height),
            width:  CGFloat(bbox.width)  * CGFloat(cgImage.width),
            height: CGFloat(bbox.height) * CGFloat(cgImage.height)
        ).intersection(iR).integral
        guard cr.width >= minSubCropPx, cr.height >= minSubCropPx else { return nil }
        return cgImage.cropping(to: cr)
    }

    private static func clamp(_ bbox: BoundingBox) -> BoundingBox {
        let x = max(0, min(1, bbox.x)), y = max(0, min(1, bbox.y))
        return BoundingBox(x: x, y: y,
                           width:  max(0, min(1 - x, bbox.width)),
                           height: max(0, min(1 - y, bbox.height)))
    }
}
