import Foundation
import UIKit

nonisolated struct ReferenceStorageService: Sendable {
    static let shared = ReferenceStorageService()
    private init() {}

    private var baseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SnapAuditRef", isDirectory: true)
    }

    func skuDirectory(skuId: UUID) -> URL {
        baseDirectory.appendingPathComponent(skuId.uuidString, isDirectory: true)
    }

    private func ensureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func savePhoto(_ data: Data, skuId: UUID) throws -> String {
        let dir = skuDirectory(skuId: skuId)
        try ensureDirectory(at: dir)
        let fileURL = dir.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: fileURL)
        return fileURL.path
    }

    func saveVideoFromTemp(_ tempURL: URL, skuId: UUID) throws -> String {
        let dir = skuDirectory(skuId: skuId)
        try ensureDirectory(at: dir)
        let destURL = dir.appendingPathComponent("\(UUID().uuidString).mov")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: tempURL, to: destURL)
        return destURL.path
    }

    func deleteFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    func loadImage(at path: String) -> UIImage? {
        UIImage(contentsOfFile: path)
    }

    func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
