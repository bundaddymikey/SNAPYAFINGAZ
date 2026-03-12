import Foundation
import Speech
import AVFoundation

/// Voice fallback input service using SFSpeechRecognizer.
/// Allows operators to speak product names during capture when scanning fails.
@Observable
@MainActor
final class VoiceInputService: NSObject {
    static let shared = VoiceInputService()

    var isListening: Bool = false
    var transcribedText: String = ""
    var matchedProduct: ProductSKU? = nil
    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    var error: String? = nil

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var catalog: [ProductSKU] = []
    private var onMatch: ((ProductSKU) -> Void)?
    private var onRawText: ((String) -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Authorization

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                self?.authorizationStatus = status
            }
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    // MARK: - Public API

    /// Start listening for voice input.
    /// - Parameters:
    ///   - catalog: Array of ProductSKU to fuzzy-match against
    ///   - onMatch: Called when a product name is matched
    ///   - onRawText: Called with the raw transcribed text (for manual entry)
    func startListening(
        catalog: [ProductSKU],
        onMatch: @escaping (ProductSKU) -> Void,
        onRawText: @escaping (String) -> Void
    ) {
        guard !isListening else { return }
        guard authorizationStatus == .authorized else {
            requestAuthorization()
            return
        }

        self.catalog = catalog
        self.onMatch = onMatch
        self.onRawText = onRawText
        self.transcribedText = ""
        self.matchedProduct = nil
        self.error = nil

        do {
            try startRecognition()
            isListening = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Stop listening and return final result.
    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    // MARK: - Recognition

    private func startRecognition() throws {
        // Cancel any previous task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        recognitionRequest = request

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available"
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, taskError in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcribedText = text

                    // Try fuzzy match against catalog
                    if let match = self.findBestMatch(for: text) {
                        self.matchedProduct = match
                    }

                    if result.isFinal {
                        if let matched = self.matchedProduct {
                            self.onMatch?(matched)
                        } else {
                            self.onRawText?(text)
                        }
                        self.stopListening()
                    }
                }

                if let taskError {
                    self.error = taskError.localizedDescription
                    self.stopListening()
                }
            }
        }

        // Install audio tap
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - Fuzzy Matching

    /// Find the best matching product from the catalog based on spoken text.
    private func findBestMatch(for spokenText: String) -> ProductSKU? {
        let normalized = spokenText.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3 else { return nil }

        var bestMatch: ProductSKU? = nil
        var bestScore: Double = 0

        for product in catalog {
            let productName = product.name.lowercased()
            let productBrand = product.brand.lowercased()

            // Exact name match
            if productName == normalized {
                return product
            }

            // Compute similarity score
            var score: Double = 0

            // Check if spoken text contains product name or vice versa
            if productName.contains(normalized) || normalized.contains(productName) {
                score = 0.9
            }

            // Word overlap scoring
            let spokenWords = Set(normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
            let nameWords = Set(productName.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
            let overlap = spokenWords.intersection(nameWords).count
            if nameWords.count > 0 {
                let overlapScore = Double(overlap) / Double(nameWords.count)
                score = max(score, overlapScore)
            }

            // Brand match bonus
            if !productBrand.isEmpty && normalized.contains(productBrand) {
                score += 0.15
            }

            // SKU match
            let skuLower = product.sku.lowercased()
            if !skuLower.isEmpty && normalized.contains(skuLower) {
                score = max(score, 0.95)
            }

            if score > bestScore && score >= 0.6 {
                bestScore = score
                bestMatch = product
            }
        }

        return bestMatch
    }
}
