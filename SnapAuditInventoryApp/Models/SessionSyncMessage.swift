import Foundation

// MARK: - Device Role

/// Defines whether this device acts as the main dashboard or a remote scanner.
enum DeviceRole: String, Codable, CaseIterable, Sendable {
    case dashboard
    case scanner

    var displayName: String {
        switch self {
        case .dashboard: "Dashboard"
        case .scanner: "Scanner"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "rectangle.3.group"
        case .scanner: "camera.viewfinder"
        }
    }

    var description: String {
        switch self {
        case .dashboard: "View live counts and manage the audit session"
        case .scanner: "Scan products and send results to the dashboard"
        }
    }
}

// MARK: - Peer Device

/// Represents a discovered nearby device available for pairing.
struct PeerDevice: Identifiable, Hashable, Sendable {
    let id: String          // MCPeerID displayName (unique per session)
    let displayName: String
    var role: DeviceRole
    var isConnected: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PeerDevice, rhs: PeerDevice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Sync Message Envelope

/// Generic message envelope exchanged between paired devices over MultipeerConnectivity.
struct SessionSyncMessage: Codable, Sendable {
    let type: MessageType
    let payload: Data       // JSON-encoded payload specific to the message type
    let senderDeviceId: String
    let timestamp: Date

    enum MessageType: String, Codable, Sendable {
        // Phase 0: basic relay
        case scanResult         // Scanner → Dashboard: a new detection (Phase 0 compat)
        case statusChange       // Either direction: scanning started/paused/finished
        case heartbeat          // Either direction: keep-alive
        case sessionInfo        // Dashboard → Scanner: session metadata

        // Stage 1: structured session handshake & events
        case joinRequest        // Scanner → Dashboard: request to join with session code
        case joinAck            // Dashboard → Scanner: accept/reject with SharedAuditSession
        case scanEvent          // Scanner → Dashboard: structured ScanEvent record
        case quantityUpdate     // Dashboard → Scanner: updated SKU quantities after reconciliation
    }

    init(type: MessageType, payload: Data, senderDeviceId: String) {
        self.type = type
        self.payload = payload
        self.senderDeviceId = senderDeviceId
        self.timestamp = Date()
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> SessionSyncMessage? {
        try? JSONDecoder().decode(SessionSyncMessage.self, from: data)
    }
}

// MARK: - Scan Result Payload

/// Lightweight detection result sent from scanner → dashboard.
struct ScanResultPayload: Codable, Sendable {
    let skuId: UUID?
    let skuName: String
    let confidence: Double
    let timestamp: Date
    let shelfZoneName: String

    init(
        skuId: UUID?,
        skuName: String,
        confidence: Double,
        shelfZoneName: String = ""
    ) {
        self.skuId = skuId
        self.skuName = skuName
        self.confidence = confidence
        self.timestamp = Date()
        self.shelfZoneName = shelfZoneName
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> ScanResultPayload? {
        try? JSONDecoder().decode(ScanResultPayload.self, from: data)
    }
}

// MARK: - Status Change Payload

/// Communicates scan state changes between devices.
struct StatusChangePayload: Codable, Sendable {
    let newStatus: String   // LiveScanState rawValue
    let framesProcessed: Int
    let totalItemsDetected: Int

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> StatusChangePayload? {
        try? JSONDecoder().decode(StatusChangePayload.self, from: data)
    }
}
