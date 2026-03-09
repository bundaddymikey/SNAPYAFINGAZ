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

    var hasCameraAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestPermissions() async -> Bool {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if videoStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { return false }
        } else if videoStatus != .authorized {
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
        return
        #else
        guard captureSession == nil else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: camera) else {
            errorMessage = "Camera not available"
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

        Task.detached { [weak session] in
            session?.startRunning()
            await MainActor.run { [weak self] in
                self?.isSessionRunning = true
            }
        }
        #endif
    }

    func takePhoto(completion: @escaping (Data?) -> Void) {
        #if targetEnvironment(simulator)
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
        }
        completion(data)
        #else
        guard let photoOutput else {
            completion(nil)
            return
        }
        let settings = AVCapturePhotoSettings()
        let delegate = PhotoCaptureDelegate { [weak self] data in
            if let data {
                self?.capturedPhotos.append(data)
                self?.lastCapturedImage = UIImage(data: data)
            }
            completion(data)
        }
        photoOutput.capturePhoto(with: settings, delegate: delegate)
        #endif
    }

    func startRecording() {
        #if targetEnvironment(simulator)
        isRecording = true
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.recordingDuration += 0.1
            }
        }
        #else
        guard let movieOutput, !movieOutput.isRecording else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let delegate = VideoRecordingDelegate { [weak self] url in
            self?.recordedVideoURL = url
            self?.isRecording = false
            self?.recordingTimer?.invalidate()
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
        Task.detached { [weak self] in
            await self?.captureSession?.stopRunning()
            await MainActor.run { [weak self] in
                self?.isSessionRunning = false
                self?.captureSession = nil
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
    let completion: @MainActor (Data?) -> Void

    init(completion: @escaping @MainActor (Data?) -> Void) {
        self.completion = completion
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            completion(data)
        }
    }
}

private class VideoRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    let completion: @MainActor (URL?) -> Void

    init(completion: @escaping @MainActor (URL?) -> Void) {
        self.completion = completion
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let url = error == nil ? outputFileURL : nil
        Task { @MainActor in
            completion(url)
        }
    }
}
