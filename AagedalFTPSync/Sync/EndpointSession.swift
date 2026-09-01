import Foundation

protocol EndpointSession: Sendable {
    func testConnection() async throws
    func listFiles() async throws -> [String: SyncFile]
    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws
    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws
    func importFileIfAbsent(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws
    func deleteFile(_ file: SyncFile, ifOlderThan cutoff: Date) async throws -> Bool
    func removeFile(_ file: SyncFile) async throws
    func close() async
}

/// Optional capabilities used to publish a small remote batch before the
/// authoritative recursive listing has completed.
protocol FastStartSourceSession: EndpointSession {
    func listFilesForFastStart(filter: FileFilter, minimumCount: Int) async throws -> [String: SyncFile]
    func refreshMetadataForFastStart(_ files: [SyncFile]) async throws -> [SyncFile]
}

protocol EndpointFileLookupSession: EndpointSession {
    func fileInfo(relativePath: String) async throws -> SyncFile?
}

extension EndpointSession {
    func testConnection() async throws {
        _ = try await listFiles()
    }

    func deleteFile(_ file: SyncFile, ifOlderThan cutoff: Date) async throws -> Bool {
        throw AppError.invalidConfiguration("Cleanup was attempted on an unsupported target.")
    }

    func importFileIfAbsent(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        throw AppError.invalidConfiguration("Collision-safe processed-file import is not supported by this location.")
    }

    func removeFile(_ file: SyncFile) async throws {
        throw AppError.invalidConfiguration("Moving a processed source file is not supported by this location.")
    }

    func close() async {}
}

enum EndpointConnectionTester {
    static func test(
        endpoint: Endpoint,
        password: String,
        sessionFactory: @Sendable (Endpoint, String) throws -> any EndpointSession = { endpoint, password in
            try EndpointSessionFactory.make(endpoint: endpoint, password: password)
        }
    ) async throws {
        guard endpoint.kind.isRemote else {
            throw AppError.invalidConfiguration("Connection testing is only available for remote locations.")
        }
        if let message = endpoint.connectionValidationMessage {
            throw AppError.invalidConfiguration(message)
        }

        let session = try sessionFactory(endpoint, password)
        do {
            try await session.testConnection()
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }
}

enum EndpointSessionFactory {
    static func make(
        endpoint: Endpoint,
        password: String?,
        managedFolder: ManagedOutputFolder? = nil
    ) throws -> any EndpointSession {
        switch endpoint.kind {
        case .local:
            return try LocalEndpointSession(endpoint: endpoint, managedFolder: managedFolder)
        case .ftp, .ftps:
            guard managedFolder == nil else {
                throw AppError.invalidConfiguration("Managed output folders require a local destination.")
            }
            guard let password else {
                throw AppError.invalidConfiguration("No password is saved for \(endpoint.host).")
            }
            return FTPEndpointSession(endpoint: endpoint, password: password)
        case .sftp:
            guard managedFolder == nil else {
                throw AppError.invalidConfiguration("Managed output folders require a local destination.")
            }
            guard let password else {
                throw AppError.invalidConfiguration("No password is saved for \(endpoint.host).")
            }
            return SFTPEndpointSession(endpoint: endpoint, password: password)
        }
    }
}
