import Foundation
import SwiftData

nonisolated enum MediaType: String, Codable, CaseIterable, Sendable {
    case photo
    case video

    var displayName: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        }
    }

    var icon: String {
        switch self {
        case .photo: "photo"
        case .video: "film"
        }
    }
}

@Model
class CapturedMedia {
    @Attribute(.unique) var id: UUID
    var session: AuditSession?
    var type: MediaType
    var fileURL: String
    var createdAt: Date
    var metadataJSON: String

    @Relationship(deleteRule: .cascade) var sampledFrames: [SampledFrame] = []

    init(
        session: AuditSession,
        type: MediaType,
        fileURL: String,
        metadataJSON: String = "{}"
    ) {
        self.id = UUID()
        self.session = session
        self.type = type
        self.fileURL = fileURL
        self.createdAt = Date()
        self.metadataJSON = metadataJSON
    }
}
