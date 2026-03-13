import Foundation

// MARK: - Participant Device

/// A device participating in a shared audit session.
struct SessionParticipant: Codable, Sendable, Identifiable {
    let id: String          // deviceId (MCPeerID displayName)
    let displayName: String
    var role: DeviceRole
    var joinedAt: Date

    init(deviceId: String, displayName: String, role: DeviceRole) {
        self.id = deviceId
        self.displayName = displayName
        self.role = role
        self.joinedAt = Date()
    }
}

// MARK: - Shared Audit Session

/// In-memory representation of the shared audit session shared between two devices.
/// This is NOT a SwiftData model — it is held exclusively in `SessionSyncService`.
/// The underlying `AuditSession` persists locally on the dashboard device only.
struct SharedAuditSession: Codable, Sendable {
    let sessionId: UUID             // Maps to AuditSession.id on the dashboard
    let sessionCode: String         // 6-character alphanumeric join code
    let locationName: String
    var participants: [SessionParticipant]
    var createdAt: Date

    init(
        sessionId: UUID,
        sessionCode: String,
        locationName: String,
        hostParticipant: SessionParticipant
    ) {
        self.sessionId = sessionId
        self.sessionCode = sessionCode
        self.locationName = locationName
        self.participants = [hostParticipant]
        self.createdAt = Date()
    }

    /// Whether the scanner slot is taken.
    var hasScannerJoined: Bool {
        participants.contains { $0.role == .scanner }
    }

    /// Summary line for display.
    var participantSummary: String {
        "\(participants.count) device\(participants.count == 1 ? "" : "s") connected"
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> SharedAuditSession? {
        try? JSONDecoder().decode(SharedAuditSession.self, from: data)
    }
}

// MARK: - Quantity Snapshot

/// Per-SKU quantity state broadcast from dashboard to scanner after each ScanEvent.
struct SKUQuantityUpdate: Codable, Sendable {
    let skuId: UUID
    let skuName: String
    let actualQty: Int      // Total confirmed count so far this session
    let expectedQty: Int?   // From the session's expected snapshot (if loaded)
    let difference: Int?    // actualQty - expectedQty; nil if no expected data
    let sessionTotalItems: Int

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> SKUQuantityUpdate? {
        try? JSONDecoder().decode(SKUQuantityUpdate.self, from: data)
    }
}

// MARK: - Join Request / Ack Payloads

struct JoinRequestPayload: Codable, Sendable {
    let sessionCode: String
    let deviceId: String
    let displayName: String
    let requestedRole: DeviceRole

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(from data: Data) -> JoinRequestPayload? {
        try? JSONDecoder().decode(JoinRequestPayload.self, from: data)
    }
}

struct JoinAckPayload: Codable, Sendable {
    let accepted: Bool
    let rejectionReason: String?
    let sharedSession: SharedAuditSession?

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(from data: Data) -> JoinAckPayload? {
        try? JSONDecoder().decode(JoinAckPayload.self, from: data)
    }
}
