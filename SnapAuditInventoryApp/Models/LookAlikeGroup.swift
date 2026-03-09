import Foundation
import SwiftData

@Model
class LookAlikeGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var notes: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade) var members: [LookAlikeGroupMember] = []

    init(name: String, notes: String = "") {
        self.id = UUID()
        self.name = name
        self.notes = notes
        self.createdAt = Date()
    }
}

@Model
class LookAlikeGroupMember {
    @Attribute(.unique) var id: UUID
    var skuId: UUID
    var group: LookAlikeGroup?

    init(skuId: UUID) {
        self.id = UUID()
        self.skuId = skuId
    }
}
