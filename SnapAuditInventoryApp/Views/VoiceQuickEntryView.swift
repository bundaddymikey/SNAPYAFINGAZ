import SwiftUI
import SwiftData

// MARK: - VoiceEntryViewModel

/// Coordinates VoiceEntryService + VoiceCatalogMatcher → quantity updates.
@Observable
@MainActor
final class VoiceEntryViewModel {

    // MARK: - State

    enum MatchState: Equatable {
        case idle
        case listening
        case processing
        case highConfidence(VoiceMatchResult)     // Auto-increment
        case disambiguation([VoiceMatchResult])   // Show picker
        case noMatch(String)                      // Show "no match" + query
        case confirmed(ProductSKUSnapshot, Int)   // Incremented to N
        case error(String)
    }

    var matchState: MatchState = .idle
    var liveTranscript: String = ""

    // Quantity incremented this session per skuId
    var sessionCounts: [UUID: Int] = [:]

    // MARK: - Deps

    let voiceService = VoiceEntryService()
    private var catalog: [ProductSKUSnapshot] = []

    // Callback: called when a sku should have its quantity incremented
    var onCountIncremented: ((ProductSKUSnapshot, Int) -> Void)?

    // MARK: - Load Catalog

    func loadCatalog(from context: ModelContext) {
        let descriptor = FetchDescriptor<ProductSKU>(
            predicate: #Predicate { $0.isActive == true }
        )
        let skus = (try? context.fetch(descriptor)) ?? []
        catalog = skus.map { ProductSKUSnapshot(from: $0) }
    }

    // MARK: - Voice Flow

    func startListening() async {
        guard voiceService.state == .idle else { return }

        // Ensure permission
        let authorized = await voiceService.requestAuthorization()
        guard authorized else {
            matchState = .error("Speech recognition permission denied. Enable in Settings.")
            return
        }

        matchState = .listening
        voiceService.startListening()

        // Observe the service state
        await observeVoiceService()
    }

    func cancelListening() {
        voiceService.reset()
        matchState = .idle
        liveTranscript = ""
    }

    // MARK: - Disambiguation

    /// User picked one of the top-3 candidates.
    func confirmMatch(_ result: VoiceMatchResult) {
        increment(result.sku)
    }

    // MARK: - Private

    private func observeVoiceService() async {
        // Poll until a terminal state is reached
        while true {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

            liveTranscript = voiceService.transcript

            switch voiceService.state {
            case .idle, .listening, .processing:
                if case .listening = voiceService.state { matchState = .listening }
                if case .processing = voiceService.state { matchState = .processing }
                continue

            case .result(let text):
                voiceService.reset()
                await runMatch(query: text)
                return

            case .error(let message):
                voiceService.reset()
                matchState = .error(message)
                return
            }
        }
    }

    private func runMatch(query: String) async {
        matchState = .processing
        let results = VoiceCatalogMatcher.match(query: query, against: catalog)

        if results.isEmpty {
            matchState = .noMatch(query)
            return
        }

        let top = results[0]
        if top.isHighConfidence {
            matchState = .highConfidence(top)
            // Auto-increment after brief confirmation delay
            try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
            increment(top.sku)
        } else {
            matchState = .disambiguation(results)
        }
    }

    private func increment(_ sku: ProductSKUSnapshot) {
        sessionCounts[sku.id, default: 0] += 1
        let newCount = sessionCounts[sku.id]!
        matchState = .confirmed(sku, newCount)
        onCountIncremented?(sku, newCount)
    }

    var isActive: Bool {
        if case .idle = matchState { return false }
        return true
    }
}

// MARK: - VoiceQuickEntryButton

/// Compact mic button to embed in toolbars or scan views.
struct VoiceQuickEntryButton: View {
    @Bindable var viewModel: VoiceEntryViewModel
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(viewModel.isActive ? .red : .primary)
                .symbolEffect(.bounce, isActive: viewModel.isActive)
        }
        .sheet(isPresented: $showSheet) {
            VoiceQuickEntrySheet(viewModel: viewModel)
        }
    }
}

// MARK: - VoiceQuickEntrySheet

/// Main voice entry bottom sheet.
struct VoiceQuickEntrySheet: View {
    @Bindable var viewModel: VoiceEntryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch viewModel.matchState {
                case .idle:
                    idleContent
                case .listening:
                    listeningContent
                case .processing:
                    processingContent
                case .highConfidence(let result):
                    highConfidenceContent(result)
                case .disambiguation(let results):
                    disambiguationContent(results)
                case .noMatch(let query):
                    noMatchContent(query)
                case .confirmed(let sku, let count):
                    confirmedContent(sku: sku, count: count)
                case .error(let message):
                    errorContent(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Voice Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        viewModel.cancelListening()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if case .idle = viewModel.matchState {
                Task { await viewModel.startListening() }
            }
        }
    }

    // MARK: - Idle

    private var idleContent: some View {
        VStack(spacing: 20) {
            Spacer()
            micButton
            Text("Tap to speak a product name")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var micButton: some View {
        Button {
            Task { await viewModel.startListening() }
        } label: {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.12))
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(.red)
                    .frame(width: 72, height: 72)
                Image(systemName: "mic.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Listening

    private var listeningContent: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated waveform indicator
            ZStack {
                Circle()
                    .fill(.red.opacity(0.08))
                    .frame(width: 120, height: 120)
                    .scaleEffect(1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: viewModel.matchState)
                Circle()
                    .fill(.red.opacity(0.15))
                    .frame(width: 100, height: 100)
                Circle()
                    .fill(.red)
                    .frame(width: 72, height: 72)
                Image(systemName: "mic.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("Listening…")
                    .font(.headline)
                if !viewModel.liveTranscript.isEmpty {
                    Text("\"\(viewModel.liveTranscript)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Speak a product name")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Button("Stop") {
                viewModel.voiceService.stopListening()
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())

            Spacer()
        }
    }

    // MARK: - Processing

    private var processingContent: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Searching catalog…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !viewModel.liveTranscript.isEmpty {
                Text("\"\(viewModel.liveTranscript)\"")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - High Confidence (auto-increment)

    private func highConfidenceContent(_ result: VoiceMatchResult) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            VStack(spacing: 6) {
                Text(result.sku.productName)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                if !result.sku.brand.isEmpty {
                    Text(result.sku.brand)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: "%.0f%% match", result.score * 100))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            Text("Incrementing count…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Disambiguation (top 3)

    private func disambiguationContent(_ results: [VoiceMatchResult]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which product?")
                    .font(.headline)
                if !viewModel.liveTranscript.isEmpty {
                    Text("Heard: \"\(viewModel.liveTranscript)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            ForEach(results) { result in
                Button {
                    viewModel.confirmMatch(result)
                } label: {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.sku.productName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                if !result.sku.brand.isEmpty {
                                    Text(result.sku.brand)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !result.sku.variant.isEmpty {
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(result.sku.variant)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let sz = result.sku.sizeOrWeight, !sz.isEmpty {
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(sz)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.0f%%", result.score * 100))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(result.isHighConfidence ? .green : .orange)
                            Text(result.matchedField)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }

            Button {
                viewModel.cancelListening()
                Task { await viewModel.startListening() }
            } label: {
                Label("Try again", systemImage: "mic")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - No Match

    private func noMatchContent(_ query: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("No match found")
                    .font(.headline)
                Text("Heard: \"\(query)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.cancelListening()
                Task { await viewModel.startListening() }
            } label: {
                Label("Try again", systemImage: "mic")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Confirmed

    private func confirmedContent(sku: ProductSKUSnapshot, count: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(.green.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
            }
            VStack(spacing: 6) {
                Text(sku.productName)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                if !sku.brand.isEmpty {
                    Text(sku.brand)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Count: \(count)")
                    .font(.title2.monospacedDigit().bold())
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button {
                    viewModel.cancelListening()
                    Task { await viewModel.startListening() }
                } label: {
                    Label("Scan again", systemImage: "mic")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.cancelListening()
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    // MARK: - Error

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            VStack(spacing: 6) {
                Text("Something went wrong")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                viewModel.cancelListening()
                Task { await viewModel.startListening() }
            } label: {
                Label("Try again", systemImage: "mic")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}
