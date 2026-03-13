import Foundation
import SwiftData

/// Stage 1 multi-device sync orchestrator.
///
/// Dashboard (host):
///   1. Calls `hostSession(auditSession:)` to create a SharedAuditSession + generate a session code.
///   2. Receives `joinRequest`, validates the code, sends back `joinAck` with session info.
///   3. Receives `scanEvent` payloads → records them in `ScanEventStore` → updates AuditLineItem
///      quantities → broadcasts `quantityUpdate` back to the scanner.
///
/// Scanner (joiner):
///   1. User enters code or scans QR → calls `requestJoin(code:)`.
///   2. Receives `joinAck` → stores `activeSharedSession`.
///   3. When LiveScan detects a product → calls `sendScanEvent(_:)`.
///   4. Receives `quantityUpdate` payloads → stores them in `remoteQuantities`.
@Observable
@MainActor
final class SessionSyncService {

    // MARK: - Public State

    // Phase 0 compat
    var remoteScanResults: [ScanResultPayload] = []
    var remoteRunningCounts: [String: Int] = [:]
    var remoteTotalItems: Int = 0
    var remoteScanStatus: String = "idle"
    var remoteFramesProcessed: Int = 0

    // Stage 1: Session state
    var activeSharedSession: SharedAuditSession?
    var isHosting: Bool = false
    var joinState: JoinState = .idle
    var pendingSessionCode: String = ""

    // Stage 1: Quantity tracking (dashboard accumulates, scanner receives updates)
    let scanEventStore = ScanEventStore()
    var remoteQuantities: [UUID: SKUQuantityUpdate] = [:]  // skuId → latest update

    // MARK: - Join State

    enum JoinState: Equatable {
        case idle
        case waitingForAck
        case joined
        case rejected(String)
    }

    // MARK: - Callbacks for higher-level layers

    /// Called on the dashboard when a new ScanEvent has been received and quantities updated.
    /// Parameters: (skuId, skuName, actualQty)
    var onQuantityUpdated: ((UUID?, String, Int) -> Void)?

    /// Called when join is accepted or rejected (scanner side).
    var onJoinStateChanged: ((JoinState) -> Void)?

    // MARK: - Dependencies

    let multipeerService: MultipeerService
    private(set) var deviceRole: DeviceRole = .dashboard
    private var modelContext: ModelContext?

    /// Optional unified count service for persisting line item updates.
    var countService: AuditCountService?

    // MARK: - Init

    init(multipeerService: MultipeerService) {
        self.multipeerService = multipeerService
        setupDataHandler()
    }

    /// Provide a ModelContext so the service can update AuditLineItem records on the dashboard.
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Setup

    func start(as role: DeviceRole) {
        deviceRole = role
        multipeerService.start(as: role)
    }

    func stop() {
        multipeerService.stop()
        resetRemoteState()
        activeSharedSession = nil
        isHosting = false
        joinState = .idle
        pendingSessionCode = ""
        scanEventStore.clear()
        remoteQuantities = [:]
    }

    func resetRemoteState() {
        remoteScanResults = []
        remoteRunningCounts = [:]
        remoteTotalItems = 0
        remoteScanStatus = "idle"
        remoteFramesProcessed = 0
    }

    // MARK: - Hosting (Dashboard)

    /// Create a shared session bound to an existing AuditSession.
    /// Returns the join code for display.
    @discardableResult
    func hostSession(auditSession: AuditSession) -> String {
        let code = SessionCodeService.generate()
        let host = SessionParticipant(
            deviceId: multipeerService.deviceId,
            displayName: multipeerService.deviceId,
            role: .dashboard
        )
        let shared = SharedAuditSession(
            sessionId: auditSession.id,
            sessionCode: code,
            locationName: auditSession.locationName,
            hostParticipant: host
        )
        activeSharedSession = shared
        isHosting = true
        AuditLogger.shared.logSession("SessionSync: hosting session \(code) for \(auditSession.locationName)")
        return code
    }

    // MARK: - Joining (Scanner)

    /// Scanner sends a join request with the entered session code.
    func requestJoin(code: String) {
        guard multipeerService.isConnected else {
            joinState = .rejected("No connected device found. Pair first.")
            return
        }
        let normalized = SessionCodeService.normalize(code)
        guard SessionCodeService.isValid(normalized) else {
            joinState = .rejected("Invalid session code format.")
            return
        }
        let payload = JoinRequestPayload(
            sessionCode: normalized,
            deviceId: multipeerService.deviceId,
            displayName: multipeerService.deviceId,
            requestedRole: .scanner
        )
        guard let payloadData = payload.encoded() else { return }
        sendMessage(type: .joinRequest, payload: payloadData)
        joinState = .waitingForAck
        pendingSessionCode = normalized
        AuditLogger.shared.logSession("SessionSync: join request sent for code \(normalized)")
    }

    // MARK: - Scan Events (Scanner → Dashboard)

    /// Scanner calls this when a detection occurs during a shared session.
    func sendScanEvent(_ event: ScanEvent) {
        guard deviceRole == .scanner, multipeerService.isConnected else { return }
        guard let payloadData = event.encoded() else { return }
        sendMessage(type: .scanEvent, payload: payloadData)

        // Also update legacy Phase 0 running counts locally on scanner
        remoteRunningCounts[event.skuName, default: 0] += 1
        remoteTotalItems += 1
    }

    // MARK: - Phase 0 compat send methods

    func sendScanResult(_ payload: ScanResultPayload) {
        guard deviceRole == .scanner, multipeerService.isConnected else { return }
        guard let payloadData = payload.encoded() else { return }
        sendMessage(type: .scanResult, payload: payloadData)
    }

    func sendStatusChange(status: String, framesProcessed: Int, totalItems: Int) {
        guard multipeerService.isConnected else { return }
        let payload = StatusChangePayload(
            newStatus: status,
            framesProcessed: framesProcessed,
            totalItemsDetected: totalItems
        )
        guard let payloadData = payload.encoded() else { return }
        sendMessage(type: .statusChange, payload: payloadData)
    }

    func sendHeartbeat() {
        guard multipeerService.isConnected else { return }
        sendMessage(type: .heartbeat, payload: Data())
    }

    // MARK: - Receiving

    private func setupDataHandler() {
        multipeerService.onDataReceived = { [weak self] data, senderName in
            Task { @MainActor [weak self] in
                self?.handleIncomingData(data, from: senderName)
            }
        }
    }

    private func handleIncomingData(_ data: Data, from senderName: String) {
        guard let message = SessionSyncMessage.decode(from: data) else {
            AuditLogger.shared.logError("SessionSync: decode failed from \(senderName)")
            return
        }

        switch message.type {
        // Phase 0
        case .scanResult:       handleScanResult(message.payload)
        case .statusChange:     handleStatusChange(message.payload)
        case .heartbeat:        break
        case .sessionInfo:      break

        // Stage 1
        case .joinRequest:      handleJoinRequest(message.payload)
        case .joinAck:          handleJoinAck(message.payload)
        case .scanEvent:        handleScanEvent(message.payload)
        case .quantityUpdate:   handleQuantityUpdate(message.payload)
        }
    }

    // MARK: - Incoming: Dashboard handlers

    private func handleJoinRequest(_ data: Data) {
        // Only the dashboard handles join requests
        guard deviceRole == .dashboard, isHosting else { return }
        guard let request = JoinRequestPayload.decode(from: data) else { return }
        guard let session = activeSharedSession else { return }

        let codeMatches = SessionCodeService.normalize(request.sessionCode) == session.sessionCode

        if codeMatches {
            // Accept: add participant and send back the full session info
            let participant = SessionParticipant(
                deviceId: request.deviceId,
                displayName: request.displayName,
                role: request.requestedRole
            )
            activeSharedSession?.participants.append(participant)

            let ack = JoinAckPayload(
                accepted: true,
                rejectionReason: nil,
                sharedSession: activeSharedSession
            )
            if let payloadData = ack.encoded() {
                sendMessage(type: .joinAck, payload: payloadData)
            }
            AuditLogger.shared.logSession("SessionSync: accepted join from \(request.displayName)")
        } else {
            // Reject
            let ack = JoinAckPayload(
                accepted: false,
                rejectionReason: "Session code does not match.",
                sharedSession: nil
            )
            if let payloadData = ack.encoded() {
                sendMessage(type: .joinAck, payload: payloadData)
            }
            AuditLogger.shared.logError("SessionSync: rejected join from \(request.displayName) — bad code")
        }
    }

    private func handleScanEvent(_ data: Data) {
        // Only the dashboard processes incoming scan events
        guard deviceRole == .dashboard else { return }
        guard let event = ScanEvent.decode(from: data) else { return }
        guard let session = activeSharedSession, event.sessionId == session.sessionId else { return }

        // Record in the in-memory store
        let newTally = scanEventStore.record(event)

        // === Persist to SwiftData AuditLineItem ===
        persistScanEvent(event, tally: newTally)

        // Compute expected quantity from the SwiftData AuditSession if context is available
        let expectedQty = fetchExpectedQty(skuId: event.skuId, skuName: event.skuName)
        let difference = expectedQty.map { newTally - $0 }

        // Push update back to the scanner
        if let skuId = event.skuId {
            let update = SKUQuantityUpdate(
                skuId: skuId,
                skuName: event.skuName,
                actualQty: newTally,
                expectedQty: expectedQty,
                difference: difference,
                sessionTotalItems: scanEventStore.totalCount
            )
            remoteQuantities[skuId] = update
            if let payloadData = update.encoded() {
                sendMessage(type: .quantityUpdate, payload: payloadData)
            }
        }

        // Notify observers (e.g., DashboardView)
        onQuantityUpdated?(event.skuId, event.skuName, newTally)

        // Also update Phase 0 compat state
        remoteRunningCounts[event.skuName, default: 0] += event.quantity
        remoteTotalItems = scanEventStore.totalCount

        AuditLogger.shared.logRecognition(
            skuName: event.skuName,
            score: event.confidence,
            status: "remote-scanEvent(\(event.sourceType.rawValue), qty=\(event.quantity))"
        )
    }

    /// Persist the scan event quantity into the AuditLineItem for the active session.
    private func persistScanEvent(_ event: ScanEvent, tally: Int) {
        guard let context = modelContext,
              let session = activeSharedSession else { return }

        let sessionId = session.sessionId
        let descriptor = FetchDescriptor<AuditSession>(
            predicate: #Predicate { $0.id == sessionId }
        )
        guard let auditSession = try? context.fetch(descriptor).first else { return }

        // Use AuditCountService if available (unified delta/flag logic)
        if let countService {
            // Create a temporary service without syncService to avoid re-broadcasting
            countService.recordCount(
                session: auditSession,
                skuId: event.skuId,
                skuName: event.skuName,
                quantity: event.quantity,
                confidence: event.confidence,
                sourceType: event.sourceType,
                context: context,
                skipBroadcast: true
            )
        } else {
            // Fallback: inline persistence
            if let skuId = event.skuId,
               let lineItem = auditSession.lineItems.first(where: { $0.skuId == skuId }) {
                lineItem.visionCount += event.quantity
                if let exp = lineItem.expectedQty {
                    lineItem.delta = lineItem.visionCount - exp
                    lineItem.deltaPercent = exp > 0
                        ? Double(lineItem.visionCount - exp) / Double(exp) * 100
                        : nil
                }
            } else {
                let lineItem = AuditLineItem(
                    session: auditSession,
                    skuId: event.skuId,
                    skuNameSnapshot: event.skuName,
                    visionCount: event.quantity,
                    countConfidence: event.confidence,
                    reviewStatus: .confirmed
                )
                context.insert(lineItem)
                auditSession.lineItems.append(lineItem)
            }
            try? context.save()
        }
    }

    // MARK: - Incoming: Scanner handlers

    private func handleJoinAck(_ data: Data) {
        guard let ack = JoinAckPayload.decode(from: data) else { return }
        if ack.accepted, let session = ack.sharedSession {
            activeSharedSession = session
            joinState = .joined
            AuditLogger.shared.logSession("SessionSync: join accepted — session \(session.sessionCode)")
        } else {
            let reason = ack.rejectionReason ?? "Unknown reason."
            joinState = .rejected(reason)
            AuditLogger.shared.logError("SessionSync: join rejected — \(reason)")
        }
        onJoinStateChanged?(joinState)
    }

    private func handleQuantityUpdate(_ data: Data) {
        guard let update = SKUQuantityUpdate.decode(from: data) else { return }
        remoteQuantities[update.skuId] = update
        remoteTotalItems = update.sessionTotalItems
        AuditLogger.shared.logSession("SessionSync: qty update \(update.skuName) → \(update.actualQty)")
    }

    // MARK: - Phase 0 compat handlers

    private func handleScanResult(_ data: Data) {
        guard let payload = ScanResultPayload.decode(from: data) else { return }
        remoteScanResults.append(payload)
        remoteRunningCounts[payload.skuName, default: 0] += 1
        remoteTotalItems += 1
        AuditLogger.shared.logRecognition(skuName: payload.skuName, score: payload.confidence, status: "remote-received")
    }

    private func handleStatusChange(_ data: Data) {
        guard let payload = StatusChangePayload.decode(from: data) else { return }
        remoteScanStatus = payload.newStatus
        remoteFramesProcessed = payload.framesProcessed
    }

    // MARK: - SwiftData Query

    /// Fetch the expected quantity for a given SKU from the active AuditSession's snapshot.
    private func fetchExpectedQty(skuId: UUID?, skuName: String) -> Int? {
        guard let skuId,
              let session = activeSharedSession,
              let context = modelContext else { return nil }

        let descriptor = FetchDescriptor<AuditSession>(
            predicate: #Predicate { $0.id == session.sessionId }
        )
        guard let auditSession = try? context.fetch(descriptor).first,
              let snapshot = auditSession.expectedSnapshot else { return nil }

        return snapshot.rows.first(where: { $0.matchedSkuId == skuId })?.expectedQty
    }

    // MARK: - Private helpers

    private func sendMessage(type: SessionSyncMessage.MessageType, payload: Data) {
        let message = SessionSyncMessage(
            type: type,
            payload: payload,
            senderDeviceId: multipeerService.deviceId
        )
        guard let data = message.encoded() else { return }
        multipeerService.send(data: data)
    }

    // MARK: - Convenience

    var sortedRemoteCounts: [(name: String, count: Int)] {
        remoteRunningCounts
            .sorted { $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
    }

    var isScannerConnected: Bool {
        deviceRole == .scanner && multipeerService.isConnected
    }

    var isDashboardReceiving: Bool {
        deviceRole == .dashboard && multipeerService.isConnected
    }

    var isInSharedSession: Bool {
        activeSharedSession != nil
    }
}
