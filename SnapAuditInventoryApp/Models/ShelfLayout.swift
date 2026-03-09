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

    @Relationship(deleteRule: .cascade) var zones: [ShelfZone] = []

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
