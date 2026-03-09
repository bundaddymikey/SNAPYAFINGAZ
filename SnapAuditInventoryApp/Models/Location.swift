import Foundation
import SwiftData

@Model
class Location {
    @Attribute(.unique) var id: UUID
    var name: String
    var notes: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade) var productLinks: [ProductLocationLink] = []

    init(name: String, notes: String = "") {
        self.id = UUID()
        self.name = name
        self.notes = notes
        self.createdAt = Date()
    }
}
