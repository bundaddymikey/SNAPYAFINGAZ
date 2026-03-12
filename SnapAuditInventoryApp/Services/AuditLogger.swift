import Foundation

/// Lightweight in-memory logger for recognition events, review decisions, and audit actions.
/// Retains the last 500 entries. Thread-safe via MainActor.
@Observable
@MainActor
final class AuditLogger {
    static let shared = AuditLogger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let message: String

        enum Category: String, CaseIterable {
            case recognition = "Recognition"
            case review = "Review"
            case session = "Session"
            case error = "Error"
            case info = "Info"

            var icon: String {
                switch self {
                case .recognition: "eye.fill"
                case .review: "checkmark.shield.fill"
                case .session: "folder.fill"
                case .error: "exclamationmark.triangle.fill"
                case .info: "info.circle.fill"
                }
            }
        }

        var formattedTimestamp: String {
            Self.formatter.string(from: timestamp)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 500

    private init() {}

    func log(_ message: String, category: LogEntry.Category = .info) {
        let entry = LogEntry(timestamp: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func logRecognition(skuName: String, score: Double, status: String) {
        log("[\(skuName)] score=\(String(format: "%.2f", score)) → \(status)", category: .recognition)
    }

    func logReview(action: String, skuName: String, evidenceId: UUID) {
        log("\(action): \(skuName) (evidence: \(evidenceId.uuidString.prefix(8)))", category: .review)
    }

    func logSession(_ message: String) {
        log(message, category: .session)
    }

    func logError(_ message: String) {
        log(message, category: .error)
    }

    func clear() {
        entries.removeAll()
    }
}
