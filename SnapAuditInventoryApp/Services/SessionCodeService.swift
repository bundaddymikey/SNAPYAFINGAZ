import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Generates and validates 6-character alphanumeric session join codes.
/// Also provides QR code images for display and scanning.
enum SessionCodeService {

    // Characters that avoid visual ambiguity (no 0/O, I/1/l)
    private static let charset = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    // MARK: - Code Generation

    /// Generate a new random 6-character session code.
    static func generate() -> String {
        (0..<6).compactMap { _ in charset.randomElement() }.map(String.init).joined()
    }

    /// Normalize user-entered code: uppercase and strip spaces.
    static func normalize(_ input: String) -> String {
        input.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Basic validation: 6 chars, all from the allowed charset.
    static func isValid(_ code: String) -> Bool {
        let normalized = normalize(code)
        return normalized.count == 6 && normalized.allSatisfy { charset.contains($0) }
    }

    // MARK: - QR Code Generation

    /// Generates a UIImage QR code encoding the given session code.
    /// Returns nil only if CoreImage fails (very unlikely in practice).
    static func qrCode(for sessionCode: String, size: CGFloat = 200) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        guard let data = sessionCode.data(using: .utf8) else { return nil }
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        // Scale up to the requested size cleanly (nearest neighbor)
        let scale = size / outputImage.extent.size.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - URL Scheme (future deep-link support)
    //
    // Format: snapaudit://join?code=XXXXXX
    // Reserved for future use in Phase 2.

    static func joinURL(for code: String) -> URL? {
        var components = URLComponents()
        components.scheme = "snapaudit"
        components.host = "join"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url
    }
}
