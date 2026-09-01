import Foundation

enum TransactionalRemoval {
    static func stageAndDelete<Item>(
        sources: [Item],
        holdings: [Item],
        labels: [String],
        move: (Item, Item) async throws -> Void,
        delete: (Item) async throws -> Void
    ) async throws {
        precondition(sources.count == holdings.count && sources.count == labels.count)
        var stagedCount = 0
        do {
            for index in sources.indices {
                try await move(sources[index], holdings[index])
                stagedCount += 1
            }
        } catch {
            var rollbackFailures: [String] = []
            for index in (0..<stagedCount).reversed() {
                do { try await move(holdings[index], sources[index]) }
                catch { rollbackFailures.append(labels[index]) }
            }
            if !rollbackFailures.isEmpty {
                throw AppError.transferFailed(
                    "Source removal staging failed, and rollback could not restore: \(rollbackFailures.joined(separator: ", "))."
                )
            }
            throw error
        }
        for holding in holdings { try await delete(holding) }
    }
}

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
    func removeFilesTransactionally(_ files: [SyncFile]) async throws
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

    func removeFilesTransactionally(_ files: [SyncFile]) async throws {
        guard files.count == 1, let file = files.first else {
            throw AppError.invalidConfiguration(
                "Transactional multi-file source removal is not supported by this location."
            )
        }
        try await removeFile(file)
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
