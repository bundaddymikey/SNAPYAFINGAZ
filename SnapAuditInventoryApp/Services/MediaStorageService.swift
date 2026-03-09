import Foundation
import UIKit

nonisolated struct MediaStorageService: Sendable {
    static let shared = MediaStorageService()

    private var baseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SnapAuditMedia", isDirectory: true)
    }

    func sessionDirectory(sessionId: UUID) -> URL {
        baseDirectory.appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    func framesDirectory(sessionId: UUID, mediaId: UUID) -> URL {
        sessionDirectory(sessionId: sessionId)
            .appendingPathComponent("frames_\(mediaId.uuidString)", isDirectory: true)
    }

    func ensureDirectoryExists(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func savePhoto(_ imageData: Data, sessionId: UUID, filename: String) throws -> String {
        let dir = sessionDirectory(sessionId: sessionId)
        try ensureDirectoryExists(at: dir)
        let fileURL = dir.appendingPathComponent(filename)
        try imageData.write(to: fileURL)
        return fileURL.path
    }

    func saveVideo(from tempURL: URL, sessionId: UUID, filename: String) throws -> String {
        let dir = sessionDirectory(sessionId: sessionId)
        try ensureDirectoryExists(at: dir)
        let destURL = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: tempURL, to: destURL)
        return destURL.path
    }

    func saveFrame(_ imageData: Data, sessionId: UUID, mediaId: UUID, filename: String) throws -> String {
        let dir = framesDirectory(sessionId: sessionId, mediaId: mediaId)
        try ensureDirectoryExists(at: dir)
        let fileURL = dir.appendingPathComponent(filename)
        try imageData.write(to: fileURL)
        return fileURL.path
    }

    func saveCrop(_ imageData: Data, sessionId: UUID, filename: String) throws -> String {
        let dir = sessionDirectory(sessionId: sessionId).appendingPathComponent("crops", isDirectory: true)
        try ensureDirectoryExists(at: dir)
        let fileURL = dir.appendingPathComponent(filename)
        try imageData.write(to: fileURL)
        return fileURL.path
    }

    func deleteSessionFiles(sessionId: UUID) {
        let dir = sessionDirectory(sessionId: sessionId)
        try? FileManager.default.removeItem(at: dir)
    }

    func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func loadImage(at path: String) -> UIImage? {
        UIImage(contentsOfFile: path)
    }
}
