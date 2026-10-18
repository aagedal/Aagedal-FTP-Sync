import Foundation

enum AppError: LocalizedError {
    case invalidConfiguration(String)
    case folderPermissionLost(String)
    case transferFailed(String)
    case recoveryRequired(String)
    case remoteOperationTimedOut(protocolName: String, operation: String, seconds: Int64)
    case untrustedSSHHostKey(hostID: String, fingerprint: String)
    case changedSSHHostKey(hostID: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
             .folderPermissionLost(let message),
             .transferFailed(let message): message
        case .recoveryRequired(let message):
            message + " Automatic sync retries are paused. Stop other jobs using this folder and keep a backup of the retained files and affected current files. Reconcile them before removing the resolved recovery folder, then retry the operation."
        case .remoteOperationTimedOut(let protocolName, let operation, let seconds):
            "The \(protocolName) \(operation) received no response for \(seconds) seconds. The connection was closed; try again or check the server."
        case .untrustedSSHHostKey(let hostID, let fingerprint):
            "The SSH host key for \(hostID) is not trusted. Verify this fingerprint with the server administrator before trusting it: \(fingerprint)"
        case .changedSSHHostKey(let hostID, let expected, let actual):
            "The SSH host key for \(hostID) does not match the saved fingerprint. Expected \(expected), received \(actual). Connection refused."
        }
    }

    /// Carry the recovery decision as data, never by interpreting a path or error text.
    static func requiresRecovery(_ error: any Error) -> Bool {
        if let appError = error as? AppError, case .recoveryRequired = appError { return true }
        return (error as? SyncRunFailure)?.requiresRecovery == true
    }
}
