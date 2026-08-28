import Foundation

struct SyncEngine: Sendable {
    private let tolerance: TimeInterval = 1.5

    func run(job: SyncJob, leftPassword: String?, rightPassword: String?) async throws -> SyncResult {
        if let message = job.validationMessage { throw AppError.invalidConfiguration(message) }
        let left = try EndpointSessionFactory.make(endpoint: job.left, password: leftPassword)
        let right = try EndpointSessionFactory.make(endpoint: job.right, password: rightPassword)
        do {
            async let leftListing = left.listFiles()
            async let rightListing = right.listFiles()
            let (leftFiles, rightFiles) = try await (leftListing, rightListing)
            try validateLocalDestinationPaths(job: job, leftFiles: leftFiles, rightFiles: rightFiles)
            let transferred: Int
            let conflicts: [String]
            switch job.direction {
            case .leftToRight:
                transferred = try await transferNewer(from: left, files: leftFiles, to: right, files: rightFiles, job: job)
                conflicts = []
            case .rightToLeft:
                transferred = try await transferNewer(from: right, files: rightFiles, to: left, files: leftFiles, job: job)
                conflicts = []
            case .bidirectional:
                let result = try await transferBothWays(
                    left: left,
                    leftFiles: leftFiles,
                    right: right,
                    rightFiles: rightFiles,
                    job: job
                )
                transferred = result.transferred
                conflicts = result.conflicts
            }
            let deleted = try await cleanupTargetIfNeeded(
                job: job,
                left: left,
                leftFiles: leftFiles,
                right: right,
                rightFiles: rightFiles
            )
            await left.close()
            await right.close()
            return SyncResult(transferred: transferred, deleted: deleted, conflicts: conflicts)
        } catch {
            await left.close()
            await right.close()
            throw error
        }
    }

    private func validateLocalDestinationPaths(
        job: SyncJob,
        leftFiles: [String: SyncFile],
        rightFiles: [String: SyncFile]
    ) throws {
        let paths: Set<String>
        switch job.direction {
        case .leftToRight where job.right.kind == .local:
            paths = Set(leftFiles.keys).union(rightFiles.keys)
        case .rightToLeft where job.left.kind == .local:
            paths = Set(leftFiles.keys).union(rightFiles.keys)
        case .bidirectional where job.left.kind == .local || job.right.kind == .local:
            paths = Set(leftFiles.keys).union(rightFiles.keys)
        default:
            return
        }

        if let collision = PathSafety.localPathCollision(in: Array(paths)) {
            throw AppError.transferFailed(
                "Two paths cannot safely coexist on the local destination: \(collision[0]) and \(collision[1]). Rename one of them before syncing."
            )
        }
    }

    private func cleanupTargetIfNeeded(
        job: SyncJob,
        left: any EndpointSession,
        leftFiles: [String: SyncFile],
        right: any EndpointSession,
        rightFiles: [String: SyncFile]
    ) async throws -> Int {
        guard let cleanup = job.targetCleanup else { return 0 }
        let target: any EndpointSession
        let targetFiles: [String: SyncFile]
        switch job.direction {
        case .leftToRight:
            target = right
            targetFiles = rightFiles
        case .rightToLeft:
            target = left
            targetFiles = leftFiles
        case .bidirectional:
            throw AppError.invalidConfiguration("Automatic cleanup cannot run for a two-way job.")
        }

        let cutoff = Date().addingTimeInterval(-Double(cleanup.olderThanHours) * 3_600)
        let candidates = targetFiles.values
            .filter { job.filter.includesFileType(path: $0.relativePath) && $0.modifiedAt < cutoff }
            .sorted { $0.modifiedAt < $1.modifiedAt }
        var deleted = 0
        for file in candidates {
            try Task.checkCancellation()
            if try await target.deleteFile(file, ifOlderThan: cutoff) { deleted += 1 }
        }
        return deleted
    }

    private func transferNewer(
        from source: any EndpointSession,
        files sourceFiles: [String: SyncFile],
        to destination: any EndpointSession,
        files destinationFiles: [String: SyncFile],
        job: SyncJob
    ) async throws -> Int {
        let candidates = sourceFiles.values
            .filter { job.filter.includes(path: $0.relativePath, modifiedAt: $0.modifiedAt) }
            .filter { file in
                let willRewriteMetadata = job.metadataAutomation?
                    .assignment(for: file.relativePath, modifiedAt: file.modifiedAt) != nil
                return needsTransfer(
                    file,
                    destinationFiles[file.relativePath],
                    verifySize: job.verifyFileSizes && !willRewriteMetadata
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        var transferred = 0
        for file in candidates {
            try Task.checkCancellation()
            try await transfer(
                file,
                from: source,
                to: destination,
                preserveDate: job.preserveModificationDates,
                verifySize: job.verifyFileSizes,
                metadataAssignment: job.metadataAutomation?
                    .assignment(for: file.relativePath, modifiedAt: file.modifiedAt)
            )
            transferred += 1
        }
        return transferred
    }

    private func transferBothWays(
        left: any EndpointSession,
        leftFiles: [String: SyncFile],
        right: any EndpointSession,
        rightFiles: [String: SyncFile],
        job: SyncJob
    ) async throws -> (transferred: Int, conflicts: [String]) {
        let paths = Set(leftFiles.keys).union(rightFiles.keys)
        var actions: [(SyncFile, any EndpointSession, any EndpointSession)] = []
        var conflicts: [String] = []
        for path in paths {
            let leftFile = leftFiles[path]
            let rightFile = rightFiles[path]
            switch (leftFile, rightFile) {
            case let (file?, nil) where job.filter.includes(path: path, modifiedAt: file.modifiedAt):
                actions.append((file, left, right))
            case let (nil, file?) where job.filter.includes(path: path, modifiedAt: file.modifiedAt):
                actions.append((file, right, left))
            case let (leftFile?, rightFile?):
                guard job.filter.includes(path: path, modifiedAt: max(leftFile.modifiedAt, rightFile.modifiedAt)) else { continue }
                if leftFile.modifiedAt > rightFile.modifiedAt.addingTimeInterval(tolerance) {
                    actions.append((leftFile, left, right))
                } else if rightFile.modifiedAt > leftFile.modifiedAt.addingTimeInterval(tolerance) {
                    actions.append((rightFile, right, left))
                } else if job.verifyFileSizes, leftFile.size != rightFile.size {
                    // Equal timestamps with different sizes are ambiguous. Keep both by refusing to overwrite.
                    conflicts.append(path)
                    continue
                }
            default:
                continue
            }
        }
        actions.sort { $0.0.modifiedAt > $1.0.modifiedAt }
        for (file, source, destination) in actions {
            try Task.checkCancellation()
            try await transfer(
                file,
                from: source,
                to: destination,
                preserveDate: job.preserveModificationDates,
                verifySize: job.verifyFileSizes,
                metadataAssignment: nil
            )
        }
        return (actions.count, conflicts.sorted())
    }

    private func needsTransfer(_ source: SyncFile, _ destination: SyncFile?, verifySize: Bool) -> Bool {
        guard let destination else { return true }
        if source.modifiedAt > destination.modifiedAt.addingTimeInterval(tolerance) { return true }
        return verifySize && source.size != destination.size && source.modifiedAt >= destination.modifiedAt.addingTimeInterval(-tolerance)
    }

    private func transfer(
        _ file: SyncFile,
        from source: any EndpointSession,
        to destination: any EndpointSession,
        preserveDate: Bool,
        verifySize: Bool,
        metadataAssignment: MetadataAssignment?
    ) async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalFTPSync", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporaryURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await source.exportFile(file, to: temporaryURL)

        let importedFile: SyncFile
        if let metadataAssignment {
            try MetadataWriter.apply(metadataAssignment, to: temporaryURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let rewrittenSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            importedFile = SyncFile(
                relativePath: file.relativePath,
                size: rewrittenSize,
                modifiedAt: file.modifiedAt
            )
        } else {
            importedFile = file
        }

        try await destination.importFile(
            from: temporaryURL,
            as: importedFile,
            preserveDate: preserveDate,
            verifySize: verifySize
        )
    }
}
