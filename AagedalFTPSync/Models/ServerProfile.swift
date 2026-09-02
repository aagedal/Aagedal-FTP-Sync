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

struct ServerProfileMigrationResult: Equatable, Sendable {
    let jobs: [SyncJob]
    let profiles: [ServerProfile]
    let migratedEndpointCount: Int
}

extension ServerProfile {
    /// Converts legacy remote endpoints into references without moving or
    /// rewriting their existing Keychain credentials. Endpoints share a
    /// profile only when every connection setting, including the credential
    /// identifier and SFTP trust, already matches.
    static func migratingEmbeddedEndpoints(
        in jobs: [SyncJob],
        existingProfiles: [ServerProfile]
    ) -> ServerProfileMigrationResult {
        var migratedJobs = jobs
        var profiles = existingProfiles
        var migratedEndpointCount = 0
        var usedNames = Set(profiles.map { foldedName($0.name) })

        func migrate(_ endpoint: inout Endpoint) {
            guard endpoint.kind.isRemote, endpoint.serverProfileID == nil else { return }

            if let matchingProfile = profiles.first(where: { $0.matchesConnection(of: endpoint) }) {
                endpoint.serverProfileID = matchingProfile.id
                migratedEndpointCount += 1
                return
            }

            let baseName = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseName.isEmpty else { return }
            let name = uniqueName(basedOn: baseName, usedNames: &usedNames)
            let profile = ServerProfile(
                name: name,
                kind: endpoint.kind,
                host: endpoint.host,
                port: endpoint.port,
                username: endpoint.username,
                credentialID: endpoint.credentialID,
                hostKeyFingerprint: endpoint.hostKeyFingerprint
            )
            // Legacy jobs with incomplete connection or trust settings must
            // remain editable as embedded endpoints rather than preventing all
            // otherwise valid profiles from being persisted.
            guard profile.validationMessage == nil else { return }

            profiles.append(profile)
            endpoint.serverProfileID = profile.id
            migratedEndpointCount += 1
        }

        for index in migratedJobs.indices {
            migrate(&migratedJobs[index].left)
            migrate(&migratedJobs[index].right)
        }

        return ServerProfileMigrationResult(
            jobs: migratedJobs,
            profiles: profiles,
            migratedEndpointCount: migratedEndpointCount
        )
    }

    private func matchesConnection(of endpoint: Endpoint) -> Bool {
        kind == endpoint.kind
            && host == endpoint.host
            && port == endpoint.port
            && username == endpoint.username
            && credentialID == endpoint.credentialID
            && hostKeyFingerprint == endpoint.hostKeyFingerprint
    }

    private static func uniqueName(basedOn baseName: String, usedNames: inout Set<String>) -> String {
        var candidate = baseName
        var suffix = 2
        while !usedNames.insert(foldedName(candidate)).inserted {
            candidate = "\(baseName) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    private static func foldedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
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
