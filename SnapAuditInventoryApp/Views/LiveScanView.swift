import SwiftUI
import SwiftData
import AVFoundation

// MARK: - Live Scan View

struct LiveScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let session: AuditSession
    @Bindable var viewModel: LiveScanViewModel
    let onFinish: () -> Void

    @State private var showFinishAlert = false

    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewLayer(scanService: viewModel.scanService)
                .ignoresSafeArea()

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
        .onAppear {
            viewModel.setup(context: modelContext)
            Task { await viewModel.startScanning() }
        }
        .onDisappear {
            viewModel.tearDown()
        }
        .alert("Finish Scan?", isPresented: $showFinishAlert) {
            Button("Finish") {
                viewModel.finishScanning()
                onFinish()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stop scanning and view results. \(viewModel.totalItemsDetected) items detected across \(viewModel.framesProcessed) frames.")
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
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if let layer = scanService.previewLayer, uiView.previewLayer == nil {
            layer.frame = uiView.bounds
            uiView.layer.insertSublayer(layer, at: 0)
            uiView.previewLayer = layer
        }
        uiView.previewLayer?.frame = uiView.bounds
    }
}

final class CameraPreviewUIView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
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
                    Label("Location", systemImage: "mappin")
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
