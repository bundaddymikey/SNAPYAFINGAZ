import Foundation

/// Parses a CSV file into an array of `ShelfExpectedRow` objects.
///
/// Supported column headers (case-insensitive):
/// - Product name: `product_name`, `name`, `product name`
/// - Brand:        `brand`
/// - Product ID:   `product_id`, `sku`, `upc_code`, `item_id`
/// - Barcode:      `barcode`, `upc`, `ean`, `gtin`
/// - Quantity:     `expected_qty`, `qty`, `quantity`, `expected`, `count`
///
/// Rows where both product name and quantity are empty are skipped.
/// The parser handles quoted fields and escaped commas.
enum ShelfCSVParser {

    struct ParsedRow {
        var productName: String = ""
        var brand: String = ""
        var productId: String = ""
        var barcode: String = ""
        var expectedQty: Int = 0
    }

    /// Parse raw CSV text into `ShelfExpectedRow` model objects.
    static func parse(csvText: String) -> [ShelfExpectedRow] {
        let rawRows = parseCSV(csvText)
        guard rawRows.count > 1 else { return [] }

        let headers = rawRows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let dataRows = rawRows.dropFirst()

        let nameIdx    = headers.firstIndex(where: { ["product_name","name","product name","item name","item_name"].contains($0) })
        let brandIdx   = headers.firstIndex(where: { ["brand","manufacturer"].contains($0) })
        let productIdx = headers.firstIndex(where: { ["product_id","sku","item_id","upc_code","code"].contains($0) })
        let barcodeIdx = headers.firstIndex(where: { ["barcode","upc","ean","gtin","ean13"].contains($0) })
        let qtyIdx     = headers.firstIndex(where: { ["expected_qty","qty","quantity","expected","count","expected quantity","expected count"].contains($0) })

        var results: [ShelfExpectedRow] = []

        for row in dataRows {
            guard row.count == headers.count || row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }

            func col(_ idx: Int?) -> String {
                guard let i = idx, i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let name    = col(nameIdx)
            let brand   = col(brandIdx)
            let pid     = col(productIdx)
            let barcode = col(barcodeIdx)
            let qtyStr  = col(qtyIdx)
            let qty     = Int(qtyStr) ?? 0

            // Skip rows with no meaningful data
            guard !name.isEmpty || qty > 0 else { continue }

            let shelfRow = ShelfExpectedRow(
                productName: name.isEmpty ? pid : name,
                brand:       brand,
                productId:   pid,
                barcode:     barcode,
                expectedQty: qty
            )
            results.append(shelfRow)
        }

        return results
    }

    // MARK: - RFC 4180 CSV parser

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        let chars = Array(text.unicodeScalars)
        var i = chars.startIndex

        while i < chars.endIndex {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    let next = chars.index(after: i)
                    if next < chars.endIndex && chars[next] == "\"" {
                        currentField.append("\"")
                        i = chars.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.unicodeScalars.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    currentRow.append(currentField)
                    currentField = ""
                } else if c == "\n" || c == "\r" {
                    // Handle \r\n
                    let next = chars.index(after: i)
                    if c == "\r" && next < chars.endIndex && chars[next] == "\n" {
                        i = chars.index(after: i)
                    }
                    currentRow.append(currentField)
                    currentField = ""
                    rows.append(currentRow)
                    currentRow = []
                } else {
                    currentField.unicodeScalars.append(c)
                }
            }
            i = chars.index(after: i)
        }

        // Flush last field/row
        currentRow.append(currentField)
        if currentRow.contains(where: { !$0.isEmpty }) {
            rows.append(currentRow)
        }

        return rows
    }
}
