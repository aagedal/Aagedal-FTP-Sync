import Foundation
import OSLog

enum SyncLogStage: String, Sendable {
    case run
    case protocolOperation = "protocol"
    case publication
}

enum SyncLogOperation: String, Sendable {
    case sync
    case listing
    case sourceRead = "source-read"
    case destinationOutput = "destination-output"
}

enum SyncLogOutcome: String, Sendable {
    case started
    case succeeded
    case failed
    case cancelled
}

enum SyncLogEndpointRole: String, Sendable {
    case left
    case right
    case processed
}

enum SyncLogFailureCategory: String, Sendable {
    case configuration
    case folderAccess = "folder-access"
    case transfer
    case hostKeyTrust = "host-key-trust"
    case network
    case unexpected

    static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .unexpected }
        if error is SyncRunFailure { return .transfer }
        if error is URLError { return .network }
        guard let appError = error as? AppError else { return .unexpected }
        switch appError {
        case .invalidConfiguration:
            return .configuration
        case .folderPermissionLost:
            return .folderAccess
        case .transferFailed:
            return .transfer
        case .untrustedSSHHostKey, .changedSSHHostKey:
            return .hostKeyTrust
        }
    }
}

/// A deliberately closed, privacy-safe schema for sync diagnostics. Free-form
/// strings are excluded so endpoint details, paths, filenames, credentials,
/// fingerprints, and server-provided error text cannot reach Unified Logging.
struct SyncLogEvent: Equatable, Sendable {
    let runID: UUID
    let jobID: UUID
    let stage: SyncLogStage
    let operation: SyncLogOperation
    let outcome: SyncLogOutcome
    var endpointRole: SyncLogEndpointRole? = nil
    var endpointKind: EndpointKind? = nil
    var itemCount: Int? = nil
    var transferred: Int? = nil
    var deleted: Int? = nil
    var processed: Int? = nil
    var conflictCount: Int? = nil
    var failureCategory: SyncLogFailureCategory? = nil

    var formattedMessage: String {
        var fields = [
            "event=sync-pipeline",
            "run_id=\(runID.uuidString.lowercased())",
            "job_id=\(jobID.uuidString.lowercased())",
            "stage=\(stage.rawValue)",
            "operation=\(operation.rawValue)",
            "outcome=\(outcome.rawValue)",
        ]
        if let endpointRole { fields.append("endpoint_role=\(endpointRole.rawValue)") }
        if let endpointKind { fields.append("endpoint_kind=\(endpointKind.rawValue)") }
        if let itemCount { fields.append("item_count=\(itemCount)") }
        if let transferred { fields.append("transferred=\(transferred)") }
        if let deleted { fields.append("deleted=\(deleted)") }
        if let processed { fields.append("processed=\(processed)") }
        if let conflictCount { fields.append("conflicts=\(conflictCount)") }
        if let failureCategory { fields.append("failure_category=\(failureCategory.rawValue)") }
        return fields.joined(separator: " ")
    }
}

protocol SyncEventLogging: Sendable {
    func record(_ event: SyncLogEvent)
}

struct SystemSyncEventLogger: SyncEventLogging {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "no.aagedal.AagedalFTPSync",
        category: "SyncPipeline"
    )

    func record(_ event: SyncLogEvent) {
        let message = event.formattedMessage
        switch event.outcome {
        case .failed:
            logger.error("\(message, privacy: .public)")
        case .cancelled:
            logger.notice("\(message, privacy: .public)")
        case .started, .succeeded:
            logger.info("\(message, privacy: .public)")
        }
    }
}
