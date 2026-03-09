import Foundation

nonisolated final class CSVExportService: Sendable {
    static let shared = CSVExportService()
    private init() {}

    func exportSession(_ session: AuditSession) -> String {
        var lines: [String] = []

        let headers = [
            "Timestamp", "Location", "SKU", "ProductName", "VisionCount",
            "CountConfidence%", "PendingCount", "FlagReasons",
            "ExpectedQty", "OnHandQty", "DeltaExpected", "DeltaOnHand",
            "InferredFromPrior", "ReviewedBy", "Notes"
        ]
        lines.append(headers.map { csvEscape($0) }.joined(separator: ","))

        let dateStr = session.createdAt.formatted(.dateTime.year().month().day().hour().minute())
        let sorted = session.lineItems.sorted { $0.skuNameSnapshot < $1.skuNameSnapshot }

        for item in sorted {
            let confidence = String(format: "%.1f", item.countConfidence * 100)
            let flags = item.flagReasons.map { $0.rawValue }.joined(separator: "|")
            let pending = "\(item.pendingEvidenceCount)"
            let expected = item.expectedQty.map { "\($0)" } ?? ""
            let onHand = item.posOnHand.map { "\($0)" } ?? ""
            let deltaExp = item.delta.map { deltaSign($0) } ?? ""
            let deltaOH = item.deltaOnHand.map { deltaSign($0) } ?? ""
            let inferred = item.inferredFromPrior ? "Y" : "N"

            let row = [
                dateStr,
                session.locationName,
                "",
                item.skuNameSnapshot,
                "\(item.visionCount)",
                confidence,
                pending,
                flags,
                expected,
                onHand,
                deltaExp,
                deltaOH,
                inferred,
                "",
                item.notes
            ]
            lines.append(row.map { csvEscape($0) }.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    func writeToTempFile(_ csv: String, filename: String) -> URL? {
        let tmpDir = FileManager.default.temporaryDirectory
        let url = tmpDir.appendingPathComponent(filename)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func deltaSign(_ value: Int) -> String {
        if value > 0 { return "+\(value)" }
        return "\(value)"
    }
}
