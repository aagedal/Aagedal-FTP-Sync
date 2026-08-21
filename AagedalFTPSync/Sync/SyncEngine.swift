import Foundation

struct SyncEngine: Sendable {
    private let tolerance: TimeInterval = 1.5

    func run(job: SyncJob, leftPassword: String?, rightPassword: String?) async throws -> Int {
        if let message = job.validationMessage { throw AppError.invalidConfiguration(message) }
        let left = try EndpointSessionFactory.make(endpoint: job.left, password: leftPassword)
        let right = try EndpointSessionFactory.make(endpoint: job.right, password: rightPassword)
        do {
            async let leftListing = left.listFiles()
            async let rightListing = right.listFiles()
            let (leftFiles, rightFiles) = try await (leftListing, rightListing)
            let result: Int
            switch job.direction {
            case .leftToRight:
                result = try await transferNewer(from: left, files: leftFiles, to: right, files: rightFiles, job: job)
            case .rightToLeft:
                result = try await transferNewer(from: right, files: rightFiles, to: left, files: leftFiles, job: job)
            case .bidirectional:
                result = try await transferBothWays(left: left, leftFiles: leftFiles, right: right, rightFiles: rightFiles, job: job)
            }
            await left.close()
            await right.close()
            return result
        } catch {
            await left.close()
            await right.close()
            throw error
        }
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
            .filter { needsTransfer($0, destinationFiles[$0.relativePath], verifySize: job.verifyFileSizes) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        var transferred = 0
        for file in candidates {
            try Task.checkCancellation()
            try await transfer(file, from: source, to: destination, preserveDate: job.preserveModificationDates)
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
    ) async throws -> Int {
        let paths = Set(leftFiles.keys).union(rightFiles.keys)
        var actions: [(SyncFile, any EndpointSession, any EndpointSession)] = []
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
                    continue
                }
            default:
                continue
            }
        }
        actions.sort { $0.0.modifiedAt > $1.0.modifiedAt }
        for (file, source, destination) in actions {
            try Task.checkCancellation()
            try await transfer(file, from: source, to: destination, preserveDate: job.preserveModificationDates)
        }
        return actions.count
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
        preserveDate: Bool
    ) async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalFTPSync", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporaryURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await source.exportFile(file, to: temporaryURL)
        try await destination.importFile(from: temporaryURL, as: file, preserveDate: preserveDate)
    }
}
