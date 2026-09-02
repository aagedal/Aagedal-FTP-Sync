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
    /// Identifies the shared connection settings used by this remote endpoint.
    /// The endpoint continues to own `remotePath`; the remaining remote fields
    /// are a runtime projection kept for compatibility with the sync engine.
    var serverProfileID: UUID?
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
        serverProfileID: UUID? = nil,
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
        self.serverProfileID = serverProfileID
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.remotePath = remotePath
        self.credentialID = credentialID
        self.hostKeyFingerprint = hostKeyFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case kind, localPath, bookmark, serverProfileID, host, port, username, remotePath, credentialID, hostKeyFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(EndpointKind.self, forKey: .kind)
        localPath = try container.decode(String.self, forKey: .localPath)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        serverProfileID = try container.decodeIfPresent(UUID.self, forKey: .serverProfileID)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        credentialID = try container.decode(String.self, forKey: .credentialID)
        hostKeyFingerprint = try container.decodeIfPresent(String.self, forKey: .hostKeyFingerprint) ?? ""
    }

    static var local: Endpoint { Endpoint(kind: .local) }
    static var remote: Endpoint { Endpoint(kind: .ftps) }

    var summary: String {
        if kind == .local { return localPath.isEmpty ? "Choose a folder" : localPath }
        let path = remotePath.isEmpty ? "/" : remotePath
        return "\(kind.rawValue)://\(host):\(port)\(path)"
    }

    var connectionValidationMessage: String? {
        if kind == .local {
            return localPath.isEmpty || bookmark == nil ? "Choose a folder." : nil
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a server address." }
        if !(1...65_535).contains(port) { return "Port must be between 1 and 65535." }
        if username.isEmpty { return "Enter a username." }
        if !remotePath.hasPrefix("/") { return "Remote path must begin with /." }
        return nil
    }

    var validationMessage: String? {
        if let connectionValidationMessage { return connectionValidationMessage }
        if kind == .sftp, SSHHostKeyFingerprint.normalized(hostKeyFingerprint) == nil {
            return "Verify and trust the server's SSH host-key fingerprint."
        }
        return nil
    }
}
