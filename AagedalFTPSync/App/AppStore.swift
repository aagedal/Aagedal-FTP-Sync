import AppKit
import Combine
import Foundation
import ServiceManagement

struct JobTransferTotals: Sendable {
    private var cumulativeFileCounts: [UUID: Int] = [:]
    private var latestSessionFileCounts: [UUID: Int] = [:]

    mutating func record(jobID: UUID, fileCount: Int) {
        latestSessionFileCounts[jobID] = fileCount
        guard fileCount > 0 else { return }
        cumulativeFileCounts[jobID, default: 0] += fileCount
    }

    func fileCount(jobID: UUID, latestSessionOnly: Bool) -> Int {
        let counts = latestSessionOnly ? latestSessionFileCounts : cumulativeFileCounts
        return counts[jobID, default: 0]
    }

    mutating func reset(jobID: UUID) {
        cumulativeFileCounts[jobID] = 0
        latestSessionFileCounts[jobID] = 0
    }

    mutating func remove(jobID: UUID) {
        cumulativeFileCounts[jobID] = nil
        latestSessionFileCounts[jobID] = nil
    }
}

enum MetadataReprocessPhase: Equatable, Sendable {
    case idle
    case running
    case succeeded(Date, MetadataReprocessResult)
    case failed(String)
}

enum SyncRetryPolicy {
    static func delay(baseInterval: Double, consecutiveFailures: Int) -> Double {
        var delay = min(max(baseInterval, 2), 300)
        for _ in 1..<max(consecutiveFailures, 1) {
            delay = min(delay * 2, 300)
        }
        return delay
    }
}

struct PhotographerLibraryImportResult: Equatable, Sendable {
    let addedCount: Int
    let updatedCount: Int
    let unchangedCount: Int
}

struct ConfigurationImportResult: Equatable, Sendable {
    let scope: ConfigurationTransferScope
    let importedJobs: Int
    let importedMetadataProgramming: Int
    let skippedMetadataProgramming: Int
    let importedPresets: Int
    let importedPhotographers: Int

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

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var jobs: [SyncJob]
    @Published private(set) var metadataPresets: [MetadataPreset]
    @Published private(set) var photographerLibrary: [PhotographerProfile]
    @Published private(set) var metadataAuditEntries: [UUID: [MetadataAuditEntry]] = [:]
    @Published private(set) var phases: [UUID: JobPhase] = [:]
    @Published private(set) var metadataReprocessPhases: [UUID: MetadataReprocessPhase] = [:]
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published var selectedJobID: UUID?
    @Published var alertMessage: String?

    private let repository: JobRepository
    private let metadataPresetRepository: MetadataPresetRepository
    private let photographerProfileRepository: PhotographerProfileRepository
    private let metadataAuditRepository: MetadataAuditRepository
    private let keychain: KeychainStore
    private let engine = SyncEngine()
    private var scheduleTasks: [UUID: Task<Void, Never>] = [:]
    private var runningJobs: Set<UUID> = []
    private var transferTotals = JobTransferTotals()
    private var cachedPasswords: [String: String] = [:]
    private var loadedCredentialIDs = Set<String>()

    init(
        repository: JobRepository = JobRepository(),
        metadataPresetRepository: MetadataPresetRepository = MetadataPresetRepository(),
        photographerProfileRepository: PhotographerProfileRepository = PhotographerProfileRepository(),
        metadataAuditRepository: MetadataAuditRepository = MetadataAuditRepository(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.repository = repository
        self.metadataPresetRepository = metadataPresetRepository
        self.photographerProfileRepository = photographerProfileRepository
        self.metadataAuditRepository = metadataAuditRepository
        self.keychain = keychain
        do {
            let loadResult = try metadataPresetRepository.loadResult()
            metadataPresets = loadResult.presets
            if loadResult.recoveredFromBackup {
                alertMessage = "The metadata preset library was damaged, so its most recent backup was restored."
            }
        } catch {
            metadataPresets = []
            alertMessage = "Saved metadata presets could not be loaded: \(error.localizedDescription)"
        }
        var photographerLoadAlert: String?
        do {
            let loadResult = try photographerProfileRepository.loadResult()
            photographerLibrary = loadResult.photographers
            if loadResult.recoveredFromBackup {
                photographerLoadAlert = "The photographer library was damaged, so its most recent backup was restored."
            }
        } catch {
            photographerLibrary = []
            photographerLoadAlert = "Saved photographers could not be loaded: \(error.localizedDescription)"
        }
        let recoveredFromBackup: Bool
        do {
            let loadResult = try repository.loadResult()
            jobs = loadResult.jobs
            recoveredFromBackup = loadResult.recoveredFromBackup
            if loadResult.recoveredFromBackup {
                appendAlert("The jobs file was damaged, so the most recent backup was restored. Review your jobs before starting them.")
            }
        } catch {
            jobs = []
            recoveredFromBackup = false
            appendAlert("Saved jobs could not be loaded: \(error.localizedDescription)")
        }
        if let photographerLoadAlert {
            appendAlert(photographerLoadAlert)
        }
        let migratedPhotographers = mergedPhotographerLibrary(
            photographerLibrary,
            with: jobs.flatMap { $0.metadataAutomation?.photographers ?? [] }
        )
        if migratedPhotographers != photographerLibrary {
            do {
                try photographerProfileRepository.save(migratedPhotographers)
                photographerLibrary = migratedPhotographers
            } catch {
                appendAlert("Photographers from existing jobs could not be added to the shared library: \(error.localizedDescription)")
            }
        }
        do {
            let loadResult = try metadataAuditRepository.loadResult()
            metadataAuditEntries = Dictionary(grouping: loadResult.entries, by: \.jobID)
            if loadResult.recoveredFromBackup {
                appendAlert("The metadata audit trail was damaged, so its most recent backup was restored.")
            }
        } catch {
            metadataAuditEntries = [:]
            appendAlert("The metadata audit trail could not be loaded: \(error.localizedDescription)")
        }
        refreshLaunchAtLoginStatus()
        selectedJobID = jobs.last?.id
        for index in jobs.indices {
            let configuredToStart = jobs[index].startsOnAppLaunch
            let shouldStart = !recoveredFromBackup && configuredToStart
            jobs[index].startOnAppLaunch = configuredToStart
            jobs[index].isEnabled = shouldStart
            phases[jobs[index].id] = .stopped
        }
        Task { [weak self] in self?.restartSchedules() }
    }

    deinit {
        for task in scheduleTasks.values { task.cancel() }
    }

    func addJob() -> SyncJob {
        var job = SyncJob(name: uniqueName())
        job.isEnabled = false
        job.startsOnAppLaunch = false
        jobs.append(job)
        selectedJobID = job.id
        phases[job.id] = .stopped
        persist()
        return job
    }

    @discardableResult
    func saveJob(_ job: SyncJob, leftPassword: String, rightPassword: String) -> Bool {
        if let message = job.validationMessage {
            alertMessage = message
            return false
        }
        let previousJob = jobs.first(where: { $0.id == job.id })
        let wasEnabled = previousJob?.isEnabled ?? false
        do {
            if job.left.kind.isRemote, !leftPassword.isEmpty {
                try savePasswordIfNeeded(leftPassword, for: job.left.credentialID)
            }
            if job.right.kind.isRemote, !rightPassword.isEmpty {
                try savePasswordIfNeeded(rightPassword, for: job.right.credentialID)
            }
            var updatedJobs = jobs
            if let index = updatedJobs.firstIndex(where: { $0.id == job.id }) { updatedJobs[index] = job }
            else { updatedJobs.append(job) }
            try repository.save(updatedJobs)
            jobs = updatedJobs

            if let previousJob {
                removeCredentialsNoLongerUsed(previousJob: previousJob, updatedJob: job)
            }
            if job.isEnabled, !wasEnabled { transferTotals.reset(jobID: job.id) }
            reschedule(job.id)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func updateFilter(jobID: UUID, preset: FilterPreset) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].filter.preset = preset
        persist()
    }

    func updateInterval(jobID: UUID, seconds: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].intervalSeconds = min(max(seconds, 2), 300)
        persist()
        reschedule(jobID)
    }

    func updateFileAge(jobID: UUID, recentHours: Int?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].filter.recentHours = recentHours
        if let recentHours,
           let cleanup = jobs[index].targetCleanup,
           cleanup.olderThanHours <= recentHours {
            jobs[index].targetCleanup?.olderThanHours = recentHours + 1
        }
        persist()
    }

    @discardableResult
    func saveMetadataAutomation(_ automation: MetadataAutomation, for jobID: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return false }
        var normalizedAutomation = automation
        normalizedAutomation.photographers = automation.photographers.map { profile in
            var normalized = profile.usingCreatorAsPhotographerName()
            normalized.filenamePrefix = normalized.formattedFilenamePrefixes
            return normalized
        }
        var updatedJob = jobs[index]
        updatedJob.metadataAutomation = normalizedAutomation
        if let message = updatedJob.validationMessage {
            alertMessage = message
            return false
        }

        var updatedJobs = jobs
        updatedJobs[index] = updatedJob
        let updatedPhotographerLibrary = mergedPhotographerLibrary(
            photographerLibrary,
            with: normalizedAutomation.photographers
        )
        if let duplicate = duplicateFilenameInitials(in: updatedPhotographerLibrary) {
            alertMessage = "The filename initials \(duplicate) are already used by another photographer."
            return false
        }
        do {
            try photographerProfileRepository.save(updatedPhotographerLibrary)
            try repository.save(updatedJobs)
            photographerLibrary = updatedPhotographerLibrary
            jobs = updatedJobs
            return true
        } catch {
            alertMessage = "Metadata programming could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func photographerUsageCount(_ photographerID: UUID) -> Int {
        jobs.reduce(into: 0) { count, job in
            if job.metadataAutomation?.photographers.contains(where: { $0.id == photographerID }) == true {
                count += 1
            }
        }
    }

    func photographerLibraryExportData() -> Data? {
        do {
            return try PhotographerLibraryTransferCodec.encode(photographerLibrary)
        } catch {
            alertMessage = "The photographer list could not be exported: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importPhotographerLibrary(from data: Data) -> PhotographerLibraryImportResult? {
        do {
            let importedProfiles = try PhotographerLibraryTransferCodec.decode(data)
            return try importPhotographerProfiles(importedProfiles)
        } catch {
            alertMessage = "The photographers could not be imported: \(error.localizedDescription)"
            return nil
        }
    }

    func configurationExportData(
        scope: ConfigurationTransferScope,
        password: String
    ) -> Data? {
        do {
            let transfer = ConfigurationTransfer(
                scope: scope,
                jobs: jobs,
                metadataPresets: metadataPresets,
                photographers: photographerLibrary
            )
            return try EncryptedConfigurationTransferCodec.encode(transfer, password: password)
        } catch {
            alertMessage = "The configuration could not be exported: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importConfiguration(from data: Data, password: String) -> ConfigurationImportResult? {
        do {
            let transfer = try EncryptedConfigurationTransferCodec.decode(data, password: password)
            return try applyImportedConfiguration(transfer)
        } catch {
            alertMessage = "The configuration could not be imported: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func savePhotographerProfile(_ profile: PhotographerProfile) -> Bool {
        let normalizedProfile = profile.usingCreatorAsPhotographerName()
        let trimmedName = normalizedProfile.photographerName
        guard !trimmedName.isEmpty else {
            alertMessage = "Give the photographer a name."
            return false
        }
        guard !normalizedProfile.normalizedPrefixes.isEmpty else {
            alertMessage = "Give \(trimmedName) filename initials."
            return false
        }
        let otherPrefixes = Set(photographerLibrary
            .filter { $0.id != normalizedProfile.id }
            .flatMap(\.normalizedPrefixes))
        if let duplicate = normalizedProfile.normalizedPrefixes.first(where: otherPrefixes.contains) {
            alertMessage = "The filename initials \(duplicate) are already used by another photographer."
            return false
        }

        var updatedProfile = normalizedProfile
        updatedProfile.filenamePrefix = normalizedProfile.formattedFilenamePrefixes
        var updatedLibrary = photographerLibrary
        if let index = updatedLibrary.firstIndex(where: { $0.id == profile.id }) {
            updatedLibrary[index] = updatedProfile
        } else {
            updatedLibrary.append(updatedProfile)
        }
        updatedLibrary.sort {
            $0.photographerName.localizedCaseInsensitiveCompare($1.photographerName) == .orderedAscending
        }

        var updatedJobs = jobs
        for jobIndex in updatedJobs.indices {
            guard var automation = updatedJobs[jobIndex].metadataAutomation,
                  let photographerIndex = automation.photographers.firstIndex(where: { $0.id == profile.id }) else {
                continue
            }
            automation.photographers[photographerIndex] = updatedProfile
            if let message = automation.validationMessage {
                alertMessage = "\(updatedJobs[jobIndex].name): \(message)"
                return false
            }
            updatedJobs[jobIndex].metadataAutomation = automation
        }

        do {
            try photographerProfileRepository.save(updatedLibrary)
            try repository.save(updatedJobs)
            photographerLibrary = updatedLibrary
            jobs = updatedJobs
            return true
        } catch {
            alertMessage = "The photographer could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func removePhotographerProfile(_ photographerID: UUID) -> Bool {
        let usageCount = photographerUsageCount(photographerID)
        guard usageCount == 0 else {
            let jobsDescription = usageCount == 1 ? "1 sync job" : "\(usageCount) sync jobs"
            alertMessage = "Remove this photographer from \(jobsDescription) before deleting the shared profile."
            return false
        }
        let updatedLibrary = photographerLibrary.filter { $0.id != photographerID }
        guard updatedLibrary.count != photographerLibrary.count else { return true }
        do {
            try photographerProfileRepository.save(updatedLibrary)
            photographerLibrary = updatedLibrary
            return true
        } catch {
            alertMessage = "The photographer could not be removed: \(error.localizedDescription)"
            return false
        }
    }

    private func importPhotographerProfiles(
        _ importedProfiles: [PhotographerProfile]
    ) throws -> PhotographerLibraryImportResult {
        var seenIDs = Set<UUID>()
        var normalizedProfiles: [PhotographerProfile] = []
        normalizedProfiles.reserveCapacity(importedProfiles.count)

        for profile in importedProfiles {
            guard seenIDs.insert(profile.id).inserted else {
                throw AppError.invalidConfiguration("The imported list contains the same photographer more than once.")
            }
            var normalized = profile.usingCreatorAsPhotographerName()
            let trimmedName = normalized.photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw AppError.invalidConfiguration("An imported photographer does not have a name.")
            }
            guard !normalized.normalizedPrefixes.isEmpty else {
                throw AppError.invalidConfiguration("Give \(trimmedName) filename initials before importing this list.")
            }
            normalized.name = trimmedName
            normalized.creator = trimmedName
            normalized.filenamePrefix = normalized.formattedFilenamePrefixes
            normalizedProfiles.append(normalized)
        }

        let existingByID = Dictionary(uniqueKeysWithValues: photographerLibrary.map { ($0.id, $0) })
        var mergedByID = existingByID
        for profile in normalizedProfiles {
            mergedByID[profile.id] = profile
        }
        let updatedLibrary = mergedByID.values.sorted {
            $0.photographerName.localizedCaseInsensitiveCompare($1.photographerName) == .orderedAscending
        }
        if let duplicate = duplicateFilenameInitials(in: updatedLibrary) {
            throw AppError.invalidConfiguration("The filename initials \(duplicate) are already used by another photographer.")
        }

        let importedByID = Dictionary(uniqueKeysWithValues: normalizedProfiles.map { ($0.id, $0) })
        var updatedJobs = jobs
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

        try photographerProfileRepository.save(updatedLibrary)
        try repository.save(updatedJobs)
        photographerLibrary = updatedLibrary
        jobs = updatedJobs

        let addedCount = normalizedProfiles.filter { existingByID[$0.id] == nil }.count
        let updatedCount = normalizedProfiles.filter {
            guard let existing = existingByID[$0.id] else { return false }
            return existing != $0
        }.count
        return PhotographerLibraryImportResult(
            addedCount: addedCount,
            updatedCount: updatedCount,
            unchangedCount: normalizedProfiles.count - addedCount - updatedCount
        )
    }

    private func applyImportedConfiguration(
        _ transfer: ConfigurationTransfer
    ) throws -> ConfigurationImportResult {
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

        var updatedJobs = jobs
        var importedJobIDs: [UUID: UUID] = [:]
        var usedNames = Set(updatedJobs.map { $0.name.folding(options: [.caseInsensitive], locale: .current) })

        for sourceJob in transfer.jobs {
            let trimmedName = sourceJob.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw AppError.invalidConfiguration("An imported sync job does not have a name.")
            }
            let name = uniqueImportedJobName(trimmedName, usedNames: &usedNames)
            let importedID = UUID()
            importedJobIDs[sourceJob.id] = importedID
            updatedJobs.append(sourceJob.preparedForImport(id: importedID, name: name))
        }

        var appliedProgramming = 0
        var skippedProgramming = 0
        var targetedJobIDs = Set<UUID>()
        for programming in transfer.metadataProgramming {
            let targetID: UUID?
            if transfer.scope == .package, let importedID = importedJobIDs[programming.jobID] {
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
            photographerLibrary,
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

        var presetsByID = Dictionary(uniqueKeysWithValues: metadataPresets.map { ($0.id, $0) })
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

        // Save all related stores before publishing any of the new in-memory state.
        // If a later write fails, make a best-effort rollback to the three
        // previously published collections so a failed import is not half-applied.
        do {
            try photographerProfileRepository.save(updatedPhotographers)
            try metadataPresetRepository.save(updatedPresets)
            try repository.save(updatedJobs)
        } catch {
            try? photographerProfileRepository.save(photographerLibrary)
            try? metadataPresetRepository.save(metadataPresets)
            try? repository.save(jobs)
            throw error
        }
        photographerLibrary = updatedPhotographers
        metadataPresets = updatedPresets
        jobs = updatedJobs

        for importedID in importedJobIDs.values {
            phases[importedID] = .stopped
        }
        if let sourceID = sourceJobIDs.last, let lastImportedID = importedJobIDs[sourceID] {
            selectedJobID = lastImportedID
        }

        return ConfigurationImportResult(
            scope: transfer.scope,
            importedJobs: transfer.jobs.count,
            importedMetadataProgramming: appliedProgramming,
            skippedMetadataProgramming: skippedProgramming,
            importedPresets: transfer.metadataPresets.count,
            importedPhotographers: normalizedImportedPhotographers.count
        )
    }

    private func uniqueImportedJobName(_ base: String, usedNames: inout Set<String>) -> String {
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
        for profile in profiles where !profile.photographerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    @discardableResult
    func saveMetadataPreset(_ preset: MetadataPreset) -> Bool {
        let normalized = preset.normalized()
        if let message = normalized.validationMessage {
            alertMessage = message
            return false
        }

        var updatedPresets = metadataPresets
        if let index = updatedPresets.firstIndex(where: { $0.id == normalized.id }) {
            updatedPresets[index] = normalized
        } else {
            updatedPresets.append(normalized)
        }
        updatedPresets.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        do {
            try metadataPresetRepository.save(updatedPresets)
            metadataPresets = updatedPresets
            return true
        } catch {
            alertMessage = "The metadata preset could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func removeMetadataPreset(_ presetID: UUID) -> Bool {
        let updatedPresets = metadataPresets.filter { $0.id != presetID }
        guard updatedPresets.count != metadataPresets.count else { return true }
        do {
            try metadataPresetRepository.save(updatedPresets)
            metadataPresets = updatedPresets
            return true
        } catch {
            alertMessage = "The metadata preset could not be removed: \(error.localizedDescription)"
            return false
        }
    }

    func setEnabled(_ enabled: Bool, for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if enabled, !jobs[index].isEnabled { transferTotals.reset(jobID: jobID) }
        jobs[index].isEnabled = enabled
        persist()
        reschedule(jobID)
    }

    func removeJob(_ jobID: UUID) {
        scheduleTasks[jobID]?.cancel()
        scheduleTasks[jobID] = nil
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        keychain.removePassword(for: job.left.credentialID)
        keychain.removePassword(for: job.right.credentialID)
        removeCachedPassword(for: job.left.credentialID)
        removeCachedPassword(for: job.right.credentialID)
        jobs.removeAll { $0.id == jobID }
        if selectedJobID == jobID { selectedJobID = jobs.last?.id }
        phases[jobID] = nil
        metadataReprocessPhases[jobID] = nil
        transferTotals.remove(jobID: jobID)
        do {
            let retained = try metadataAuditRepository.remove(jobID: jobID)
            metadataAuditEntries = Dictionary(grouping: retained, by: \.jobID)
        } catch {
            appendAlert("The metadata audit trail for this job could not be removed: \(error.localizedDescription)")
        }
        persist()
    }

    func runNow(_ jobID: UUID) {
        Task { _ = await performSync(jobID) }
    }

    func reprocessExistingLocalFiles(_ jobID: UUID) {
        Task { await performMetadataReprocess(jobID) }
    }

    func isJobBusy(_ jobID: UUID) -> Bool {
        runningJobs.contains(jobID)
    }

    func openLocalFolder(_ endpoint: Endpoint) {
        guard endpoint.kind == .local else { return }
        do {
            let access = try BookmarkAccess(endpoint: endpoint)
            guard NSWorkspace.shared.open(access.url) else {
                throw AppError.folderPermissionLost("Finder could not open the folder.")
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var launchAtLoginRequiresApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            alertMessage = "Launch at Login could not be \(enabled ? "enabled" : "disabled"): \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func startAll() {
        for index in jobs.indices {
            if !jobs[index].isEnabled { transferTotals.reset(jobID: jobs[index].id) }
            jobs[index].isEnabled = true
        }
        persist()
        restartSchedules()
    }

    func stopAll() {
        for index in jobs.indices { jobs[index].isEnabled = false }
        persist()
        restartSchedules()
    }

    func password(for endpoint: Endpoint) -> String {
        guard endpoint.kind.isRemote else { return "" }
        return (try? cachedPassword(for: endpoint.credentialID)) ?? ""
    }

    var activeCount: Int { jobs.filter(\.isEnabled).count }
    var isSyncing: Bool { phases.values.contains(.syncing) }

    func transferredFileCount(for jobID: UUID? = nil) -> Int {
        if let jobID {
            guard let job = jobs.first(where: { $0.id == jobID }) else { return 0 }
            return transferTotals.fileCount(
                jobID: jobID,
                latestSessionOnly: job.showsLatestSessionTransferCountOnly
            )
        }

        return jobs.reduce(into: 0) { count, job in
            count += transferTotals.fileCount(
                jobID: job.id,
                latestSessionOnly: job.showsLatestSessionTransferCountOnly
            )
        }
    }

    func metadataAuditTrail(for jobID: UUID) -> [MetadataAuditEntry] {
        metadataAuditEntries[jobID, default: []]
    }

    /// Persists a completed run's per-file metadata decisions. Engine callers
    /// should invoke this independently from transfer-total accounting.
    func recordMetadataAudit(_ report: MetadataRunReport, jobID: UUID) {
        let scopedReport = MetadataRunReport(entries: report.entries.filter { $0.jobID == jobID })
        guard scopedReport.hasActivity else { return }
        do {
            let retained = try metadataAuditRepository.append(scopedReport)
            metadataAuditEntries = Dictionary(grouping: retained, by: \.jobID)
        } catch {
            appendAlert("The metadata audit trail could not be saved: \(error.localizedDescription)")
        }
    }

    private func restartSchedules() {
        for task in scheduleTasks.values { task.cancel() }
        scheduleTasks.removeAll()
        for job in jobs where job.isEnabled { schedule(job.id) }
    }

    private func reschedule(_ jobID: UUID) {
        scheduleTasks[jobID]?.cancel()
        scheduleTasks[jobID] = nil
        if jobs.first(where: { $0.id == jobID })?.isEnabled == true { schedule(jobID) }
        else if !runningJobs.contains(jobID) { phases[jobID] = .stopped }
    }

    private func schedule(_ jobID: UUID) {
        scheduleTasks[jobID] = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled {
                let attempt = await self.performSync(jobID)
                guard !Task.isCancelled,
                      let job = self.jobs.first(where: { $0.id == jobID }),
                      job.isEnabled else { break }

                let delay: Double
                switch attempt {
                case .succeeded:
                    consecutiveFailures = 0
                    delay = job.intervalSeconds
                case .failed:
                    consecutiveFailures += 1
                    delay = SyncRetryPolicy.delay(
                        baseInterval: job.intervalSeconds,
                        consecutiveFailures: consecutiveFailures
                    )
                case .skipped:
                    delay = job.intervalSeconds
                case .cancelled:
                    return
                }

                let next = Date().addingTimeInterval(delay)
                switch attempt {
                case .succeeded:
                    if case .succeeded(
                        let date,
                        let transferred,
                        let deleted,
                        let processed,
                        let conflicts,
                        let metadataReport,
                        _
                    ) = self.phases[jobID] {
                        self.phases[jobID] = .succeeded(
                            date,
                            transferred: transferred,
                            deleted: deleted,
                            processed: processed,
                            conflicts: conflicts,
                            metadataReport: metadataReport,
                            nextRun: next
                        )
                    }
                case .failed(let message):
                    self.phases[jobID] = .failed(message, retryAt: next)
                case .skipped:
                    break
                case .cancelled:
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch { break }
            }
        }
    }

    private func performSync(_ jobID: UUID) async -> SyncAttempt {
        guard !runningJobs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }) else { return .skipped }
        runningJobs.insert(jobID)
        phases[jobID] = .syncing
        defer { runningJobs.remove(jobID) }
        do {
            let leftPassword = job.left.kind.isRemote ? try cachedPassword(for: job.left.credentialID) : nil
            let rightPassword = job.right.kind.isRemote ? try cachedPassword(for: job.right.credentialID) : nil
            let result = try await engine.run(job: job, leftPassword: leftPassword, rightPassword: rightPassword)
            let completedAt = Date()
            transferTotals.record(jobID: jobID, fileCount: result.transferred)
            recordMetadataAudit(result.metadataReport, jobID: jobID)
            phases[jobID] = .succeeded(
                completedAt,
                transferred: result.transferred,
                deleted: result.deleted,
                processed: result.processed,
                conflicts: result.conflicts,
                metadataReport: result.metadataReport,
                nextRun: nil
            )
            return .succeeded
        } catch is CancellationError {
            phases[jobID] = .stopped
            return .cancelled
        } catch {
            let message = error.localizedDescription
            phases[jobID] = .failed(message, retryAt: nil)
            return .failed(message)
        }
    }

    private func performMetadataReprocess(_ jobID: UUID) async {
        guard !runningJobs.contains(jobID),
              let job = jobs.first(where: { $0.id == jobID }) else { return }
        runningJobs.insert(jobID)
        metadataReprocessPhases[jobID] = .running
        defer { runningJobs.remove(jobID) }

        do {
            let leftPassword = job.left.kind.isRemote ? try cachedPassword(for: job.left.credentialID) : nil
            let rightPassword = job.right.kind.isRemote ? try cachedPassword(for: job.right.credentialID) : nil
            let result = try await engine.reprocessExistingLocalFiles(
                job: job,
                leftPassword: leftPassword,
                rightPassword: rightPassword
            )
            recordMetadataAudit(result.metadataReport, jobID: jobID)
            metadataReprocessPhases[jobID] = .succeeded(Date(), result)
        } catch is CancellationError {
            metadataReprocessPhases[jobID] = .idle
        } catch {
            let message = error.localizedDescription
            metadataReprocessPhases[jobID] = .failed(message)
            alertMessage = message
        }
    }

    private func persist() {
        do { try repository.save(jobs) }
        catch { alertMessage = "Changes could not be saved: \(error.localizedDescription)" }
    }

    private func appendAlert(_ message: String) {
        if let alertMessage, !alertMessage.isEmpty {
            self.alertMessage = alertMessage + "\n\n" + message
        } else {
            alertMessage = message
        }
    }

    private func cachedPassword(for credentialID: String) throws -> String? {
        if loadedCredentialIDs.contains(credentialID) {
            return cachedPasswords[credentialID]
        }

        let password = try keychain.password(for: credentialID)
        loadedCredentialIDs.insert(credentialID)
        if let password { cachedPasswords[credentialID] = password }
        return password
    }

    private func cache(password: String, for credentialID: String) {
        cachedPasswords[credentialID] = password
        loadedCredentialIDs.insert(credentialID)
    }

    private func savePasswordIfNeeded(_ password: String, for credentialID: String) throws {
        if loadedCredentialIDs.contains(credentialID), cachedPasswords[credentialID] == password {
            return
        }
        try keychain.setPassword(password, for: credentialID)
        cache(password: password, for: credentialID)
    }

    private func removeCachedPassword(for credentialID: String) {
        cachedPasswords[credentialID] = nil
        loadedCredentialIDs.remove(credentialID)
    }

    private func removeCredentialsNoLongerUsed(previousJob: SyncJob, updatedJob: SyncJob) {
        let previousIDs = Set([previousJob.left, previousJob.right]
            .filter(\.kind.isRemote)
            .map(\.credentialID))
        let updatedIDs = Set([updatedJob.left, updatedJob.right]
            .filter(\.kind.isRemote)
            .map(\.credentialID))
        for credentialID in previousIDs.subtracting(updatedIDs) {
            keychain.removePassword(for: credentialID)
            removeCachedPassword(for: credentialID)
        }
    }

    private func uniqueName() -> String {
        let base = "Photo sync"
        var candidate = base
        var suffix = 2
        let names = Set(jobs.map(\.name))
        while names.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }
}

private enum SyncAttempt {
    case succeeded
    case failed(String)
    case cancelled
    case skipped
}
