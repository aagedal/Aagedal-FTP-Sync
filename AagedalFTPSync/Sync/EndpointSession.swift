import Foundation

struct EndpointFileImport: Sendable {
    let localURL: URL
    let file: SyncFile
}

struct RemoteTreeEntry: Sendable {
    let relativePath: String
    let file: SyncFile?
    let hasAuthoritativeTimestamp: Bool

    var isDirectory: Bool { file == nil }
}

struct CompletedDirectoryListing: Sendable {
    let relativeDirectory: String
    let entries: [RemoteTreeEntry]
    let validatedAncestors: [String]
}

struct RemoteDirectoryEntry: Sendable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date
    let hasAuthoritativeTimestamp: Bool
}

enum RemoteTreeWalker {
    static func listFiles(
        root: String,
        join: @Sendable (String, String) -> String,
        listDirectory: @Sendable (String) async throws -> [RemoteDirectoryEntry],
        onCompletedDirectory: (@Sendable (CompletedDirectoryListing) async throws -> Void)?
    ) async throws -> [String: SyncFile] {
        var files: [String: SyncFile] = [:]
        var directories = [(remote: root, relative: "")]
        var directoryIndex = 0

        while directoryIndex < directories.count {
            try Task.checkCancellation()
            let directory = directories[directoryIndex]
            directoryIndex += 1
            let entries = try await listDirectory(directory.remote)
                .filter { !PathSafety.isInternalStagingPath($0.name) }

            if let collision = PathSafety.localPathCollision(in: entries.map(\.name)) {
                let directoryLabel = directory.relative.isEmpty ? "/" : directory.relative
                throw AppError.transferFailed(
                    "Two server entries cannot safely coexist at \(directoryLabel): \(collision[0]) and \(collision[1]). Rename one before syncing."
                )
            }

            var completedEntries: [RemoteTreeEntry] = []
            var childDirectories: [(remote: String, relative: String)] = []
            for entry in entries {
                guard PathSafety.isSafeServerName(entry.name) else { continue }
                let relative = directory.relative.isEmpty
                    ? entry.name
                    : "\(directory.relative)/\(entry.name)"
                if entry.isDirectory {
                    childDirectories.append((join(directory.remote, entry.name), relative))
                    completedEntries.append(RemoteTreeEntry(
                        relativePath: relative,
                        file: nil,
                        hasAuthoritativeTimestamp: true
                    ))
                } else {
                    let file = SyncFile(
                        relativePath: relative,
                        size: entry.size,
                        modifiedAt: entry.modifiedAt
                    )
                    if let existing = files[relative],
                       !PathSafety.hasIdenticalRepresentation(existing.relativePath, relative) {
                        throw AppError.transferFailed(
                            "Two server paths differ only by Unicode representation: \(existing.relativePath) and \(relative)."
                        )
                    }
                    files[relative] = file
                    completedEntries.append(RemoteTreeEntry(
                        relativePath: relative,
                        file: file,
                        hasAuthoritativeTimestamp: entry.hasAuthoritativeTimestamp
                    ))
                }
            }
            childDirectories.sort { $0.relative < $1.relative }
            directories.append(contentsOf: childDirectories)

            let components = directory.relative.split(separator: "/").map(String.init)
            let ancestors = components.indices.map {
                components[...$0].joined(separator: "/")
            }
            if let onCompletedDirectory {
                try await onCompletedDirectory(CompletedDirectoryListing(
                    relativeDirectory: directory.relative,
                    entries: completedEntries,
                    validatedAncestors: ancestors
                ))
            }
        }
        return files
    }
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
    var supportsCompletedDirectoryListings: Bool { get }
    func testConnection() async throws
    func listFiles() async throws -> [String: SyncFile]
    func listFilesIncrementally(
        onCompletedDirectory: @escaping @Sendable (CompletedDirectoryListing) async throws -> Void
    ) async throws -> [String: SyncFile]
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
    func importFilesTransactionallyIfAbsent(
        _ imports: [EndpointFileImport],
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
    var supportsCompletedDirectoryListings: Bool { false }

    func listFilesIncrementally(
        onCompletedDirectory: @escaping @Sendable (CompletedDirectoryListing) async throws -> Void
    ) async throws -> [String: SyncFile] {
        let files = try await listFiles()
        try await onCompletedDirectory(CompletedDirectoryListing(
            relativeDirectory: "",
            entries: files.values.map {
                RemoteTreeEntry(
                    relativePath: $0.relativePath,
                    file: $0,
                    hasAuthoritativeTimestamp: true
                )
            },
            validatedAncestors: []
        ))
        return files
    }

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

    func importFilesTransactionallyIfAbsent(
        _ imports: [EndpointFileImport],
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        guard imports.count == 1, let item = imports.first else {
            throw AppError.invalidConfiguration(
                "Collision-safe atomic output-group publication is not supported by this location."
            )
        }
        try await importFileIfAbsent(
            from: item.localURL,
            as: item.file,
            preserveDate: preserveDate,
            verifySize: verifySize
        )
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
