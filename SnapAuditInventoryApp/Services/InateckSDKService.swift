import Foundation

/// Barcode delivery service using the Inateck Bluetooth SDK.
///
/// This conforms to `BarcodeInputSource` so consumer views can treat it
/// identically to the HID keyboard service. The SDK delivers barcodes
/// via callback from `ScannerConnectionService`.
@Observable
@MainActor
final class InateckSDKService: BarcodeInputSource {

    // MARK: - BarcodeInputSource

    var isActive: Bool = false
    var onBarcodeScanned: ((String) -> Void)?

    /// Reference to the connection service that manages the SDK lifecycle.
    private weak var connectionService: ScannerConnectionService?

    // MARK: - Debounce

    private var debounceCode: String = ""
    private static let debounceInterval: TimeInterval = 1.5

    // MARK: - Init

    init(connectionService: ScannerConnectionService? = nil) {
        self.connectionService = connectionService
    }

    /// Bind to a ScannerConnectionService.
    /// Call this once after both services are available.
    func bind(to service: ScannerConnectionService) {
        connectionService = service
    }

    // MARK: - BarcodeInputSource

    func activate() {
        guard let connectionService, connectionService.state.isConnected else {
            isActive = false
            return
        }

        // Wire the SDK barcode callback
        connectionService.onBarcodeReceived = { [weak self] code in
            Task { @MainActor [weak self] in
                self?.handleScannedCode(code)
            }
        }

        isActive = true
    }

    func deactivate() {
        connectionService?.onBarcodeReceived = nil
        isActive = false
    }

    // MARK: - Barcode Processing

    private func handleScannedCode(_ rawCode: String) {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }

        // Debounce: ignore same code within interval
        if code == debounceCode { return }
        debounceCode = code

        onBarcodeScanned?(code)

        // Reset debounce after interval
        let debounced = code
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
            await MainActor.run {
                if self.debounceCode == debounced {
                    self.debounceCode = ""
                }
            }
        }
    }
}
