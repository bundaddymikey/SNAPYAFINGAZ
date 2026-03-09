import Foundation
import SwiftData

nonisolated struct ZoneRect: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var weight: Double

    init(name: String, x: Double, y: Double, w: Double, h: Double, weight: Double) {
        self.id = UUID()
        self.name = name
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.weight = weight
    }
}

nonisolated enum ZonePreset: String, CaseIterable, Sendable {
    case bottomLabel = "Bottom Label Focus"
    case topBadge = "Top Badge Focus"
    case rightLabel = "Right Label Focus"
    case custom = "Custom"

    var zones: [ZoneRect] {
        switch self {
        case .bottomLabel:
            return [ZoneRect(name: "Bottom Label", x: 0.0, y: 0.72, w: 1.0, h: 0.28, weight: 2.5)]
        case .topBadge:
            return [ZoneRect(name: "Top Badge", x: 0.25, y: 0.0, w: 0.5, h: 0.25, weight: 2.5)]
        case .rightLabel:
            return [ZoneRect(name: "Right Label", x: 0.60, y: 0.10, w: 0.40, h: 0.80, weight: 2.5)]
        case .custom:
            return [ZoneRect(name: "Zone 1", x: 0.1, y: 0.1, w: 0.8, h: 0.4, weight: 2.0)]
        }
    }

    var icon: String {
        switch self {
        case .bottomLabel: "square.bottomhalf.filled"
        case .topBadge: "square.tophalf.filled"
        case .rightLabel: "rectangle.righthalf.filled"
        case .custom: "slider.horizontal.3"
        }
    }
}

@Model
class ZoneProfile {
    @Attribute(.unique) var id: UUID
    var groupId: UUID
    var zonesJSON: String

    init(groupId: UUID, zonesJSON: String = "[]") {
        self.id = UUID()
        self.groupId = groupId
        self.zonesJSON = zonesJSON
    }

    var zones: [ZoneRect] {
        get {
            guard let data = zonesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ZoneRect].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            zonesJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }
}
