import Foundation
import SwiftData

@Model
class InventorySystemSnapshot {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var createdAt: Date
    var sourceFilename: String
    var rawCSVText: String

    @Relationship(deleteRule: .cascade) var rows: [OnHandRow] = []

    init(sessionId: UUID, sourceFilename: String, rawCSVText: String) {
        self.id = UUID()
        self.sessionId = sessionId
        self.createdAt = Date()
        self.sourceFilename = sourceFilename
        self.rawCSVText = rawCSVText
    }

    var matchedCount: Int { rows.filter { $0.isMatched }.count }
    var unmatchedCount: Int { rows.filter { !$0.isMatched }.count }
    var totalQty: Int { rows.reduce(0) { $0 + $1.onHandQty } }
}
