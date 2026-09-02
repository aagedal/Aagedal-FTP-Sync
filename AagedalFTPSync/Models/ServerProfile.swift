import Foundation

/// Reusable connection settings for an FTP, FTPS, or SFTP server.
///
/// Remote paths deliberately remain on `Endpoint`; a profile represents only
/// the connection identity and its Keychain-backed credential.
struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kind: EndpointKind
    var host: String
    var port: Int
    var username: String
    var credentialID: String
    var hostKeyFingerprint: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: EndpointKind = .ftps,
        host: String = "",
        port: Int? = nil,
        username: String = "",
        credentialID: String = UUID().uuidString,
        hostKeyFingerprint: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.credentialID = credentialID
        self.hostKeyFingerprint = hostKeyFingerprint
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give this server a name."
        }
        guard kind.isRemote else {
            return "Server profiles support FTP, FTPS, and SFTP connections."
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a server address."
        }
        if !(1...65_535).contains(port) {
            return "Port must be between 1 and 65535."
        }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a username."
        }
        if credentialID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The server is missing its credential reference."
        }
        if kind == .sftp, SSHHostKeyFingerprint.normalized(hostKeyFingerprint) == nil {
            return "Verify and trust the server's SSH host-key fingerprint."
        }
        return nil
    }

    func endpoint(remotePath: String = "/") -> Endpoint {
        Endpoint(
            kind: kind,
            host: host,
            port: port,
            username: username,
            remotePath: remotePath,
            credentialID: credentialID,
            hostKeyFingerprint: hostKeyFingerprint
        )
    }
}

