import SwiftUI
import SwiftData
import AVFoundation

// MARK: - Live Scan View

struct LiveScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionSyncService.self) private var syncService
    @Environment(ScannerConnectionService.self) private var scannerConnection
    @Environment(AuditCountService.self) private var countService
    let session: AuditSession
    @Bindable var viewModel: LiveScanViewModel
    let onFinish: () -> Void

    @State private var showFinishAlert = false
    @State private var showFallbackReview = false
    @State private var voiceEntryVM = VoiceEntryViewModel()
    @State private var inputRouter: BarcodeInputRouter?

    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewLayer(scanService: viewModel.scanService)
                .ignoresSafeArea()

            // Hidden UIKit host for barcode input (SDK or HID)
            if let router = inputRouter {
                BarcodeInputHostView(router: router)
                    .frame(width: 0, height: 0)
            }

            // Bounding box overlays
            GeometryReader { geo in
                ForEach(viewModel.currentDetections) { detection in
                    let rect = scaledRect(detection.bbox, in: geo.size)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(boxColor(detection.confidence), lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .overlay(alignment: .top) {
                            Text(detection.skuName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(boxColor(detection.confidence).opacity(0.85), in: Capsule())
                                .offset(y: -14)
                                .lineLimit(1)
                        }
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .ignoresSafeArea()

            // UI overlay
            VStack(spacing: 0) {
                // Top status bar
                topStatusBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                // Bottom panel
                VStack(spacing: 12) {
                    // Running counts
                    if !viewModel.sortedCounts.isEmpty {
                        runningCountsPanel
                    }

                    // Controls
                    controlBar
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationBarBackButtonHidden()
        .statusBarHidden()
        .sheet(isPresented: $showFallbackReview) {
            LiveReviewFallbackView(session: session, store: viewModel.fallbackStore)
        }
        .onAppear {
            viewModel.setup(context: modelContext)
            viewModel.syncService = syncService
            viewModel.currentSession = session
            viewModel.countService = countService
            voiceEntryVM.loadCatalog(from: modelContext)
            voiceEntryVM.onCountIncremented = { sku, _ in
                viewModel.runningCounts[sku.productName, default: 0] += 1
                viewModel.totalItemsDetected += 1
                // Persist via unified pipeline (handles delta, flags, broadcast)
                countService.recordCount(
                    session: session,
                    skuId: sku.id,
                    skuName: sku.productName,
                    quantity: 1,
                    sourceType: .voice,
                    context: modelContext
                )
            }
            hardwareScannerSetup: do {
                let router = BarcodeInputRouter(connectionService: scannerConnection)
                router.onBarcodeScanned = { code in
                    if let product = router.hid.lookupProduct(barcode: code, context: modelContext) {
                        viewModel.runningCounts[product.productName, default: 0] += 1
                        viewModel.totalItemsDetected += 1
                        // Persist via unified pipeline (replaces HardwareBarcodeService.incrementCount)
                        countService.recordCount(
                            session: session,
                            skuId: product.id,
                            skuName: product.productName,
                            quantity: 1,
                            sourceType: .barcode,
                            context: modelContext
                        )
                        TTSService.shared.speakBarcodeScan(productName: product.productName)
                    } else {
                        TTSService.shared.speakUnknownBarcode(code)
                    }
                }
                inputRouter = router
            }
            Task { await viewModel.startScanning() }
        }
        .onDisappear {
            viewModel.tearDown()
            inputRouter?.deactivate()
            viewModel.fallbackStore.clear()
        }
        .alert("Finish Scan?", isPresented: $showFinishAlert) {
            if viewModel.fallbackStore.pendingCount > 0 {
                Button("Review First") {
                    showFallbackReview = true
                }
            }
            Button("Finish") {
                viewModel.finishScanning()
                onFinish()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let pending = viewModel.fallbackStore.pendingCount
            let pendingText = pending > 0 ? " \(pending) item\(pending == 1 ? "" : "s") still need review." : ""
            Text("Stop scanning and view results. \(viewModel.totalItemsDetected) items detected across \(viewModel.framesProcessed) frames.\(pendingText)")
        }
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        HStack(spacing: 12) {
            // Status pill
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .overlay {
                        if viewModel.scanState == .scanning {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 8, height: 8)
                                .scaleEffect(2)
                                .opacity(0)
                                .animation(
                                    .easeInOut(duration: 1.0).repeatForever(autoreverses: false),
                                    value: viewModel.scanState
                                )
                        }
                    }
                Text(viewModel.scanState.rawValue)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            // Review fallback badge
            if viewModel.fallbackStore.pendingCount > 0 {
                LiveReviewBadge(count: viewModel.fallbackStore.pendingCount) {
                    showFallbackReview = true
                }
                .animation(.spring(duration: 0.3), value: viewModel.fallbackStore.pendingCount)
            }

            Spacer()

            // Frame counter
            HStack(spacing: 4) {
                Image(systemName: "photo.stack")
                    .font(.caption2)
                Text("\(viewModel.framesProcessed)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            // Item counter
            HStack(spacing: 4) {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                Text("\(viewModel.totalItemsDetected)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            // Connected device indicator
            if syncService.isScannerConnected {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    // MARK: - Running Counts Panel

    private var runningCountsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Running Counts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.sortedCounts.count) products")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(viewModel.sortedCounts, id: \.name) { item in
                        HStack {
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("×\(item.count)")
                                .font(.caption.monospacedDigit().weight(.bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 6))
                    }
                }
            }
            .frame(maxHeight: 140)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 20) {
            // Cancel / Back
            Button {
                viewModel.tearDown()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 50, height: 50)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            // Pause / Resume
            Button {
                if viewModel.scanState == .paused {
                    viewModel.resumeScanning()
                } else {
                    viewModel.pauseScanning()
                }
            } label: {
                Image(systemName: viewModel.scanState == .paused ? "play.fill" : "pause.fill")
                    .font(.title2.weight(.semibold))
                    .frame(width: 64, height: 64)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            // Voice Quick Entry
            VoiceQuickEntryButton(viewModel: voiceEntryVM)
                .font(.body.weight(.semibold))
                .frame(width: 50, height: 50)
                .background(.ultraThinMaterial, in: Circle())

            Spacer()

            // Finish
            Button {
                showFinishAlert = true
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .frame(width: 50, height: 50)
                    .background(.green.opacity(0.8), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private func scaledRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.origin.x * size.width,
            y: normalized.origin.y * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    private func boxColor(_ confidence: Float) -> Color {
        if confidence >= 0.75 { return .green }
        if confidence >= 0.55 { return .orange }
        return .red
    }

    private var statusDotColor: Color {
        switch viewModel.scanState {
        case .scanning: .green
        case .processing: .blue
        case .paused: .orange
        case .finished: .gray
        case .idle: .gray
        }
    }
}

// MARK: - Camera Preview UIViewRepresentable

struct CameraPreviewLayer: UIViewRepresentable {
    let scanService: LiveScanService

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        #if DEBUG
        print("[CameraPreviewLayer] makeUIView — UIView host created for LiveScan preview")
        #endif
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        guard let layer = scanService.previewLayer else {
            #if DEBUG
            print("[CameraPreviewLayer] updateUIView — previewLayer not ready yet")
            #endif
            return
        }
        uiView.attach(previewLayer: layer)
    }
}

final class CameraPreviewUIView: UIView {
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    /// Attach or re-use the preview layer. Idempotent — safe to call multiple times.
    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        if layer === previewLayer {
            // Same layer already attached — just keep frame in sync
            layer.frame = bounds
            return
        }
        // Remove any old layer
        previewLayer?.removeFromSuperlayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        #if DEBUG
        print("[CameraPreviewUIView] Preview layer attached — bounds: \(bounds)")
        #endif
    }
}


// MARK: - Live Scan Results View (Stage 1 — simple summary)

struct LiveScanResultsView: View {
    let viewModel: LiveScanViewModel
    let session: AuditSession
    let onDismiss: () -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Label("Shelf", systemImage: "mappin")
                    Spacer()
                    Text(session.locationName)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Frames Processed", systemImage: "photo.stack")
                    Spacer()
                    Text("\(viewModel.framesProcessed)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Total Detections", systemImage: "shippingbox")
                    Spacer()
                    Text("\(viewModel.totalItemsDetected)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Unique Products", systemImage: "list.bullet")
                    Spacer()
                    Text("\(viewModel.sortedCounts.count)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Scan Summary")
            }

            if !viewModel.sortedCounts.isEmpty {
                Section("Detected Products") {
                    ForEach(viewModel.sortedCounts, id: \.name) { item in
                        HStack {
                            Text(item.name)
                                .font(.body)
                            Spacer()
                            Text("×\(item.count)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Scan Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDismiss() }
                    .fontWeight(.semibold)
            }
        }
    }
}
