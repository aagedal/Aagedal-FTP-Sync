import Foundation

enum MetadataReprocessScope: Equatable, Sendable {
    case all
    case photographer(UUID)
    case clip(UUID)

    var isClip: Bool {
        if case .clip = self { return true }
        return false
    }

    func includes(_ assignment: MetadataAssignment) -> Bool {
        switch self {
        case .all:
            true
        case .photographer(let photographerID):
            assignment.photographer.id == photographerID
        case .clip(let clipID):
            assignment.clip.id == clipID
        }
    }
}

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
    let publishedProcessedPaths: Set<String>
}

private struct TransferStepFailure: LocalizedError, Sendable {
    let failureDescription: String
    let outcome: TransferMetadataOutcome

    init(_ error: any Error, outcome: TransferMetadataOutcome) {
        failureDescription = error.localizedDescription
        self.outcome = outcome
    }

    var errorDescription: String? { failureDescription }
}

struct SyncEngine: Sendable {
    private let tolerance: TimeInterval = 1.5
    private let sourceSignatureRepository: SourceSignatureRepository
    private let sessionFactory: @Sendable (
        Endpoint,
        String?,
        ManagedOutputFolder?
    ) throws -> any EndpointSession

    init(
        sourceSignatureRepository: SourceSignatureRepository = SourceSignatureRepository(),
        sessionFactory: @escaping @Sendable (
            Endpoint,
            String?,
            ManagedOutputFolder?
        ) throws -> any EndpointSession = { endpoint, password, managedFolder in
            try EndpointSessionFactory.make(
                endpoint: endpoint,
                password: password,
                managedFolder: managedFolder
            )
        }
    ) {
        self.sourceSignatureRepository = sourceSignatureRepository
        self.sessionFactory = sessionFactory
    }

    func run(job: SyncJob, leftPassword: String?, rightPassword: String?) async throws -> SyncResult {
        if let message = job.validationMessage { throw AppError.invalidConfiguration(message) }
        let leftManagedFolder: ManagedOutputFolder? = job.usesManagedFolderStructure && job.direction == .rightToLeft
            ? .syncedFiles
            : nil
        let rightManagedFolder: ManagedOutputFolder? = job.usesManagedFolderStructure && job.direction == .leftToRight
            ? .syncedFiles
            : nil
        let left = try sessionFactory(job.left, leftPassword, leftManagedFolder)
        let right = try sessionFactory(job.right, rightPassword, rightManagedFolder)
        let processedDestination: (any EndpointSession)?
        switch job.movesProcessedFiles ? job.effectiveProcessedFilesLocation : nil {
        case .customFolder:
            processedDestination = try job.processedFolder.map {
                try sessionFactory($0, nil, nil)
            }
        case .processedSubfolder:
            guard let destinationEndpoint = job.destinationEndpoint else {
                throw AppError.invalidConfiguration("Managed output folders require a one-way job.")
            }
            processedDestination = try sessionFactory(destinationEndpoint, nil, .processedFiles)
        case nil:
            processedDestination = nil
        }
        do {
            async let leftListing = left.listFiles()
            async let rightListing = right.listFiles()
            async let processedListing = processedDestination?.listFiles() ?? [:]
            let (leftFiles, rightFiles, processedFiles) = try await (leftListing, rightListing, processedListing)
            try validateLocalDestinationPaths(job: job, leftFiles: leftFiles, rightFiles: rightFiles)
            switch job.direction {
            case .leftToRight:
                try validateCompleteOutputNamespace(
                    sourceFiles: leftFiles,
                    destinationFiles: rightFiles,
                    job: job
                )
            case .rightToLeft:
                try validateCompleteOutputNamespace(
                    sourceFiles: rightFiles,
                    destinationFiles: leftFiles,
                    job: job
                )
            case .bidirectional:
                break
            }
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
            let completedTransfers = SyncResult(
                transferred: transferResult.transferred,
                deleted: 0,
                processed: transferResult.processed,
                conflicts: conflicts,
                metadataReport: transferResult.metadataReport
            )
            let deleted: Int
            do {
                deleted = try await cleanupTargetIfNeeded(
                    job: job,
                    left: left,
                    leftFiles: leftFiles,
                    right: right,
                    rightFiles: rightFiles
                )
            } catch let failure as SyncRunFailure {
                throw SyncRunFailure(
                    failureDescription: failure.failureDescription,
                    partialResult: completedTransfers.adding(failure.partialResult)
                )
            }
            await left.close()
            await right.close()
            await processedDestination?.close()
            return completedTransfers.adding(SyncResult(transferred: 0, deleted: deleted))
        } catch {
            await left.close()
            await right.close()
            await processedDestination?.close()
            throw error
        }
    }

    func reprocessExistingLocalFiles(
        job: SyncJob,
        scope: MetadataReprocessScope = .all,
        leftPassword: String? = nil,
        rightPassword: String? = nil
    ) async throws -> MetadataReprocessResult {
        guard let automation = job.metadataAutomation, automation.isEnabled else {
            throw AppError.invalidConfiguration("Enable and save automatic metadata before reprocessing files.")
        }
        if let message = automation.validationMessage {
            throw AppError.invalidConfiguration(message)
        }
        let scopedPhotographerID: UUID?
        switch scope {
        case .all:
            scopedPhotographerID = nil
        case .photographer(let photographerID):
            guard automation.photographers.contains(where: { $0.id == photographerID }) else {
                throw AppError.invalidConfiguration("The selected photographer is no longer part of this metadata program.")
            }
            scopedPhotographerID = photographerID
        case .clip(let clipID):
            guard let clip = automation.clips.first(where: { $0.id == clipID }) else {
                throw AppError.invalidConfiguration("The selected metadata clip is no longer part of this metadata program.")
            }
            scopedPhotographerID = clip.photographerID
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
        let sourceFiles = try await sourceFilesForReprocessing(
            job: job,
            automation: automation,
            leftPassword: leftPassword,
            rightPassword: rightPassword
        )
        let files = destinationFiles.values
            .filter { job.filter.includesFileType(path: $0.relativePath) }
            .filter { file in
                guard let scopedPhotographerID else { return true }
                return automation.matchingPhotographer(for: file.relativePath)?.id == scopedPhotographerID
            }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        if automation.timestampPolicy == .sourceModification, !job.preserveModificationDates {
            let missingSourcePaths = files
                .map(\.relativePath)
                .filter { sourceFiles[$0] == nil }
            if let firstMissingPath = missingSourcePaths.first {
                let description = missingSourcePaths.count == 1
                    ? firstMissingPath
                    : "\(firstMissingPath) and \(missingSourcePaths.count - 1) other files"
                throw AppError.invalidConfiguration(
                    "Source modification times are unavailable for \(description). Reconnect or restore the source files before reprocessing, or use camera capture time."
                )
            }
        }
        var scanned = scope.isClip ? 0 : files.count
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
                if scope.isClip { continue }
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
                if scope.isClip { continue }
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
            guard scope.includes(assignment) else { continue }
            if scope.isClip { scanned += 1 }

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
            scanned: scanned,
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
    ) async throws -> [String: SyncFile] {
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
            throw AppError.invalidConfiguration("Metadata reprocessing requires a one-way job.")
        }

        let source: any EndpointSession
        do {
            source = try sessionFactory(sourceEndpoint, password, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppError.transferFailed(
                "Source modification times could not be loaded for metadata reprocessing. Reconnect the source and try again. \(error.localizedDescription)"
            )
        }
        do {
            let files = try await source.listFiles()
            await source.close()
            return files
        } catch is CancellationError {
            await source.close()
            throw CancellationError()
        } catch {
            await source.close()
            throw AppError.transferFailed(
                "Source modification times could not be loaded for metadata reprocessing. Reconnect the source and try again. \(error.localizedDescription)"
            )
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

    private func validateCompleteOutputNamespace(
        sourceFiles: [String: SyncFile],
        destinationFiles: [String: SyncFile],
        job: SyncJob
    ) throws {
        let eligible = sourceFiles.values.filter {
            job.filter.includes(path: $0.relativePath, modifiedAt: $0.modifiedAt)
        }
        let handledSidecars = Set(eligible.compactMap { file -> String? in
            guard MetadataWriter.usesXMPSidecar(for: file.relativePath) else { return nil }
            let sidecarPath = MetadataWriter.sidecarRelativePath(for: file.relativePath)
            return sourceFiles[sidecarPath] == nil ? nil : sidecarPath
        })
        try validateGeneratedSidecarOutputPaths(
            candidates: eligible.filter { !handledSidecars.contains($0.relativePath) },
            sourceFiles: sourceFiles,
            automation: job.metadataAutomation,
            enforceLocalPathRules: job.destinationEndpoint?.kind == .local,
            occupiedDestinationPaths: Set(destinationFiles.keys)
        )
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
        let groups = cleanupOutputGroups(
            targetFiles: targetFiles,
            filter: job.filter,
            cutoff: cutoff
        )
        var deleted = 0
        for group in groups {
            try Task.checkCancellation()
            do {
                deleted += try await target.deleteFilesTransactionally(
                    group,
                    ifOlderThan: cutoff,
                    matching: job.filter
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SyncRunFailure(
                    error,
                    partialResult: SyncResult(transferred: 0, deleted: deleted)
                )
            }
        }
        return deleted
    }

    private func cleanupOutputGroups(
        targetFiles: [String: SyncFile],
        filter: FileFilter,
        cutoff: Date
    ) -> [[SyncFile]] {
        let eligiblePrimaries = targetFiles.values.filter {
            filter.includesFileType(path: $0.relativePath)
        }
        let rawPrimariesBySidecar = Dictionary(grouping: eligiblePrimaries.filter {
            MetadataWriter.usesXMPSidecar(for: $0.relativePath)
        }) {
            MetadataWriter.sidecarRelativePath(for: $0.relativePath)
        }
        let unambiguousCompanionPaths = Set(rawPrimariesBySidecar.compactMap { path, primaries in
            primaries.count == 1 && targetFiles[path] != nil ? path : nil
        })
        let ambiguousRawPaths = Set(rawPrimariesBySidecar.values.compactMap { primaries -> [String]? in
            guard primaries.count > 1,
                  targetFiles[MetadataWriter.sidecarRelativePath(for: primaries[0].relativePath)] != nil else {
                return nil
            }
            return primaries.map(\.relativePath)
        }.flatMap { $0 })

        return eligiblePrimaries
            .filter { !unambiguousCompanionPaths.contains($0.relativePath) }
            .filter { !ambiguousRawPaths.contains($0.relativePath) }
            .compactMap { primary -> [SyncFile]? in
                var group = [primary]
                if MetadataWriter.usesXMPSidecar(for: primary.relativePath) {
                    let sidecarPath = MetadataWriter.sidecarRelativePath(for: primary.relativePath)
                    if unambiguousCompanionPaths.contains(sidecarPath),
                       let sidecar = targetFiles[sidecarPath] {
                        group.append(sidecar)
                    }
                }
                return group.allSatisfy { $0.modifiedAt < cutoff } ? group : nil
            }
            .sorted { first, second in
                let firstDate = first.map(\.modifiedAt).max() ?? .distantFuture
                let secondDate = second.map(\.modifiedAt).max() ?? .distantFuture
                return firstDate < secondDate
            }
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
        let preliminaryCandidates = sourceFiles.values
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
        let handledSourceSidecars = Set(preliminaryCandidates.compactMap { file -> String? in
            guard MetadataWriter.usesXMPSidecar(for: file.relativePath) else { return nil }
            let sidecarPath = MetadataWriter.sidecarRelativePath(for: file.relativePath)
            return sourceFiles[sidecarPath] == nil ? nil : sidecarPath
        })
        let candidates = preliminaryCandidates
            .filter { !handledSourceSidecars.contains($0.relativePath) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        try validateGeneratedSidecarOutputPaths(
            candidates: candidates,
            sourceFiles: sourceFiles,
            automation: job.metadataAutomation,
            enforceLocalPathRules: job.destinationEndpoint?.kind == .local,
            occupiedDestinationPaths: Set(destinationFiles.keys)
        )
        var transferred = 0
        var processed = 0
        var occupiedProcessedPaths = Set(processedFiles.keys)
        var metadataReport = MetadataRunReport.empty
        var pendingSourceSignatures: [SyncFile] = []
        let runID = UUID()
        for file in candidates {
            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                try? await sourceSignatureRepository.record(
                    pendingSourceSignatures,
                    jobID: job.id,
                    sourceEndpoint: sourceEndpoint
                )
                throw CancellationError()
            }
            let outcome: TransferMetadataOutcome
            var deferredFailureDescription: String?
            do {
                outcome = try await transfer(
                    file,
                    from: source,
                    to: destination,
                    existingDestinationFiles: destinationFiles,
                    processedDestination: processedDestination,
                    occupiedProcessedPaths: occupiedProcessedPaths,
                    existingProcessedFiles: processedFiles,
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
            } catch is CancellationError {
                try? await sourceSignatureRepository.record(
                    pendingSourceSignatures,
                    jobID: job.id,
                    sourceEndpoint: sourceEndpoint
                )
                throw CancellationError()
            } catch let failure as TransferStepFailure {
                outcome = failure.outcome
                deferredFailureDescription = failure.failureDescription
            } catch {
                let transferError = error
                do {
                    try await sourceSignatureRepository.record(
                        pendingSourceSignatures,
                        jobID: job.id,
                        sourceEndpoint: sourceEndpoint
                    )
                } catch {
                    throw SyncRunFailure(
                        failureDescription: transferError.localizedDescription
                            + " Source signature persistence also failed: \(error.localizedDescription)",
                        partialResult: SyncResult(
                            transferred: transferred,
                            deleted: 0,
                            processed: processed,
                            metadataReport: metadataReport
                        )
                    )
                }
                throw SyncRunFailure(
                    transferError,
                    partialResult: SyncResult(
                        transferred: transferred,
                        deleted: 0,
                        processed: processed,
                        metadataReport: metadataReport
                    )
                )
            }
            if let auditEntry = outcome.auditEntry {
                metadataReport.append(auditEntry)
            }
            if outcome.movedToProcessed { processed += 1 }
            occupiedProcessedPaths.formUnion(outcome.publishedProcessedPaths)
            transferred += 1
            if outcome.embeddedMetadataApplied {
                pendingSourceSignatures.append(file)
            }
            if let deferredFailureDescription {
                do {
                    try await sourceSignatureRepository.record(
                        pendingSourceSignatures,
                        jobID: job.id,
                        sourceEndpoint: sourceEndpoint
                    )
                } catch {
                    throw SyncRunFailure(
                        failureDescription: deferredFailureDescription
                            + " Source signature persistence also failed: \(error.localizedDescription)",
                        partialResult: SyncResult(
                            transferred: transferred,
                            deleted: 0,
                            processed: processed,
                            metadataReport: metadataReport
                        )
                    )
                }
                throw SyncRunFailure(
                    failureDescription: deferredFailureDescription,
                    partialResult: SyncResult(
                        transferred: transferred,
                        deleted: 0,
                        processed: processed,
                        metadataReport: metadataReport
                    )
                )
            }
        }
        do {
            try await sourceSignatureRepository.record(
                pendingSourceSignatures,
                jobID: job.id,
                sourceEndpoint: sourceEndpoint
            )
        } catch {
            throw SyncRunFailure(
                error,
                partialResult: SyncResult(
                    transferred: transferred,
                    deleted: 0,
                    processed: processed,
                    metadataReport: metadataReport
                )
            )
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
        var transferred = 0
        for (file, source, destination) in actions {
            try Task.checkCancellation()
            do {
                _ = try await transfer(
                    file,
                    from: source,
                    to: destination,
                    existingDestinationFiles: [:],
                    processedDestination: nil,
                    occupiedProcessedPaths: [],
                    existingProcessedFiles: [:],
                    preserveDate: job.preserveModificationDates,
                    verifySize: job.verifyFileSizes,
                    metadataAutomation: nil,
                    sortProcessedFilesByPhotographer: false,
                    sourceSidecar: nil,
                    jobID: job.id,
                    runID: UUID()
                )
                transferred += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SyncRunFailure(
                    error,
                    partialResult: SyncResult(
                        transferred: transferred,
                        deleted: 0,
                        conflicts: conflicts.sorted()
                    )
                )
            }
        }
        return (transferred, conflicts.sorted())
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
        existingDestinationFiles: [String: SyncFile],
        processedDestination: (any EndpointSession)?,
        occupiedProcessedPaths: Set<String>,
        existingProcessedFiles: [String: SyncFile],
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

        var destinationImports = [EndpointFileImport(localURL: importedURL, file: importedFile)]
        if let sidecarImport {
            destinationImports.append(
                EndpointFileImport(localURL: sidecarImport.url, file: sidecarImport.file)
            )
        }
        try await destination.importFilesTransactionally(
            destinationImports,
            replacing: existingDestinationFiles,
            preserveDate: preserveDate,
            verifySize: verifySize
        )
        var movedToProcessed = false
        var publishedProcessedPaths = Set<String>()
        if auditEntry?.status == .applied,
           let metadataAssignment,
           let processedDestination {
            do {
                let processedFile = processedCopy(
                    of: importedFile,
                    assignment: metadataAssignment,
                    automation: activeAutomation,
                    sortedByPhotographer: sortProcessedFilesByPhotographer
                )
                var processedOutputs = [(localURL: importedURL, file: processedFile)]
                if let sidecarImport {
                    let processedSidecar = processedCopy(
                        of: sidecarImport.file,
                        assignment: metadataAssignment,
                        automation: activeAutomation,
                        sortedByPhotographer: sortProcessedFilesByPhotographer
                    )
                    processedOutputs.append((sidecarImport.url, processedSidecar))
                }
                let outputPaths = processedOutputs.map { $0.file.relativePath }
                let exactCollisions = outputPaths.filter(occupiedProcessedPaths.contains)
                var outputsWereAlreadyPublished = false
                if exactCollisions.count == outputPaths.count, !outputPaths.isEmpty {
                    outputsWereAlreadyPublished = try await processedOutputsMatch(
                        processedOutputs,
                        existingFiles: existingProcessedFiles,
                        in: processedDestination
                    )
                }

                if !outputsWereAlreadyPublished {
                    try validateProcessedOutputPaths(
                        outputPaths,
                        occupiedPaths: occupiedProcessedPaths
                    )

                    var importedProcessedFiles: [SyncFile] = []
                    do {
                        for output in processedOutputs {
                            try await importProcessedFile(
                                from: output.localURL,
                                as: output.file,
                                to: processedDestination
                            )
                            importedProcessedFiles.append(output.file)
                        }
                    } catch {
                        var rollbackFailures: [String] = []
                        for importedFile in importedProcessedFiles.reversed() {
                            do {
                                try await processedDestination.removeFile(importedFile)
                            } catch {
                                rollbackFailures.append(importedFile.relativePath)
                            }
                        }
                        if !rollbackFailures.isEmpty {
                            throw AppError.transferFailed(
                                "The processed RAW/XMP pair could not be completed, and rollback failed for \(rollbackFailures.joined(separator: ", ")). The source was left untouched."
                            )
                        }
                        throw error
                    }
                }
                publishedProcessedPaths = Set(outputPaths)
                try await source.removeFilesTransactionally([file] + (sourceSidecar.map { [$0] } ?? []))
                movedToProcessed = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TransferStepFailure(
                    error,
                    outcome: TransferMetadataOutcome(
                        auditEntry: auditEntry,
                        embeddedMetadataApplied: embeddedMetadataApplied,
                        movedToProcessed: movedToProcessed,
                        publishedProcessedPaths: publishedProcessedPaths
                    )
                )
            }
        }
        return TransferMetadataOutcome(
            auditEntry: auditEntry,
            embeddedMetadataApplied: embeddedMetadataApplied,
            movedToProcessed: movedToProcessed,
            publishedProcessedPaths: publishedProcessedPaths
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
        to processedDestination: any EndpointSession
    ) async throws {
        try await processedDestination.importFileIfAbsent(
            from: localURL,
            as: file,
            preserveDate: true,
            verifySize: true
        )
    }

    private func processedOutputsMatch(
        _ outputs: [(localURL: URL, file: SyncFile)],
        existingFiles: [String: SyncFile],
        in processedDestination: any EndpointSession
    ) async throws -> Bool {
        for output in outputs {
            guard let existing = existingFiles[output.file.relativePath],
                  existing.size == output.file.size else { return false }
            let comparisonURL = try makeTemporaryURL(for: existing)
            defer { try? FileManager.default.removeItem(at: comparisonURL) }
            try await processedDestination.exportFile(existing, to: comparisonURL)
            guard FileManager.default.contentsEqual(
                atPath: output.localURL.path,
                andPath: comparisonURL.path
            ) else { return false }
        }
        return true
    }

    private func validateProcessedOutputPaths(
        _ outputPaths: [String],
        occupiedPaths: Set<String>
    ) throws {
        if let collision = outputPaths.first(where: occupiedPaths.contains) {
            throw AppError.transferFailed(
                "The processed folder already contains a file at \(collision). Nothing there was overwritten, and the source was left untouched."
            )
        }
        if let collision = PathSafety.localPathCollision(in: Array(occupiedPaths) + outputPaths) {
            throw AppError.transferFailed(
                "Two processed paths cannot safely coexist: \(collision[0]) and \(collision[1]). Nothing was overwritten, and the source was left untouched."
            )
        }
        if Set(outputPaths).count != outputPaths.count {
            throw AppError.transferFailed(
                "Two processed outputs would use the same path. Nothing was overwritten, and the source was left untouched."
            )
        }
    }

    private func validateGeneratedSidecarOutputPaths(
        candidates: [SyncFile],
        sourceFiles: [String: SyncFile],
        automation: MetadataAutomation?,
        enforceLocalPathRules: Bool,
        occupiedDestinationPaths: Set<String> = []
    ) throws {
        var ownerByPath: [String: String] = [:]
        var outputPaths: [String] = []

        func register(_ outputPath: String, owner: String) throws {
            if let existingOwner = ownerByPath[outputPath], existingOwner != owner {
                throw AppError.transferFailed(
                    "The source files \(existingOwner) and \(owner) would both write \(outputPath). Rename one before syncing so no XMP sidecar can be overwritten."
                )
            }
            ownerByPath[outputPath] = owner
            outputPaths.append(outputPath)
        }

        for candidate in candidates {
            try register(candidate.relativePath, owner: candidate.relativePath)
            guard MetadataWriter.usesXMPSidecar(for: candidate.relativePath) else { continue }
            let sidecarPath = MetadataWriter.sidecarRelativePath(for: candidate.relativePath)
            let willPublishSidecar = sourceFiles[sidecarPath] != nil
                || shouldAttemptProcessedMove(candidate, automation: automation)
            if willPublishSidecar {
                try register(sidecarPath, owner: candidate.relativePath)
            }
        }

        if enforceLocalPathRules,
           let collision = PathSafety.localPathCollision(
               in: Array(occupiedDestinationPaths) + outputPaths
           ) {
            throw AppError.transferFailed(
                "Two transfer outputs cannot safely coexist on the local destination: \(collision[0]) and \(collision[1]). Rename one before syncing."
            )
        }
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
