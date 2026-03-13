import Foundation

/// A source that can deliver barcode strings to the app.
/// Both HID keyboard input and Inateck SDK input conform to this protocol,
/// allowing consumer views to be agnostic about the transport layer.
@MainActor
protocol BarcodeInputSource: AnyObject {
    /// Whether this source is currently active and listening for barcodes.
    var isActive: Bool { get }

    /// Called when a complete barcode string has been received.
    var onBarcodeScanned: ((String) -> Void)? { get set }

    /// Start listening for barcode input.
    func activate()

    /// Stop listening for barcode input and release resources.
    func deactivate()
}
