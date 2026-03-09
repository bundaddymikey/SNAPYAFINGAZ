import Foundation
import SwiftData

@Model
class SampledFrame {
    @Attribute(.unique) var id: UUID
    var media: CapturedMedia?
    var frameIndex: Int
    var timestampMs: Int
    var fileURL: String

    init(
        media: CapturedMedia,
        frameIndex: Int,
        timestampMs: Int,
        fileURL: String
    ) {
        self.id = UUID()
        self.media = media
        self.frameIndex = frameIndex
        self.timestampMs = timestampMs
        self.fileURL = fileURL
    }
}
