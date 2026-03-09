import Foundation

nonisolated struct CSVParseResult: Sendable {
    let headers: [String]
    let rows: [[String: String]]
    let rawText: String
    let filename: String
}

nonisolated struct CSVColumnMapping: Sendable {
    let keyColumn: String
    let qtyColumn: String
    let locationColumn: String?
    let zoneColumn: String?
}

nonisolated struct CSVRowMatch: Sendable {
    let skuOrNameKey: String
    let qty: Int
    let matchedSkuId: UUID?
    let locationName: String
    let zone: String
    var isMatched: Bool { matchedSkuId != nil }
}

nonisolated struct ParsedSKUInfo: Sendable {
    let id: UUID
    let sku: String
    let name: String
}

nonisolated final class CSVImportService: Sendable {
    static let shared = CSVImportService()
    private init() {}

    func parse(text: String, filename: String) -> CSVParseResult {
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return CSVParseResult(headers: [], rows: [], rawText: text, filename: filename)
        }

        let headers = parseCSVLine(lines.removeFirst())
        var rows: [[String: String]] = []

        for line in lines {
            let values = parseCSVLine(line)
            var dict: [String: String] = [:]
            for (i, header) in headers.enumerated() {
                dict[header] = i < values.count ? values[i].trimmingCharacters(in: .whitespaces) : ""
            }
            if !dict.values.allSatisfy({ $0.isEmpty }) {
                rows.append(dict)
            }
        }

        return CSVParseResult(headers: headers, rows: rows, rawText: text, filename: filename)
    }

    func applyMapping(
        rows: [[String: String]],
        mapping: CSVColumnMapping,
        skus: [ParsedSKUInfo]
    ) -> [CSVRowMatch] {
        rows.compactMap { row -> CSVRowMatch? in
            let key = row[mapping.keyColumn] ?? ""
            guard !key.isEmpty else { return nil }
            let qtyStr = row[mapping.qtyColumn] ?? "0"
            let qty = Int(qtyStr.replacingOccurrences(of: ",", with: "")) ?? 0
            let location = mapping.locationColumn.flatMap { row[$0] } ?? ""
            let zone = mapping.zoneColumn.flatMap { row[$0] } ?? ""
            let matchedId = findSKU(for: key, in: skus)?.id
            return CSVRowMatch(skuOrNameKey: key, qty: qty, matchedSkuId: matchedId, locationName: location, zone: zone)
        }
    }

    func findSKU(for key: String, in skus: [ParsedSKUInfo]) -> ParsedSKUInfo? {
        let lower = key.lowercased().trimmingCharacters(in: .whitespaces)
        if let exact = skus.first(where: { $0.sku.lowercased() == lower }) { return exact }
        if let exact = skus.first(where: { $0.name.lowercased() == lower }) { return exact }
        if let partial = skus.first(where: {
            let s = $0.sku.lowercased()
            return s.contains(lower) || lower.contains(s)
        }) { return partial }
        if let partial = skus.first(where: {
            let n = $0.name.lowercased()
            return n.contains(lower) || lower.contains(n)
        }) { return partial }
        return nil
    }

    func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 2
                    continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
}
