import Foundation
import SwiftUI
import SwiftData
import UIKit
@preconcurrency import AVFoundation

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

    // MARK: - Services

    let scanService = LiveScanService()
    /// Optional sync service for multi-device relay. Set by the view when a device is in scanner mode.
    var syncService: SessionSyncService?
    /// The active AuditSession during a shared multi-device session (used for ScanEvent session ID).
    var currentSession: AuditSession?
    /// Unified count service — persists confirmed live detections into AuditLineItem.
    var countService: AuditCountService?
    /// Review fallback store — accumulates uncertain detections for operator review.
    let fallbackStore = LiveReviewFallbackStore()
    /// Persistent cross-frame object tracker — ensures each physical item is counted only once.
    let objectTracker = LiveObjectTracker()
    /// Pending raw frame for recognition — CVPixelBuffer avoids UIImage conversion overhead.
    private var pendingPixelBuffer: CVPixelBuffer?
    /// Wall-clock time the pending buffer was received. Used for stale-frame rejection.
    private var pendingFrameWallTime: CFAbsoluteTime = 0
    private var isProcessingLocked = false
    /// Shared CIContext for CVPixelBuffer → CGImage conversion in recognition path.
    private let recognitionCIContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Catalog Data (loaded once)

    private var embeddingRecords: [EmbeddingRecord] = []
    private var candidateSkuIds: [UUID] = []
    private var skuNameMap: [UUID: String] = [:]
    private var modelContext: ModelContext?

    /// Expected sheet context for the current session.
    /// When non-empty, this narrows recognition candidates and gates suspicious counts.
    private var expectedSheetCtx: ExpectedSheetContext = .empty

    // MARK: - Confidence Threshold

    private let countThreshold: Float = 0.55

    // MARK: - Setup

    func setup(context: ModelContext) {
        self.modelContext = context
        loadCatalogData(context: context, session: nil)
    }

    /// Call this when a session is attached so that the expected sheet context
    /// can narrow candidateSkuIds and sanity-check counts.
    func attachSession(_ session: AuditSession, context: ModelContext) {
        currentSession = session
        loadCatalogData(context: context, session: session)
    }

    private func loadCatalogData(context: ModelContext, session: AuditSession?) {
        // Load embeddings (fetch Embedding model, convert to EmbeddingRecord structs)
        let embDescriptor = FetchDescriptor<Embedding>()
        let embeddings = (try? context.fetch(embDescriptor)) ?? []
        embeddingRecords = embeddings.compactMap { emb -> EmbeddingRecord? in
            guard let url = emb.sourceMedia?.fileURL else { return nil }
            let angle = emb.viewAngle
            return EmbeddingRecord(
                embeddingId: emb.id,
                skuId: emb.skuId,
                vectorData: emb.vectorData,
                qualityScore: emb.qualityScore,
                sourceMediaURL: url,
                viewAngle: angle,
                isHighPriority: angle.isHighPriority
            )
        }

        // Load active SKUs
        let skuDescriptor = FetchDescriptor<ProductSKU>()
        let allSkus = (try? context.fetch(skuDescriptor)) ?? []
        let allCandidateIds = allSkus.filter(\.isActive).map(\.id)
        skuNameMap = Dictionary(uniqueKeysWithValues: allSkus.map { ($0.id, $0.productName) })

        // Build expected sheet context if a session is provided.
        // This context narrows candidateSkuIds to the expected product set when available.
        if let session {
            var shelfSnapshots: [ShelfExpectedRowSnapshot] = []
            var sessionSnapshots: [ExpectedRowSnapshot] = []

            if let layoutId = session.selectedLayoutId {
                let layoutDescriptor = FetchDescriptor<ShelfLayout>()
                if let layouts = try? context.fetch(layoutDescriptor),
                   let layout = layouts.first(where: { $0.id == layoutId }) {
                    shelfSnapshots = layout.expectedRows.map { ShelfExpectedRowSnapshot(from: $0) }
                }
            }
            if let snapshot = session.expectedSnapshot {
                sessionSnapshots = snapshot.rows.map { ExpectedRowSnapshot(from: $0) }
            }

            if !shelfSnapshots.isEmpty || !sessionSnapshots.isEmpty {
                expectedSheetCtx = ExpectedSheetContext(shelfRows: shelfSnapshots, sessionRows: sessionSnapshots)
            } else {
                expectedSheetCtx = .empty
            }
        } else {
            expectedSheetCtx = .empty
        }

        // Narrow candidateSkuIds to expected products when a sheet is active.
        // This makes recognition faster and more accurate on known inventory.
        candidateSkuIds = expectedSheetCtx.effectiveCandidateIds(fullCatalogIds: allCandidateIds)

        AuditLogger.shared.logSession(
            "LiveScan: loaded \(candidateSkuIds.count) candidate SKUs " +
            "(\(expectedSheetCtx.isEmpty ? "full catalog" : "expected-sheet narrowed")), " +
            "\(embeddingRecords.count) embeddings"
        )
    }

    // MARK: - Start / Stop / Pause

    func startScanning() async {
        guard await scanService.requestPermissions() else {
            scanService.errorMessage = "Camera permission required"
            return
        }

        // Reset tracker and counts for a clean session start.
        objectTracker.reset()
        runningCounts.removeAll()
        totalItemsDetected = 0
        framesProcessed = 0
        fallbackStore.clear()

        // Reload catalog data with the current session so expected-sheet narrowing is applied.
        if let context = modelContext {
            loadCatalogData(context: context, session: currentSession)
        }

        scanState = .scanning

        // Hook the raw CVPixelBuffer callback path.
        // LiveScanService.maxProcessingFPS is the single throttle source of truth.
        // We process directly in the callback — no secondary timer needed.
        scanService.rawRecognitionHandler = { [weak self] pixelBuffer, _ in
            let arrivedAt = CFAbsoluteTimeGetCurrent()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingPixelBuffer = pixelBuffer
                self.pendingFrameWallTime = arrivedAt
                await self.processNextFrame()
            }
        }
        // Start the session. UIImage handler not used for recognition; preview via latestFrame.
        scanService.setupSession(onFrame: { _ in })

        AuditLogger.shared.logSession("LiveScan: started — throttle owned by LiveScanService at \(scanService.maxProcessingFPS) fps")
    }

    func pauseScanning() {
        scanState = .paused
        scanService.stopRunning()
        AuditLogger.shared.logSession("LiveScan: paused after \(framesProcessed) frames")
        syncService?.sendStatusChange(status: "Paused", framesProcessed: framesProcessed, totalItems: totalItemsDetected)
    }

    func resumeScanning() {
        scanState = .scanning
        scanService.startRunning()
        AuditLogger.shared.logSession("LiveScan: resumed")
        syncService?.sendStatusChange(status: "Scanning…", framesProcessed: framesProcessed, totalItems: totalItemsDetected)
    }

    func finishScanning() {
        scanState = .finished
        scanService.stopRunning()
        objectTracker.reset()
        AuditLogger.shared.logSession("LiveScan: finished — \(totalItemsDetected) items across \(framesProcessed) frames")
        syncService?.sendStatusChange(status: "Finished", framesProcessed: framesProcessed, totalItems: totalItemsDetected)
    }

    func tearDown() {
        scanService.tearDown()
        objectTracker.reset()
    }

    // MARK: - Frame Processing

    /// Result of processing a single camera frame.
    private struct FrameResult {
        var detections: [LiveDetection]
        var fallbackCandidates: [FallbackCandidate]

        struct FallbackCandidate {
            let candidates: [LiveProductCandidate]
            let cropImage: UIImage?
            let timestamp: Date
        }
    }

    private func processNextFrame() async {
        guard scanState == .scanning,
              !isProcessingLocked,
              let pixelBuffer = pendingPixelBuffer else { return }

        // Stale-frame guard: reject if the buffer is older than 2× the service throttle interval.
        // This prevents re-processing a buffer that arrived before a pause or processing delay.
        let staleThreshold = (2.0 / max(scanService.maxProcessingFPS, 1.0))
        guard CFAbsoluteTimeGetCurrent() - pendingFrameWallTime <= staleThreshold else {
            pendingPixelBuffer = nil  // discard stale buffer
            return
        }

        isProcessingLocked = true
        isProcessingFrame = true
        pendingPixelBuffer = nil

        do {
            let result = try await recognizeFrame(pixelBuffer)
            currentDetections = result.detections
            updateRunningCounts(from: result.detections)

            // Route sub-threshold candidates to review store
            let sessionId = currentSession?.id ?? UUID()
            for fc in result.fallbackCandidates {
                _ = fallbackStore.evaluateAndRoute(
                    candidates: fc.candidates,
                    cropImage: fc.cropImage,
                    timestamp: fc.timestamp,
                    auditSessionId: sessionId
                )
            }

            framesProcessed += 1
        } catch {
            AuditLogger.shared.logError("LiveScan frame error: \(error.localizedDescription)")
        }

        isProcessingFrame = false
        isProcessingLocked = false
    }

    /// Run detection + classification on a raw CVPixelBuffer, off the main thread.
    /// CVPixelBuffer → CGImage conversion uses the shared recognitionCIContext (no per-frame alloc).
    /// UIImage is only produced for crop thumbnails (evidence/review), not for the whole frame.
    private func recognizeFrame(_ pixelBuffer: CVPixelBuffer) async throws -> FrameResult {
        guard !embeddingRecords.isEmpty, !candidateSkuIds.isEmpty else { return FrameResult(detections: [], fallbackCandidates: []) }

        let ciContext = recognitionCIContext
        return try await Task.detached(priority: .userInitiated) { [candidateSkuIds, embeddingRecords, skuNameMap, countThreshold] in
            // 1. Region proposal — CVPixelBuffer-first path (no whole-frame UIImage created)
            let regions = await DetectionService.shared.proposeRegions(from: pixelBuffer, ciContext: ciContext)

            #if DEBUG
            // print("[LiveScanViewModel] \(regions.count) regions proposed from CVPixelBuffer")
            #endif

            // Limit to top regions for performance
            let topRegions = Array(regions.prefix(8))

            // 2. Classify each region — crop UIImages are produced by DetectionService per-region
            var detections: [LiveDetection] = []
            var fallbackCandidates: [FrameResult.FallbackCandidate] = []

            for region in topRegions {
                let candidates = try await OnDeviceEngine.shared.classify(
                    image: region.cropImage,
                    candidateSkuIds: candidateSkuIds,
                    embeddings: embeddingRecords
                )

                guard let best = candidates.first else { continue }

                let liveCandidates = candidates.prefix(3).map { c in
                    LiveProductCandidate(
                        skuId: c.skuId,
                        skuName: skuNameMap[c.skuId] ?? "Unknown",
                        confidence: c.score
                    )
                }

                if best.score >= countThreshold {
                    let name = skuNameMap[best.skuId] ?? "Unknown"
                    detections.append(LiveDetection(
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
                    ))
                } else {
                    fallbackCandidates.append(FrameResult.FallbackCandidate(
                        candidates: liveCandidates,
                        cropImage: region.cropImage,
                        timestamp: Date()
                    ))
                }
            }

            return FrameResult(detections: detections, fallbackCandidates: fallbackCandidates)
        }.value
    }

    /// Accumulate running counts from detections using the persistent object tracker.
    ///
    /// Flow:
    /// 1. All raw detections are passed through `objectTracker.processFrame(_:)` which
    ///    matches them to existing tracks, advances their confirmation state, and returns:
    ///    - `newlyCounted`: detections to count (1 per physical object, ever).
    ///    - `rateBlocked`: detections blocked by the per-second cap → routed to review.
    /// 2. Rate-blocked detections go directly to the fallback store for operator review.
    /// 3. Each newly-confirmed detection is sanity-checked against the expected sheet:
    ///    - Unexpected items (not on the sheet) are routed to review.
    ///    - Suspicious overcounts (count >> expected qty) are routed to review.
    /// 4. Detections that pass all gates increment `runningCounts` and persist.
    private func updateRunningCounts(from detections: [LiveDetection]) {
        let sessionId = currentSession?.id ?? UUID()

        // --- Primary gate: object tracker (returns newlyCounted + rateBlocked) ---
        let trackerResult = objectTracker.processFrame(detections)

        // Route rate-blocked detections to review — they were confirmed by the tracker
        // but exceeded the per-second burst cap. An operator can accept/reject them.
        for blocked in trackerResult.rateBlocked {
            let candidates = [
                LiveProductCandidate(
                    skuId: blocked.skuId,
                    skuName: blocked.skuName,
                    confidence: blocked.confidence
                )
            ]
            _ = fallbackStore.evaluateAndRoute(
                candidates: candidates,
                cropImage: nil,
                timestamp: blocked.timestamp,
                auditSessionId: sessionId
            )
            AuditLogger.shared.logRecognition(
                skuName: blocked.skuName,
                score: Double(blocked.confidence),
                status: "rate-blocked-to-review (per-sec cap)"
            )
        }

        let newlyConfirmed = trackerResult.newlyCounted

        for detection in newlyConfirmed {
            // --- Expected sheet sanity check ---
            if !expectedSheetCtx.isEmpty {
                let currentCount = runningCounts[detection.skuName, default: 0]
                let proposedCount = currentCount + 1
                let sanity = expectedSheetCtx.sanityCheck(
                    skuId: detection.skuId,
                    productName: detection.skuName,
                    proposedCount: proposedCount
                )

                switch sanity {
                case .ok:
                    break // Pass through — proceed to count gate

                case .unexpectedItem:
                    // Item is not on the expected sheet — route to review
                    let candidates = [
                        LiveProductCandidate(
                            skuId: detection.skuId,
                            skuName: detection.skuName,
                            confidence: detection.confidence
                        )
                    ]
                    _ = fallbackStore.evaluateAndRoute(
                        candidates: candidates,
                        cropImage: nil,
                        timestamp: detection.timestamp,
                        auditSessionId: sessionId
                    )
                    AuditLogger.shared.logRecognition(
                        skuName: detection.skuName,
                        score: Double(detection.confidence),
                        status: "live-unexpected-item (not on expected sheet)"
                    )
                    continue  // Skip normal count path

                case .suspiciousOvercount(let expectedQty, let actualCount, let multiplier):
                    // Count is unrealistically high — route to review
                    let candidates = [
                        LiveProductCandidate(
                            skuId: detection.skuId,
                            skuName: detection.skuName,
                            confidence: detection.confidence
                        )
                    ]
                    _ = fallbackStore.evaluateAndRoute(
                        candidates: candidates,
                        cropImage: nil,
                        timestamp: detection.timestamp,
                        auditSessionId: sessionId
                    )
                    AuditLogger.shared.logRecognition(
                        skuName: detection.skuName,
                        score: Double(detection.confidence),
                        status: "live-suspicious-overcount (expected=\(expectedQty), actual=\(actualCount), \(String(format: "%.1f", multiplier))×)"
                    )
                    continue  // Skip normal count path
                }
            }

            // --- Secondary gate: confidence + close-match guardrail ---
            let candidates = [
                LiveProductCandidate(
                    skuId: detection.skuId,
                    skuName: detection.skuName,
                    confidence: detection.confidence
                )
            ]

            let shouldCount = fallbackStore.evaluateAndRoute(
                candidates: candidates,
                cropImage: nil,
                timestamp: detection.timestamp,
                auditSessionId: sessionId
            )

            guard shouldCount else {
                AuditLogger.shared.logRecognition(
                    skuName: detection.skuName,
                    score: Double(detection.confidence),
                    status: "routed-to-review"
                )
                continue
            }

            runningCounts[detection.skuName, default: 0] += 1
            totalItemsDetected += 1

            // Persist into AuditLineItem via unified pipeline
            if let countService, let session = currentSession, let context = modelContext {
                countService.recordCount(
                    session: session,
                    skuId: detection.skuId,
                    skuName: detection.skuName,
                    quantity: 1,
                    confidence: Double(detection.confidence),
                    sourceType: .liveCamera,
                    context: context,
                    skipBroadcast: true
                )
            }

            AuditLogger.shared.logRecognition(
                skuName: detection.skuName,
                score: Double(detection.confidence),
                status: "live-counted"
            )

            guard let syncService, syncService.isScannerConnected else { continue }

            if syncService.isInSharedSession, let session = currentSession {
                let event = ScanEvent(
                    sessionId: session.id,
                    skuId: detection.skuId,
                    skuName: detection.skuName,
                    confidence: Double(detection.confidence),
                    originDeviceId: syncService.multipeerService.deviceId,
                    originDeviceRole: .scanner,
                    sourceType: .liveCamera
                )
                syncService.sendScanEvent(event)
            } else {
                let payload = ScanResultPayload(
                    skuId: detection.skuId,
                    skuName: detection.skuName,
                    confidence: Double(detection.confidence)
                )
                syncService.sendScanResult(payload)
            }
        }
    }

    /// Sorted running counts for display.
    var sortedCounts: [(name: String, count: Int)] {
        runningCounts
            .sorted { $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
    }
}
