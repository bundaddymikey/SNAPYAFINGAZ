import SwiftUI
import SwiftData
import AVFoundation

/// Barcode scanner view using AVCaptureSession + AVCaptureMetadataOutput.
/// Detects barcodes, looks up matching ProductSKU, and announces via TTS.
struct BarcodeScannerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ScannerConnectionService.self) private var scannerConnection
    let session: AuditSession
    let auditViewModel: AuditViewModel

    @State private var lastScannedCode: String = ""
    @State private var lastMatchedProduct: ProductSKU? = nil
    @State private var scanCount: Int = 0
    @State private var showUnknownBanner: Bool = false
    @State private var unknownCode: String = ""
    @State private var flashGreen: Bool = false
    @State private var flashOrange: Bool = false
    @State private var scannedItems: [ScannedBarcodeItem] = []
    @State private var inputRouter: BarcodeInputRouter?

    struct ScannedBarcodeItem: Identifiable {
        let id = UUID()
        let barcode: String
        let productName: String
        let timestamp: Date
        let matched: Bool
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            BarcodeCameraPreview(onBarcodeDetected: handleBarcode)

            // Hidden UIKit host for barcode input (SDK or HID)
            if let router = inputRouter {
                BarcodeInputHostView(router: router)
                    .frame(width: 0, height: 0)
            }

            VStack {
                // Top scan indicator
                HStack(spacing: 8) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text("Barcode Scanner")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)

                    if let mode = inputRouter?.activeMode, mode != .none {
                        HStack(spacing: 4) {
                            Circle().fill(.cyan).frame(width: 6, height: 6)
                            Text(mode == .sdk ? "SDK" : "HID")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.cyan)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.cyan.opacity(0.15), in: Capsule())
                    }

                    Spacer()
                    Text("\(scanCount) scanned")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

                Spacer()

                // Scanning guide crosshair
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        flashGreen ? .green : (flashOrange ? .orange : .cyan),
                        lineWidth: 2.5
                    )
                    .frame(width: 280, height: 120)
                    .background(.clear)
                    .animation(.easeOut(duration: 0.3), value: flashGreen)
                    .animation(.easeOut(duration: 0.3), value: flashOrange)

                Spacer()

                // Result banner
                if let product = lastMatchedProduct {
                    matchedBanner(product: product)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if showUnknownBanner {
                    unknownBarcodeBanner
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Scanned items list
                if !scannedItems.isEmpty {
                    scannedItemsList
                }
            }
            .animation(.spring(response: 0.35), value: lastMatchedProduct?.id)
            .animation(.spring(response: 0.35), value: showUnknownBanner)
        }
        .onAppear {
            let router = BarcodeInputRouter(connectionService: scannerConnection)
            router.onBarcodeScanned = { code in
                handleBarcode(code)
            }
            inputRouter = router
        }
        .onDisappear {
            inputRouter?.deactivate()
        }
    }

    // MARK: - Barcode Handling

    private func handleBarcode(_ code: String) {
        // Debounce: don't re-scan the same code within 2 seconds
        guard code != lastScannedCode else { return }
        lastScannedCode = code

        // Look up product by barcode
        let descriptor = FetchDescriptor<ProductSKU>()
        let allProducts = (try? modelContext.fetch(descriptor)) ?? []
        let matched = allProducts.first { $0.barcode == code }

        if let product = matched {
            // Successful match
            lastMatchedProduct = product
            showUnknownBanner = false
            scanCount += 1

            // Flash green
            flashGreen = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                flashGreen = false
            }

            // TTS announce
            TTSService.shared.speakBarcodeScan(productName: product.name)

            // Add to scanned items
            scannedItems.insert(ScannedBarcodeItem(
                barcode: code,
                productName: product.name,
                timestamp: Date(),
                matched: true
            ), at: 0)

            // Clear after delay for next scan
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if lastScannedCode == code {
                    lastScannedCode = ""
                    lastMatchedProduct = nil
                }
            }
        } else {
            // Unknown barcode
            lastMatchedProduct = nil
            unknownCode = code
            showUnknownBanner = true

            // Flash orange
            flashOrange = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                flashOrange = false
            }

            // TTS announce
            TTSService.shared.speakUnknownBarcode(code)

            // Add to scanned items
            scannedItems.insert(ScannedBarcodeItem(
                barcode: code,
                productName: "Unknown",
                timestamp: Date(),
                matched: false
            ), at: 0)

            // Clear after delay
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if lastScannedCode == code {
                    lastScannedCode = ""
                    showUnknownBanner = false
                }
            }
        }
    }

    // MARK: - UI Components

    private func matchedBanner(product: ProductSKU) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(product.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !product.brand.isEmpty {
                        Text(product.brand)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                    if let barcode = product.barcode {
                        Text(barcode)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.green.opacity(0.6))
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var unknownBarcodeBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "questionmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Unknown Barcode")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(unknownCode)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.gray)
            }

            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var scannedItemsList: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(scannedItems.prefix(10)) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.matched ? .green : .orange)
                                .frame(width: 6, height: 6)
                            Text(item.matched ? item.productName : "Unknown")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)
            .background(.black.opacity(0.6))
        }
    }
}

// MARK: - AVFoundation Camera Preview for Barcode Scanning

struct BarcodeCameraPreview: UIViewRepresentable {
    let onBarcodeDetected: (String) -> Void

    func makeUIView(context: Context) -> BarcodeCameraUIView {
        let view = BarcodeCameraUIView()
        view.onBarcodeDetected = onBarcodeDetected
        return view
    }

    func updateUIView(_ uiView: BarcodeCameraUIView, context: Context) {}
}

class BarcodeCameraUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onBarcodeDetected: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let metadataOutput = AVCaptureMetadataOutput()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = [
                .ean13, .ean8, .upce, .code128, .code39, .code93,
                .interleaved2of5, .itf14, .qr, .dataMatrix
            ]
        }

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        layer.addSublayer(preview)
        previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue,
              !code.isEmpty else { return }
        onBarcodeDetected?(code)
    }

    func stopSession() {
        captureSession.stopRunning()
    }
}
