import Foundation
@preconcurrency import AVFoundation
import UIKit
import CoreImage

// MARK: - Frame Throttle State (nonisolated, videoOutputQueue-only)

/// Lightweight state container for frame throttle + processing guard.
/// Lives off MainActor; all access is on `videoOutputQueue`.
private final class FrameThrottleState {
    var lastForwardedTimestamp: CFAbsoluteTime = 0
    var isProcessingFrame = false
    var minFrameInterval: Double = 1.0 / 4.0  // default 4 fps
    /// Optional raw pixel buffer callback — stored here so the nonisolated delegate can reach it.
    var rawPixelBufferHandler: ((CVPixelBuffer, CMTime) -> Void)?
    /// Legacy UIImage callback for backward compat (called after lazy conversion).
    var uiImageHandler: ((UIImage) -> Void)?
}

// MARK: - LiveScanService

/// Camera service for Real-Time Scan mode.
/// Provides a stable, persistent preview layer and delivers throttled video frames via callbacks.
@Observable
@MainActor
final class LiveScanService: NSObject {

    // MARK: - Observable State

    var isRunning = false
    var latestFrame: UIImage?
    var errorMessage: String?

    // MARK: - Configuration

    /// Maximum frames per second forwarded to the recognition pipeline.
    /// Frames arriving faster than this rate are silently dropped.
    var maxProcessingFPS: Double = 4.0 {
        didSet { throttleState.minFrameInterval = maxProcessingFPS > 0 ? 1.0 / maxProcessingFPS : 0 }
    }

    // MARK: - Private: Session

    private var captureSession: AVCaptureSession?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let sessionQueue = DispatchQueue(label: "com.snapaudit.livescan.session", qos: .userInitiated)
    private let videoOutputQueue = DispatchQueue(label: "com.snapaudit.livescan.video", qos: .userInitiated)

    // MARK: - Private: Preview Layer (persistent — created once)

    private var _previewLayer: AVCaptureVideoPreviewLayer?

    /// Persistent cached preview layer. Never recreated after first access.
    var previewLayer: AVCaptureVideoPreviewLayer? {
        if let existing = _previewLayer { return existing }
        guard let session = captureSession else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        _previewLayer = layer
        return layer
    }

    // MARK: - Private: Shared Image Processing Resources

    /// Allocated once at init. CIContext creation is expensive; never recreate per frame.
    private let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Private: Throttle State (off MainActor)

    private let throttleState = FrameThrottleState()

    // MARK: - Private: Callbacks

    /// Primary callback: now stores the UIImage handler in throttleState for preview use.
    private var frameHandler: ((UIImage) -> Void)? {
        get { throttleState.uiImageHandler }
        set { throttleState.uiImageHandler = newValue }
    }

    /// Primary recognition callback: raw CVPixelBuffer on `videoOutputQueue`.
    /// The ViewModel hooks here for recognition — no UIImage conversion on this path.
    var rawRecognitionHandler: ((CVPixelBuffer, CMTime) -> Void)? {
        get { throttleState.rawPixelBufferHandler }
        set { throttleState.rawPixelBufferHandler = newValue }
    }

    /// Legacy UIImage callback — preserved for backward compatibility.
    /// Receives a lazily-converted UIImage after the raw recognition path fires.
    /// Set via `setupSession(onFrame:)`; do not set both this and rawRecognitionHandler
    /// unless you need both paths simultaneously.
    var rawPixelBufferHandler: ((CVPixelBuffer, CMTime) -> Void)? {
        get { throttleState.rawPixelBufferHandler }
        set { throttleState.rawPixelBufferHandler = newValue }
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return status == .authorized
    }

    // MARK: - Setup

    /// Configure and start the capture session.
    /// - Parameter onFrame: Called on MainActor with each throttled UIImage frame.
    func setupSession(onFrame: @escaping (UIImage) -> Void) {
        #if targetEnvironment(simulator)
        errorMessage = "Camera not available on simulator"
        #if DEBUG
        print("[LiveScanService] Camera unavailable — simulator")
        #endif
        return
        #else
        guard captureSession == nil else { return }
        self.frameHandler = onFrame

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
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        // Continuous autofocus, auto-exposure, auto white balance
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
        frameHandler = nil
        rawPixelBufferHandler = nil
        latestFrame = nil
        throttleState.isProcessingFrame = false
        throttleState.lastForwardedTimestamp = 0
    }
}

// MARK: - Sample Buffer Delegate

extension LiveScanService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // --- Frame throttle ---
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = throttleState.minFrameInterval
        guard now - throttleState.lastForwardedTimestamp >= minInterval else { return }

        // --- Processing guard ---
        guard !throttleState.isProcessingFrame else { return }

        throttleState.isProcessingFrame = true
        throttleState.lastForwardedTimestamp = now

        // --- PRIMARY PATH: deliver raw CVPixelBuffer directly (no image conversion) ---
        // This is the preferred recognition path. The ViewModel does detection on the buffer.
        if let rawHandler = throttleState.rawPixelBufferHandler {
            #if DEBUG
            // print("[LiveScanService] Raw frame delivered to recognition")
            #endif
            rawHandler(pixelBuffer, pts)
        }

        // --- PREVIEW PATH: lazy UIImage conversion only when a UI handler or preview update is needed ---
        let hasUIImageHandler = throttleState.uiImageHandler != nil
        if hasUIImageHandler {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImage = sharedCIContext.createCGImage(ciImage, from: ciImage.extent) {
                let image = UIImage(cgImage: cgImage)
                #if DEBUG
                // print("[LiveScanService] UIImage conversion used (preview handler present)")
                #endif
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.latestFrame = image
                    self.throttleState.uiImageHandler?(image)
                }
            }
        } else {
            // No UIImage handler — still update latestFrame for any UI that reads it,
            // but only if the raw path didn't already handle it.
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImage = sharedCIContext.createCGImage(ciImage, from: ciImage.extent) {
                let image = UIImage(cgImage: cgImage)
                Task { @MainActor [weak self] in
                    self?.latestFrame = image
                }
            }
        }

        // Reset processing guard after the throttle interval
        let resetDelay = max(minInterval, 0.05)
        videoOutputQueue.asyncAfter(deadline: .now() + resetDelay) { [weak self] in
            self?.throttleState.isProcessingFrame = false
        }
    }
}

