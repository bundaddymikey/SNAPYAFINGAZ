import Foundation
import SwiftData

nonisolated enum UserRole: String, Codable, CaseIterable, Sendable {
    case admin
    case auditor
    case viewer

    var displayName: String {
        switch self {
        case .admin: "Admin"
        case .auditor: "Auditor"
        case .viewer: "Viewer"
        }
    }

    var icon: String {
        switch self {
        case .admin: "shield.checkered"
        case .auditor: "clipboard"
        case .viewer: "eye"
        }
    }
}

@Model
class AppUser {
    @Attribute(.unique) var id: UUID
    var name: String
    var role: UserRole
    var pinHash: String
    var pinSalt: String
    var createdAt: Date

    init(name: String, role: UserRole, pinHash: String, pinSalt: String) {
        self.id = UUID()
        self.name = name
        self.role = role
        self.pinHash = pinHash
        self.pinSalt = pinSalt
        self.createdAt = Date()
    }
}
