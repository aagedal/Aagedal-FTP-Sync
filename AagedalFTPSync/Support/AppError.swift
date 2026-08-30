import Foundation

enum AppError: LocalizedError {
    case invalidConfiguration(String)
    case folderPermissionLost(String)
    case transferFailed(String)
    case untrustedSSHHostKey(hostID: String, fingerprint: String)
    case changedSSHHostKey(hostID: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
             .folderPermissionLost(let message),
             .transferFailed(let message): message
        case .untrustedSSHHostKey(let hostID, let fingerprint):
            "The SSH host key for \(hostID) is not trusted. Verify this fingerprint with the server administrator before trusting it: \(fingerprint)"
        case .changedSSHHostKey(let hostID, let expected, let actual):
            "The SSH host key for \(hostID) does not match the saved fingerprint. Expected \(expected), received \(actual). Connection refused."
        }
    }
}
