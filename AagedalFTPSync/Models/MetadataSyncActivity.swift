import Foundation

enum MetadataSyncPhase: String {
    case waiting, pending, fetching, sending, current, paused, conflict, offline, failed

    var title: String {
        switch self {
        case .waiting: "Waiting to sync"
        case .pending: "Changes waiting to sync"
        case .fetching: "Fetching calendar…"
        case .sending: "Sending changes…"
        case .current: "Up to date"
        case .paused: "Sync paused"
        case .conflict: "Conflict needs review"
        case .offline: "Waiting for connection"
        case .failed: "Sync needs attention"
        }
    }
    var symbol: String {
        switch self {
        case .waiting, .pending: "clock"
        case .fetching: "arrow.down.circle"
        case .sending: "arrow.up.circle"
        case .current: "checkmark.circle"
        case .paused: "pause.circle"
        case .offline: "wifi.slash"
        case .conflict, .failed: "exclamationmark.triangle"
        }
    }
    var isActive: Bool { self == .fetching || self == .sending }
}

struct MetadataSyncActivity {
    var phase: MetadataSyncPhase = .waiting
    var detail = "Saved changes sync shortly after editing. Updates from other Macs are checked about every 10 seconds."
    var lastSuccess: Date?
}

/// Diagnostic entries contain fixed descriptions and protocol codes, never request
/// bodies, server addresses, keys, invitations, job names or calendar contents.
struct MetadataSyncEvent: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var jobID: UUID?
    var operation: String
    var detail: String
    var isError = false
    var revision: Int64?
    var occurrences = 1

    static func errorDetail(_ error: Error) -> String {
        if let failure = error as? MetadataSyncFailure {
            return failure.diagnosticCode ?? "Calendar validation or local storage failed. Review the current sync status for details."
        }
        if let urlError = error as? URLError {
            let reason: String
            switch urlError.code {
            case .notConnectedToInternet: reason = "macOS reports no internet connection"
            case .cannotConnectToHost: reason = "could not connect to the server"
            case .timedOut: reason = "the request timed out"
            case .cannotFindHost, .dnsLookupFailed: reason = "the server name could not be resolved"
            case .networkConnectionLost: reason = "the connection was interrupted"
            default: reason = "network request failed"
            }
            return "Network request failed: \(reason) (URL error \(urlError.code.rawValue))."
        }
        if error is DecodingError { return "The server response could not be decoded. Check app/server compatibility." }
        if let serverError = error as? MetadataSyncServerError { return serverError.localizedDescription }
        return "Sync failed. Review the current sync status for details."
    }
}

struct MetadataSyncEventRepository {
    var url: URL
    func load() -> [MetadataSyncEvent] {
        guard let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([MetadataSyncEvent].self, from: data) else { return [] }
        return Array(events.suffix(200))
    }
    func save(_ events: [MetadataSyncEvent]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(events.suffix(200))).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct MetadataSyncInvitation {
    let address: String?
    let token: String

    /// Accept either the token alone or the complete text produced by Copy Invitation.
    init(_ text: String) throws {
        var address: String?
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("server:") {
            guard let separator = token.range(of: "invitation:", options: .caseInsensitive) else {
                throw MetadataSyncFailure(message: "The copied invitation is incomplete. Copy it again from the owner’s Mac.")
            }
            address = String(token[token.index(token.startIndex, offsetBy: 7)..<separator.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            token = String(token[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if token.lowercased().hasPrefix("invitation:") {
            token = String(token.dropFirst(11)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MetadataSyncFailure(message: "Paste the invitation copied by the calendar owner, or its 64-character invitation code.")
        }
        self.address = try address.map { try MetadataSyncServer(address: $0).baseURL.absoluteString }
        self.token = token
    }
}
