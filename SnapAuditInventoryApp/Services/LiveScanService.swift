import Foundation
import AVFoundation
import UIKit

/// Camera service for Real-Time Scan mode.
/// Provides a live camera preview and delivers video frames via `AVCaptureVideoDataOutput`.
@Observable
@MainActor
final class LiveScanService: NSObject {
    var isRunning = false
    var latestFrame: UIImage?
    var errorMessage: String?

    private var captureSession: AVCaptureSession?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let sessionQueue = DispatchQueue(label: "com.snapaudit.livescan.session")
    private let videoOutputQueue = DispatchQueue(label: "com.snapaudit.livescan.video", qos: .userInitiated)
    private var frameHandler: ((UIImage) -> Void)?

    /// The preview layer for embedding in a UIView.
    var previewLayer: AVCaptureVideoPreviewLayer? {
        guard let session = captureSession else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    func requestPermissions() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return status == .authorized
    }

    /// Set up the capture session with video data output (no photo/movie).
    func setupSession(onFrame: @escaping (UIImage) -> Void) {
        #if targetEnvironment(simulator)
        errorMessage = "Camera not available on simulator"
        return
        #else
        guard captureSession == nil else { return }
        self.frameHandler = onFrame

        let session = AVCaptureSession()
        session.sessionPreset = .medium // Lower res for performance

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: camera) else {
            errorMessage = "Camera not available"
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        // Configure auto-focus for continuous scanning
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            try? camera.lockForConfiguration()
            camera.focusMode = .continuousAutoFocus
            camera.unlockForConfiguration()
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

    func startRunning() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.startRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = true
            }
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = false
            }
        }
    }

    func tearDown() {
        stopRunning()
        captureSession = nil
        videoDataOutput = nil
        frameHandler = nil
        latestFrame = nil
    }
}

// MARK: - Sample Buffer Delegate

extension LiveScanService: @preconcurrency AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)

        Task { @MainActor [weak self] in
            self?.latestFrame = image
            self?.frameHandler?(image)
        }
    }
}
