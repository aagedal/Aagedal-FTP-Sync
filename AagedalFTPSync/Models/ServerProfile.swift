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
            serverProfileID: id,
            host: host,
            port: port,
            username: username,
            remotePath: remotePath,
            credentialID: credentialID,
            hostKeyFingerprint: hostKeyFingerprint
        )
    }
}

enum ServerProfileResolutionError: LocalizedError, Equatable {
    case missingProfile(UUID)

    var errorDescription: String? {
        switch self {
        case .missingProfile:
            "A remote location references a server profile that is no longer available. Choose another server profile before running the job."
        }
    }
}

extension Endpoint {
    /// Refreshes the runtime connection projection from the referenced profile
    /// while preserving the path that belongs to this job endpoint.
    func resolvingServerProfile(in profiles: [ServerProfile]) throws -> Endpoint {
        guard let serverProfileID else { return self }
        guard let profile = profiles.first(where: { $0.id == serverProfileID }) else {
            throw ServerProfileResolutionError.missingProfile(serverProfileID)
        }
        return profile.endpoint(remotePath: remotePath)
    }
}

extension SyncJob {
    func resolvingServerProfiles(in profiles: [ServerProfile]) throws -> SyncJob {
        var resolved = self
        resolved.left = try left.resolvingServerProfile(in: profiles)
        resolved.right = try right.resolvingServerProfile(in: profiles)
        return resolved
    }
}
