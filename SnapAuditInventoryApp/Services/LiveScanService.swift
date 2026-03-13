import Foundation
@preconcurrency import AVFoundation
import UIKit
import CoreImage

// MARK: - Frame Pipeline Actor
// A Swift actor serializes all frame-throttle and callback state.
// captureOutput dispatches to it without touching @MainActor-isolated state.

actor FramePipelineActor {
    var lastForwardedTimestamp: CFAbsoluteTime = 0
    var isProcessingFrame = false
    var minFrameInterval: Double = 1.0 / 4.0
    var rawPixelBufferHandler: ((CVPixelBuffer, CMTime) -> Void)?
    var uiImageHandler: ((UIImage) -> Void)?
    /// Shared CIContext — created once inside the actor; accessed only from captureOutput.
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func setMinFrameInterval(_ interval: Double) {
        minFrameInterval = interval
    }

    func setRawHandler(_ handler: ((CVPixelBuffer, CMTime) -> Void)?) {
        rawPixelBufferHandler = handler
    }

    func setUIHandler(_ handler: ((UIImage) -> Void)?) {
        uiImageHandler = handler
    }

    func reset() {
        isProcessingFrame = false
        lastForwardedTimestamp = 0
        rawPixelBufferHandler = nil
        uiImageHandler = nil
    }

    /// Try to acquire the processing slot. Returns nil if throttled or already processing.
    /// On success, returns a snapshot of the callbacks to use for this frame.
    func acquireSlot(now: CFAbsoluteTime) -> (rawHandler: ((CVPixelBuffer, CMTime) -> Void)?,
                                               uiHandler: ((UIImage) -> Void)?,
                                               ciContext: CIContext,
                                               resetDelay: Double)? {
        guard now - lastForwardedTimestamp >= minFrameInterval else { return nil }
        guard !isProcessingFrame else { return nil }
        isProcessingFrame = true
        lastForwardedTimestamp = now
        return (rawPixelBufferHandler, uiImageHandler, ciContext, max(minFrameInterval, 0.05))
    }

    func releaseSlot() {
        isProcessingFrame = false
    }
}

// MARK: - LiveScanService

/// Camera service for Real-Time Scan mode.
/// UI-observable state is @MainActor-isolated.
/// Frame delivery uses an actor-isolated FramePipelineActor for thread-safe state.
@Observable
@MainActor
final class LiveScanService: NSObject {

    // MARK: - Observable State (MainActor)

    var isRunning = false
    var latestFrame: UIImage?
    var errorMessage: String?

    // MARK: - Configuration

    /// Maximum frames per second forwarded to the recognition pipeline.
    var maxProcessingFPS: Double = 4.0 {
        didSet {
            let interval = maxProcessingFPS > 0 ? 1.0 / maxProcessingFPS : 0
            Task { await pipeline.setMinFrameInterval(interval) }
        }
    }

    // MARK: - Private: Session

    private var captureSession: AVCaptureSession?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let sessionQueue = DispatchQueue(label: "com.snapaudit.livescan.session", qos: .userInitiated)
    private let videoOutputQueue = DispatchQueue(label: "com.snapaudit.livescan.video", qos: .userInitiated)

    // MARK: - Private: Preview Layer (persistent — created once)

    private var _previewLayer: AVCaptureVideoPreviewLayer?

    var previewLayer: AVCaptureVideoPreviewLayer? {
        if let existing = _previewLayer { return existing }
        guard let session = captureSession else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        _previewLayer = layer
        return layer
    }

    // MARK: - Private: Frame Pipeline (actor — not MainActor-isolated)

    private let pipeline = FramePipelineActor()

    // MARK: - Callbacks

    /// Raw CVPixelBuffer callback for the recognition path — called on `videoOutputQueue`.
    var rawRecognitionHandler: ((CVPixelBuffer, CMTime) -> Void)? {
        get { nil } // write-only; getter not meaningful across actor boundary
        set { Task { await pipeline.setRawHandler(newValue) } }
    }

    /// Legacy: same as rawRecognitionHandler for backward compat.
    var rawPixelBufferHandler: ((CVPixelBuffer, CMTime) -> Void)? {
        get { nil }
        set { Task { await pipeline.setRawHandler(newValue) } }
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        #if DEBUG
        print("[LiveScanService] Camera permission status: \(status.rawValue)")
        #endif
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            #if DEBUG
            print("[LiveScanService] Camera permission request result: \(granted)")
            #endif
            return granted
        }
        let authorized = status == .authorized
        if !authorized {
            #if DEBUG
            print("[LiveScanService] Camera permission not authorized (status=\(status.rawValue))")
            #endif
        }
        return authorized
    }

    // MARK: - Setup

    func setupSession(onFrame: @escaping (UIImage) -> Void) {
        #if targetEnvironment(simulator)
        errorMessage = "Camera not available on simulator"
        #if DEBUG
        print("[LiveScanService] Camera unavailable — simulator")
        #endif
        return
        #else
        guard captureSession == nil else {
            #if DEBUG
            print("[LiveScanService] setupSession called but session already exists — skipping")
            #endif
            return
        }
        #if DEBUG
        print("[LiveScanService] setupSession — starting camera session setup on device")
        #endif
        Task { await pipeline.setUIHandler(onFrame) }

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            errorMessage = "Camera not available"
            #if DEBUG
            print("[LiveScanService] No back camera found")
            #endif
            return
        }

        guard let videoInput = try? AVCaptureDeviceInput(device: camera) else {
            errorMessage = "Camera input unavailable"
            #if DEBUG
            print("[LiveScanService] ERROR: Could not create AVCaptureDeviceInput")
            #endif
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            camera.unlockForConfiguration()
        } catch {
            #if DEBUG
            print("[LiveScanService] Camera config warning: \(error.localizedDescription)")
            #endif
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: videoOutputQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
            videoDataOutput = output
        }

        captureSession = session
        startRunning()
        #endif
    }

    // MARK: - Lifecycle (idempotent)

    func startRunning() {
        guard let session = captureSession else { return }
        sessionQueue.async { [weak self] in
            guard !session.isRunning else { return }
            session.startRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = true
                #if DEBUG
                print("[LiveScanService] Session started")
                #endif
            }
        }
    }

    func stopRunning() {
        guard let session = captureSession else { return }
        sessionQueue.async { [weak self] in
            guard session.isRunning else { return }
            session.stopRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = false
                #if DEBUG
                print("[LiveScanService] Session stopped")
                #endif
            }
        }
    }

    func tearDown() {
        stopRunning()
        captureSession = nil
        videoDataOutput = nil
        _previewLayer = nil
        latestFrame = nil
        Task { await pipeline.reset() }
    }
}

// MARK: - Sample Buffer Delegate
// captureOutput is nonisolated. It uses the FramePipelineActor via async Task — safely.

extension LiveScanService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = CFAbsoluteTimeGetCurrent()
        let p = pipeline // local capture of the actor reference — safe across concurrency

        Task {
            // Acquire the processing slot from the actor — this handles throttle + guard atomically.
            guard let slot = await p.acquireSlot(now: now) else { return }

            // --- PRIMARY PATH: raw CVPixelBuffer to recognition (no image conversion) ---
            if let rawHandler = slot.rawHandler {
                rawHandler(pixelBuffer, pts)
            }

            // --- PREVIEW PATH: lazy UIImage conversion ---
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImage = slot.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                let image = UIImage(cgImage: cgImage)
                let uiHandler = slot.uiHandler
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.latestFrame = image
                    uiHandler?(image)
                }
            }

            // Reset processing slot after the throttle interval
            try? await Task.sleep(nanoseconds: UInt64(slot.resetDelay * 1_000_000_000))
            await p.releaseSlot()
        }
    }
}
