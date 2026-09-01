import Foundation

struct LocalEndpointSession: EndpointSession, EndpointFileLookupSession, @unchecked Sendable {
    private let access: BookmarkAccess
    private let rootURL: URL
    private let fileManager = FileManager.default
    private let holdingURLFactory: @Sendable (URL) -> URL

    init(
        endpoint: Endpoint,
        managedFolder: ManagedOutputFolder? = nil,
        holdingURLFactory: @escaping @Sendable (URL) -> URL = { source in
            source.deletingLastPathComponent().appendingPathComponent(
                ".aagedal-sync-\(UUID().uuidString).hold"
            )
        }
    ) throws {
        access = try BookmarkAccess(endpoint: endpoint)
        self.holdingURLFactory = holdingURLFactory
        if let managedFolder {
            rootURL = try managedFolder.url(inside: access.url, createIfNeeded: true)
        } else {
            rootURL = access.url.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    func listFiles() async throws -> [String: SyncFile] {
        let root = rootURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            throw AppError.folderPermissionLost("Could not read \(root.path).")
        }

        var files: [String: SyncFile] = [:]
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalURL.path.hasPrefix(root.path + "/") else { continue }
            let relative = String(canonicalURL.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty, !PathSafety.isInternalStagingPath(relative) else { continue }
            if let existing = files[relative],
               !PathSafety.hasIdenticalRepresentation(existing.relativePath, relative) {
                throw AppError.transferFailed(
                    "Two file paths differ only by Unicode representation: \(existing.relativePath) and \(relative)."
                )
            }
            files[relative] = SyncFile(
                relativePath: relative,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        return files
    }

    func fileInfo(relativePath: String) async throws -> SyncFile? {
        guard PathSafety.isSafeRelativePath(relativePath) else {
            throw AppError.transferFailed("A file contained an unsafe relative path and was skipped.")
        }
        var currentURL = rootURL
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let names = try fileManager.contentsOfDirectory(atPath: currentURL.path)
            if names.contains(where: { PathSafety.hasIdenticalRepresentation($0, component) }) {
                currentURL.appendPathComponent(component)
                let componentValues = try currentURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                if componentValues.isSymbolicLink == true {
                    throw AppError.transferFailed(
                        "A file path contained a symbolic link and was rejected: \(relativePath)"
                    )
                }
                if index < components.count - 1, componentValues.isDirectory != true { return nil }
                continue
            }
            if let collision = names.first(where: {
                PathSafety.localPathCollision(in: [$0, component]) != nil
            }) {
                throw AppError.transferFailed(
                    "Two file paths cannot safely coexist on the local destination: \(collision) and \(component). Rename one before syncing."
                )
            }
            return nil
        }

        let values = try currentURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return SyncFile(
            relativePath: relativePath,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        let source = try safeURL(for: file.relativePath)
        try fileManager.copyItem(at: source, to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        try importFile(
            from: localURL,
            as: file,
            preserveDate: preserveDate,
            verifySize: verifySize,
            replaceExisting: true
        )
    }

    func importFileIfAbsent(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        try importFile(
            from: localURL,
            as: file,
            preserveDate: preserveDate,
            verifySize: verifySize,
            replaceExisting: false
        )
    }

    private func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool,
        replaceExisting: Bool
    ) throws {
        let destination = try safeURL(for: file.relativePath)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !replaceExisting, fileManager.fileExists(atPath: destination.path) {
            throw AppError.transferFailed("A file already exists at \(file.relativePath).")
        }
        let staging = directory.appendingPathComponent(".aagedal-sync-\(UUID().uuidString).part")
        do {
            try fileManager.copyItem(at: localURL, to: staging)
            let localArrivalTime = Date()
            if verifySize {
                let attributes = try fileManager.attributesOfItem(atPath: staging.path)
                let copiedSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard copiedSize == file.size else {
                    throw AppError.transferFailed(
                        "Size verification failed for \(file.relativePath): expected \(file.size) bytes, copied \(copiedSize) bytes."
                    )
                }
            }
            try fileManager.setAttributes(
                [.modificationDate: preserveDate ? file.modifiedAt : localArrivalTime],
                ofItemAtPath: staging.path
            )
            if replaceExisting, fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            if !replaceExisting, fileManager.fileExists(atPath: destination.path) {
                throw AppError.transferFailed("A file already exists at \(file.relativePath).")
            }
            throw error
        }
    }

    func deleteFile(_ file: SyncFile, ifOlderThan cutoff: Date) async throws -> Bool {
        let target = try safeURL(for: file.relativePath)
        guard fileManager.fileExists(atPath: target.path) else { return false }
        let root = rootURL
        let resolvedTarget = target.resolvingSymlinksInPath()
        guard resolvedTarget.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("A target path attempted to leave its selected folder.")
        }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let modifiedAt = values.contentModificationDate,
              modifiedAt < cutoff else { return false }
        try fileManager.removeItem(at: target)
        return true
    }

    func removeFile(_ file: SyncFile) async throws {
        let source = try safeURL(for: file.relativePath)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AppError.transferFailed("Only regular source files can be moved to the processed folder.")
        }
        try fileManager.removeItem(at: source)
    }

    func removeFilesTransactionally(_ files: [SyncFile]) async throws {
        let sources = try files.map { file -> URL in
            let source = try safeURL(for: file.relativePath)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AppError.transferFailed("Only regular source files can be moved to the processed folder.")
            }
            return source
        }
        let staged = sources.map(holdingURLFactory)
        try await TransactionalRemoval.stageAndDelete(
            sources: sources,
            holdings: staged,
            labels: files.map(\.relativePath),
            move: { source, destination in
                try fileManager.moveItem(at: source, to: destination)
            },
            delete: { holding in try fileManager.removeItem(at: holding) }
        )
    }

    private func safeURL(for relativePath: String) throws -> URL {
        guard PathSafety.isSafeRelativePath(relativePath) else {
            throw AppError.transferFailed("A file contained an unsafe relative path and was skipped.")
        }
        let root = rootURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("A file path attempted to leave its selected folder.")
        }

        var existingComponent = root
        for component in relativePath.split(separator: "/") {
            existingComponent.appendPathComponent(String(component))
            if (try? fileManager.destinationOfSymbolicLink(atPath: existingComponent.path)) != nil {
                throw AppError.transferFailed(
                    "A file path contained a symbolic link and was rejected: \(relativePath)"
                )
            }
            if !fileManager.fileExists(atPath: existingComponent.path) { break }
        }

        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard resolvedParent == root || resolvedParent.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("A file path attempted to leave its selected folder through a symbolic link.")
        }
        return candidate
    }
}

struct JobResetResult: Equatable, Sendable {
    let deletedFiles: Int
    let downloadFolderPath: String
}

actor JobResetService {
    static func validationMessage(for job: SyncJob) -> String? {
        guard job.direction != .bidirectional else {
            return "Reset Job is unavailable for two-way jobs because there is no single download folder."
        }
        guard let destination = job.destinationEndpoint, destination.kind == .local else {
            return "Reset Job requires a local download destination."
        }

        let destinationURL = URL(fileURLWithPath: destination.localPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let downloadURL = job.usesManagedFolderStructure
            ? destinationURL.appendingPathComponent(ManagedOutputFolder.syncedFiles.directoryName, isDirectory: true)
            : destinationURL
        guard isAcceptableResetRoot(downloadURL) else {
            return "Reset Job refuses to clear a filesystem root or the current user's home folder. Choose a dedicated download folder instead."
        }

        if let source = job.sourceEndpoint, source.kind == .local {
            let sourceURL = URL(fileURLWithPath: source.localPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if foldersOverlap(sourceURL, downloadURL) {
                return "Reset Job is unavailable because the local source and download folders overlap."
            }
        }
        return nil
    }

    func resetDownloads(for job: SyncJob) throws -> JobResetResult {
        if let message = Self.validationMessage(for: job) {
            throw AppError.invalidConfiguration(message)
        }
        guard let destination = job.destinationEndpoint else {
            throw AppError.invalidConfiguration("Reset Job requires a one-way job.")
        }

        let access = try BookmarkAccess(endpoint: destination)
        let rootURL: URL
        if job.usesManagedFolderStructure {
            rootURL = try ManagedOutputFolder.syncedFiles.url(inside: access.url, createIfNeeded: true)
        } else {
            rootURL = access.url.standardizedFileURL.resolvingSymlinksInPath()
        }
        guard Self.isAcceptableResetRoot(rootURL) else {
            throw AppError.invalidConfiguration(
                "Reset Job refuses to clear a filesystem root or the current user's home folder."
            )
        }

        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        guard !children.isEmpty else {
            return JobResetResult(deletedFiles: 0, downloadFolderPath: rootURL.path)
        }

        let deletedFiles = children.reduce(into: 0) { count, child in
            count += Self.fileCount(at: child, fileManager: fileManager)
        }
        let holdingURL = rootURL.appendingPathComponent(
            ".aagedal-sync-reset-\(UUID().uuidString).trash",
            isDirectory: true
        )
        try fileManager.createDirectory(at: holdingURL, withIntermediateDirectories: false)
        var movedItems: [(original: URL, held: URL)] = []
        do {
            for child in children {
                let held = holdingURL.appendingPathComponent(child.lastPathComponent)
                try fileManager.moveItem(at: child, to: held)
                movedItems.append((child, held))
            }
        } catch {
            var rollbackFailures: [String] = []
            for item in movedItems.reversed() {
                do {
                    try fileManager.moveItem(at: item.held, to: item.original)
                } catch {
                    rollbackFailures.append(item.original.lastPathComponent)
                }
            }
            try? fileManager.removeItem(at: holdingURL)
            if !rollbackFailures.isEmpty {
                throw AppError.transferFailed(
                    "The download-folder reset failed, and rollback could not restore: \(rollbackFailures.joined(separator: ", "))."
                )
            }
            throw error
        }

        do {
            try fileManager.removeItem(at: holdingURL)
        } catch {
            throw AppError.transferFailed(
                "The downloads were isolated but could not be fully deleted. A hidden reset folder remains inside \(rootURL.path). \(error.localizedDescription)"
            )
        }
        return JobResetResult(deletedFiles: deletedFiles, downloadFolderPath: rootURL.path)
    }

    private static func isAcceptableResetRoot(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return resolved.path != "/" && resolved != home
    }

    private static func foldersOverlap(_ first: URL, _ second: URL) -> Bool {
        first == second
            || first.path.hasPrefix(second.path + "/")
            || second.path.hasPrefix(first.path + "/")
    }

    private static func fileCount(at url: URL, fileManager: FileManager) -> Int {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile == true || values.isSymbolicLink == true {
            return 1
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        while let child = enumerator.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                continue
            }
            if values.isRegularFile == true || values.isSymbolicLink == true { count += 1 }
        }
        return count
    }
}
