import Foundation

struct PhotographerLibraryImportResult: Equatable, Sendable {
    let addedCount: Int
    let updatedCount: Int
    let unchangedCount: Int
}

struct MetadataLibraryState: Sendable {
    let jobs: [SyncJob]
    let photographers: [PhotographerProfile]
}

private struct MetadataLibraryMessageError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class MetadataLibraryCoordinator {
    private let persistenceCoordinator: AppPersistenceCoordinator

    init(persistenceCoordinator: AppPersistenceCoordinator) {
        self.persistenceCoordinator = persistenceCoordinator
    }

    func saveAutomation(
        _ automation: MetadataAutomation,
        for jobID: UUID,
        state: MetadataLibraryState
    ) throws -> MetadataLibraryState? {
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }) else { return nil }
        var normalizedAutomation = automation
        normalizedAutomation.photographers = automation.photographers.map { profile in
            var normalized = profile.usingCreatorAsPhotographerName()
            normalized.filenamePrefix = normalized.formattedFilenamePrefixes
            return normalized
        }

        var updatedJob = state.jobs[index]
        updatedJob.metadataAutomation = normalizedAutomation
        if let message = updatedJob.validationMessage {
            throw MetadataLibraryMessageError(message: message)
        }

        var updatedJobs = state.jobs
        updatedJobs[index] = updatedJob
        let updatedPhotographers = mergedLibrary(
            state.photographers,
            with: normalizedAutomation.photographers
        )
        if let duplicate = duplicateFilenameInitials(in: updatedPhotographers) {
            throw MetadataLibraryMessageError(
                message: "The filename initials \(duplicate) are already used by another photographer."
            )
        }

        do {
            try persistenceCoordinator.saveJobsAndPhotographers(
                previousJobs: state.jobs,
                previousPhotographers: state.photographers,
                updatedJobs: updatedJobs,
                updatedPhotographers: updatedPhotographers
            )
        } catch {
            throw MetadataLibraryMessageError(
                message: "Metadata programming could not be saved: \(error.localizedDescription)"
            )
        }
        return MetadataLibraryState(jobs: updatedJobs, photographers: updatedPhotographers)
    }

    func usageCount(for photographerID: UUID, in jobs: [SyncJob]) -> Int {
        jobs.reduce(into: 0) { count, job in
            if job.metadataAutomation?.photographers.contains(where: { $0.id == photographerID }) == true {
                count += 1
            }
        }
    }

    func exportData(for photographers: [PhotographerProfile]) throws -> Data {
        try PhotographerLibraryTransferCodec.encode(photographers)
    }

    func importLibrary(
        from data: Data,
        state: MetadataLibraryState
    ) throws -> (state: MetadataLibraryState, result: PhotographerLibraryImportResult) {
        let importedProfiles = try PhotographerLibraryTransferCodec.decode(data)
        var seenIDs = Set<UUID>()
        var normalizedProfiles: [PhotographerProfile] = []
        normalizedProfiles.reserveCapacity(importedProfiles.count)

        for profile in importedProfiles {
            guard seenIDs.insert(profile.id).inserted else {
                throw AppError.invalidConfiguration(
                    "The imported list contains the same photographer more than once."
                )
            }
            var normalized = profile.usingCreatorAsPhotographerName()
            let trimmedName = normalized.photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw AppError.invalidConfiguration("An imported photographer does not have a name.")
            }
            guard !normalized.normalizedPrefixes.isEmpty else {
                throw AppError.invalidConfiguration(
                    "Give \(trimmedName) filename initials before importing this list."
                )
            }
            normalized.name = trimmedName
            normalized.creator = trimmedName
            normalized.filenamePrefix = normalized.formattedFilenamePrefixes
            normalizedProfiles.append(normalized)
        }

        let existingByID = Dictionary(uniqueKeysWithValues: state.photographers.map { ($0.id, $0) })
        var mergedByID = existingByID
        for profile in normalizedProfiles {
            mergedByID[profile.id] = profile
        }
        let updatedPhotographers = mergedByID.values.sorted(by: profileNameSort)
        if let duplicate = duplicateFilenameInitials(in: updatedPhotographers) {
            throw AppError.invalidConfiguration(
                "The filename initials \(duplicate) are already used by another photographer."
            )
        }

        let importedByID = Dictionary(uniqueKeysWithValues: normalizedProfiles.map { ($0.id, $0) })
        var updatedJobs = state.jobs
        for jobIndex in updatedJobs.indices {
            guard var automation = updatedJobs[jobIndex].metadataAutomation else { continue }
            var changed = false
            for photographerIndex in automation.photographers.indices {
                let photographerID = automation.photographers[photographerIndex].id
                guard let imported = importedByID[photographerID] else { continue }
                automation.photographers[photographerIndex] = imported
                changed = true
            }
            guard changed else { continue }
            if let message = automation.validationMessage {
                throw AppError.invalidConfiguration("\(updatedJobs[jobIndex].name): \(message)")
            }
            updatedJobs[jobIndex].metadataAutomation = automation
        }

        try persistenceCoordinator.saveJobsAndPhotographers(
            previousJobs: state.jobs,
            previousPhotographers: state.photographers,
            updatedJobs: updatedJobs,
            updatedPhotographers: updatedPhotographers
        )

        let addedCount = normalizedProfiles.filter { existingByID[$0.id] == nil }.count
        let updatedCount = normalizedProfiles.filter {
            guard let existing = existingByID[$0.id] else { return false }
            return existing != $0
        }.count
        return (
            MetadataLibraryState(jobs: updatedJobs, photographers: updatedPhotographers),
            PhotographerLibraryImportResult(
                addedCount: addedCount,
                updatedCount: updatedCount,
                unchangedCount: normalizedProfiles.count - addedCount - updatedCount
            )
        )
    }

    func saveProfile(
        _ profile: PhotographerProfile,
        state: MetadataLibraryState
    ) throws -> MetadataLibraryState {
        let normalizedProfile = profile.usingCreatorAsPhotographerName()
        let trimmedName = normalizedProfile.photographerName
        guard !trimmedName.isEmpty else {
            throw MetadataLibraryMessageError(message: "Give the photographer a name.")
        }
        guard !normalizedProfile.normalizedPrefixes.isEmpty else {
            throw MetadataLibraryMessageError(message: "Give \(trimmedName) filename initials.")
        }
        let otherPrefixes = Set(state.photographers
            .filter { $0.id != normalizedProfile.id }
            .flatMap(\.normalizedPrefixes))
        if let duplicate = normalizedProfile.normalizedPrefixes.first(where: otherPrefixes.contains) {
            throw MetadataLibraryMessageError(
                message: "The filename initials \(duplicate) are already used by another photographer."
            )
        }

        var updatedProfile = normalizedProfile
        updatedProfile.filenamePrefix = normalizedProfile.formattedFilenamePrefixes
        var updatedPhotographers = state.photographers
        if let index = updatedPhotographers.firstIndex(where: { $0.id == profile.id }) {
            updatedPhotographers[index] = updatedProfile
        } else {
            updatedPhotographers.append(updatedProfile)
        }
        updatedPhotographers.sort(by: profileNameSort)

        var updatedJobs = state.jobs
        for jobIndex in updatedJobs.indices {
            guard var automation = updatedJobs[jobIndex].metadataAutomation,
                  let photographerIndex = automation.photographers.firstIndex(where: { $0.id == profile.id }) else {
                continue
            }
            automation.photographers[photographerIndex] = updatedProfile
            if let message = automation.validationMessage {
                throw MetadataLibraryMessageError(message: "\(updatedJobs[jobIndex].name): \(message)")
            }
            updatedJobs[jobIndex].metadataAutomation = automation
        }

        do {
            try persistenceCoordinator.saveJobsAndPhotographers(
                previousJobs: state.jobs,
                previousPhotographers: state.photographers,
                updatedJobs: updatedJobs,
                updatedPhotographers: updatedPhotographers
            )
        } catch {
            throw MetadataLibraryMessageError(
                message: "The photographer could not be saved: \(error.localizedDescription)"
            )
        }
        return MetadataLibraryState(jobs: updatedJobs, photographers: updatedPhotographers)
    }

    func removeProfile(
        _ photographerID: UUID,
        state: MetadataLibraryState
    ) throws -> MetadataLibraryState {
        let usageCount = usageCount(for: photographerID, in: state.jobs)
        guard usageCount == 0 else {
            let jobsDescription = usageCount == 1 ? "1 sync job" : "\(usageCount) sync jobs"
            throw MetadataLibraryMessageError(
                message: "Remove this photographer from \(jobsDescription) before deleting the shared profile."
            )
        }
        let updatedPhotographers = state.photographers.filter { $0.id != photographerID }
        guard updatedPhotographers.count != state.photographers.count else { return state }
        do {
            try persistenceCoordinator.savePhotographers(updatedPhotographers)
        } catch {
            throw MetadataLibraryMessageError(
                message: "The photographer could not be removed: \(error.localizedDescription)"
            )
        }
        return MetadataLibraryState(jobs: state.jobs, photographers: updatedPhotographers)
    }

    private func mergedLibrary(
        _ existing: [PhotographerProfile],
        with profiles: [PhotographerProfile]
    ) -> [PhotographerProfile] {
        var merged = existing
        for profile in profiles where !profile.photographerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.normalizedPrefixes.isEmpty {
            if let index = merged.firstIndex(where: { $0.id == profile.id }) {
                merged[index] = profile
            } else {
                merged.append(profile)
            }
        }
        return merged.sorted(by: profileNameSort)
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

    private func profileNameSort(_ lhs: PhotographerProfile, _ rhs: PhotographerProfile) -> Bool {
        lhs.photographerName.localizedCaseInsensitiveCompare(rhs.photographerName) == .orderedAscending
    }
}
