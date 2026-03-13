import Foundation
import Speech
import AVFoundation

/// Wraps SFSpeechRecognizer for short-phrase voice input.
/// Optimized for 1–5 word product name utterances, not long dictation.
@Observable
@MainActor
final class VoiceEntryService: NSObject {

    // MARK: - State

    enum RecordingState: Equatable {
        case idle
        case listening
        case processing
        case result(String)
        case error(String)
    }

    var state: RecordingState = .idle
    var transcript: String = ""

    // MARK: - Private

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // Short-phrase cutoff: stop after this many seconds of silence
    private let silenceTimeout: TimeInterval = 1.8
    private var silenceTimer: Timer?

    // MARK: - Init

    override init() {
        super.init()
        // Prefer en-US; fall back to device locale
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
    }

    // MARK: - Public API

    var isAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    /// Request authorization if needed. Returns true if already authorized.
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Start a short-phrase recording session.
    func startListening() {
        guard state == .idle else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .error("Speech recognition not available.")
            return
        }

        do {
            try startAudioSession()
            try startRecognition(recognizer: recognizer)
            state = .listening
            transcript = ""
        } catch {
            state = .error("Could not start microphone: \(error.localizedDescription)")
        }
    }

    /// Stop recording and finalize transcript.
    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        state = .processing
    }

    /// Reset to idle (call after result consumed).
    func reset() {
        cancelRecognition()
        state = .idle
        transcript = ""
    }

    // MARK: - Private

    private func startAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startRecognition(recognizer: SFSpeechRecognizer) throws {
        cancelRecognition()

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else {
            throw NSError(domain: "VoiceEntry", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create recognition request"])
        }

        // Short-phrase optimizations
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .search          // Short-form, non-dictation
        if #available(iOS 16.0, *) {
            recognitionRequest.addsPunctuation = false // No periods in product names
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    let best = result.bestTranscription.formattedString
                    self.transcript = best
                    self.resetSilenceTimer()    // Still getting audio

                    if result.isFinal {
                        self.finalize(transcript: best)
                    }
                }

                if let error {
                    // Code 1110 = no speech; treat gracefully
                    let nsError = error as NSError
                    if nsError.code == 1110 {
                        self.state = .error("No speech detected. Try again.")
                    } else if self.state == .listening || self.state == .processing {
                        let best = self.transcript
                        if !best.isEmpty {
                            self.finalize(transcript: best)
                        } else {
                            self.state = .error("Recognition failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopListening()
            }
        }
    }

    private func finalize(transcript: String) {
        guard state == .listening || state == .processing else { return }
        cancelRecognition()
        let cleaned = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        state = .result(cleaned)
    }

    private func cancelRecognition() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
