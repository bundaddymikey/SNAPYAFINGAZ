import Foundation
import CryptoKit

struct PINService {
    static func generateSalt() -> String {
        let saltData = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        return saltData.base64EncodedString()
    }

    static func hash(pin: String, salt: String) -> String {
        let combined = pin + salt
        let data = Data(combined.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verify(pin: String, hash: String, salt: String) -> Bool {
        let computed = self.hash(pin: pin, salt: salt)
        return computed == hash
    }
}
