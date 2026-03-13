import Foundation

// MARK: - Scan Source Type

/// Identifies which input method produced a scan event.
enum ScanSourceType: String, Codable, CaseIterable, Sendable {
    case barcode
    case voice
    case photo
    case video
    case liveCamera

    var displayName: String {
        switch self {
        case .barcode:    "Barcode"
        case .voice:      "Voice"
        case .photo:      "Photo"
        case .video:      "Video"
        case .liveCamera: "Live Camera"
        }
    }

    var icon: String {
        switch self {
        case .barcode:    "barcode.viewfinder"
        case .voice:      "mic.fill"
        case .photo:      "camera.fill"
        case .video:      "video.fill"
        case .liveCamera: "livephoto.play"
        }
    }
}

// MARK: - Scan Event

/// A single scan event emitted by any device when it detects/counts a product.
/// These records are the source of truth for quantity accumulation during a shared session.
/// On the scanner: ScanEvents are created locally and broadcast over MultipeerConnectivity.
/// On the dashboard: received ScanEvents are applied to the corresponding AuditLineItem.
struct ScanEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let sessionId: UUID             // The AuditSession this event belongs to
    let skuId: UUID?
    let skuName: String
    let confidence: Double
    let shelfZoneName: String
    let originDeviceId: String      // Which device produced this event
    let originDeviceRole: DeviceRole
    let quantity: Int               // Units counted (default 1; voice can say "3 of Coke")
    let sourceType: ScanSourceType  // How the scan was produced
    let timestamp: Date

    init(
        sessionId: UUID,
        skuId: UUID?,
        skuName: String,
        confidence: Double,
        shelfZoneName: String = "",
        originDeviceId: String,
        originDeviceRole: DeviceRole,
        quantity: Int = 1,
        sourceType: ScanSourceType = .liveCamera
    ) {
        self.id = UUID()
        self.sessionId = sessionId
        self.skuId = skuId
        self.skuName = skuName
        self.confidence = confidence
        self.shelfZoneName = shelfZoneName
        self.originDeviceId = originDeviceId
        self.originDeviceRole = originDeviceRole
        self.quantity = quantity
        self.sourceType = sourceType
        self.timestamp = Date()
    }

    // MARK: - Serialization

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> ScanEvent? {
        try? JSONDecoder().decode(ScanEvent.self, from: data)
    }
}

// MARK: - Scan Event Store (in-memory, session-scoped)

/// Holds all ScanEvents for the current shared session in memory.
/// Used to build quantity tallies and compute differences against expected quantities.
@Observable
@MainActor
final class ScanEventStore {

    private(set) var events: [ScanEvent] = []

    // MARK: - Accumulation

    /// Add a new event and return the updated tally for its SKU.
    @discardableResult
    func record(_ event: ScanEvent) -> Int {
        events.append(event)
        return tally(for: event.skuId, skuName: event.skuName)
    }

    /// Total confirmed count for a given SKU ID (or name if ID is nil) across all events.
    func tally(for skuId: UUID?, skuName: String) -> Int {
        events.filter { e in
            if let id = skuId, let eId = e.skuId {
                return id == eId
            }
            return e.skuName == skuName
        }.reduce(0) { $0 + $1.quantity }
    }

    /// All unique SKU names seen so far with their total counts.
    var skuTallies: [(skuId: UUID?, skuName: String, count: Int)] {
        var seen: [String: (skuId: UUID?, skuName: String, count: Int)] = [:]
        for event in events {
            let key = event.skuId?.uuidString ?? event.skuName
            if seen[key] == nil {
                seen[key] = (skuId: event.skuId, skuName: event.skuName, count: 0)
            }
            seen[key]!.count += 1
        }
        return seen.values.sorted { $0.count > $1.count }
    }

    /// Total number of scan events.
    var totalCount: Int { events.count }

    /// Clear all events (e.g. when session ends).
    func clear() { events = [] }
}
