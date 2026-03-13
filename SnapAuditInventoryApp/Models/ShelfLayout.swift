import Foundation
import SwiftData
import CoreGraphics

nonisolated struct ShelfRect: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let full = ShelfRect(x: 0.05, y: 0.05, w: 0.9, h: 0.9)

    func contains(cx: Double, cy: Double) -> Bool {
        cx >= x && cx <= (x + w) && cy >= y && cy <= (y + h)
    }


}

@Model
class ShelfLayout {
    @Attribute(.unique) var id: UUID
    var name: String
    var locationId: UUID
    var notes: String
    var createdAt: Date

    // Expected inventory CSV attachment
    /// Raw CSV text of the expected inventory file for this shelf.
    var expectedInventoryCSV: String?
    /// Original filename of the last uploaded expected inventory CSV.
    var expectedInventoryFilename: String?
    /// Timestamp when the expected sheet was last replaced.
    var lastExpectedSheetUpdatedAt: Date?

    @Relationship(deleteRule: .cascade) var zones: [ShelfZone] = []
    @Relationship(deleteRule: .cascade) var expectedRows: [ShelfExpectedRow] = []

    init(name: String, locationId: UUID, notes: String = "") {
        self.id = UUID()
        self.name = name
        self.locationId = locationId
        self.notes = notes
        self.createdAt = Date()
    }

    var sortedZones: [ShelfZone] {
        zones.sorted { $0.sortOrder < $1.sortOrder }
    }

    var assignedZoneCount: Int {
        zones.filter { $0.isAssigned }.count
    }

    var hasExpectedInventory: Bool { !expectedRows.isEmpty }

    var totalExpectedQty: Int { expectedRows.reduce(0) { $0 + $1.expectedQty } }

    /// Replace the existing expected sheet with a new set of rows.
    /// Existing rows are removed; new rows are inserted directly.
    /// Call `modelContext.save()` after.
    func replaceExpectedRows(with newRows: [ShelfExpectedRow], csvText: String, filename: String) {
        expectedRows.removeAll()
        for row in newRows {
            row.layout = self
            expectedRows.append(row)
        }
        expectedInventoryCSV = csvText
        expectedInventoryFilename = filename
        lastExpectedSheetUpdatedAt = Date()
    }
}

@Model
class ShelfZone {
    @Attribute(.unique) var id: UUID
    var layoutId: UUID
    var name: String
    var rectJSON: String
    var assignedSkuId: UUID?
    var assignedGroupId: UUID?
    var assignedSkuName: String
    var assignedGroupName: String
    var sortOrder: Int
    var layout: ShelfLayout?

    @Relationship(deleteRule: .cascade) var history: [LayoutAssignmentHistory] = []

    init(layoutId: UUID, name: String, rect: ShelfRect = .full, sortOrder: Int = 0) {
        self.id = UUID()
        self.layoutId = layoutId
        self.name = name
        self.sortOrder = sortOrder
        self.assignedSkuName = ""
        self.assignedGroupName = ""
        let data = (try? JSONEncoder().encode(rect)) ?? Data()
        self.rectJSON = String(data: data, encoding: .utf8) ?? "{}"
    }

    var rect: ShelfRect {
        get {
            guard let data = rectJSON.data(using: .utf8) else { return .full }
            return (try? JSONDecoder().decode(ShelfRect.self, from: data)) ?? .full
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            rectJSON = String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    var assignmentLabel: String {
        if !assignedSkuName.isEmpty { return assignedSkuName }
        if !assignedGroupName.isEmpty { return "Group: \(assignedGroupName)" }
        return "Unassigned"
    }

    var isAssigned: Bool { assignedSkuId != nil || assignedGroupId != nil }
}

@Model
class LayoutAssignmentHistory {
    @Attribute(.unique) var id: UUID
    var zoneId: UUID
    var changedAt: Date
    var changedBy: String
    var previousSkuName: String
    var newSkuName: String
    var zone: ShelfZone?

    init(zoneId: UUID, changedBy: String, previousSkuName: String, newSkuName: String) {
        self.id = UUID()
        self.zoneId = zoneId
        self.changedAt = Date()
        self.changedBy = changedBy
        self.previousSkuName = previousSkuName
        self.newSkuName = newSkuName
    }
}

// MARK: - ShelfExpectedRow

/// One row from the expected inventory CSV attached to a ShelfLayout.
/// Each row represents a product expected to be present on the shelf,
/// with the quantity that should be counted during a Bag Audit.
@Model
class ShelfExpectedRow {
    @Attribute(.unique) var id: UUID
    var layout: ShelfLayout?

    // Product identification fields (from CSV columns)
    var productName: String
    var brand: String
    var productId: String      // UPC / SKU code from the CSV
    var barcode: String        // Barcode string (for scanner matching)
    var expectedQty: Int

    // Resolved after matching against the ProductSKU catalog
    var matchedSkuId: UUID?
    var isMatched: Bool

    init(
        productName: String,
        brand: String = "",
        productId: String = "",
        barcode: String = "",
        expectedQty: Int
    ) {
        self.id = UUID()
        self.productName = productName
        self.brand = brand
        self.productId = productId
        self.barcode = barcode
        self.expectedQty = expectedQty
        self.isMatched = false
    }
}
