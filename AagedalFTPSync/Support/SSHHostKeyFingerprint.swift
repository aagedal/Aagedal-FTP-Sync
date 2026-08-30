import CryptoKit
import Foundation

enum SSHHostKeyFingerprint {
    static func make(fromOpenSSHKey openSSHKey: String) -> String? {
        let components = openSSHKey.split(whereSeparator: { $0.isWhitespace })
        guard components.count >= 2,
              let keyBlob = Data(base64Encoded: String(components[1])) else { return nil }
        let digest = SHA256.hash(data: keyBlob)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 7,
              trimmed.prefix(7).lowercased() == "sha256:" else { return nil }
        let encoded = String(trimmed.dropFirst(7)).replacingOccurrences(of: "=", with: "")
        let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let decoded = Data(base64Encoded: encoded + padding), decoded.count == 32 else { return nil }
        return "SHA256:\(encoded)"
    }
}
