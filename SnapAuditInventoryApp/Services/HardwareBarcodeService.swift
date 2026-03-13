import UIKit
import SwiftUI
import SwiftData

/// Captures barcode input from Bluetooth HID scanners (e.g. Inateck BCST-70).
///
/// HID scanners pair as Bluetooth keyboards and send barcode digits as keystrokes
/// followed by a carriage return (`\n`). This service uses a hidden `UITextField`
/// as first responder to capture those keystrokes without any visible UI.
///
/// Usage:
/// 1. Call `activate()` to start listening.
/// 2. Subscribe to `onBarcodeScanned` for incoming barcodes.
/// 3. Call `deactivate()` when leaving the scan view.
@Observable
@MainActor
final class HardwareBarcodeService: NSObject, BarcodeInputSource {

    // MARK: - State

    var isActive: Bool = false
    var lastScannedCode: String = ""
    var lastMatchedProductName: String?
    var scanCount: Int = 0

    // MARK: - Callback

    /// Fires when a complete barcode is received (after CR/LF).
    var onBarcodeScanned: ((String) -> Void)?

    // MARK: - Settings

    @ObservationIgnored
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hardwareScannerEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hardwareScannerEnabled") }
    }

    // MARK: - Private

    private var hidTextField: HIDCaptureTextField?
    private var debounceCode: String = ""
    private static let debounceInterval: TimeInterval = 1.5

    // MARK: - Activate / Deactivate

    /// Protocol conformance: activate without a host view (creates its own).
    func activate() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootView = windowScene.windows.first?.rootViewController?.view else {
            return
        }
        activate(in: rootView)
    }

    /// Install a hidden text field into the given view and become first responder.
    func activate(in hostView: UIView) {
        guard isEnabled else { return }
        deactivate()

        let tf = HIDCaptureTextField()
        tf.onLineReceived = { [weak self] code in
            Task { @MainActor [weak self] in
                self?.handleScannedCode(code)
            }
        }
        tf.frame = CGRect(x: -9999, y: -9999, width: 0, height: 0)
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.keyboardType = .asciiCapable
        // Make sure iOS doesn't show the software keyboard for this field
        if #available(iOS 17.0, *) {
            // On iOS 17+ UITextField respects external keyboard automatically
        }
        hostView.addSubview(tf)
        tf.becomeFirstResponder()
        hidTextField = tf
        isActive = true
    }

    /// Remove the hidden text field and stop listening.
    func deactivate() {
        hidTextField?.resignFirstResponder()
        hidTextField?.removeFromSuperview()
        hidTextField = nil
        isActive = false
    }

    // MARK: - Barcode Processing

    private func handleScannedCode(_ rawCode: String) {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }

        // Debounce: ignore same code within interval
        if code == debounceCode { return }
        debounceCode = code

        lastScannedCode = code
        scanCount += 1
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

    // MARK: - Product Lookup Helper

    /// Look up product by barcode in SwiftData. Returns nil if no match.
    func lookupProduct(barcode: String, context: ModelContext) -> ProductSKU? {
        let descriptor = FetchDescriptor<ProductSKU>()
        let allProducts = (try? context.fetch(descriptor)) ?? []
        return allProducts.first { $0.barcode == barcode }
    }

    /// Increment visionCount on the matching AuditLineItem, or create a new one.
    func incrementCount(
        for product: ProductSKU,
        in session: AuditSession,
        context: ModelContext
    ) {
        // Find existing line item for this SKU in this session
        if let existing = session.lineItems.first(where: { $0.skuId == product.id }) {
            existing.visionCount += 1
            // Recompute delta if expected qty is set
            if let expected = existing.expectedQty {
                existing.delta = existing.visionCount - expected
                if expected > 0 {
                    existing.deltaPercent = Double(existing.visionCount - expected) / Double(expected) * 100
                }
            }
        } else {
            // Create new line item
            let lineItem = AuditLineItem(
                session: session,
                skuId: product.id,
                skuNameSnapshot: product.productName,
                visionCount: 1,
                countConfidence: 1.0
            )
            context.insert(lineItem)
        }

        try? context.save()
    }
}

// MARK: - Hidden UITextField for HID Capture

/// A UITextField that sits offscreen and captures HID keyboard input.
/// Barcode scanners send characters followed by `\n` (carriage return).
/// This field buffers characters and fires `onLineReceived` on `\n`.
final class HIDCaptureTextField: UITextField, UITextFieldDelegate {

    var onLineReceived: ((String) -> Void)?
    private var buffer: String = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        addTarget(self, action: #selector(textDidChange), for: .editingChanged)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    // Keep first responder even when other views appear
    override var canResignFirstResponder: Bool { false }

    // Prevent software keyboard from showing (we only want HID input)
    private let emptyInputView = UIView(frame: .zero)
    override var inputView: UIView? {
        get { emptyInputView }
        set { /* intentionally ignored */ }
    }

    @objc private func textDidChange() {
        guard let text else { return }

        // Check for newline (scanner sends CR/LF at end of barcode)
        if text.contains("\n") || text.contains("\r") {
            let code = text
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                onLineReceived?(code)
            }
            self.text = ""
            buffer = ""
        } else {
            buffer = text
        }
    }

    // UITextFieldDelegate: allow return key processing
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let code = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty {
            onLineReceived?(code)
        }
        textField.text = ""
        buffer = ""
        return false
    }
}

// MARK: - SwiftUI Bridge

/// UIViewRepresentable that provides a UIKit host view for the hidden HID text field.
/// Add to any SwiftUI view with `.frame(width: 0, height: 0)`.
struct HIDHostView: UIViewRepresentable {
    let service: HardwareBarcodeService

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        // Delay activation to next runloop so the view is in the hierarchy
        DispatchQueue.main.async {
            service.activate(in: container)
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
