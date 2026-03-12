import Foundation
import SwiftUI
import SwiftData
import UIKit

/// Lightweight detection result for a single recognized item in a live scan frame.
struct LiveDetection: Identifiable, Equatable {
    let id = UUID()
    let bbox: CGRect           // Normalized 0–1 coordinates
    let skuId: UUID
    let skuName: String
    let confidence: Float
    let timestamp: Date

    static func == (lhs: LiveDetection, rhs: LiveDetection) -> Bool {
        lhs.id == rhs.id
    }
}

/// Scan state for the live scanning pipeline.
enum LiveScanState: String {
    case idle = "Ready"
    case scanning = "Scanning…"
    case processing = "Processing…"
    case paused = "Paused"
    case finished = "Finished"
}

/// Orchestrates throttled frame sampling → detection → classification for Real-Time Scan mode.
@Observable
@MainActor
final class LiveScanViewModel {

    // MARK: - Published State

    var scanState: LiveScanState = .idle
    var currentDetections: [LiveDetection] = []
    var runningCounts: [String: Int] = [:]      // skuName → count
    var totalItemsDetected: Int = 0
    var framesProcessed: Int = 0
    var isProcessingFrame = false

    // MARK: - Configuration

    var processedFramesPerSecond: Double = 2.0

    // MARK: - Services

    let scanService = LiveScanService()
    private var processingTimer: Timer?
    private var pendingFrame: UIImage?
    private var isProcessingLocked = false

    // MARK: - Catalog Data (loaded once)

    private var embeddingRecords: [EmbeddingRecord] = []
    private var candidateSkuIds: [UUID] = []
    private var skuNameMap: [UUID: String] = [:]
    private var modelContext: ModelContext?

    // MARK: - Confidence Threshold

    private let countThreshold: Float = 0.55

    // MARK: - Setup

    func setup(context: ModelContext) {
        self.modelContext = context
        loadCatalogData(context: context)
    }

    private func loadCatalogData(context: ModelContext) {
        // Load embeddings (fetch Embedding model, convert to EmbeddingRecord structs)
        let embDescriptor = FetchDescriptor<Embedding>()
        let embeddings = (try? context.fetch(embDescriptor)) ?? []
        embeddingRecords = embeddings.compactMap { emb -> EmbeddingRecord? in
            guard let url = emb.sourceMedia?.fileURL else { return nil }
            return EmbeddingRecord(
                embeddingId: emb.id,
                skuId: emb.skuId,
                vectorData: emb.vectorData,
                qualityScore: emb.qualityScore,
                sourceMediaURL: url
            )
        }

        // Load active SKUs
        let skuDescriptor = FetchDescriptor<ProductSKU>()
        let allSkus = (try? context.fetch(skuDescriptor)) ?? []
        candidateSkuIds = allSkus.filter(\.isActive).map(\.id)
        skuNameMap = Dictionary(uniqueKeysWithValues: allSkus.map { ($0.id, $0.productName) })

        AuditLogger.shared.logSession("LiveScan: loaded \(candidateSkuIds.count) SKUs, \(embeddingRecords.count) embeddings")
    }

    // MARK: - Start / Stop / Pause

    func startScanning() async {
        guard await scanService.requestPermissions() else {
            scanService.errorMessage = "Camera permission required"
            return
        }

        scanState = .scanning
        scanService.setupSession { [weak self] frame in
            self?.pendingFrame = frame
        }

        // Start the throttled processing timer
        let interval = 1.0 / processedFramesPerSecond
        processingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.processNextFrame()
            }
        }

        AuditLogger.shared.logSession("LiveScan: started at \(processedFramesPerSecond) fps")
    }

    func pauseScanning() {
        scanState = .paused
        processingTimer?.invalidate()
        processingTimer = nil
        scanService.stopRunning()
        AuditLogger.shared.logSession("LiveScan: paused after \(framesProcessed) frames")
    }

    func resumeScanning() {
        scanState = .scanning
        scanService.startRunning()

        let interval = 1.0 / processedFramesPerSecond
        processingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.processNextFrame()
            }
        }

        AuditLogger.shared.logSession("LiveScan: resumed")
    }

    func finishScanning() {
        scanState = .finished
        processingTimer?.invalidate()
        processingTimer = nil
        scanService.stopRunning()
        AuditLogger.shared.logSession("LiveScan: finished — \(totalItemsDetected) items across \(framesProcessed) frames")
    }

    func tearDown() {
        processingTimer?.invalidate()
        processingTimer = nil
        scanService.tearDown()
    }

    // MARK: - Frame Processing

    private func processNextFrame() async {
        guard scanState == .scanning,
              !isProcessingLocked,
              let frame = pendingFrame else { return }

        isProcessingLocked = true
        isProcessingFrame = true
        pendingFrame = nil

        do {
            let detections = try await recognizeFrame(frame)
            currentDetections = detections
            updateRunningCounts(from: detections)
            framesProcessed += 1
        } catch {
            AuditLogger.shared.logError("LiveScan frame error: \(error.localizedDescription)")
        }

        isProcessingFrame = false
        isProcessingLocked = false
    }

    /// Run detection + classification on a single frame, off the main thread.
    private func recognizeFrame(_ image: UIImage) async throws -> [LiveDetection] {
        guard !embeddingRecords.isEmpty, !candidateSkuIds.isEmpty else { return [] }

        return try await Task.detached(priority: .userInitiated) { [candidateSkuIds, embeddingRecords, skuNameMap, countThreshold] in
            // 1. Region proposal (multi-scale)
            let regions = await DetectionService.shared.proposeRegions(from: image)

            // Limit to top regions for performance
            let topRegions = Array(regions.prefix(8))

            // 2. Classify each region
            var detections: [LiveDetection] = []

            for region in topRegions {
                let candidates = try await OnDeviceEngine.shared.classify(
                    image: region.cropImage,
                    candidateSkuIds: candidateSkuIds,
                    embeddings: embeddingRecords
                )

                guard let best = candidates.first, best.score >= countThreshold else { continue }
                let name = skuNameMap[best.skuId] ?? "Unknown"

                let detection = LiveDetection(
                    bbox: CGRect(
                        x: CGFloat(region.bbox.x),
                        y: CGFloat(region.bbox.y),
                        width: CGFloat(region.bbox.width),
                        height: CGFloat(region.bbox.height)
                    ),
                    skuId: best.skuId,
                    skuName: name,
                    confidence: best.score,
                    timestamp: Date()
                )
                detections.append(detection)
            }

            return detections
        }.value
    }

    /// Accumulate running counts from detections.
    /// Stage 1: naive counting — each detection adds to count (no dedup).
    private func updateRunningCounts(from detections: [LiveDetection]) {
        for detection in detections {
            runningCounts[detection.skuName, default: 0] += 1
            totalItemsDetected += 1

            AuditLogger.shared.logRecognition(
                skuName: detection.skuName,
                score: Double(detection.confidence),
                status: "live-counted"
            )
        }
    }

    /// Sorted running counts for display.
    var sortedCounts: [(name: String, count: Int)] {
        runningCounts
            .sorted { $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
    }
}
