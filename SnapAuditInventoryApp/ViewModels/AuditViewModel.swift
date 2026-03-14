import SwiftUI
import SwiftData

nonisolated struct LayoutZoneInfo {
    let zones: [ShelfZone]
    let groupMembers: [UUID: [UUID]]

    static let empty = LayoutZoneInfo(zones: [], groupMembers: [:])

    func findZone(for bbox: BoundingBox) -> ShelfZone? {
        let cx = bbox.centerX
        let cy = bbox.centerY
        return zones.first { zone in
            zone.rect.contains(cx: cx, cy: cy)
        }
    }

    func skuIds(for zone: ShelfZone) -> [UUID]? {
        if let skuId = zone.assignedSkuId {
            return [skuId]
        }
        if let groupId = zone.assignedGroupId {
            return groupMembers[groupId]
        }
        return nil
    }
}

nonisolated struct RawDetection: Sendable {
    let sourceId: UUID
    let bbox: BoundingBox
    let top3: [DetectedCandidate]
    let finalScore: Double
    let flagReasons: [FlagReason]
    let chosenSkuId: UUID?
    let chosenSkuName: String
    let isSoftAssigned: Bool
    let reviewStatus: ReviewStatus
    let scaleLevel: Double
    let isClusterSplit: Bool
    let queryEmbeddingData: Data
    var cropPath: String = ""
    var metadataJSON: String = ""
    var bestHotspotCropPath: String = ""
    var shelfZoneName: String = ""
    var contrastiveExplanation: String = ""
    var contrastiveBoost: Double = 0
}

@Observable
@MainActor
class AuditViewModel {
    var sessions: [AuditSession] = []
    var currentSession: AuditSession?
    var isProcessing = false
    var processingProgress: Double = 0
    var processingStatus: String = ""

    /// Unified count service — used for delta/flag recomputation after photo/video evidence changes.
    var countService: AuditCountService?

    private var modelContext: ModelContext?

    func setup(context: ModelContext) {
        self.modelContext = context
        recoverStuckSessions(context: context)
        fetchSessions()
    }

    /// Detect sessions stuck in `.processing` (e.g. app killed mid-process) and reset them to `.draft`.
    private func recoverStuckSessions(context: ModelContext) {
        let descriptor = FetchDescriptor<AuditSession>()
        guard let allSessions = try? context.fetch(descriptor) else { return }
        var didRecover = false
        for session in allSessions where session.status == .processing {
            session.status = .draft
            didRecover = true
        }
        if didRecover {
            try? context.save()
        }
    }

    func fetchSessions() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<AuditSession>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        sessions = (try? modelContext.fetch(descriptor)) ?? []
    }

    func createSession(
        locationId: UUID,
        locationName: String,
        userId: UUID,
        userName: String,
        mode: CaptureMode,
        reviewWorkflow: ReviewWorkflow = .reviewLater,
        captureQualityMode: CaptureQualityMode = .standard,
        selectedLayoutId: UUID? = nil,
        selectedLayoutName: String = "",
        recognitionScope: RecognitionScope = .all,
        mainBrand: String = "",
        secondaryBrand: String = "",
        strictBrandFilter: Bool = true,
        allowPossibleStragglers: Bool = false,
        mainCategory: String = "",
        mainSubcategory: String = "",
        presetName: String = "",
        presetIdRaw: String = ""
    ) -> AuditSession? {
        guard let modelContext else { return nil }
        let session = AuditSession(
            locationId: locationId,
            locationName: locationName,
            createdByUserId: userId,
            createdByUserName: userName,
            mode: mode,
            reviewWorkflow: reviewWorkflow,
            captureQualityMode: captureQualityMode,
            selectedLayoutId: selectedLayoutId,
            selectedLayoutName: selectedLayoutName,
            recognitionScope: recognitionScope,
            mainBrand: mainBrand,
            secondaryBrand: secondaryBrand,
            strictBrandFilter: strictBrandFilter,
            allowPossibleStragglers: allowPossibleStragglers,
            mainCategory: mainCategory,
            mainSubcategory: mainSubcategory,
            presetName: presetName,
            presetIdRaw: presetIdRaw
        )
        modelContext.insert(session)
        try? modelContext.save()
        currentSession = session
        fetchSessions()
        return session
    }

    func attachExpectedSnapshot(to session: AuditSession, draft: CSVImportDraft, skuInfos: [ParsedSKUInfo]) {
        guard let modelContext else { return }
        let snapshot = ExpectedSnapshot(
            sessionId: session.id,
            sourceFilename: draft.filename,
            rawCSVText: draft.rawCSVText
        )
        modelContext.insert(snapshot)

        let matches = CSVImportService.shared.applyMapping(
            rows: draft.parseResult.rows,
            mapping: draft.mapping,
            skus: skuInfos
        )
        for match in matches {
            let row = ExpectedRow(
                skuOrNameKey: match.skuOrNameKey,
                expectedQty: match.qty,
                locationName: match.locationName,
                zone: match.zone
            )
            row.matchedSkuId = match.matchedSkuId
            row.isMatched = match.isMatched
            row.snapshot = snapshot
            snapshot.rows.append(row)
            modelContext.insert(row)
        }

        session.expectedSnapshot = snapshot
        try? modelContext.save()
    }

    func attachOnHandSnapshot(to session: AuditSession, draft: CSVImportDraft, skuInfos: [ParsedSKUInfo]) {
        guard let modelContext else { return }
        let snapshot = InventorySystemSnapshot(
            sessionId: session.id,
            sourceFilename: draft.filename,
            rawCSVText: draft.rawCSVText
        )
        modelContext.insert(snapshot)

        let matches = CSVImportService.shared.applyMapping(
            rows: draft.parseResult.rows,
            mapping: draft.mapping,
            skus: skuInfos
        )
        for match in matches {
            let row = OnHandRow(skuOrNameKey: match.skuOrNameKey, onHandQty: match.qty)
            row.matchedSkuId = match.matchedSkuId
            row.isMatched = match.isMatched
            row.snapshot = snapshot
            snapshot.rows.append(row)
            modelContext.insert(row)
        }

        session.inventorySnapshot = snapshot
        try? modelContext.save()
    }

    // MARK: - Shelf Expected Inventory

    /// Called when an audit starts for a shelf that has expected inventory attached.
    ///
    /// For each `ShelfExpectedRow` on the layout, this creates (or updates) an
    /// `AuditLineItem` with `expectedQty` pre-populated. The expected quantity
    /// becomes the source of truth for Bag Audit diff calculations.
    ///
    /// - Matching priority:
    ///   1. `ShelfExpectedRow.matchedSkuId` (pre-resolved at CSV upload time)
    ///   2. barcode field on a `ProductSKU`
    ///   3. productId field on a `ProductSKU` (treated as UPC/SKU code)
    ///   4. name-based fuzzy match (skuNameSnapshot)
    func loadExpectedInventoryFromShelf(layout: ShelfLayout, session: AuditSession) {
        guard let modelContext else { return }
        guard layout.hasExpectedInventory else { return }

        // Build a lookup from skuId → ProductSKU for fast resolution
        let allSKUs = (try? modelContext.fetch(FetchDescriptor<ProductSKU>())) ?? []
        let skuById = Dictionary(uniqueKeysWithValues: allSKUs.compactMap { sku -> (UUID, ProductSKU)? in
            (sku.id, sku)
        })
        let skuByBarcode = Dictionary(
            allSKUs.compactMap { sku -> (String, ProductSKU)? in
                guard let bc = sku.barcode, !bc.isEmpty else { return nil }
                return (bc, sku)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for expectedRow in layout.expectedRows {
            // Resolve skuId
            var resolvedSkuId: UUID? = expectedRow.matchedSkuId
            var resolvedName = expectedRow.productName

            if resolvedSkuId == nil, !expectedRow.barcode.isEmpty,
               let sku = skuByBarcode[expectedRow.barcode] {
                resolvedSkuId = sku.id
                resolvedName = sku.productName
            }

            if let skuId = resolvedSkuId, let sku = skuById[skuId] {
                resolvedName = sku.productName
            }

            // Find or create the AuditLineItem for this SKU
            if let existing = session.lineItems.first(where: {
                $0.skuId == resolvedSkuId && resolvedSkuId != nil
            }) {
                existing.expectedQty = expectedRow.expectedQty
                if let exp = existing.expectedQty {
                    existing.delta = existing.visionCount - exp
                    existing.deltaPercent = exp > 0
                        ? Double(existing.visionCount - exp) / Double(exp) * 100
                        : nil
                }
            } else {
                let lineItem = AuditLineItem(
                    session: session,
                    skuId: resolvedSkuId,
                    skuNameSnapshot: resolvedName,
                    visionCount: 0,
                    countConfidence: 1.0,
                    reviewStatus: .confirmed
                )
                lineItem.expectedQty = expectedRow.expectedQty
                lineItem.delta = -expectedRow.expectedQty
                lineItem.deltaPercent = -100
                modelContext.insert(lineItem)
                session.lineItems.append(lineItem)
            }
        }

        try? modelContext.save()
    }

    /// Parse a CSV and replace the expected inventory for a shelf.
    ///
    /// Expected CSV columns (order-independent, case-insensitive headers):
    ///   `product_name` | `name` — required
    ///   `brand`
    ///   `product_id` | `sku`
    ///   `barcode` | `upc`
    ///   `expected_qty` | `qty` | `quantity` — required
    ///
    /// After parsing, rows are matched against the `ProductSKU` catalog by barcode,
    /// then by productId, so that `matchedSkuId` is pre-resolved for fast audit-start loading.
    func uploadShelfExpectedInventory(
        layout: ShelfLayout,
        csvText: String,
        filename: String
    ) {
        guard let modelContext else { return }

        let rows = ShelfCSVParser.parse(csvText: csvText)

        // Match against product catalog
        let allSKUs = (try? modelContext.fetch(FetchDescriptor<ProductSKU>())) ?? []
        let skuByBarcode = Dictionary(
            allSKUs.compactMap { sku -> (String, ProductSKU)? in
                guard let bc = sku.barcode, !bc.isEmpty else { return nil }
                return (bc.lowercased(), sku)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let skuByProductId = Dictionary(
            allSKUs.compactMap { sku -> (String, ProductSKU)? in
                guard !sku.sku.isEmpty else { return nil }
                return (sku.sku.lowercased(), sku)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for row in rows {
            if !row.barcode.isEmpty, let sku = skuByBarcode[row.barcode.lowercased()] {
                row.matchedSkuId = sku.id
                row.isMatched = true
            } else if !row.productId.isEmpty, let sku = skuByProductId[row.productId.lowercased()] {
                row.matchedSkuId = sku.id
                row.isMatched = true
            }
            modelContext.insert(row)
        }

        layout.replaceExpectedRows(with: rows, csvText: csvText, filename: filename)
        try? modelContext.save()
    }

    func addPhoto(data: Data, to session: AuditSession) {
        guard let modelContext else { return }
        let filename = "photo_\(UUID().uuidString).jpg"
        do {
            let path = try MediaStorageService.shared.savePhoto(data, sessionId: session.id, filename: filename)
            let media = CapturedMedia(session: session, type: .photo, fileURL: path)
            modelContext.insert(media)
            try? modelContext.save()
        } catch {}
    }

    func addVideo(tempURL: URL, to session: AuditSession) {
        guard let modelContext else { return }
        let filename = "video_\(UUID().uuidString).mov"
        do {
            let path = try MediaStorageService.shared.saveVideo(from: tempURL, sessionId: session.id, filename: filename)
            let media = CapturedMedia(session: session, type: .video, fileURL: path)
            modelContext.insert(media)
            try? modelContext.save()
        } catch {}
    }

    func processSession(_ session: AuditSession) async {
        guard let modelContext else { return }
        isProcessing = true
        processingProgress = 0
        processingStatus = "Preparing…"
        AuditLogger.shared.logSession("Processing session \(session.id.uuidString.prefix(8)) at \(session.locationName)")

        session.status = .processing
        try? modelContext.save()

        // Phase 1: Frame sampling
        await sampleVideoFrames(session: session, modelContext: modelContext)
        processingProgress = 0.20

        // Phase 2: Collect images
        processingStatus = "Loading images…"
        let imageSources = collectImages(from: session)
        processingProgress = 0.22

        // Phase 3: Fetch embeddings + candidate info
        processingStatus = "Loading catalog…"
        let embeddingRecords = fetchEmbeddingRecords(modelContext: modelContext)
        let (skuIds, expectedQtyMap, onHandQtyMap) = fetchCandidateInfo(for: session, modelContext: modelContext)
        let skuNameMap = fetchSkuNames(modelContext: modelContext)

        // Build the expected sheet context — drives candidate restriction, prior factors,
        // and unexpected-item flagging throughout the entire processing pipeline.
        let expectedSheetCtx = buildExpectedSheetContext(for: session, modelContext: modelContext)
        let priorFactors = buildPriorFactors(
            expectedQtyMap: expectedQtyMap,
            skuIds: skuIds,
            expectedSheetCtx: expectedSheetCtx
        )
        AuditLogger.shared.logSession(
            "ExpectedSheet: \(expectedSheetCtx.candidateSkuIds.count) expected SKUs " +
            "(\'\(expectedSheetCtx.isEmpty ? "no sheet" : "active")\'); " +
            "priorFactors: \(priorFactors.count)"
        )

        let lookAlikeInfo = fetchLookAlikeInfo(modelContext: modelContext)
        let skuKeywordsMap = fetchSkuKeywords(modelContext: modelContext)
        let layoutZoneInfo = fetchLayoutZoneInfo(for: session, lookAlikeInfo: lookAlikeInfo, modelContext: modelContext)
        let smartFocusZonesEnabled = UserDefaults.standard.object(forKey: "smartFocusZonesEnabled") as? Bool ?? true
        let smartFocusOCRZonesEnabled = UserDefaults.standard.object(forKey: "smartFocusOCRZonesEnabled") as? Bool ?? true
        let skuZonesMap: [UUID: [ZoneRect]] = Dictionary(
            uniqueKeysWithValues: skuIds.compactMap { id -> (UUID, [ZoneRect])? in
                guard let groupId = lookAlikeInfo.skuToGroup[id],
                      let zones = lookAlikeInfo.groupZones[groupId],
                      !zones.isEmpty else { return nil }
                return (id, zones)
            }
        )
        processingProgress = 0.25

        // Brand scope: pre-compute brand SKU sets
        let brandScopeInfo = buildBrandScopeInfo(for: session, modelContext: modelContext)

        // Phase 4: Region proposal + classification
        let closeMargin = UserDefaults.standard.double(forKey: "closeMatchMargin").nonZeroOrDefault(0.10)
        let autoAcceptThreshold = UserDefaults.standard.double(forKey: "autoAcceptConfidence").nonZeroOrDefault(0.85)
        let weakMatchThreshold = 0.45

        var allDetections: [RawDetection] = []
        var tentativeCounts: [UUID: Int] = [:]
        var saturatedSkuIds = Set<UUID>()
        let totalImages = max(imageSources.count, 1)

        processingStatus = "Proposing regions…"

        // Pre-compute total expected count for the pile analyzer
        let totalExpected: Int? = expectedQtyMap.values.reduce(0, +) > 0
            ? expectedQtyMap.values.reduce(0, +) : nil
        let isTrayMode = session.mode == .trayCount

        for (i, source) in imageSources.enumerated() {
            let base = 0.25 + Double(i) / Double(totalImages) * 0.45
            processingProgress = base
            processingStatus = "Multi-scale scan… (\(i + 1)/\(totalImages))"

            // ── Tray mode: pile-aware region proposal ────────────────────────────
            // 1. proposeRegionsForTray uses lower thresholds for packed items.
            // 2. PileClusterAnalyzer adds grid/edge-guided sub-regions for dense clusters.
            let rawRegions: [DetectionRegion]
            if isTrayMode, let cgImage = source.image.cgImage {
                let trayRegions = await DetectionService.shared.proposeRegionsForTray(from: source.image)
                rawRegions = await PileClusterAnalyzer.shared.augmentRegions(
                    trayRegions, in: cgImage, expectedItemCount: totalExpected
                )
                AuditLogger.shared.logSession(
                    "Pile analyzer: \(trayRegions.count) standard → \(rawRegions.count) augmented regions (source \(i + 1))"
                )
            } else {
                rawRegions = await DetectionService.shared.proposeRegions(from: source.image)
            }
            let regions = rawRegions

            for region in regions {
                let matchedZone = layoutZoneInfo.findZone(for: region.bbox)
                let zoneCandidateIds: [UUID]? = matchedZone.flatMap { layoutZoneInfo.skuIds(for: $0) }
                var effectiveCandidateIds = zoneCandidateIds ?? skuIds

                // Brand-limited strict filter: narrow candidates to selected brands (preserve zone override)
                if session.recognitionScope == .brandLimited && session.strictBrandFilter && !brandScopeInfo.brandSkuIds.isEmpty {
                    let filtered = effectiveCandidateIds.filter { brandScopeInfo.brandSkuIds.contains($0) }
                    if !filtered.isEmpty { effectiveCandidateIds = filtered }
                }
                let shelfZoneName = matchedZone?.name ?? ""
                let embeddingResult: (vector: Data, quality: QualityMetrics)?
                if !embeddingRecords.isEmpty && !effectiveCandidateIds.isEmpty {
                    embeddingResult = try? await EmbeddingService.shared.computeEmbedding(for: region.cropImage)
                } else {
                    embeddingResult = nil
                }
                let quality = embeddingResult?.quality ?? EmbeddingService.shared.analyzeQuality(for: region.cropImage)
                let queryEmbeddingData = embeddingResult?.vector ?? Data()

                // Compute visibility factor from bbox
                let visibilityFactor: Double = {
                    let bbox = region.bbox
                    if bbox.touchesEdge || bbox.area < 0.015 { return 0.65 }
                    if bbox.area < 0.04 { return 0.82 }
                    return 1.0
                }()

                var reasons: [FlagReason] = []
                if quality.lightScore < 0.25 { reasons.append(.lowLight) }
                if quality.blurScore > 0.60  { reasons.append(.blur) }
                if quality.glareScore > 0.50 { reasons.append(.glare) }
                if region.bbox.touchesEdge || !region.isFromRectangle { reasons.append(.partial) }

                var top3: [DetectedCandidate] = []
                var chosenSkuId: UUID? = nil
                var chosenSkuName = "Unknown Item"
                var finalScore: Double = 0
                var isSoftAssigned = false
                var reviewStatus: ReviewStatus = .pending
                var metadataJSON = ""
                var bestHotspotCropImage: UIImage?
                var contrastiveExplanation = ""
                var contrastiveBoostValue: Double = 0

                if !embeddingRecords.isEmpty && !effectiveCandidateIds.isEmpty {
                    let customHotspots = effectiveCandidateIds.compactMap { skuZonesMap[$0] }.first
                    let focusHotspots: [FocusHotspot] = {
                        guard smartFocusZonesEnabled else { return [] }
                        if let customHotspots, !customHotspots.isEmpty {
                            return OnDeviceEngine.hotspots(from: customHotspots)
                        }
                        return OnDeviceEngine.defaultFocusHotspots()
                    }()

                    let classificationResult = try? await OnDeviceEngine.shared.classifyWithFocusZones(
                        image: region.cropImage,
                        candidateSkuIds: effectiveCandidateIds,
                        embeddings: embeddingRecords,
                        hotspots: focusHotspots,
                        precomputedQueryVector: queryEmbeddingData.isEmpty ? nil : queryEmbeddingData
                    )
                    let rawCandidates: [RecognitionCandidate]
                    if let classificationResult {
                        rawCandidates = classificationResult.candidates
                    } else {
                        rawCandidates = (try? await OnDeviceEngine.shared.classify(
                            image: region.cropImage,
                            candidateSkuIds: effectiveCandidateIds,
                            embeddings: embeddingRecords
                        )) ?? []
                    }

                    if !rawCandidates.isEmpty {
                        var hotspotScores = classificationResult?.hotspots ?? []

                        var priorBoosted = rawCandidates.map { candidate -> RecognitionCandidate in
                            let factor = Float(priorFactors[candidate.skuId] ?? 1.0)
                            var score = min(1.0, candidate.score * factor)

                            // Brand scope boost / penalty (non-strict path only; strict already filtered candidates)
                            if session.recognitionScope == .brandLimited && !session.strictBrandFilter {
                                let isInBrand = brandScopeInfo.brandSkuIds.contains(candidate.skuId)
                                if isInBrand {
                                    score = min(1.0, score + 0.18)
                                } else if session.allowPossibleStragglers {
                                    // Allow outside-brand only if raw confidence is very high
                                    if Float(candidate.score) < 0.78 { score = max(0, score - 0.25) }
                                } else {
                                    score = 0  // suppress when stragglers not allowed
                                }
                            }

                            return RecognitionCandidate(
                                id: candidate.id,
                                skuId: candidate.skuId,
                                score: Float(score),
                                nearestReferenceURL: candidate.nearestReferenceURL
                            )
                        }.sorted { $0.score > $1.score }

                        let shouldRunFocusOCR = smartFocusOCRZonesEnabled && smartFocusZonesEnabled && !focusHotspots.isEmpty
                        if shouldRunFocusOCR {
                            var ocrResults: [OCRZoneResult] = []
                            for hotspot in focusHotspots {
                                guard let hotspotImage = OnDeviceEngine.crop(image: region.cropImage, normalizedRect: hotspot.normalizedRect) else { continue }
                                let recognized = await OCRService.shared.recognizeZones(
                                    in: hotspotImage,
                                    zones: [ZoneRect(name: hotspot.name, x: 0, y: 0, w: 1, h: 1, weight: hotspot.weight)]
                                )
                                ocrResults.append(contentsOf: recognized)
                            }

                            if !ocrResults.isEmpty {
                                let boosts = OCRService.shared.computeBoosts(
                                    ocrResults: ocrResults,
                                    candidates: priorBoosted,
                                    skuKeywords: skuKeywordsMap
                                )
                                if !boosts.isEmpty {
                                    priorBoosted = priorBoosted.map { candidate in
                                        let boost = boosts[candidate.skuId] ?? 0
                                        return RecognitionCandidate(
                                            id: candidate.id,
                                            skuId: candidate.skuId,
                                            score: min(1.0, candidate.score + boost),
                                            nearestReferenceURL: candidate.nearestReferenceURL
                                        )
                                    }.sorted { $0.score > $1.score }
                                }

                                hotspotScores = hotspotScores.map { score in
                                    let matchingText = ocrResults
                                        .filter { $0.zoneName == score.hotspot.name }
                                        .map(\.rawText)
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " · ")
                                    return FocusHotspotScore(
                                        hotspot: score.hotspot,
                                        matchedSkuId: score.matchedSkuId,
                                        score: score.score,
                                        ocrText: matchingText
                                    )
                                }

                                if let bestHotspot = classificationResult?.bestHotspot {
                                    bestHotspotCropImage = OnDeviceEngine.crop(image: region.cropImage, normalizedRect: bestHotspot.normalizedRect)
                                }

                                let metadata = DetectionEvidenceMetadata(
                                    hotspotScores: hotspotScores,
                                    ocrResults: ocrResults,
                                    bestHotspotName: classificationResult?.bestHotspot?.name,
                                    bestHotspotCropURL: nil
                                )
                                if let data = try? JSONEncoder().encode(metadata),
                                   let json = String(data: data, encoding: .utf8) {
                                    metadataJSON = json
                                }
                            }
                        }

                        if metadataJSON.isEmpty {
                            if let bestHotspot = classificationResult?.bestHotspot {
                                bestHotspotCropImage = OnDeviceEngine.crop(image: region.cropImage, normalizedRect: bestHotspot.normalizedRect)
                            }
                            let metadata = DetectionEvidenceMetadata(
                                hotspotScores: hotspotScores,
                                ocrResults: [],
                                bestHotspotName: classificationResult?.bestHotspot?.name,
                                bestHotspotCropURL: nil
                            )
                            if let data = try? JSONEncoder().encode(metadata),
                               let json = String(data: data, encoding: .utf8) {
                                metadataJSON = json
                            }
                        }

                        let boosted = priorBoosted

                        top3 = boosted.prefix(3).map {
                            DetectedCandidate(
                                skuId: $0.skuId,
                                skuName: skuNameMap[$0.skuId] ?? "Unknown",
                                score: $0.score
                            )
                        }

                        if let best = boosted.first, best.score > 0.20 {
                            let second = boosted.dropFirst().first
                            var margin = Double(best.score - (second?.score ?? 0))

                            // Skip saturated high-confidence SKUs
                            if saturatedSkuIds.contains(best.skuId) && Double(best.score) >= 0.75 {
                                continue
                            }

                            // Look-alike group: apply stricter margin
                            let isLookAlike = lookAlikeInfo.skuToGroup[best.skuId] != nil
                            let effectiveCloseMargin = isLookAlike ? min(closeMargin * 1.5, 0.30) : closeMargin

                            chosenSkuId = best.skuId
                            chosenSkuName = skuNameMap[best.skuId] ?? "Unknown"
                            finalScore = Double(best.score) * quality.qualityScore * visibilityFactor

                            // Contrastive Variant Training pass
                            let contrastiveEnabled = UserDefaults.standard.object(forKey: "contrastiveVariantTrainingEnabled") as? Bool ?? true
                            if contrastiveEnabled,
                               let secondCandidate = second,
                               ContrastiveTrainingService.shared.shouldTriggerContrastive(
                                   top3: Array(boosted.prefix(3)),
                                   lookAlikeInfo: lookAlikeInfo,
                                   margin: effectiveCloseMargin
                               ) {
                                let groupId = lookAlikeInfo.skuToGroup[best.skuId]!
                                let ocrAssisted = UserDefaults.standard.object(forKey: "ocrAssistedVariantComparison") as? Bool ?? true

                                // Load differentiator zones from VariantComparisonProfile or ZoneProfile
                                var differentiatorZones: [ZoneRect] = []
                                if let groupZones = lookAlikeInfo.groupZones[groupId], !groupZones.isEmpty {
                                    differentiatorZones = groupZones
                                }

                                let contrastiveResult = await ContrastiveTrainingService.shared.performContrastiveComparison(
                                    cropImage: region.cropImage,
                                    candidate1SkuId: best.skuId,
                                    candidate1Score: best.score,
                                    candidate2SkuId: secondCandidate.skuId,
                                    candidate2Score: secondCandidate.score,
                                    groupId: groupId,
                                    differentiatorZones: differentiatorZones,
                                    skuKeywords: skuKeywordsMap,
                                    embeddings: embeddingRecords,
                                    verifiedSamples: ContrastiveTrainingService.shared.fetchVerifiedSampleRecords(
                                        for: effectiveCandidateIds,
                                        modelContext: modelContext
                                    ),
                                    ocrAssistedEnabled: ocrAssisted
                                )

                                contrastiveExplanation = contrastiveResult.explanation
                                contrastiveBoostValue = contrastiveResult.netAdjustment

                                // Apply contrastive adjustment
                                if contrastiveResult.winnerSkuId != best.skuId {
                                    // Swap to the contrastive winner
                                    chosenSkuId = contrastiveResult.winnerSkuId
                                    chosenSkuName = skuNameMap[contrastiveResult.winnerSkuId] ?? "Unknown"
                                    finalScore = Double(secondCandidate.score) * quality.qualityScore * visibilityFactor + contrastiveResult.netAdjustment
                                    margin = abs(contrastiveResult.netAdjustment)
                                } else {
                                    finalScore += contrastiveResult.netAdjustment
                                }
                            }

                            if Double(best.score) >= autoAcceptThreshold && margin >= effectiveCloseMargin {
                                reviewStatus = .confirmed
                                isSoftAssigned = false
                            } else {
                                reviewStatus = .pending
                                isSoftAssigned = true
                                if margin < effectiveCloseMargin {
                                    reasons.appendIfNotContains(.closeMatch)
                                    if isLookAlike { reasons.appendIfNotContains(.lookAlikeGroup) }
                                }
                                if Double(best.score) < weakMatchThreshold { reasons.appendIfNotContains(.weakMatch) }
                            }

                            if reviewStatus == .confirmed {
                                tentativeCounts[best.skuId, default: 0] += 1
                                if let expected = expectedQtyMap[best.skuId],
                                   tentativeCounts[best.skuId, default: 0] >= expected {
                                    saturatedSkuIds.insert(best.skuId)
                                }
                            }
                        } else {
                            reasons.appendIfNotContains(.weakMatch)
                            finalScore = 0
                        }
                    }
                } else {
                    // No embeddings: all regions become pending with weak-match flag
                    reasons.appendIfNotContains(.weakMatch)
                    isSoftAssigned = true
                    reviewStatus = .pending
                }

                // Brand-limited: flag straggler items detected outside selected brands
                if session.recognitionScope == .brandLimited,
                   let resolvedId = chosenSkuId,
                   !brandScopeInfo.brandSkuIds.isEmpty,
                   !brandScopeInfo.brandSkuIds.contains(resolvedId) {
                    reasons.appendIfNotContains(.outsideSelectedBrand)
                    reviewStatus = .pending  // Always needs review
                    isSoftAssigned = true
                }

                var detection = RawDetection(
                    sourceId: source.id,
                    bbox: region.bbox,
                    top3: top3,
                    finalScore: finalScore,
                    flagReasons: reasons,
                    chosenSkuId: chosenSkuId,
                    chosenSkuName: chosenSkuName,
                    isSoftAssigned: isSoftAssigned,
                    reviewStatus: reviewStatus,
                    scaleLevel: region.scaleLevel,
                    isClusterSplit: region.isClusterSplit,
                    queryEmbeddingData: queryEmbeddingData
                )
                detection.metadataJSON = metadataJSON
                detection.contrastiveExplanation = contrastiveExplanation
                detection.contrastiveBoost = contrastiveBoostValue
                if let bestHotspotCropImage,
                   let bestHotspotData = bestHotspotCropImage.jpegData(compressionQuality: 0.75),
                   let hotspotPath = try? MediaStorageService.shared.saveCrop(
                    bestHotspotData,
                    sessionId: session.id,
                    filename: "hotspot_\(UUID().uuidString).jpg"
                   ) {
                    detection.bestHotspotCropPath = hotspotPath
                }
                detection.shelfZoneName = shelfZoneName
                allDetections.append(detection)
            }
        }

        processingProgress = 0.70

        // Phase 5: Deduplication — strategy depends on mode
        if session.mode == .trayCount {
            // ── Tray Count: cross-frame spatial deduplication ──────────────────────
            // Convert raw detections to TrayDetection, tagged with sourceIndex so the
            // deduplicator can prevent the same physical item being counted twice in
            // the same image.
            processingStatus = "Cross-frame deduplication…"
            let sourceIdToIndex: [UUID: Int] = Dictionary(
                uniqueKeysWithValues: imageSources.enumerated().map { ($1.id, $0) }
            )

            let trayDetections: [TrayDetection] = allDetections.map { raw in
                TrayDetection(
                    sourceIndex: sourceIdToIndex[raw.sourceId] ?? 0,
                    skuId: raw.chosenSkuId,
                    skuName: raw.chosenSkuName,
                    bbox: raw.bbox,
                    confidence: raw.finalScore,
                    isSoftAssigned: raw.isSoftAssigned,
                    flagReasons: raw.flagReasons,
                    reviewStatus: raw.reviewStatus,
                    cropPath: raw.cropPath,
                    queryEmbeddingData: raw.queryEmbeddingData,
                    top3: raw.top3,
                    metadataJSON: raw.metadataJSON
                )
            }

            let (confirmedClusters, reviewItems) = TrayCountDeduplicator.deduplicate(
                trayDetections,
                expectedQtyMap: expectedQtyMap
            )

            AuditLogger.shared.logSession(
                "TrayCount dedup: \(allDetections.count) detections → " +
                "\(confirmedClusters.count) clusters + \(reviewItems.count) low-confidence"
            )

            processingProgress = 0.80
            processingStatus = "Saving evidence…"

            // Phase 6T: Save crops for clusters + build line items
            buildTrayCountLineItems(
                for: session,
                clusters: confirmedClusters,
                reviewItems: reviewItems,
                imageSources: imageSources,
                expectedSheetCtx: expectedSheetCtx,
                modelContext: modelContext
            )

        } else {
            // ── Standard path: per-image IoU deduplication ────────────────────────
            processingStatus = "Deduplicating multi-scale results…"
            let surviving = deduplicate(detections: allDetections)

            processingProgress = 0.80
            processingStatus = "Saving evidence…"

            // Phase 6: Save evidence crops
            var savedDetections: [RawDetection] = []
            for var det in surviving {
                if det.bbox.width > 0,
                   let jpeg = cropFromSource(sourceId: det.sourceId, bbox: det.bbox, imageSources: imageSources),
                   let data = jpeg.jpegData(compressionQuality: 0.75),
                   let path = try? MediaStorageService.shared.saveCrop(
                    data, sessionId: session.id, filename: "crop_\(UUID().uuidString).jpg"
                   ) {
                    det.cropPath = path
                }
                savedDetections.append(det)
            }

            processingProgress = 0.88
            processingStatus = "Summarizing results…"

            // Phase 7: Build line items — pass the expected sheet context for unexpected-item flagging
            buildLineItems(for: session, detections: savedDetections, expectedSheetCtx: expectedSheetCtx, modelContext: modelContext)
        }

        // Phase 8: Reconcile with expected/on-hand
        processingStatus = "Reconciling…"
        reconcileLineItems(
            for: session,
            expectedQtyMap: expectedQtyMap,
            onHandQtyMap: onHandQtyMap,
            skuNameMap: skuNameMap,
            modelContext: modelContext
        )

        processingProgress = 0.95

        // Phase 9: Clean up original video if needed
        let saveOriginal = UserDefaults.standard.object(forKey: "saveOriginalVideo") as? Bool ?? true
        if !saveOriginal {
            for media in session.capturedMedia.filter({ $0.type == .video }) {
                try? FileManager.default.removeItem(atPath: media.fileURL)
            }
        }

        // Set status based on whether there are pending review items
        let hasPendingReview = session.lineItems.contains { item in
            item.evidence.contains { $0.reviewStatus == .pending }
        }
        session.status = hasPendingReview ? .reviewRequired : .complete
        try? modelContext.save()
        processingProgress = 1.0
        processingStatus = hasPendingReview ? "Review Required" : "Complete"
        isProcessing = false

        let totalEvidence = session.lineItems.flatMap(\.evidence).count
        let pendingCount = session.lineItems.flatMap(\.evidence).filter { $0.reviewStatus == .pending }.count
        AuditLogger.shared.logSession("Session complete: \(totalEvidence) detections, \(pendingCount) pending review")

        fetchSessions()
    }

    // MARK: - Finalize Guard

    /// Returns true only when all evidence in the session has been reviewed (none pending).
    func canFinalizeSession(_ session: AuditSession) -> Bool {
        !session.lineItems.contains { item in
            item.evidence.contains { $0.reviewStatus == .pending }
        }
    }

    /// Finalize the session — transitions from .reviewRequired to .complete.
    /// Only succeeds if the review queue is fully resolved.
    func finalizeSession(_ session: AuditSession) -> Bool {
        guard let modelContext else { return false }
        guard canFinalizeSession(session) else { return false }
        session.status = .complete
        try? modelContext.save()
        fetchSessions()
        return true
    }

    // MARK: - Review Actions

    func confirmEvidence(_ evidence: DetectionEvidence) {
        guard let modelContext else { return }
        evidence.reviewStatus = .confirmed
        evidence.isSoftAssigned = false
        recomputeLineItem(evidence.lineItem, modelContext: modelContext)
        try? modelContext.save()

        AuditLogger.shared.logReview(action: "Confirmed", skuName: evidence.chosenSkuName, evidenceId: evidence.id)

        // Save as verified sample for the learning loop
        saveAsVerifiedSample(evidence, modelContext: modelContext)

        // Check if session can now be finalized automatically
        if let session = evidence.lineItem?.session, session.status == .reviewRequired {
            if canFinalizeSession(session) {
                session.status = .complete
                try? modelContext.save()
                fetchSessions()
            }
        }
    }

    func rejectEvidence(_ evidence: DetectionEvidence) {
        guard let modelContext else { return }
        evidence.reviewStatus = .rejected
        recomputeLineItem(evidence.lineItem, modelContext: modelContext)
        try? modelContext.save()
        AuditLogger.shared.logReview(action: "Rejected", skuName: evidence.chosenSkuName, evidenceId: evidence.id)
    }

    func reassignEvidence(_ evidence: DetectionEvidence, toSkuId: UUID, skuName: String) {
        guard let modelContext else { return }
        let oldLineItem = evidence.lineItem
        evidence.chosenSkuId = toSkuId
        evidence.chosenSkuName = skuName
        evidence.reviewStatus = .confirmed
        evidence.isSoftAssigned = false

        if let existing = oldLineItem?.session?.lineItems.first(where: { $0.skuId == toSkuId }) {
            evidence.lineItem = existing
            existing.evidence.append(evidence)
        } else if let session = oldLineItem?.session {
            let newItem = AuditLineItem(
                session: session,
                skuId: toSkuId,
                skuNameSnapshot: skuName,
                reviewStatus: .confirmed
            )
            modelContext.insert(newItem)
            evidence.lineItem = newItem
            newItem.evidence.append(evidence)
        }

        recomputeLineItem(oldLineItem, modelContext: modelContext)
        recomputeLineItem(evidence.lineItem, modelContext: modelContext)
        try? modelContext.save()
    }

    func markEvidenceUnknown(_ evidence: DetectionEvidence) {
        guard let modelContext else { return }
        evidence.chosenSkuId = nil
        evidence.chosenSkuName = "Unknown Item"
        evidence.reviewStatus = .confirmed
        evidence.isSoftAssigned = false
        recomputeLineItem(evidence.lineItem, modelContext: modelContext)
        try? modelContext.save()
    }

    func applyActionToSimilar(
        like evidence: DetectionEvidence,
        allEvidence: [DetectionEvidence],
        action: @escaping (DetectionEvidence) -> Void
    ) {
        guard let bucket = evidence.bbox?.positionBucket,
              let topSkuId = evidence.top3Candidates.first?.skuId else { return }

        for other in allEvidence where other.id != evidence.id && other.reviewStatus == .pending {
            guard let otherBucket = other.bbox?.positionBucket,
                  let otherTopId = other.top3Candidates.first?.skuId else { continue }
            if otherBucket == bucket && otherTopId == topSkuId {
                action(other)
            }
        }
    }

    func reReconcile(session: AuditSession) {
        guard let modelContext else { return }
        var expectedQtyMap: [UUID: Int] = [:]
        var onHandQtyMap: [UUID: Int] = [:]

        if let snap = session.expectedSnapshot {
            for row in snap.rows {
                if let id = row.matchedSkuId {
                    expectedQtyMap[id] = row.expectedQty
                }
            }
        }
        if let snap = session.inventorySnapshot {
            for row in snap.rows {
                if let id = row.matchedSkuId {
                    onHandQtyMap[id] = row.onHandQty
                }
            }
        }

        guard !expectedQtyMap.isEmpty || !onHandQtyMap.isEmpty else { return }

        let skuNameMap = fetchSkuNames(modelContext: modelContext)
        reconcileLineItems(
            for: session,
            expectedQtyMap: expectedQtyMap,
            onHandQtyMap: onHandQtyMap,
            skuNameMap: skuNameMap,
            modelContext: modelContext
        )
        fetchSessions()
    }

    func deleteSession(_ session: AuditSession) {
        guard let modelContext else { return }
        MediaStorageService.shared.deleteSessionFiles(sessionId: session.id)
        modelContext.delete(session)
        try? modelContext.save()
        fetchSessions()
    }

    /// Pause the capture phase — keeps all captured media, marks session as paused.
    /// The user can resume from the session list.
    func pauseSession(_ session: AuditSession) {
        guard let modelContext else { return }
        session.status = .paused
        session.pausedAt = Date()
        try? modelContext.save()
        fetchSessions()
    }

    /// Stop and discard — deletes the session and all associated media files.
    func stopAndDiscardSession(_ session: AuditSession) {
        guard let modelContext else { return }
        MediaStorageService.shared.deleteSessionFiles(sessionId: session.id)
        modelContext.delete(session)
        try? modelContext.save()
        fetchSessions()
    }

    func mediaCount(for session: AuditSession) -> Int { session.capturedMedia.count }
    func frameCount(for session: AuditSession) -> Int {
        session.capturedMedia.reduce(0) { $0 + $1.sampledFrames.count }
    }

    // MARK: - Verified Sample Learning

    /// Saves a confirmed detection's crop image + embedding as a VerifiedSample
    /// so the contrastive training pipeline can learn from user confirmations.
    private func saveAsVerifiedSample(_ evidence: DetectionEvidence, modelContext: ModelContext) {
        guard let skuId = evidence.chosenSkuId,
              evidence.reviewStatus == .confirmed,
              !evidence.cropURL.isEmpty else { return }

        // Check we don't already have a verified sample for this evidence crop
        let descriptor = FetchDescriptor<VerifiedSample>()
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        if existing.contains(where: { $0.cropURL == evidence.cropURL && $0.skuId == skuId }) {
            return
        }

        // Load the crop image and compute its embedding
        guard let cropImage = MediaStorageService.shared.loadImage(at: evidence.cropURL) else { return }

        Task {
            guard let (vector, _) = try? await EmbeddingService.shared.computeEmbedding(for: cropImage) else { return }

            await MainActor.run {
                let sample = VerifiedSample(
                    skuId: skuId,
                    cropURL: evidence.cropURL,
                    vectorData: vector,
                    metadataJSON: "{\"source\":\"review_confirmation\",\"finalScore\":\(evidence.finalScore)}"
                )
                modelContext.insert(sample)
                try? modelContext.save()
            }
        }
    }

    // MARK: - Private Helpers

    private struct BrandScopeInfo {
        let brandSkuIds: Set<UUID>
        let brandsSet: Set<String>
    }

    private func buildBrandScopeInfo(for session: AuditSession, modelContext: ModelContext) -> BrandScopeInfo {
        guard session.recognitionScope == .brandLimited, !session.mainBrand.isEmpty else {
            return BrandScopeInfo(brandSkuIds: [], brandsSet: [])
        }
        var brands = Set<String>([session.mainBrand])
        let secondary = session.secondaryBrand.trimmingCharacters(in: .whitespaces)
        if !secondary.isEmpty { brands.insert(secondary) }

        // Use normalized brand comparison for reliability across casing differences
        let normalizedBrands = brands.map { $0.normalized }
        let descriptor = FetchDescriptor<ProductSKU>()
        let allSKUs = (try? modelContext.fetch(descriptor)) ?? []
        let ids = Set(allSKUs.filter { normalizedBrands.contains($0.normalizedBrand) }.map { $0.id })
        return BrandScopeInfo(brandSkuIds: ids, brandsSet: brands)
    }

    /// Builds a SKUCatalogFilter from the session's recognition scope settings.
    private static func buildCatalogFilter(for session: AuditSession) -> SKUCatalogFilter {
        switch session.recognitionScope {
        case .categoryLimited:
            let mainCategory = session.mainCategory.trimmingCharacters(in: .whitespaces)
            let subCategory = session.mainSubcategory.trimmingCharacters(in: .whitespaces)
            guard !mainCategory.isEmpty else { return SKUCatalogFilter() }
            return SKUCatalogFilter(
                parentCategory: mainCategory,
                subcategory: subCategory.isEmpty ? nil : subCategory,
                activeOnly: true
            )
        case .brandLimited, .all:
            // Brand filtering handled separately in buildBrandScopeInfo
            return SKUCatalogFilter(activeOnly: true)
        }
    }

    private func recomputeLineItem(_ lineItem: AuditLineItem?, modelContext: ModelContext) {
        guard let lineItem else { return }
        let nonRejected = lineItem.evidence.filter { $0.reviewStatus != .rejected }
        let confirmed = nonRejected.filter { $0.reviewStatus == .confirmed }

        lineItem.visionCount = max(confirmed.count, nonRejected.count > 0 ? 1 : 0)

        let scores = nonRejected.map { $0.finalScore }
        let mean = scores.isEmpty ? 0.0 : scores.reduce(0, +) / Double(scores.count)
        let pendingCount = nonRejected.filter { $0.reviewStatus == .pending }.count
        let pendingPenalty = min(0.25, Double(pendingCount) * 0.03)
        let closeMatchPenalty: Double = nonRejected.contains { $0.flagReasons.contains(.closeMatch) } ? 0.05 : 0
        let partialPenalty: Double = nonRejected.contains { $0.flagReasons.contains(.partial) } ? 0.03 : 0
        lineItem.countConfidence = max(0, min(1, mean * (1 - pendingPenalty) - closeMatchPenalty - partialPenalty))

        let hasPending = nonRejected.contains { $0.reviewStatus == .pending }
        let autoAccept = UserDefaults.standard.double(forKey: "autoAcceptConfidence").nonZeroOrDefault(0.85)

        if nonRejected.isEmpty {
            lineItem.reviewStatus = .rejected
        } else if hasPending {
            lineItem.reviewStatus = lineItem.countConfidence >= autoAccept ? .confirmed : .pending
        } else {
            lineItem.reviewStatus = .confirmed
        }

        // Propagate non-mismatch evidence flags to the line item
        var flags: [FlagReason] = lineItem.flagReasons.filter { $0.isMismatch }
        for ev in nonRejected {
            for r in ev.flagReasons where !flags.contains(r) && !r.isMismatch { flags.append(r) }
        }
        lineItem.flagReasons = flags

        // Refresh deltas + mismatch flags via unified service
        if let countService {
            countService.recomputeDeltas(lineItem)
            countService.recomputeMismatchFlags(lineItem)
        }
    }

    private func sampleVideoFrames(session: AuditSession, modelContext: ModelContext) async {
        let videoMedia = session.capturedMedia.filter { $0.type == .video }
        guard !videoMedia.isEmpty else { return }

        let fps = Double(UserDefaults.standard.integer(forKey: "frameSamplingRate"))
        let effectiveFps = fps > 0 ? fps : 2.0

        let videoCount = videoMedia.count

        for (mediaIndex, media) in videoMedia.enumerated() {
            processingStatus = "Sampling frames from video \(mediaIndex + 1) of \(videoCount)…"
            do {
                let results = try await FrameSamplingService.shared.sampleFrames(
                    videoPath: media.fileURL,
                    sessionId: session.id,
                    mediaId: media.id,
                    fps: effectiveFps
                ) { [weak self, mediaIndex, videoCount] progress in
                    Task { @MainActor [weak self] in
                        let base = Double(mediaIndex) / Double(videoCount)
                        let seg = 0.20 / Double(videoCount)
                        self?.processingProgress = base * 0.20 + progress * seg
                    }
                }
                for result in results {
                    let frame = SampledFrame(
                        media: media,
                        frameIndex: result.index,
                        timestampMs: result.timestampMs,
                        fileURL: result.filePath
                    )
                    modelContext.insert(frame)
                }
                try? modelContext.save()
            } catch {}
        }
    }

    private func collectImages(from session: AuditSession) -> [(id: UUID, image: UIImage)] {
        var sources: [(id: UUID, image: UIImage)] = []
        for media in session.capturedMedia {
            if media.type == .photo, let img = MediaStorageService.shared.loadImage(at: media.fileURL) {
                sources.append((id: media.id, image: img))
            }
            for frame in media.sampledFrames {
                if let img = MediaStorageService.shared.loadImage(at: frame.fileURL) {
                    sources.append((id: frame.id, image: img))
                }
            }
        }
        return sources
    }

    private func fetchEmbeddingRecords(modelContext: ModelContext) -> [EmbeddingRecord] {
        let descriptor = FetchDescriptor<Embedding>()
        let embeddings = (try? modelContext.fetch(descriptor)) ?? []
        return embeddings.compactMap { emb -> EmbeddingRecord? in
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
    }


    private func fetchCandidateInfo(for session: AuditSession, modelContext: ModelContext) -> (skuIds: [UUID], expectedQtyMap: [UUID: Int], onHandQtyMap: [UUID: Int]) {
        var expectedQtyMap: [UUID: Int] = [:]
        var onHandQtyMap: [UUID: Int] = [:]

        if let expectedSnapshot = session.expectedSnapshot {
            for row in expectedSnapshot.rows {
                if let skuId = row.matchedSkuId {
                    expectedQtyMap[skuId] = row.expectedQty
                }
            }
        }

        if let inventorySnapshot = session.inventorySnapshot {
            for row in inventorySnapshot.rows {
                if let skuId = row.matchedSkuId {
                    onHandQtyMap[skuId] = row.onHandQty
                }
            }
        }

        // Also incorporate shelf-attached expected rows so that recognized expected quantities
        // are available for saturation and reconciliation even without a per-session CSV.
        if let layoutId = session.selectedLayoutId, expectedQtyMap.isEmpty {
            let descriptor = FetchDescriptor<ShelfLayout>()
            if let layouts = try? modelContext.fetch(descriptor),
               let layout = layouts.first(where: { $0.id == layoutId }) {
                for row in layout.expectedRows {
                    if let skuId = row.matchedSkuId, expectedQtyMap[skuId] == nil {
                        expectedQtyMap[skuId] = row.expectedQty
                    }
                }
            }
        }

        let guidedSkuIds = Array(expectedQtyMap.keys)
        if !guidedSkuIds.isEmpty {
            return (guidedSkuIds, expectedQtyMap, onHandQtyMap)
        }

        let descriptor = FetchDescriptor<ProductSKU>()
        let all = (try? modelContext.fetch(descriptor)) ?? []

        // Narrow candidates using SKUCatalogFilter when category/brand scope is set
        let filter = Self.buildCatalogFilter(for: session)
        let filtered = filter.candidateIds(from: all)
        let candidateIds = filtered.isEmpty ? all.map(\.id) : filtered
        return (candidateIds, expectedQtyMap, onHandQtyMap)
    }

    /// Build an `ExpectedSheetContext` for a session by merging:
    /// 1. ShelfExpectedRow records from the selected layout (layout-attached CSV)
    /// 2. ExpectedRow records from the session's ExpectedSnapshot (per-session CSV upload)
    private func buildExpectedSheetContext(for session: AuditSession, modelContext: ModelContext) -> ExpectedSheetContext {
        var shelfSnapshots: [ShelfExpectedRowSnapshot] = []
        var sessionSnapshots: [ExpectedRowSnapshot] = []

        if let layoutId = session.selectedLayoutId {
            let descriptor = FetchDescriptor<ShelfLayout>()
            if let layouts = try? modelContext.fetch(descriptor),
               let layout = layouts.first(where: { $0.id == layoutId }) {
                shelfSnapshots = layout.expectedRows.map { ShelfExpectedRowSnapshot(from: $0) }
            }
        }

        if let snapshot = session.expectedSnapshot {
            sessionSnapshots = snapshot.rows.map { ExpectedRowSnapshot(from: $0) }
        }

        guard !shelfSnapshots.isEmpty || !sessionSnapshots.isEmpty else { return .empty }
        return ExpectedSheetContext(shelfRows: shelfSnapshots, sessionRows: sessionSnapshots)
    }

    private func buildPriorFactors(
        expectedQtyMap: [UUID: Int],
        skuIds: [UUID],
        expectedSheetCtx: ExpectedSheetContext = .empty
    ) -> [UUID: Double] {
        // If an expected sheet context is available, use its richer prior computation.
        if !expectedSheetCtx.isEmpty {
            return expectedSheetCtx.priorFactors(for: skuIds)
        }
        // Legacy path: minimal 1.1/0.85 boost from raw qty map.
        guard !expectedQtyMap.isEmpty else { return [:] }
        var factors: [UUID: Double] = [:]
        for skuId in skuIds {
            if let expected = expectedQtyMap[skuId] {
                factors[skuId] = expected > 0 ? 1.1 : 0.85
            } else {
                factors[skuId] = 1.0
            }
        }
        return factors
    }

    private func fetchSkuNames(modelContext: ModelContext) -> [UUID: String] {
        let descriptor = FetchDescriptor<ProductSKU>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
    }

    private func fetchSkuKeywords(modelContext: ModelContext) -> [UUID: [String]] {
        let descriptor = FetchDescriptor<ProductSKU>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        var result: [UUID: [String]] = [:]
        for sku in all where !sku.ocrKeywords.isEmpty {
            result[sku.id] = sku.ocrKeywords
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return result
    }

    private func fetchLookAlikeInfo(modelContext: ModelContext) -> (skuToGroup: [UUID: UUID], groupZones: [UUID: [ZoneRect]]) {
        let memberDescriptor = FetchDescriptor<LookAlikeGroupMember>()
        let members = (try? modelContext.fetch(memberDescriptor)) ?? []

        let profileDescriptor = FetchDescriptor<ZoneProfile>()
        let profiles = (try? modelContext.fetch(profileDescriptor)) ?? []

        var skuToGroup: [UUID: UUID] = [:]
        for member in members {
            if let group = member.group {
                skuToGroup[member.skuId] = group.id
            }
        }

        var groupZones: [UUID: [ZoneRect]] = [:]
        for profile in profiles where !profile.zones.isEmpty {
            groupZones[profile.groupId] = profile.zones
        }

        return (skuToGroup, groupZones)
    }

    private func fetchLayoutZoneInfo(
        for session: AuditSession,
        lookAlikeInfo: (skuToGroup: [UUID: UUID], groupZones: [UUID: [ZoneRect]]),
        modelContext: ModelContext
    ) -> LayoutZoneInfo {
        guard let layoutId = session.selectedLayoutId else { return LayoutZoneInfo(zones: [], groupMembers: [:]) }
        let descriptor = FetchDescriptor<ShelfZone>()
        let allZones = (try? modelContext.fetch(descriptor)) ?? []
        let zones = allZones.filter { $0.layoutId == layoutId }.sorted { $0.sortOrder < $1.sortOrder }

        let memberDescriptor = FetchDescriptor<LookAlikeGroupMember>()
        let members = (try? modelContext.fetch(memberDescriptor)) ?? []
        var groupMembers: [UUID: [UUID]] = [:]
        for member in members {
            if let groupId = member.group?.id {
                groupMembers[groupId, default: []].append(member.skuId)
            }
        }
        return LayoutZoneInfo(zones: zones, groupMembers: groupMembers)
    }

    private func deduplicate(detections: [RawDetection]) -> [RawDetection] {
        let groupedBySource = Dictionary(grouping: detections, by: \.sourceId)
        var deduped: [RawDetection] = []

        for (_, sourceDetections) in groupedBySource {
            let sorted = sourceDetections.sorted { mergePriority(for: $0) > mergePriority(for: $1) }
            var kept: [RawDetection] = []

            for detection in sorted {
                if let existingIndex = kept.firstIndex(where: { shouldMerge(detection, with: $0) }) {
                    if mergePriority(for: detection) > mergePriority(for: kept[existingIndex]) {
                        kept[existingIndex] = detection
                    }
                } else {
                    kept.append(detection)
                }
            }

            deduped.append(contentsOf: kept)
        }

        return deduped
    }

    private func shouldMerge(_ lhs: RawDetection, with rhs: RawDetection) -> Bool {
        let overlap = lhs.bbox.iou(with: rhs.bbox)
        let centerDistance = detectionCenterDistance(lhs, rhs)
        let similarity = detectionEmbeddingSimilarity(lhs, rhs)
        let sameSku = lhs.chosenSkuId != nil && lhs.chosenSkuId == rhs.chosenSkuId
        let distanceThreshold = max(detectionDistanceThreshold(for: lhs), detectionDistanceThreshold(for: rhs))

        if overlap >= 0.62 {
            return true
        }
        if sameSku && overlap >= 0.30 {
            return true
        }
        if sameSku && centerDistance <= distanceThreshold && similarity >= 0.90 {
            return true
        }
        if overlap >= 0.38 && similarity >= 0.92 {
            return true
        }
        return centerDistance <= distanceThreshold * 0.8 && similarity >= 0.97
    }

    private func detectionEmbeddingSimilarity(_ lhs: RawDetection, _ rhs: RawDetection) -> Float {
        guard !lhs.queryEmbeddingData.isEmpty, !rhs.queryEmbeddingData.isEmpty else { return 0 }
        return EmbeddingService.shared.cosineSimilarity(vectorA: lhs.queryEmbeddingData, vectorB: rhs.queryEmbeddingData)
    }

    private func detectionCenterDistance(_ lhs: RawDetection, _ rhs: RawDetection) -> Double {
        let dx = lhs.bbox.centerX - rhs.bbox.centerX
        let dy = lhs.bbox.centerY - rhs.bbox.centerY
        return sqrt(dx * dx + dy * dy)
    }

    private func detectionDistanceThreshold(for detection: RawDetection) -> Double {
        let diagonal = sqrt(detection.bbox.width * detection.bbox.width + detection.bbox.height * detection.bbox.height)
        return max(0.04, diagonal * 0.45)
    }

    private func mergePriority(for detection: RawDetection) -> Double {
        let partialPenalty = detection.flagReasons.contains(.partial) ? 0.04 : 0
        let reviewBoost = detection.reviewStatus == .confirmed ? 0.02 : 0
        let splitBoost = detection.isClusterSplit ? 0.02 : 0
        let scaleBoost: Double

        switch detection.scaleLevel {
        case 0.95...:
            scaleBoost = 0.01
        case 0.70...:
            scaleBoost = 0.02
        default:
            scaleBoost = 0.03
        }

        return detection.finalScore + reviewBoost + splitBoost + scaleBoost - partialPenalty
    }

    private func cropFromSource(sourceId: UUID, bbox: BoundingBox, imageSources: [(id: UUID, image: UIImage)]) -> UIImage? {
        guard let source = imageSources.first(where: { $0.id == sourceId }),
              let cgImage = source.image.cgImage else { return nil }
        let w = Double(cgImage.width)
        let h = Double(cgImage.height)
        let rect = CGRect(x: bbox.x * w, y: bbox.y * h, width: bbox.width * w, height: bbox.height * h)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    private func buildLineItems(
        for session: AuditSession,
        detections: [RawDetection],
        expectedSheetCtx: ExpectedSheetContext = .empty,
        modelContext: ModelContext
    ) {
        let autoAccept = UserDefaults.standard.double(forKey: "autoAcceptConfidence").nonZeroOrDefault(0.85)

        var grouped: [String: [RawDetection]] = [:]
        for det in detections {
            let skuPart = det.chosenSkuId?.uuidString ?? "unknown"
            let zonePart = det.shelfZoneName.isEmpty ? "" : "__zone__\(det.shelfZoneName)"
            let key = skuPart + zonePart
            grouped[key, default: []].append(det)
        }

        for (_, group) in grouped {
            guard let first = group.first else { continue }
            let scores = group.map { $0.finalScore }
            let mean = scores.reduce(0, +) / Double(max(scores.count, 1))
            let pendingCount = group.filter { $0.reviewStatus == .pending }.count
            let pendingPenalty = min(0.25, Double(pendingCount) * 0.03)
            let closeMatchPenalty: Double = group.contains { $0.flagReasons.contains(.closeMatch) } ? 0.05 : 0
            let partialPenalty: Double = group.contains { $0.flagReasons.contains(.partial) } ? 0.03 : 0
            let confidence = max(0, min(1, mean * (1 - pendingPenalty) - closeMatchPenalty - partialPenalty))

            let hasPending = group.contains { $0.reviewStatus == .pending }
            var itemReviewStatus: ReviewStatus = (confidence >= autoAccept && !hasPending) ? .confirmed : .pending

            var allFlags: [FlagReason] = []
            for det in group {
                for r in det.flagReasons where !allFlags.contains(r) { allFlags.append(r) }
            }

            // --- Expected sheet intelligence ---
            // 1. Flag items not on the expected sheet as .unexpectedItem → routes to review.
            // 2. Flag items whose count suspiciously exceeds expected → .suspiciousOvercount → review.
            if !expectedSheetCtx.isEmpty, let skuId = first.chosenSkuId {
                let proposedCount = group.count
                let sanity = expectedSheetCtx.sanityCheck(
                    skuId: skuId,
                    productName: first.chosenSkuName,
                    proposedCount: proposedCount
                )
                switch sanity {
                case .ok:
                    break // Normal — no additional flag needed

                case .unexpectedItem:
                    allFlags.appendIfNotContains(.unexpectedItem)
                    // Unexpected items always need operator confirmation
                    itemReviewStatus = .pending
                    AuditLogger.shared.logRecognition(
                        skuName: first.chosenSkuName,
                        score: mean,
                        status: "unexpected-item (not on expected sheet)"
                    )

                case .suspiciousOvercount(let expectedQty, let actualCount, let multiplier):
                    allFlags.appendIfNotContains(.suspiciousOvercount)
                    // Also flag as overage if not already
                    if expectedQty > 0 { allFlags.appendIfNotContains(.overage) }
                    // Force review for suspicious counts
                    itemReviewStatus = .pending
                    AuditLogger.shared.logRecognition(
                        skuName: first.chosenSkuName,
                        score: mean,
                        status: "suspicious-overcount (expected=\(expectedQty), actual=\(actualCount), \(String(format: "%.1f", multiplier))×)"
                    )
                }
            }

            let lineItem = AuditLineItem(
                session: session,
                skuId: first.chosenSkuId,
                skuNameSnapshot: first.chosenSkuName,
                visionCount: group.count,
                countConfidence: confidence,
                inferredFromPrior: false,
                isSoftAssigned: group.contains { $0.isSoftAssigned },
                reviewStatus: itemReviewStatus
            )
            lineItem.flagReasons = allFlags
            lineItem.shelfZoneName = first.shelfZoneName
            modelContext.insert(lineItem)

            for det in group {
                let evidence = DetectionEvidence(
                    sessionId: session.id,
                    cropURL: det.cropPath,
                    frameSourceId: det.sourceId,
                    bbox: det.bbox,
                    top3Candidates: det.top3,
                    chosenSkuId: det.chosenSkuId,
                    chosenSkuName: det.chosenSkuName,
                    finalScore: det.finalScore,
                    reasons: det.flagReasons,
                    reviewStatus: det.reviewStatus,
                    isSoftAssigned: det.isSoftAssigned
                )
                if let data = det.metadataJSON.data(using: .utf8),
                   var metadata = try? JSONDecoder().decode(DetectionEvidenceMetadata.self, from: data) {
                    metadata = DetectionEvidenceMetadata(
                        hotspotScores: metadata.hotspotScores,
                        ocrResults: metadata.ocrResults,
                        bestHotspotName: metadata.bestHotspotName,
                        bestHotspotCropURL: det.bestHotspotCropPath.isEmpty ? nil : det.bestHotspotCropPath
                    )
                    if let encoded = try? JSONEncoder().encode(metadata),
                       let json = String(data: encoded, encoding: .utf8) {
                        evidence.metadataJSON = json
                    }
                } else {
                    evidence.metadataJSON = det.metadataJSON
                }
                evidence.lineItem = lineItem
                evidence.contrastiveExplanation = det.contrastiveExplanation
                evidence.contrastiveBoost = det.contrastiveBoost
                evidence.scaleLevel = det.scaleLevel
                evidence.isClusterSplit = det.isClusterSplit
                modelContext.insert(evidence)
            }

            try? modelContext.save()
        }
    }

    // MARK: - Tray Count Line Item Builder

    /// Converts `TrayItemCluster` results from cross-frame deduplication into
    /// `AuditLineItem` records — one cluster = one physical object = count of 1.
    ///
    /// Groups are then accumulated by SKU so the line item count equals the number
    /// of distinct physical objects found (not detection count).
    ///
    /// Low-confidence review items are grouped by SKU into separate pending line items
    /// so operators see a concise list rather than hundreds of individual crops.
    private func buildTrayCountLineItems(
        for session: AuditSession,
        clusters: [TrayItemCluster],
        reviewItems: [TrayDetection],
        imageSources: [(id: UUID, image: UIImage)],
        expectedSheetCtx: ExpectedSheetContext,
        modelContext: ModelContext
    ) {
        let autoAccept = UserDefaults.standard.double(forKey: "autoAcceptConfidence").nonZeroOrDefault(0.85)

        // Group confirmed clusters by SKU (nil = unknown)
        var clustersBySkuId: [String: [TrayItemCluster]] = [:]
        for cluster in clusters {
            let key = cluster.skuId?.uuidString ?? "unknown"
            clustersBySkuId[key, default: []].append(cluster)
        }

        // Build one AuditLineItem per SKU — visionCount = number of confirmed clusters
        for (_, skuClusters) in clustersBySkuId {
            guard let first = skuClusters.first else { continue }

            let count = skuClusters.count
            let meanConf = skuClusters.reduce(0.0) { $0 + $1.confidence } / Double(max(count, 1))

            var allFlags = first.allFlagReasons
            let hasPending = skuClusters.contains { $0.reviewStatus == .pending }
            var itemStatus: ReviewStatus = (meanConf >= autoAccept && !hasPending) ? .confirmed : .pending

            // Apply expected-sheet sanity check for tray items too
            if !expectedSheetCtx.isEmpty, let skuId = first.skuId {
                let sanity = expectedSheetCtx.sanityCheck(skuId: skuId, productName: first.skuName, proposedCount: count)
                switch sanity {
                case .ok: break
                case .unexpectedItem:
                    allFlags.appendIfNotContains(.unexpectedItem)
                    itemStatus = .pending
                    AuditLogger.shared.logRecognition(skuName: first.skuName, score: meanConf, status: "tray-unexpected-item")
                case .suspiciousOvercount(let eq, let ac, let mult):
                    allFlags.appendIfNotContains(.suspiciousOvercount)
                    if eq > 0 { allFlags.appendIfNotContains(.overage) }
                    itemStatus = .pending
                    AuditLogger.shared.logRecognition(skuName: first.skuName, score: meanConf,
                        status: "tray-suspicious-overcount (expected=\(eq), actual=\(ac), \(String(format: "%.1f", mult))×)")
                }
            }

            let lineItem = AuditLineItem(
                session: session,
                skuId: first.skuId,
                skuNameSnapshot: first.skuName,
                visionCount: count,
                countConfidence: meanConf,
                inferredFromPrior: false,
                isSoftAssigned: skuClusters.contains { $0.isSoftAssigned },
                reviewStatus: itemStatus
            )
            lineItem.flagReasons = allFlags
            modelContext.insert(lineItem)

            // Attach evidence for every cluster member (best crop from representative)
            for cluster in skuClusters {
                let rep = cluster.representative
                let cropPath = rep.cropPath

                let evidence = DetectionEvidence(
                    sessionId: session.id,
                    cropURL: cropPath,
                    frameSourceId: session.id,
                    bbox: rep.bbox,
                    top3Candidates: rep.top3,
                    chosenSkuId: rep.skuId,
                    chosenSkuName: rep.skuName,
                    finalScore: rep.confidence,
                    reasons: rep.flagReasons,
                    reviewStatus: rep.reviewStatus,
                    isSoftAssigned: rep.isSoftAssigned
                )
                evidence.lineItem = lineItem
                modelContext.insert(evidence)
            }
        }

        // ── Grouped pile review ──────────────────────────────────────────────────
        // Instead of one pending line item per SKU, spatially cluster the review
        // items into pile zones ("Pile A", "Pile B", …).
        // Each pile zone becomes ONE pending line item so the operator reviews
        // a consolidated cluster rather than individual uncertain detections.
        let pileGroups = TrayCountDeduplicator.groupReviewItemsIntoPileClusters(reviewItems)

        for pileGroup in pileGroups {
            guard let rep = pileGroup.bestRepresentative else { continue }

            // Pile-level flags
            var reviewFlags = pileGroup.allFlagReasons
            reviewFlags.appendIfNotContains(.partial)   // mark as partially resolved cluster

            let reviewLineItem = AuditLineItem(
                session: session,
                skuId: pileGroup.majoritySkuId,
                skuNameSnapshot: "\(pileGroup.label): \(pileGroup.majoritySkuName)",
                visionCount: pileGroup.estimatedCount,
                countConfidence: pileGroup.averageConfidence,
                inferredFromPrior: false,
                isSoftAssigned: true,
                reviewStatus: .pending
            )
            reviewLineItem.flagReasons = reviewFlags
            modelContext.insert(reviewLineItem)

            // Attach one evidence per pile member (crops kept for operator reference)
            for trayDet in pileGroup.members {
                let evidence = DetectionEvidence(
                    sessionId: session.id,
                    cropURL: trayDet.cropPath,
                    frameSourceId: session.id,
                    bbox: trayDet.bbox,
                    top3Candidates: trayDet.top3,
                    chosenSkuId: trayDet.skuId,
                    chosenSkuName: trayDet.skuName,
                    finalScore: trayDet.confidence,
                    reasons: trayDet.flagReasons,
                    reviewStatus: .pending,
                    isSoftAssigned: true
                )
                evidence.lineItem = reviewLineItem
                modelContext.insert(evidence)
            }

            AuditLogger.shared.logSession(
                "Pile review: '\(pileGroup.label)' — \(pileGroup.members.count) uncertain detections → estimated \(pileGroup.estimatedCount) items"
            )
        }

        try? modelContext.save()
    }


    private func reconcileLineItems(
        for session: AuditSession,
        expectedQtyMap: [UUID: Int],
        onHandQtyMap: [UUID: Int],
        skuNameMap: [UUID: String],
        modelContext: ModelContext
    ) {
        for item in session.lineItems {
            guard let skuId = item.skuId else { continue }

            item.expectedQty = expectedQtyMap[skuId]
            item.posOnHand = onHandQtyMap[skuId]

            // Unified delta + flag computation
            if let countService {
                countService.recomputeDeltas(item)
                countService.recomputeMismatchFlags(item)
            } else {
                // Fallback if countService not injected
                if let exp = item.expectedQty {
                    let d = item.visionCount - exp
                    item.delta = d
                    item.deltaPercent = exp > 0 ? Double(d) / Double(exp) : nil
                }
                if let oh = item.posOnHand {
                    let d = item.visionCount - oh
                    item.deltaOnHand = d
                    item.deltaOnHandPercent = oh > 0 ? Double(d) / Double(oh) : nil
                }
            }
        }

        // Ghost items for expected SKUs not detected
        let existingSkuIds = Set(session.lineItems.compactMap { $0.skuId })
        for (skuId, expectedQty) in expectedQtyMap where !existingSkuIds.contains(skuId) && expectedQty > 0 {
            let item = AuditLineItem(
                session: session,
                skuId: skuId,
                skuNameSnapshot: skuNameMap[skuId] ?? "Unknown",
                visionCount: 0,
                countConfidence: 0,
                inferredFromPrior: false,
                reviewStatus: .confirmed
            )
            item.expectedQty = expectedQty
            item.posOnHand = onHandQtyMap[skuId]
            modelContext.insert(item)

            // Use unified service for ghost items too
            if let countService {
                countService.recomputeDeltas(item)
                countService.recomputeMismatchFlags(item)
            } else {
                item.delta = -expectedQty
                item.deltaPercent = -1.0
                if let oh = item.posOnHand {
                    item.deltaOnHand = -oh
                    item.deltaOnHandPercent = oh > 0 ? -1.0 : nil
                }
                item.flagReasons = [.shortage]
            }
        }

        try? modelContext.save()
    }
}
