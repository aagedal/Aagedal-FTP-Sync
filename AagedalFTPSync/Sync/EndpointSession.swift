import Foundation

struct EndpointFileImport: Sendable {
    let localURL: URL
    let file: SyncFile
}

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
        for index in holdings.indices {
            do {
                try await delete(holdings[index])
            } catch {
                var restoreFailures: [String] = []
                for restoreIndex in index..<holdings.count {
                    do {
                        try await move(holdings[restoreIndex], sources[restoreIndex])
                    } catch {
                        restoreFailures.append(labels[restoreIndex])
                    }
                }

                let alreadyRemoved = Array(labels.prefix(index))
                var details: [String] = []
                if alreadyRemoved.isEmpty {
                    details.append("No source files were deleted before the failure.")
                } else {
                    details.append(
                        "Verified processed copies remain available for source files already removed: \(alreadyRemoved.joined(separator: ", "))."
                    )
                }
                if restoreFailures.isEmpty {
                    details.append("Every undeleted staged source item was restored to its original name.")
                } else {
                    details.append(
                        "Staged source items could not be restored to their original names: \(restoreFailures.joined(separator: ", "))."
                    )
                }
                details.append("Deletion error: \(error.localizedDescription)")
                throw AppError.transferFailed(
                    "Final source removal could not be completed. " + details.joined(separator: " ")
                )
            }
        }
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
    func importFilesTransactionally(
        _ imports: [EndpointFileImport],
        replacing existingFiles: [String: SyncFile],
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
    func deleteFilesTransactionally(
        _ files: [SyncFile],
        ifOlderThan cutoff: Date,
        matching filter: FileFilter
    ) async throws -> Int
    func removeFile(_ file: SyncFile) async throws
    func removeFilesTransactionally(_ files: [SyncFile]) async throws
    func close() async
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

    func deleteFilesTransactionally(
        _ files: [SyncFile],
        ifOlderThan cutoff: Date,
        matching filter: FileFilter
    ) async throws -> Int {
        guard files.count == 1, let file = files.first else {
            throw AppError.invalidConfiguration(
                "Transactional companion cleanup is not supported by this target."
            )
        }
        return try await deleteFile(file, ifOlderThan: cutoff) ? 1 : 0
    }

    func importFilesTransactionally(
        _ imports: [EndpointFileImport],
        replacing existingFiles: [String: SyncFile],
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        guard imports.count > 1 else {
            if let item = imports.first {
                try await importFile(
                    from: item.localURL,
                    as: item.file,
                    preserveDate: preserveDate,
                    verifySize: verifySize
                )
            }
            return
        }

        guard Set(imports.map(\.file.relativePath)).count == imports.count else {
            throw AppError.transferFailed("A destination output group contained duplicate paths.")
        }

        let fileManager = FileManager.default
        var backups: [String: (url: URL, file: SyncFile)] = [:]
        var backupURLs: [URL] = []
        defer {
            for backupURL in backupURLs {
                try? fileManager.removeItem(at: backupURL)
            }
        }

        // Capture every previous output before publishing any member of the
        // group. Individual endpoint imports are atomic, so these snapshots
        // are sufficient to restore the complete pre-publication state.
        for item in imports {
            guard let existing = existingFiles[item.file.relativePath] else { continue }
            let backupURL = fileManager.temporaryDirectory.appendingPathComponent(
                ".aagedal-sync-\(UUID().uuidString).rollback"
            )
            backupURLs.append(backupURL)
            try await exportFile(existing, to: backupURL)
            backups[item.file.relativePath] = (backupURL, existing)
        }

        var published: [EndpointFileImport] = []
        do {
            for item in imports {
                try await importFile(
                    from: item.localURL,
                    as: item.file,
                    preserveDate: preserveDate,
                    verifySize: verifySize
                )
                published.append(item)
            }
        } catch {
            let publicationError = error
            // A cancelled parent task must not cancel the repair itself. Run
            // rollback in a fresh task, then preserve cancellation if repair
            // restored the complete pre-publication state.
            let rollbackFailures = await Task.detached { [published, backups] in
                var failures: [String] = []
                for item in published.reversed() {
                    do {
                        if let backup = backups[item.file.relativePath] {
                            try await importFile(
                                from: backup.url,
                                as: backup.file,
                                preserveDate: true,
                                verifySize: true
                            )
                        } else {
                            try await removeFile(item.file)
                        }
                    } catch {
                        failures.append(item.file.relativePath)
                    }
                }
                return failures
            }.value

            if !rollbackFailures.isEmpty {
                throw AppError.transferFailed(
                    "The primary file and its companion could not be published, and rollback failed for \(rollbackFailures.joined(separator: ", ")). The destination may contain an incomplete output group. Publication error: \(publicationError.localizedDescription)"
                )
            }
            if publicationError is CancellationError { throw CancellationError() }
            throw publicationError
        }
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
