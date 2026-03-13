import UIKit
import SwiftUI

/// Routes barcode input to the best available source.
///
/// When the Inateck SDK is connected, SDK input takes priority.
/// When SDK is not connected, HID keyboard input is used as fallback.
/// Consumer views use the router instead of directly referencing either service.
@Observable
@MainActor
final class BarcodeInputRouter {

    // MARK: - Sources

    let hid = HardwareBarcodeService()
    let sdk: InateckSDKService

    // MARK: - State

    /// Which source is currently delivering barcodes.
    enum ActiveMode: String {
        case sdk = "SDK"
        case hid = "HID"
        case none = "Off"
    }

    var activeMode: ActiveMode {
        if sdk.isActive { return .sdk }
        if hid.isActive { return .hid }
        return .none
    }

    var isActive: Bool { activeMode != .none }

    /// Unified callback — fires regardless of which source produced the barcode.
    var onBarcodeScanned: ((String) -> Void)? {
        didSet {
            hid.onBarcodeScanned = onBarcodeScanned
            sdk.onBarcodeScanned = onBarcodeScanned
        }
    }

    // MARK: - Init

    init(connectionService: ScannerConnectionService) {
        self.sdk = InateckSDKService(connectionService: connectionService)
    }

    // MARK: - Activation

    /// Activate the best available source.
    /// If SDK is connected, activate SDK and suspend HID.
    /// Otherwise, activate HID.
    func activate(in hostView: UIView) {
        sdk.activate()

        if sdk.isActive {
            // SDK takes priority — suspend HID to avoid double input
            hid.deactivate()
        } else {
            // SDK not available — fall back to HID
            hid.activate(in: hostView)
        }
    }

    /// Deactivate all sources.
    func deactivate() {
        sdk.deactivate()
        hid.deactivate()
    }
}

// MARK: - SwiftUI Bridge

/// UIViewRepresentable that provides a UIKit host view for the BarcodeInputRouter.
/// It activates the router (which selects SDK or HID) when the view appears.
struct BarcodeInputHostView: UIViewRepresentable {
    let router: BarcodeInputRouter

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            router.activate(in: container)
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
