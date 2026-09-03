import Foundation

struct ConfigurationTransferState: Equatable, Sendable {
    let jobs: [SyncJob]
    let metadataPresets: [MetadataPreset]
    let photographers: [PhotographerProfile]
    let serverProfiles: [ServerProfile]

    init(
        jobs: [SyncJob],
        metadataPresets: [MetadataPreset],
        photographers: [PhotographerProfile],
        serverProfiles: [ServerProfile] = []
    ) {
        self.jobs = jobs
        self.metadataPresets = metadataPresets
        self.photographers = photographers
        self.serverProfiles = serverProfiles
    }
}

struct PreparedConfigurationImport: Equatable, Sendable {
    let state: ConfigurationTransferState
    let result: ConfigurationImportResult
    let selectedJobID: UUID?
    let importedJobIDs: [UUID: UUID]
}

struct ConfigurationImportResult: Equatable, Sendable {
    let scope: ConfigurationTransferScope
    let importedJobs: Int
    let importedMetadataProgramming: Int
    let skippedMetadataProgramming: Int
    let importedPresets: Int
    let importedPhotographers: Int
    let importedServerProfiles: Int

    var summary: String {
        var parts: [String] = []
        if importedJobs > 0 {
            parts.append(importedJobs == 1 ? "1 sync job" : "\(importedJobs) sync jobs")
        }
        if importedMetadataProgramming > 0 {
            parts.append(
                importedMetadataProgramming == 1
                    ? "metadata programming for 1 job"
                    : "metadata programming for \(importedMetadataProgramming) jobs"
            )
        }
        if importedPresets > 0 {
            parts.append(importedPresets == 1 ? "1 metadata preset" : "\(importedPresets) metadata presets")
        }
        if importedPhotographers > 0 {
            parts.append(importedPhotographers == 1 ? "1 photographer" : "\(importedPhotographers) photographers")
        }
        if importedServerProfiles > 0 {
            parts.append(
                importedServerProfiles == 1
                    ? "1 server profile"
                    : "\(importedServerProfiles) server profiles"
            )
        }
        if skippedMetadataProgramming > 0 {
            parts.append(
                skippedMetadataProgramming == 1
                    ? "1 unmatched programming skipped"
                    : "\(skippedMetadataProgramming) unmatched programmings skipped"
            )
        }
        return parts.isEmpty ? "The package contained no changes." : "Imported " + parts.joined(separator: ", ") + "."
    }
}

struct ConfigurationTransferCoordinator {
    func exportData(
        scope: ConfigurationTransferScope,
        password: String?,
        state: ConfigurationTransferState
    ) throws -> Data {
        let transfer = ConfigurationTransfer(
            scope: scope,
            jobs: state.jobs,
            serverProfiles: state.serverProfiles,
            metadataPresets: state.metadataPresets,
            photographers: state.photographers
        )
        return try ConfigurationTransferCodec.encode(transfer, password: password)
    }

    func prepareImport(
        from data: Data,
        password: String?,
        currentState: ConfigurationTransferState,
        expectedScope: ConfigurationTransferScope? = nil,
        metadataTargetJobID: UUID? = nil
    ) throws -> PreparedConfigurationImport {
        let transfer = try ConfigurationTransferCodec.decode(data, password: password)
        if let expectedScope, transfer.scope != expectedScope {
            throw AppError.invalidConfiguration(
                "Choose an exported \(expectedScope.title.lowercased()) package."
            )
        }
        return try prepareImport(
            transfer,
            currentState: currentState,
            metadataTargetJobID: metadataTargetJobID
        )
    }

    func prepareImport(
        _ transfer: ConfigurationTransfer,
        currentState: ConfigurationTransferState,
        metadataTargetJobID: UUID? = nil
    ) throws -> PreparedConfigurationImport {
        if let metadataTargetJobID {
            guard transfer.scope == .metadata else {
                throw AppError.invalidConfiguration("Only metadata programming can be imported into a sync job.")
            }
            guard currentState.jobs.contains(where: { $0.id == metadataTargetJobID }) else {
                throw AppError.invalidConfiguration("The selected sync job is no longer available.")
            }
            guard transfer.metadataProgramming.count <= 1 else {
                throw AppError.invalidConfiguration(
                    "This package contains metadata programming for more than one job. Import it from the Sync Jobs window instead."
                )
            }
        }
        let sourceJobIDs = transfer.jobs.map(\.id)
        guard Set(sourceJobIDs).count == sourceJobIDs.count else {
            throw AppError.invalidConfiguration("The package contains the same sync job more than once.")
        }
        let programmingJobIDs = transfer.metadataProgramming.map(\.jobID)
        guard Set(programmingJobIDs).count == programmingJobIDs.count else {
            throw AppError.invalidConfiguration("The package contains metadata programming for the same job more than once.")
        }
        let presetIDs = transfer.metadataPresets.map(\.id)
        guard Set(presetIDs).count == presetIDs.count else {
            throw AppError.invalidConfiguration("The package contains the same metadata preset more than once.")
        }
        let sourceProfileIDs = transfer.serverProfiles.map(\.id)
        guard Set(sourceProfileIDs).count == sourceProfileIDs.count else {
            throw AppError.invalidConfiguration("The package contains the same server profile more than once.")
        }
        let referencedProfileIDs = Set(transfer.jobs.flatMap { job in
            [job.left.serverProfileID, job.right.serverProfileID, job.processedFolder?.serverProfileID]
                .compactMap { $0 }
        })
        guard Set(sourceProfileIDs).isSubset(of: referencedProfileIDs) else {
            throw AppError.invalidConfiguration(
                "The package contains a server profile that is not used by an imported job."
            )
        }
        if transfer.version >= 2,
           !referencedProfileIDs.isSubset(of: Set(sourceProfileIDs)) {
            throw AppError.invalidConfiguration(
                "The package is missing a server profile used by an imported job."
            )
        }
        let allowsMissingProfileReferences = transfer.version == 1

        var updatedProfiles = currentState.serverProfiles
        var importedProfilesBySourceID: [UUID: ServerProfile] = [:]
        var usedProfileNames = Set(updatedProfiles.map { foldedName($0.name) })
        for sourceProfile in transfer.serverProfiles {
            if let message = sourceProfile.validationMessage {
                throw AppError.invalidConfiguration("\(sourceProfile.name): \(message)")
            }
            let trimmedName = sourceProfile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = uniqueImportedServerName(trimmedName, usedNames: &usedProfileNames)
            let importedID = UUID()
            let imported = sourceProfile.preparedForImport(id: importedID, name: name)
            importedProfilesBySourceID[sourceProfile.id] = imported
            updatedProfiles.append(imported)
        }
        updatedProfiles.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var updatedJobs = currentState.jobs
        var importedJobIDs: [UUID: UUID] = [:]
        var usedNames = Set(updatedJobs.map {
            $0.name.folding(options: [.caseInsensitive], locale: .current)
        })

        for sourceJob in transfer.jobs {
            let trimmedName = sourceJob.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw AppError.invalidConfiguration("An imported sync job does not have a name.")
            }
            let name = uniqueImportedJobName(trimmedName, usedNames: &usedNames)
            let importedID = UUID()
            importedJobIDs[sourceJob.id] = importedID
            var importedJob = sourceJob.preparedForImport(id: importedID, name: name)
            importedJob.left = try importedEndpoint(
                importedJob.left,
                sourceProfileID: sourceJob.left.serverProfileID,
                importedProfilesBySourceID: importedProfilesBySourceID,
                allowsMissingProfileReferences: allowsMissingProfileReferences
            )
            importedJob.right = try importedEndpoint(
                importedJob.right,
                sourceProfileID: sourceJob.right.serverProfileID,
                importedProfilesBySourceID: importedProfilesBySourceID,
                allowsMissingProfileReferences: allowsMissingProfileReferences
            )
            if let processedFolder = importedJob.processedFolder {
                importedJob.processedFolder = try importedEndpoint(
                    processedFolder,
                    sourceProfileID: sourceJob.processedFolder?.serverProfileID,
                    importedProfilesBySourceID: importedProfilesBySourceID,
                    allowsMissingProfileReferences: allowsMissingProfileReferences
                )
            }
            updatedJobs.append(importedJob)
        }

        var appliedProgramming = 0
        var skippedProgramming = 0
        var targetedJobIDs = Set<UUID>()
        for programming in transfer.metadataProgramming {
            let targetID: UUID?
            if transfer.scope == .metadata, let metadataTargetJobID {
                targetID = metadataTargetJobID
            } else if transfer.scope == .package, let importedID = importedJobIDs[programming.jobID] {
                targetID = importedID
            } else if updatedJobs.contains(where: { $0.id == programming.jobID }) {
                targetID = programming.jobID
            } else {
                let matches = updatedJobs.filter {
                    $0.name.compare(
                        programming.jobName,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
                }
                targetID = matches.count == 1 ? matches[0].id : nil
            }

            guard let targetID,
                  targetedJobIDs.insert(targetID).inserted,
                  let index = updatedJobs.firstIndex(where: { $0.id == targetID }) else {
                skippedProgramming += 1
                continue
            }
            if let message = programming.automation.validationMessage {
                throw AppError.invalidConfiguration("\(programming.jobName): \(message)")
            }
            updatedJobs[index].metadataAutomation = programming.automation
            appliedProgramming += 1
        }

        let importedAutomationPhotographers = transfer.metadataProgramming
            .flatMap { $0.automation.photographers }
        var importedPhotographersByID: [UUID: PhotographerProfile] = [:]
        for photographer in transfer.photographers {
            guard importedPhotographersByID.updateValue(photographer, forKey: photographer.id) == nil else {
                throw AppError.invalidConfiguration(
                    "The package contains the same photographer more than once."
                )
            }
        }
        for photographer in importedAutomationPhotographers {
            importedPhotographersByID[photographer.id] = photographer
        }
        let normalizedImportedPhotographers = try importedPhotographersByID.values.map { profile in
            var normalized = profile.usingCreatorAsPhotographerName()
            let trimmedName = normalized.photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw AppError.invalidConfiguration("An imported photographer does not have a name.")
            }
            guard !normalized.normalizedPrefixes.isEmpty else {
                throw AppError.invalidConfiguration("Give \(trimmedName) filename initials before importing.")
            }
            normalized.name = trimmedName
            normalized.creator = trimmedName
            normalized.filenamePrefix = normalized.formattedFilenamePrefixes
            return normalized
        }
        let updatedPhotographers = mergedPhotographerLibrary(
            currentState.photographers,
            with: normalizedImportedPhotographers
        )
        if let duplicate = duplicateFilenameInitials(in: updatedPhotographers) {
            throw AppError.invalidConfiguration(
                "The filename initials \(duplicate) conflict with an existing photographer."
            )
        }
        let normalizedPhotographersByID = Dictionary(
            uniqueKeysWithValues: normalizedImportedPhotographers.map { ($0.id, $0) }
        )
        for jobIndex in updatedJobs.indices {
            guard var automation = updatedJobs[jobIndex].metadataAutomation else { continue }
            var changed = false
            for photographerIndex in automation.photographers.indices {
                let photographerID = automation.photographers[photographerIndex].id
                guard let imported = normalizedPhotographersByID[photographerID] else { continue }
                automation.photographers[photographerIndex] = imported
                changed = true
            }
            guard changed else { continue }
            if let message = automation.validationMessage {
                throw AppError.invalidConfiguration("\(updatedJobs[jobIndex].name): \(message)")
            }
            updatedJobs[jobIndex].metadataAutomation = automation
        }

        var presetsByID = Dictionary(
            uniqueKeysWithValues: currentState.metadataPresets.map { ($0.id, $0) }
        )
        for preset in transfer.metadataPresets {
            let normalized = preset.normalized()
            if let message = normalized.validationMessage {
                throw AppError.invalidConfiguration(message)
            }
            presetsByID[normalized.id] = normalized
        }
        let updatedPresets = presetsByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let selectedJobID = sourceJobIDs.last.flatMap { importedJobIDs[$0] }
        return PreparedConfigurationImport(
            state: ConfigurationTransferState(
                jobs: updatedJobs,
                metadataPresets: updatedPresets,
                photographers: updatedPhotographers,
                serverProfiles: updatedProfiles
            ),
            result: ConfigurationImportResult(
                scope: transfer.scope,
                importedJobs: transfer.jobs.count,
                importedMetadataProgramming: appliedProgramming,
                skippedMetadataProgramming: skippedProgramming,
                importedPresets: transfer.metadataPresets.count,
                importedPhotographers: normalizedImportedPhotographers.count,
                importedServerProfiles: transfer.serverProfiles.count
            ),
            selectedJobID: selectedJobID,
            importedJobIDs: importedJobIDs
        )
    }

    private func importedEndpoint(
        _ endpoint: Endpoint,
        sourceProfileID: UUID?,
        importedProfilesBySourceID: [UUID: ServerProfile],
        allowsMissingProfileReferences: Bool
    ) throws -> Endpoint {
        guard let sourceProfileID else { return endpoint }
        guard let importedProfile = importedProfilesBySourceID[sourceProfileID] else {
            // Packages written before server profiles were included still carry
            // a usable connection projection. Treat that as an embedded endpoint
            // instead of retaining a reference that cannot resolve on this Mac.
            guard allowsMissingProfileReferences else {
                throw AppError.invalidConfiguration(
                    "The package is missing a server profile used by an imported job."
                )
            }
            var legacyEmbedded = endpoint
            legacyEmbedded.serverProfileID = nil
            return legacyEmbedded
        }
        return importedProfile.endpoint(remotePath: endpoint.remotePath)
    }

    private func uniqueImportedServerName(
        _ base: String,
        usedNames: inout Set<String>
    ) -> String {
        var candidate = base
        if usedNames.contains(foldedName(candidate)) {
            candidate = "\(base) (Imported)"
        }
        var suffix = 2
        while usedNames.contains(foldedName(candidate)) {
            candidate = "\(base) (Imported \(suffix))"
            suffix += 1
        }
        usedNames.insert(foldedName(candidate))
        return candidate
    }

    private func foldedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func uniqueImportedJobName(
        _ base: String,
        usedNames: inout Set<String>
    ) -> String {
        var candidate = base
        if usedNames.contains(candidate.folding(options: [.caseInsensitive], locale: .current)) {
            candidate = "\(base) (Imported)"
        }
        var suffix = 2
        while usedNames.contains(candidate.folding(options: [.caseInsensitive], locale: .current)) {
            candidate = "\(base) (Imported \(suffix))"
            suffix += 1
        }
        usedNames.insert(candidate.folding(options: [.caseInsensitive], locale: .current))
        return candidate
    }

    private func mergedPhotographerLibrary(
        _ existing: [PhotographerProfile],
        with profiles: [PhotographerProfile]
    ) -> [PhotographerProfile] {
        var merged = existing
        for profile in profiles where
            !profile.photographerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !profile.normalizedPrefixes.isEmpty {
            if let index = merged.firstIndex(where: { $0.id == profile.id }) {
                merged[index] = profile
            } else {
                merged.append(profile)
            }
        }
        return merged.sorted {
            $0.photographerName.localizedCaseInsensitiveCompare($1.photographerName) == .orderedAscending
        }
    }

    private func duplicateFilenameInitials(in profiles: [PhotographerProfile]) -> String? {
        var owners: [String: UUID] = [:]
        for profile in profiles {
            for prefix in profile.normalizedPrefixes {
                if let owner = owners[prefix], owner != profile.id {
                    return prefix
                }
                owners[prefix] = profile.id
            }
        }
        return nil
    }
}
