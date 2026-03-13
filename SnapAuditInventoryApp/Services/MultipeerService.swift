import Foundation
import MultipeerConnectivity
import Combine

/// Wraps MultipeerConnectivity to manage device discovery, invitations, and data transport.
///
/// Usage:
/// 1. Call `start(as:)` to begin advertising and browsing.
/// 2. Observe `discoveredPeers` for nearby devices.
/// 3. Call `invite(peer:)` to connect.
/// 4. Use `send(data:)` to transmit messages.
/// 5. Subscribe to `onDataReceived` for incoming messages.
@Observable
@MainActor
final class MultipeerService: NSObject {

    // MARK: - Public State

    var discoveredPeers: [PeerDevice] = []
    var connectedPeers: [PeerDevice] = []
    var isAdvertising = false
    var isBrowsing = false
    var connectionStatus: ConnectionStatus = .disconnected
    var lastError: String?

    enum ConnectionStatus: String, Sendable {
        case disconnected = "Disconnected"
        case searching = "Searching…"
        case connecting = "Connecting…"
        case connected = "Connected"
    }

    // MARK: - Callbacks

    /// Called on the main actor when data is received from a connected peer.
    var onDataReceived: ((Data, String) -> Void)?

    /// Called when connection state changes.
    var onConnectionStateChanged: ((PeerDevice, Bool) -> Void)?

    // MARK: - Private

    private static let serviceType = "snapaudit-sync" // Max 15 chars, lowercase + hyphens
    private var myPeerId: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var myRole: DeviceRole = .dashboard
    private var peerIdMap: [MCPeerID: PeerDevice] = [:]

    // MARK: - Lifecycle

    /// Start advertising this device and browsing for peers.
    func start(as role: DeviceRole, displayName: String? = nil) {
        stop() // Clean up any prior session

        myRole = role
        let name = displayName ?? UIDevice.current.name
        myPeerId = MCPeerID(displayName: name)
        session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        // Advertise with role in discovery info
        let discoveryInfo: [String: String] = ["role": role.rawValue]
        advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerId,
            discoveryInfo: discoveryInfo,
            serviceType: Self.serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        isAdvertising = true

        // Browse for peers
        browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: Self.serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        isBrowsing = true

        connectionStatus = .searching
        AuditLogger.shared.logSession("Multipeer: started as \(role.rawValue), name=\(name)")
    }

    /// Stop all multipeer activity and disconnect.
    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        discoveredPeers = []
        connectedPeers = []
        peerIdMap = [:]
        isAdvertising = false
        isBrowsing = false
        connectionStatus = .disconnected
    }

    /// Invite a discovered peer to join the session.
    func invite(peer: PeerDevice) {
        guard let mcPeer = peerIdMap.first(where: { $0.value.id == peer.id })?.key else { return }
        connectionStatus = .connecting
        browser?.invitePeer(mcPeer, to: session, withContext: nil, timeout: 30)
        AuditLogger.shared.logSession("Multipeer: invited \(peer.displayName)")
    }

    /// Send data to all connected peers (reliable delivery).
    func send(data: Data) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            lastError = error.localizedDescription
            AuditLogger.shared.logError("Multipeer send error: \(error.localizedDescription)")
        }
    }

    /// Whether we have at least one connected peer.
    var isConnected: Bool {
        !connectedPeers.isEmpty
    }

    /// The device ID string for this device.
    var deviceId: String {
        myPeerId?.displayName ?? UIDevice.current.name
    }
}

// MARK: - MCSessionDelegate

extension MultipeerService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                AuditLogger.shared.logSession("Multipeer: connected to \(peerID.displayName)")
                if let existing = peerIdMap[peerID] {
                    var updated = existing
                    updated.isConnected = true
                    peerIdMap[peerID] = updated
                    connectedPeers = peerIdMap.values.filter(\.isConnected)
                    onConnectionStateChanged?(updated, true)
                }
                connectionStatus = .connected

            case .notConnected:
                AuditLogger.shared.logSession("Multipeer: disconnected from \(peerID.displayName)")
                if let existing = peerIdMap[peerID] {
                    var updated = existing
                    updated.isConnected = false
                    peerIdMap[peerID] = updated
                    connectedPeers = peerIdMap.values.filter(\.isConnected)
                    onConnectionStateChanged?(updated, false)
                }
                if connectedPeers.isEmpty {
                    connectionStatus = isBrowsing ? .searching : .disconnected
                }

            case .connecting:
                connectionStatus = .connecting

            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            onDataReceived?(data, peerID.displayName)
        }
    }

    // Required but unused for Phase 0
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            let role = DeviceRole(rawValue: info?["role"] ?? "") ?? .scanner
            let device = PeerDevice(
                id: peerID.displayName,
                displayName: peerID.displayName,
                role: role,
                isConnected: false
            )
            peerIdMap[peerID] = device
            discoveredPeers = Array(peerIdMap.values.filter { !$0.isConnected })
            AuditLogger.shared.logSession("Multipeer: discovered \(peerID.displayName) as \(role.rawValue)")
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            peerIdMap.removeValue(forKey: peerID)
            discoveredPeers = Array(peerIdMap.values.filter { !$0.isConnected })
            connectedPeers = peerIdMap.values.filter(\.isConnected)
            AuditLogger.shared.logSession("Multipeer: lost \(peerID.displayName)")
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Auto-accept invitations for now (Phase 0 simplicity)
        Task { @MainActor in
            AuditLogger.shared.logSession("Multipeer: auto-accepting invitation from \(peerID.displayName)")
            let role: DeviceRole = myRole == .dashboard ? .scanner : .dashboard
            let device = PeerDevice(
                id: peerID.displayName,
                displayName: peerID.displayName,
                role: role,
                isConnected: false
            )
            peerIdMap[peerID] = device
            invitationHandler(true, session)
        }
    }
}
