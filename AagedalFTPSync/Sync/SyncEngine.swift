import Foundation

struct MetadataReprocessResult: Equatable, Sendable {
    let scanned: Int
    let applied: Int
    let skipped: Int
    let failed: Int
    let metadataReport: MetadataRunReport

    init(
        scanned: Int,
        applied: Int,
        skipped: Int,
        failed: Int = 0,
        metadataReport: MetadataRunReport = .empty
    ) {
        self.scanned = scanned
        self.applied = applied
        self.skipped = skipped
        self.failed = failed
        self.metadataReport = metadataReport
    }
}

private struct TransferMetadataOutcome: Sendable {
    let auditEntry: MetadataAuditEntry?
    let embeddedMetadataApplied: Bool
    let movedToProcessed: Bool
}

struct SyncEngine: Sendable {
    private let tolerance: TimeInterval = 1.5
    private let sourceSignatureRepository: SourceSignatureRepository

    init(sourceSignatureRepository: SourceSignatureRepository = SourceSignatureRepository()) {
        self.sourceSignatureRepository = sourceSignatureRepository
    }

    func run(job: SyncJob, leftPassword: String?, rightPassword: String?) async throws -> SyncResult {
        if let message = job.validationMessage { throw AppError.invalidConfiguration(message) }
        let leftManagedFolder: ManagedOutputFolder? = job.usesManagedFolderStructure && job.direction == .rightToLeft
            ? .syncedFiles
            : nil
        let rightManagedFolder: ManagedOutputFolder? = job.usesManagedFolderStructure && job.direction == .leftToRight
            ? .syncedFiles
            : nil
        let left = try EndpointSessionFactory.make(
            endpoint: job.left,
            password: leftPassword,
            managedFolder: leftManagedFolder
        )
        let right = try EndpointSessionFactory.make(
            endpoint: job.right,
            password: rightPassword,
            managedFolder: rightManagedFolder
        )
        let processedDestination: (any EndpointSession)?
        switch job.movesProcessedFiles ? job.effectiveProcessedFilesLocation : nil {
        case .customFolder:
            processedDestination = try job.processedFolder.map {
                try EndpointSessionFactory.make(endpoint: $0, password: nil)
            }
        case .processedSubfolder:
            guard let destinationEndpoint = job.destinationEndpoint else {
                throw AppError.invalidConfiguration("Managed output folders require a one-way job.")
            }
            processedDestination = try EndpointSessionFactory.make(
                endpoint: destinationEndpoint,
                password: nil,
                managedFolder: .processedFiles
            )
        case nil:
            processedDestination = nil
        }
        do {
            async let leftListing = left.listFiles()
            async let rightListing = right.listFiles()
            async let processedListing = processedDestination?.listFiles() ?? [:]
            let (leftFiles, rightFiles, processedFiles) = try await (leftListing, rightListing, processedListing)
            try validateLocalDestinationPaths(job: job, leftFiles: leftFiles, rightFiles: rightFiles)
            let transferResult: (transferred: Int, processed: Int, metadataReport: MetadataRunReport)
            let conflicts: [String]
            switch job.direction {
            case .leftToRight:
                transferResult = try await transferNewer(
                    from: left,
                    sourceEndpoint: job.left,
                    files: leftFiles,
                    to: right,
                    files: rightFiles,
                    processedDestination: processedDestination,
                    processedFiles: processedFiles,
                    job: job
                )
                conflicts = []
            case .rightToLeft:
                transferResult = try await transferNewer(
                    from: right,
                    sourceEndpoint: job.right,
                    files: rightFiles,
                    to: left,
                    files: leftFiles,
                    processedDestination: processedDestination,
                    processedFiles: processedFiles,
                    job: job
                )
                conflicts = []
            case .bidirectional:
                let result = try await transferBothWays(
                    left: left,
                    leftFiles: leftFiles,
                    right: right,
                    rightFiles: rightFiles,
                    job: job
                )
                transferResult = (result.transferred, 0, .empty)
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
            await processedDestination?.close()
            return SyncResult(
                transferred: transferResult.transferred,
                deleted: deleted,
                processed: transferResult.processed,
                conflicts: conflicts,
                metadataReport: transferResult.metadataReport
            )
        } catch {
            await left.close()
            await right.close()
            await processedDestination?.close()
            throw error
        }
    }

    func reprocessExistingLocalFiles(
        job: SyncJob,
        leftPassword: String? = nil,
        rightPassword: String? = nil
    ) async throws -> MetadataReprocessResult {
        guard let automation = job.metadataAutomation, automation.isEnabled else {
            throw AppError.invalidConfiguration("Enable and save automatic metadata before reprocessing files.")
        }
        if let message = automation.validationMessage {
            throw AppError.invalidConfiguration(message)
        }
        guard automation.timestampPolicy != .localArrival else {
            throw AppError.invalidConfiguration(
                "Existing files cannot be reprocessed by local arrival time because their original arrival times were not recorded. Choose source modification time or camera capture time."
            )
        }

        let destinationEndpoint: Endpoint
        switch job.direction {
        case .leftToRight:
            destinationEndpoint = job.right
        case .rightToLeft:
            destinationEndpoint = job.left
        case .bidirectional:
            throw AppError.invalidConfiguration("Metadata reprocessing is only available for one-way jobs.")
        }
        guard destinationEndpoint.kind == .local else {
            throw AppError.invalidConfiguration("Metadata reprocessing requires a local destination folder.")
        }

        let destination = try LocalEndpointSession(
            endpoint: destinationEndpoint,
            managedFolder: job.usesManagedFolderStructure ? .syncedFiles : nil
        )
        let destinationFiles = try await destination.listFiles()
        let sourceFiles = await sourceFilesForReprocessing(
            job: job,
            automation: automation,
            leftPassword: leftPassword,
            rightPassword: rightPassword
        )
        let files = destinationFiles.values
            .filter { job.filter.includesFileType(path: $0.relativePath) }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        var applied = 0
        var skipped = 0
        var failed = 0
        var metadataReport = MetadataRunReport.empty
        let runID = UUID()

        for file in files {
            try Task.checkCancellation()
            let temporaryURL = try makeTemporaryURL(for: file)
            let temporarySidecarURL = temporaryURL.deletingPathExtension().appendingPathExtension("xmp")
            defer {
                try? FileManager.default.removeItem(at: temporaryURL)
                try? FileManager.default.removeItem(at: temporarySidecarURL)
            }
            try await destination.exportFile(file, to: temporaryURL)
            if MetadataWriter.usesXMPSidecar(for: file.relativePath),
               let existingSidecar = destinationFiles[MetadataWriter.sidecarRelativePath(for: file.relativePath)] {
                try await destination.exportFile(existingSidecar, to: temporarySidecarURL)
            }

            guard let scheduledAt = MetadataWriter.schedulingDate(
                for: automation.timestampPolicy,
                sourceModifiedAt: sourceFiles[file.relativePath]?.modifiedAt ?? file.modifiedAt,
                localArrivalAt: file.modifiedAt,
                fileURL: temporaryURL
            ) else {
                skipped += 1
                metadataReport.append(MetadataAuditEntry(
                    runID: runID,
                    jobID: job.id,
                    operation: .reprocess,
                    relativePath: file.relativePath,
                    status: .skipped,
                    timestampPolicy: automation.timestampPolicy,
                    scheduledAt: nil,
                    detail: "No valid camera capture timestamp was available."
                ))
                continue
            }
            guard let assignment = automation.assignment(
                for: file.relativePath,
                scheduledAt: scheduledAt
            ) else {
                skipped += 1
                metadataReport.append(MetadataAuditEntry(
                    runID: runID,
                    jobID: job.id,
                    operation: .reprocess,
                    relativePath: file.relativePath,
                    status: .skipped,
                    timestampPolicy: automation.timestampPolicy,
                    scheduledAt: scheduledAt,
                    matchedPhotographer: automation.matchingPhotographer(for: file.relativePath),
                    detail: metadataSkipDetail(
                        automation: automation,
                        relativePath: file.relativePath
                    )
                ))
                continue
            }

            if let assessment = try? MetadataWriter.assess(
                assignment,
                at: temporaryURL,
                relativePath: file.relativePath
            ), assessment != .willApply {
                skipped += 1
                let detail = assessment == .alreadyApplied
                    ? "The programmed metadata is already applied."
                    : "Existing non-empty metadata was preserved; no programmed fields needed changing."
                metadataReport.append(MetadataAuditEntry(
                    runID: runID,
                    jobID: job.id,
                    operation: .reprocess,
                    relativePath: file.relativePath,
                    status: .skipped,
                    timestampPolicy: automation.timestampPolicy,
                    scheduledAt: scheduledAt,
                    assignment: assignment,
                    detail: detail
                ))
                continue
            }

            let writeResult: MetadataWriter.WriteResult
            do {
                writeResult = try MetadataWriter.apply(
                    assignment,
                    to: temporaryURL,
                    relativePath: file.relativePath
                )
            } catch {
                failed += 1
                metadataReport.append(MetadataAuditEntry(
                    runID: runID,
                    jobID: job.id,
                    operation: .reprocess,
                    relativePath: file.relativePath,
                    status: .failed,
                    timestampPolicy: automation.timestampPolicy,
                    scheduledAt: scheduledAt,
                    assignment: assignment,
                    detail: error.localizedDescription
                ))
                continue
            }

            switch writeResult {
            case .embedded(let rewrittenSize, _):
                try await destination.importFile(
                    from: temporaryURL,
                    as: SyncFile(
                        relativePath: file.relativePath,
                        size: rewrittenSize,
                        modifiedAt: file.modifiedAt
                    ),
                    preserveDate: true,
                    verifySize: true
                )
            case .sidecar(let localURL, let sidecarSize, _):
                try await destination.importFile(
                    from: localURL,
                    as: SyncFile(
                        relativePath: MetadataWriter.sidecarRelativePath(for: file.relativePath),
                        size: sidecarSize,
                        modifiedAt: file.modifiedAt
                    ),
                    preserveDate: true,
                    verifySize: true
                )
            }
            applied += 1
            metadataReport.append(MetadataAuditEntry(
                runID: runID,
                jobID: job.id,
                operation: .reprocess,
                relativePath: file.relativePath,
                status: .applied,
                timestampPolicy: automation.timestampPolicy,
                scheduledAt: scheduledAt,
                assignment: assignment,
                swiftExifWarnings: writeResult.warnings
            ))
        }

        return MetadataReprocessResult(
            scanned: files.count,
            applied: applied,
            skipped: skipped,
            failed: failed,
            metadataReport: metadataReport
        )
    }

    private func sourceFilesForReprocessing(
        job: SyncJob,
        automation: MetadataAutomation,
        leftPassword: String?,
        rightPassword: String?
    ) async -> [String: SyncFile] {
        guard automation.timestampPolicy == .sourceModification else { return [:] }

        let sourceEndpoint: Endpoint
        let password: String?
        switch job.direction {
        case .leftToRight:
            sourceEndpoint = job.left
            password = leftPassword
        case .rightToLeft:
            sourceEndpoint = job.right
            password = rightPassword
        case .bidirectional:
            return [:]
        }

        guard let source = try? EndpointSessionFactory.make(endpoint: sourceEndpoint, password: password) else {
            return [:]
        }
        do {
            let files = try await source.listFiles()
            await source.close()
            return files
        } catch {
            await source.close()
            return [:]
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
        sourceEndpoint: Endpoint,
        files sourceFiles: [String: SyncFile],
        to destination: any EndpointSession,
        files destinationFiles: [String: SyncFile],
        processedDestination: (any EndpointSession)?,
        processedFiles: [String: SyncFile],
        job: SyncJob
    ) async throws -> (transferred: Int, processed: Int, metadataReport: MetadataRunReport) {
        let savedSignatures = try await sourceSignatureRepository.signatures(
            jobID: job.id,
            sourceEndpoint: sourceEndpoint
        )
        let candidates = sourceFiles.values
            .filter { job.filter.includes(path: $0.relativePath, modifiedAt: $0.modifiedAt) }
            .filter { file in
                let willRewriteMetadata = job.metadataAutomation?
                    .matchesPhotographer(relativePath: file.relativePath) == true
                    && !MetadataWriter.usesXMPSidecar(for: file.relativePath)
                let destinationNeedsTransfer = needsTransfer(
                    file,
                    destinationFiles[file.relativePath],
                    verifySize: job.verifyFileSizes,
                    metadataMayRewriteDestination: willRewriteMetadata,
                    savedSourceSignature: savedSignatures[file.relativePath]
                )
                return destinationNeedsTransfer
                    || (processedDestination != nil && shouldAttemptProcessedMove(file, automation: job.metadataAutomation))
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        var transferred = 0
        var processed = 0
        var metadataReport = MetadataRunReport.empty
        let runID = UUID()
        for file in candidates {
            try Task.checkCancellation()
            let outcome = try await transfer(
                file,
                from: source,
                to: destination,
                processedDestination: processedDestination,
                processedFiles: processedFiles,
                preserveDate: job.preserveModificationDates,
                verifySize: job.verifyFileSizes,
                metadataAutomation: job.metadataAutomation,
                sortProcessedFilesByPhotographer: job.sortsProcessedFilesByPhotographer,
                sourceSidecar: MetadataWriter.usesXMPSidecar(for: file.relativePath)
                    ? sourceFiles[MetadataWriter.sidecarRelativePath(for: file.relativePath)]
                    : nil,
                jobID: job.id,
                runID: runID
            )
            if let auditEntry = outcome.auditEntry {
                metadataReport.append(auditEntry)
            }
            if outcome.embeddedMetadataApplied {
                try await sourceSignatureRepository.record(
                    file,
                    jobID: job.id,
                    sourceEndpoint: sourceEndpoint
                )
            }
            if outcome.movedToProcessed { processed += 1 }
            transferred += 1
        }
        return (transferred, processed, metadataReport)
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
            _ = try await transfer(
                file,
                from: source,
                to: destination,
                processedDestination: nil,
                processedFiles: [:],
                preserveDate: job.preserveModificationDates,
                verifySize: job.verifyFileSizes,
                metadataAutomation: nil,
                sortProcessedFilesByPhotographer: false,
                sourceSidecar: nil,
                jobID: job.id,
                runID: UUID()
            )
        }
        return (actions.count, conflicts.sorted())
    }

    private func needsTransfer(
        _ source: SyncFile,
        _ destination: SyncFile?,
        verifySize: Bool,
        metadataMayRewriteDestination: Bool = false,
        savedSourceSignature: SourceFileSignature? = nil
    ) -> Bool {
        guard let destination else { return true }
        if source.modifiedAt > destination.modifiedAt.addingTimeInterval(tolerance) { return true }
        guard verifySize else { return false }
        if metadataMayRewriteDestination, let savedSourceSignature {
            // The persisted source signature remains authoritative when the job
            // does not preserve dates and the destination therefore looks newer.
            return !savedSourceSignature.matches(source, timestampTolerance: tolerance)
        }
        guard source.modifiedAt >= destination.modifiedAt.addingTimeInterval(-tolerance) else { return false }
        guard metadataMayRewriteDestination else { return source.size != destination.size }
        // Existing jobs have no saved signatures yet. A single safe bootstrap
        // transfer records the original source size before future comparisons.
        return source.size != destination.size
    }

    private func transfer(
        _ file: SyncFile,
        from source: any EndpointSession,
        to destination: any EndpointSession,
        processedDestination: (any EndpointSession)?,
        processedFiles: [String: SyncFile],
        preserveDate: Bool,
        verifySize: Bool,
        metadataAutomation: MetadataAutomation?,
        sortProcessedFilesByPhotographer: Bool,
        sourceSidecar: SyncFile?,
        jobID: UUID,
        runID: UUID
    ) async throws -> TransferMetadataOutcome {
        let temporaryURL = try makeTemporaryURL(for: file)
        let temporarySidecarURL = temporaryURL.deletingPathExtension().appendingPathExtension("xmp")
        var metadataTemporaryURL: URL?
        var metadataTemporarySidecarURL: URL?
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        defer { try? FileManager.default.removeItem(at: temporarySidecarURL) }
        defer {
            if let metadataTemporaryURL { try? FileManager.default.removeItem(at: metadataTemporaryURL) }
            if let metadataTemporarySidecarURL { try? FileManager.default.removeItem(at: metadataTemporarySidecarURL) }
        }
        try await source.exportFile(file, to: temporaryURL)
        if let sourceSidecar {
            try await source.exportFile(sourceSidecar, to: temporarySidecarURL)
        }

        let activeAutomation = metadataAutomation?.isEnabled == true ? metadataAutomation : nil
        let scheduledAt: Date?
        let metadataAssignment: MetadataAssignment?
        if let activeAutomation {
            scheduledAt = MetadataWriter.schedulingDate(
                for: activeAutomation.timestampPolicy,
                sourceModifiedAt: file.modifiedAt,
                localArrivalAt: Date(),
                fileURL: temporaryURL
            )
            metadataAssignment = scheduledAt.flatMap {
                activeAutomation.assignment(for: file.relativePath, scheduledAt: $0)
            }
        } else {
            scheduledAt = nil
            metadataAssignment = nil
        }

        var importedURL = temporaryURL
        let importedFile: SyncFile
        var sidecarImport: (url: URL, file: SyncFile)?
        var auditEntry: MetadataAuditEntry?
        var embeddedMetadataApplied = false
        if let metadataAssignment {
            do {
                let workURL = try makeTemporaryURL(for: file)
                let workSidecarURL = workURL.deletingPathExtension().appendingPathExtension("xmp")
                metadataTemporaryURL = workURL
                metadataTemporarySidecarURL = workSidecarURL
                try FileManager.default.copyItem(at: temporaryURL, to: workURL)
                if sourceSidecar != nil {
                    try FileManager.default.copyItem(at: temporarySidecarURL, to: workSidecarURL)
                }

                let writeResult = try MetadataWriter.apply(
                    metadataAssignment,
                    to: workURL,
                    relativePath: file.relativePath
                )
                importedURL = workURL
                switch writeResult {
                case .embedded(let rewrittenSize, _):
                    importedFile = SyncFile(
                        relativePath: file.relativePath,
                        size: rewrittenSize,
                        modifiedAt: file.modifiedAt
                    )
                    embeddedMetadataApplied = true
                case .sidecar(let localURL, let sidecarSize, _):
                    importedFile = file
                    sidecarImport = (
                        localURL,
                        SyncFile(
                            relativePath: MetadataWriter.sidecarRelativePath(for: file.relativePath),
                            size: sidecarSize,
                            modifiedAt: file.modifiedAt
                        )
                    )
                }
                auditEntry = MetadataAuditEntry(
                    runID: runID,
                    jobID: jobID,
                    operation: .transfer,
                    relativePath: file.relativePath,
                    status: .applied,
                    timestampPolicy: activeAutomation?.timestampPolicy ?? .sourceModification,
                    scheduledAt: scheduledAt,
                    assignment: metadataAssignment,
                    swiftExifWarnings: writeResult.warnings
                )
            } catch {
                importedFile = file
                if let sourceSidecar {
                    sidecarImport = (temporarySidecarURL, sourceSidecar)
                }
                auditEntry = MetadataAuditEntry(
                    runID: runID,
                    jobID: jobID,
                    operation: .transfer,
                    relativePath: file.relativePath,
                    status: .failed,
                    timestampPolicy: activeAutomation?.timestampPolicy ?? .sourceModification,
                    scheduledAt: scheduledAt,
                    assignment: metadataAssignment,
                    detail: error.localizedDescription
                )
            }
        } else {
            importedFile = file
            if let sourceSidecar {
                sidecarImport = (temporarySidecarURL, sourceSidecar)
            }
            if let activeAutomation {
                let matchedPhotographer = activeAutomation.matchingPhotographer(for: file.relativePath)
                auditEntry = MetadataAuditEntry(
                    runID: runID,
                    jobID: jobID,
                    operation: .transfer,
                    relativePath: file.relativePath,
                    status: .skipped,
                    timestampPolicy: activeAutomation.timestampPolicy,
                    scheduledAt: scheduledAt,
                    matchedPhotographer: matchedPhotographer,
                    detail: scheduledAt == nil
                        ? "No valid camera capture timestamp was available."
                        : metadataSkipDetail(
                            automation: activeAutomation,
                            relativePath: file.relativePath
                        )
                )
            }
        }

        try await destination.importFile(
            from: importedURL,
            as: importedFile,
            preserveDate: preserveDate,
            verifySize: verifySize
        )
        if let sidecarImport {
            try await destination.importFile(
                from: sidecarImport.url,
                as: sidecarImport.file,
                preserveDate: preserveDate,
                verifySize: verifySize
            )
        }
        var movedToProcessed = false
        if auditEntry?.status == .applied,
           let metadataAssignment,
           let processedDestination {
            let processedFile = processedCopy(
                of: importedFile,
                assignment: metadataAssignment,
                automation: activeAutomation,
                sortedByPhotographer: sortProcessedFilesByPhotographer
            )
            try await importProcessedFile(
                from: importedURL,
                as: processedFile,
                existing: processedFiles[processedFile.relativePath],
                to: processedDestination
            )
            if let sidecarImport {
                let processedSidecar = processedCopy(
                    of: sidecarImport.file,
                    assignment: metadataAssignment,
                    automation: activeAutomation,
                    sortedByPhotographer: sortProcessedFilesByPhotographer
                )
                try await importProcessedFile(
                    from: sidecarImport.url,
                    as: processedSidecar,
                    existing: processedFiles[processedSidecar.relativePath],
                    to: processedDestination
                )
            }
            if let sourceSidecar {
                try await source.removeFile(sourceSidecar)
            }
            try await source.removeFile(file)
            movedToProcessed = true
        }
        return TransferMetadataOutcome(
            auditEntry: auditEntry,
            embeddedMetadataApplied: embeddedMetadataApplied,
            movedToProcessed: movedToProcessed
        )
    }

    private func processedCopy(
        of file: SyncFile,
        assignment: MetadataAssignment,
        automation: MetadataAutomation?,
        sortedByPhotographer: Bool
    ) -> SyncFile {
        guard sortedByPhotographer else { return file }
        let folder = photographerFolderName(
            for: assignment.photographer,
            photographers: automation?.photographers ?? [assignment.photographer]
        )
        return SyncFile(
            relativePath: folder + "/" + file.relativePath,
            size: file.size,
            modifiedAt: file.modifiedAt
        )
    }

    private func photographerFolderName(
        for photographer: PhotographerProfile,
        photographers: [PhotographerProfile]
    ) -> String {
        let base = safeFolderComponent(
            photographer.photographerName,
            fallback: "Photographer",
            maximumScalars: 44
        )
        let comparisonKey = folderComparisonKey(base)
        let hasDuplicateName = photographers.contains { candidate in
            candidate.id != photographer.id
                && folderComparisonKey(
                    safeFolderComponent(
                        candidate.photographerName,
                        fallback: "Photographer",
                        maximumScalars: 44
                    )
                ) == comparisonKey
        }
        guard hasDuplicateName else { return base }

        let initials = photographer.normalizedPrefixes.first ?? String(photographer.id.uuidString.prefix(8))
        let suffix = safeFolderComponent(
            initials,
            fallback: String(photographer.id.uuidString.prefix(8)),
            maximumScalars: 10
        )
        return safeFolderComponent("\(base) (\(suffix))", fallback: "Photographer")
    }

    private func safeFolderComponent(
        _ value: String,
        fallback: String,
        maximumScalars: Int = 60
    ) -> String {
        let replacedScalars = value.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return " "
            }
            return Character(String(scalar))
        }
        let collapsed = String(replacedScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        var limited = String(collapsed.unicodeScalars.prefix(maximumScalars))
        if limited.isEmpty || limited == "." || limited == ".." {
            return fallback
        }
        if PathSafety.isInternalStagingPath(limited) {
            let visibleName = limited.drop(while: { $0 == "." })
            limited = String("Photographer \(visibleName)".unicodeScalars.prefix(maximumScalars))
        }
        return limited
    }

    private func folderComparisonKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func importProcessedFile(
        from localURL: URL,
        as file: SyncFile,
        existing: SyncFile?,
        to processedDestination: any EndpointSession
    ) async throws {
        if existing != nil {
            throw AppError.transferFailed(
                "The processed folder already contains a file at \(file.relativePath). Nothing there was overwritten, and the source was left untouched."
            )
        }
        try await processedDestination.importFile(
            from: localURL,
            as: file,
            preserveDate: true,
            verifySize: true
        )
    }

    private func shouldAttemptProcessedMove(
        _ file: SyncFile,
        automation: MetadataAutomation?
    ) -> Bool {
        guard let automation, automation.isEnabled,
              automation.matchesPhotographer(relativePath: file.relativePath) else {
            return false
        }
        switch automation.timestampPolicy {
        case .sourceModification:
            return automation.assignment(for: file.relativePath, scheduledAt: file.modifiedAt) != nil
        case .localArrival:
            return automation.assignment(for: file.relativePath, scheduledAt: Date()) != nil
        case .cameraCapture:
            return true
        }
    }

    private func metadataSkipDetail(
        automation: MetadataAutomation,
        relativePath: String
    ) -> String {
        if automation.matchingPhotographer(for: relativePath) == nil {
            return "No photographer filename initials matched."
        }
        return "No scheduled metadata clip covered the selected timestamp."
    }

    private func makeTemporaryURL(for file: SyncFile) throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalFTPSync", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporaryBaseURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceExtension = URL(fileURLWithPath: file.relativePath).pathExtension
        return sourceExtension.isEmpty
            ? temporaryBaseURL
            : temporaryBaseURL.appendingPathExtension(sourceExtension)
    }
}
