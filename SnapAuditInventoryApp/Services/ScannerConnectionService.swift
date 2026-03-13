import Foundation

/// Manages the Inateck SDK lifecycle: initialization, device discovery,
/// connection, authentication, battery, and beeper.
///
/// This service wraps the Inateck C-bridge functions (`inateck_scanner_ble_*`)
/// and provides a clean Swift-observable interface for SwiftUI.
///
/// **Note:** The actual Inateck SDK package must be added to the Xcode project
/// before the real C-bridge calls can be activated. Until then, this service
/// operates in stub mode and logs calls for verification.
@Observable
@MainActor
final class ScannerConnectionService {

    // MARK: - Connection State

    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting(deviceName: String)
        case connected(deviceId: String, deviceName: String)
        case error(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var displayName: String {
            switch self {
            case .disconnected: "Disconnected"
            case .scanning: "Scanning…"
            case .connecting(let name): "Connecting to \(name)…"
            case .connected(_, let name): "Connected — \(name)"
            case .error(let msg): "Error: \(msg)"
            }
        }

        var icon: String {
            switch self {
            case .disconnected: "antenna.radiowaves.left.and.right.slash"
            case .scanning: "antenna.radiowaves.left.and.right"
            case .connecting: "arrow.triangle.2.circlepath"
            case .connected: "checkmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }

        var color: String {
            switch self {
            case .disconnected: "gray"
            case .scanning: "blue"
            case .connecting: "orange"
            case .connected: "green"
            case .error: "red"
            }
        }
    }

    // MARK: - Discovered Device

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: String       // device_id from SDK
        let name: String     // device_name from SDK
        let isConnected: Bool
    }

    // MARK: - Published State

    var state: ConnectionState = .disconnected
    var discoveredDevices: [DiscoveredDevice] = []
    var batteryLevel: Int? = nil
    var isSDKInitialized: Bool = false

    /// Fires when the SDK delivers a barcode. Wired to `InateckSDKService`.
    var onBarcodeReceived: ((String) -> Void)? = nil

    /// Fires when the SDK reports a disconnect.
    var onDisconnected: (() -> Void)? = nil

    // MARK: - Initialization

    /// Initialize the Inateck SDK.
    /// Call once at app startup or when the SDK toggle is enabled.
    func initialize() {
        guard !isSDKInitialized else { return }

        // TODO: Replace with real SDK call when package is added:
        // let result = inateck_scanner_ble_init()
        // Parse JSON result for status == 0
        print("[ScannerConnectionService] SDK initialized (stub)")
        isSDKInitialized = true
    }

    // MARK: - Discovery

    /// Start scanning for nearby Inateck devices.
    func startDiscovery() {
        guard isSDKInitialized else {
            state = .error("SDK not initialized")
            return
        }
        state = .scanning
        discoveredDevices = []

        // TODO: Replace with real SDK calls:
        // inateck_scanner_ble_set_discover_callback(discoveryCallback)
        // inateck_scanner_ble_start_scan()
        print("[ScannerConnectionService] Discovery started (stub)")
    }

    /// Stop scanning for devices.
    func stopDiscovery() {
        guard case .scanning = state else { return }

        // TODO: inateck_scanner_ble_stop_scan()
        state = .disconnected
        print("[ScannerConnectionService] Discovery stopped (stub)")
    }

    // MARK: - Connection

    /// Connect to a specific device by its SDK device ID.
    func connect(device: DiscoveredDevice) {
        state = .connecting(deviceName: device.name)

        // TODO: Replace with real SDK calls:
        // inateck_scanner_ble_connect(device.id)
        // inateck_scanner_ble_check_communication(device.id)
        // inateck_scanner_ble_auth(device.id)
        // inateck_scanner_ble_set_code_callback(device.id, codeCallback)
        // inateck_scanner_ble_set_disconnect_callback(disconnectCallback)

        // Simulate successful connection for UI development
        state = .connected(deviceId: device.id, deviceName: device.name)
        print("[ScannerConnectionService] Connected to \(device.name) (stub)")
    }

    /// Disconnect the currently connected device.
    func disconnect() {
        guard case .connected(let deviceId, _) = state else { return }

        // TODO: inateck_scanner_ble_disconnect(deviceId)
        _ = deviceId
        state = .disconnected
        batteryLevel = nil
        onDisconnected?()
        print("[ScannerConnectionService] Disconnected (stub)")
    }

    // MARK: - Device Features

    /// Read battery level from the connected scanner.
    func readBattery() {
        guard case .connected(let deviceId, _) = state else { return }

        // TODO: inateck_scanner_ble_version(deviceId) → parse battery from JSON
        _ = deviceId
        print("[ScannerConnectionService] Battery read (stub)")
    }

    /// Trigger a beep on the connected scanner.
    func beep() {
        guard case .connected(let deviceId, _) = state else { return }

        // TODO: inateck_scanner_ble_bee(deviceId, ...)
        _ = deviceId
        print("[ScannerConnectionService] Beep triggered (stub)")
    }

    // MARK: - SDK Callbacks (to be wired when SDK is added)

    /// Called by SDK when a nearby device is discovered.
    /// Parse JSON: { "id": "...", "device_name": "...", "is_connected": "..." }
    func handleDeviceDiscovered(json: String) {
        // TODO: Parse JSON and append to discoveredDevices
        // guard let data = json.data(using: .utf8),
        //       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        //       let id = dict["id"] as? String,
        //       let name = dict["device_name"] as? String else { return }
        // let device = DiscoveredDevice(id: id, name: name, isConnected: false)
        // if !discoveredDevices.contains(where: { $0.id == id }) {
        //     discoveredDevices.append(device)
        // }
    }

    /// Called by SDK when a barcode is scanned.
    /// Parse JSON: { "code": "...", "source_code": "...", "id": "...", "device_name": "..." }
    func handleBarcodeReceived(json: String) {
        // TODO: Parse JSON and fire callback
        // guard let data = json.data(using: .utf8),
        //       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        //       let code = dict["code"] as? String else { return }
        // onBarcodeReceived?(code)
    }

    /// Called by SDK when the device disconnects.
    func handleDeviceDisconnected(json: String) {
        // TODO: Parse JSON, update state
        // state = .disconnected
        // batteryLevel = nil
        // onDisconnected?()
    }
}
