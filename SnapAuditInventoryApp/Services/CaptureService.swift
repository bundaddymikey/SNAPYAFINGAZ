import Foundation
import AVFoundation
import UIKit

@Observable
@MainActor
class CaptureService {
    var isSessionRunning = false
    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var lastCapturedImage: UIImage?
    var capturedPhotos: [Data] = []
    var recordedVideoURL: URL?
    var errorMessage: String?
    var isLowLight = false
    var isBlurry = false

    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var recordingDelegate: VideoRecordingDelegate?
    private var recordingTimer: Timer?
    private var _previewLayer: AVCaptureVideoPreviewLayer?
    /// Retains PhotoCaptureDelegate instances until their async callback fires.
    /// AVCapturePhotoOutput holds only a weak reference to its delegate, so without
    /// this array the delegate is immediately deallocated and the callback never fires.
    private var activePhotoDelegates: [PhotoCaptureDelegate] = []

    /// Persistent preview layer — created once, attached by CaptureServicePreviewLayer UIViewRepresentable.
    var previewLayer: AVCaptureVideoPreviewLayer? {
        if let existing = _previewLayer { return existing }
        guard let session = captureSession else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        _previewLayer = layer
        #if DEBUG
        print("[CaptureService] Preview layer created")
        #endif
        return layer
    }

    var hasCameraAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestPermissions() async -> Bool {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        #if DEBUG
        print("[CaptureService] Camera permission status: \(videoStatus.rawValue)")
        #endif
        if videoStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            #if DEBUG
            print("[CaptureService] Camera permission request result: \(granted)")
            #endif
            if !granted {
                #if DEBUG
                print("[CaptureService] Camera permission DENIED by user")
                #endif
                return false
            }
        } else if videoStatus != .authorized {
            #if DEBUG
            print("[CaptureService] Camera permission not authorized (status=\(videoStatus.rawValue)) — guide user to Settings")
            #endif
            return false
        }

        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioStatus == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .audio)
        }

        return true
    }

    func setupSession() {
        #if targetEnvironment(simulator)
        #if DEBUG
        print("[CaptureService] Simulator detected — skipping AVCaptureSession setup")
        #endif
        return
        #else
        guard captureSession == nil else {
            #if DEBUG
            print("[CaptureService] setupSession called but session already exists — skipping")
            #endif
            return
        }

        #if DEBUG
        print("[CaptureService] Setting up AVCaptureSession for photo/video")
        #endif

        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: camera) else {
            errorMessage = "Camera not available"
            #if DEBUG
            print("[CaptureService] ERROR: Could not access back camera or create video input")
            #endif
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        let photo = AVCapturePhotoOutput()
        if session.canAddOutput(photo) {
            session.addOutput(photo)
            photoOutput = photo
        }

        let movie = AVCaptureMovieFileOutput()
        movie.maxRecordedDuration = CMTime(seconds: 25, preferredTimescale: 600)
        if session.canAddOutput(movie) {
            session.addOutput(movie)
            movieOutput = movie
        }

        captureSession = session

        Task.detached { [weak session, weak self] in
            #if DEBUG
            print("[CaptureService] Starting AVCaptureSession...")
            #endif
            session?.startRunning()
            await MainActor.run { [weak self] in
                self?.isSessionRunning = true
                #if DEBUG
                print("[CaptureService] AVCaptureSession started — isSessionRunning = true")
                #endif
            }
        }
        #endif
    }

    func takePhoto(completion: @escaping (Data?) -> Void) {
        #if targetEnvironment(simulator)
        #if DEBUG
        print("[CaptureService] takePhoto — simulator path (synthetic image)")
        #endif
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        let img = renderer.image { ctx in
            UIColor.systemGray5.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            let text = "Simulated Photo \(capturedPhotos.count + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: 200 - size.width/2, y: 150 - size.height/2), withAttributes: attrs)
        }
        let data = img.jpegData(compressionQuality: 0.9)
        if let data {
            capturedPhotos.append(data)
            lastCapturedImage = UIImage(data: data)
            #if DEBUG
            print("[CaptureService] takePhoto — simulator photo appended (total: \(capturedPhotos.count))")
            #endif
        }
        completion(data)
        #else
        errorMessage = nil
        guard let photoOutput else {
            let msg = "Camera not ready — tap to retry"
            errorMessage = msg
            #if DEBUG
            print("[CaptureService] takePhoto — ERROR: photoOutput is nil (session not set up?)")
            #endif
            completion(nil)
            return
        }
        #if DEBUG
        print("[CaptureService] takePhoto — capturing photo on device")
        #endif
        let settings = AVCapturePhotoSettings()
        let delegateTag = UUID()
        let delegate = PhotoCaptureDelegate(tag: delegateTag) { [weak self] data, error in
            // Remove from retention array once callback fires (keyed by tag to avoid forward-capture)
            self?.activePhotoDelegates.removeAll { $0.tag == delegateTag }
            if let error {
                self?.errorMessage = "Photo failed: \(error.localizedDescription)"
                #if DEBUG
                print("[CaptureService] takePhoto — ERROR from delegate: \(error.localizedDescription)")
                #endif
                completion(nil)
                return
            }
            guard let data else {
                self?.errorMessage = "Photo produced no data"
                #if DEBUG
                print("[CaptureService] takePhoto — ERROR: delegate returned nil data")
                #endif
                completion(nil)
                return
            }
            self?.capturedPhotos.append(data)
            self?.lastCapturedImage = UIImage(data: data)
            #if DEBUG
            print("[CaptureService] takePhoto — photo received (total: \(self?.capturedPhotos.count ?? -1))")
            #endif
            completion(data)
        }
        // CRITICAL: retain the delegate — AVCapturePhotoOutput holds it weakly
        activePhotoDelegates.append(delegate)
        photoOutput.capturePhoto(with: settings, delegate: delegate)
        #endif
    }

    func startRecording() {
        #if targetEnvironment(simulator)
        #if DEBUG
        print("[CaptureService] startRecording — simulator path")
        #endif
        isRecording = true
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.recordingDuration += 0.1
            }
        }
        #else
        errorMessage = nil
        guard let movieOutput, !movieOutput.isRecording else {
            #if DEBUG
            print("[CaptureService] startRecording — skipped (movieOutput nil or already recording)")
            #endif
            return
        }
        #if DEBUG
        print("[CaptureService] startRecording — starting video capture on device")
        #endif
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let delegate = VideoRecordingDelegate { [weak self] url, error in
            if let error {
                self?.errorMessage = "Video failed: \(error.localizedDescription)"
                self?.isRecording = false
                self?.recordingTimer?.invalidate()
                #if DEBUG
                print("[CaptureService] startRecording — ERROR from delegate: \(error.localizedDescription)")
                #endif
                return
            }
            self?.recordedVideoURL = url
            self?.isRecording = false
            self?.recordingTimer?.invalidate()
            #if DEBUG
            print("[CaptureService] startRecording — video recorded successfully: \(url?.lastPathComponent ?? "nil")")
            #endif
        }
        recordingDelegate = delegate
        movieOutput.startRecording(to: tempURL, recordingDelegate: delegate)
        isRecording = true
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.recordingDuration += 0.1
            }
        }
        #endif
    }

    func stopRecording() {
        #if targetEnvironment(simulator)
        isRecording = false
        recordingTimer?.invalidate()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        recordedVideoURL = tempURL
        #else
        movieOutput?.stopRecording()
        recordingTimer?.invalidate()
        #endif
    }

    func tearDown() {
        recordingTimer?.invalidate()
        activePhotoDelegates.removeAll()
        _previewLayer = nil
        Task.detached { [weak self] in
            await self?.captureSession?.stopRunning()
            await MainActor.run { [weak self] in
                self?.isSessionRunning = false
                self?.captureSession = nil
                #if DEBUG
                print("[CaptureService] tearDown complete")
                #endif
            }
        }
    }

    func reset() {
        capturedPhotos.removeAll()
        lastCapturedImage = nil
        recordedVideoURL = nil
        recordingDuration = 0
        isRecording = false
        errorMessage = nil
    }
}

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let tag: UUID
    let completion: @MainActor (Data?, Error?) -> Void

    init(tag: UUID = UUID(), completion: @escaping @MainActor (Data?, Error?) -> Void) {
        self.tag = tag
        self.completion = completion
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            Task { @MainActor in
                self.completion(nil, error)
            }
            return
        }
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            self.completion(data, nil)
        }
    }
}

private class VideoRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    let completion: @MainActor (URL?, Error?) -> Void

    init(completion: @escaping @MainActor (URL?, Error?) -> Void) {
        self.completion = completion
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let url = error == nil ? outputFileURL : nil
        Task { @MainActor in
            self.completion(url, error)
        }
    }
}
