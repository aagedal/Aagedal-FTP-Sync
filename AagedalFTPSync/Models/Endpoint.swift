import Foundation

enum EndpointKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case ftp
    case ftps
    case sftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local folder"
        case .ftp: "FTP (unencrypted)"
        case .ftps: "FTPS (TLS)"
        case .sftp: "SFTP (SSH)"
        }
    }

    var defaultPort: Int {
        switch self {
        case .local: 0
        case .ftp: 21
        case .ftps: 990
        case .sftp: 22
        }
    }

    var isRemote: Bool { self != .local }
}

struct Endpoint: Codable, Hashable, Sendable {
    var kind: EndpointKind
    var localPath: String
    var bookmark: Data?
    var host: String
    var port: Int
    var username: String
    var remotePath: String
    var credentialID: String
    var hostKeyFingerprint: String

    init(
        kind: EndpointKind,
        localPath: String = "",
        bookmark: Data? = nil,
        host: String = "",
        port: Int? = nil,
        username: String = "",
        remotePath: String = "/",
        credentialID: String = UUID().uuidString,
        hostKeyFingerprint: String = ""
    ) {
        self.kind = kind
        self.localPath = localPath
        self.bookmark = bookmark
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.remotePath = remotePath
        self.credentialID = credentialID
        self.hostKeyFingerprint = hostKeyFingerprint
    }

    static var local: Endpoint { Endpoint(kind: .local) }
    static var remote: Endpoint { Endpoint(kind: .ftps) }

    var summary: String {
        if kind == .local { return localPath.isEmpty ? "Choose a folder" : localPath }
        let path = remotePath.isEmpty ? "/" : remotePath
        return "\(kind.rawValue)://\(host):\(port)\(path)"
    }

    var validationMessage: String? {
        if kind == .local {
            return localPath.isEmpty || bookmark == nil ? "Choose a folder." : nil
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a server address." }
        if !(1...65_535).contains(port) { return "Port must be between 1 and 65535." }
        if username.isEmpty { return "Enter a username." }
        if !remotePath.hasPrefix("/") { return "Remote path must begin with /." }
        return nil
    }
}
