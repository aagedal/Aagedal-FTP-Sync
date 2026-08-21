import Foundation

enum AppError: LocalizedError {
    case invalidConfiguration(String)
    case folderPermissionLost(String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
             .folderPermissionLost(let message),
             .transferFailed(let message): message
        }
    }
}
