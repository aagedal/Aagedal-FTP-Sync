import Combine
import Foundation

@MainActor
final class JobEditingSession: ObservableObject {
    @Published var draft = SyncJob()
    @Published var leftPassword = ""
    @Published var rightPassword = ""
    @Published private(set) var credentialLoadError: String?
    @Published private(set) var hasJob = false

    private var savedJob: SyncJob?
    private var savedLeftPassword = ""
    private var savedRightPassword = ""
    private var credentialsLoaded = false
    private var didSelectMetadataProcessingTimeZone = false

    var jobID: UUID? { hasJob ? draft.id : nil }
    var isNewJob: Bool { hasJob && savedJob == nil }

    var hasUnsavedChanges: Bool {
        guard hasJob else { return false }
        guard let savedJob else { return true }
        return draft != savedJob
            || didSelectMetadataProcessingTimeZone
            || leftPassword != savedLeftPassword
            || rightPassword != savedRightPassword
    }

    func edit(_ job: SyncJob) {
        draft = job
        savedJob = job
        leftPassword = ""
        rightPassword = ""
        savedLeftPassword = ""
        savedRightPassword = ""
        credentialLoadError = nil
        credentialsLoaded = false
        didSelectMetadataProcessingTimeZone = false
        hasJob = true
    }

    func beginNewJob(_ job: SyncJob) {
        draft = job
        savedJob = nil
        leftPassword = ""
        rightPassword = ""
        savedLeftPassword = ""
        savedRightPassword = ""
        credentialLoadError = nil
        credentialsLoaded = true
        didSelectMetadataProcessingTimeZone = false
        hasJob = true
    }

    func clear() {
        hasJob = false
        savedJob = nil
        credentialLoadError = nil
        credentialsLoaded = false
        didSelectMetadataProcessingTimeZone = false
    }

    func loadCredentials(using store: AppStore) {
        guard hasJob, !credentialsLoaded else { return }
        do {
            try refreshServerProjections(in: store.serverProfiles)
            // Read draft and saved-baseline credentials before publishing any,
            // so partial failure preserves edits and Discard restores the
            // password belonging to the original endpoint selection.
            let loadedLeft = try store.password(for: draft.left)
            let loadedRight = try store.password(for: draft.right)
            let baselineLeft = try savedJob.map { try store.password(for: $0.left) } ?? loadedLeft
            let baselineRight = try savedJob.map { try store.password(for: $0.right) } ?? loadedRight
            let leftMatchesBaseline = savedJob?.left.serverProfileID == draft.left.serverProfileID
                && savedJob?.left.credentialID == draft.left.credentialID
            let rightMatchesBaseline = savedJob?.right.serverProfileID == draft.right.serverProfileID
                && savedJob?.right.credentialID == draft.right.credentialID
            if draft.left.serverProfileID != nil || (leftMatchesBaseline && leftPassword == savedLeftPassword) {
                leftPassword = loadedLeft
            }
            if draft.right.serverProfileID != nil || (rightMatchesBaseline && rightPassword == savedRightPassword) {
                rightPassword = loadedRight
            }
            credentialsLoaded = true
            savedLeftPassword = baselineLeft
            savedRightPassword = baselineRight
            credentialLoadError = nil
        } catch {
            credentialLoadError = "Saved passwords could not be loaded from Keychain. No password changes will be saved until this is resolved. \(error.localizedDescription)"
        }
    }

    /// Shared profiles own connection settings and passwords. Keep their live
    /// projection current without changing job-local paths or custom passwords.
    func refreshServerProfiles(using store: AppStore) {
        guard hasJob else { return }
        let previousLeft = draft.left
        let previousRight = draft.right
        let previousSavedLeft = savedJob?.left
        let previousSavedRight = savedJob?.right
        do {
            try refreshServerProjections(in: store.serverProfiles)
        } catch {
            credentialsLoaded = false
            credentialLoadError = error.localizedDescription
            return
        }
        if draft.left != previousLeft || draft.right != previousRight
            || savedJob?.left != previousSavedLeft || savedJob?.right != previousSavedRight {
            credentialsLoaded = false
            loadCredentials(using: store)
        }
    }

    private func refreshServerProjections(in profiles: [ServerProfile]) throws {
        let resolved = try draft.resolvingServerProfiles(in: profiles)
        draft.left = resolved.left
        draft.right = resolved.right
        // External connection changes alone must not create unsaved job edits.
        // A locally selected different profile still differs from this baseline.
        if let baseline = savedJob {
            savedJob?.left = (try? baseline.left.resolvingServerProfile(in: profiles)) ?? baseline.left
            savedJob?.right = (try? baseline.right.resolvingServerProfile(in: profiles)) ?? baseline.right
        }
    }

    /// Rebase controls shared with the menu bar without discarding local edits.
    func refreshSharedControls(from latest: SyncJob) {
        guard hasJob, let baseline = savedJob, latest.id == draft.id else { return }
        mergeSharedControl(\.isEnabled, baseline: baseline, latest: latest)
        mergeSharedControl(\.startOnAppLaunch, baseline: baseline, latest: latest)
        mergeSharedControl(\.intervalSeconds, baseline: baseline, latest: latest)
        mergeSharedControl(\.filter.preset, baseline: baseline, latest: latest)
        mergeSharedControl(\.filter.recentHours, baseline: baseline, latest: latest)
        // Quick-control age changes can also move the cleanup safety boundary.
        mergeSharedControl(\.targetCleanup, baseline: baseline, latest: latest)
    }

    private func mergeSharedControl<Value: Equatable>(
        _ keyPath: WritableKeyPath<SyncJob, Value>, baseline: SyncJob, latest: SyncJob
    ) {
        if draft[keyPath: keyPath] == baseline[keyPath: keyPath] {
            draft[keyPath: keyPath] = latest[keyPath: keyPath]
        }
        savedJob?[keyPath: keyPath] = latest[keyPath: keyPath]
    }

    @discardableResult
    func save(using store: AppStore) -> Bool {
        refreshServerProfiles(using: store)
        guard hasJob, credentialLoadError == nil else { return false }
        // Metadata is edited in its own window. Merge the latest persisted programming
        // so an older job-settings draft cannot overwrite it.
        let latest = store.jobs.first(where: { $0.id == draft.id })
        if let latest { refreshSharedControls(from: latest) }
        draft.metadataAutomation = latest?.metadataAutomation
        // A metadata save in another window may have frozen this zone while the
        // settings draft was open. Keep it unless this editor chose a replacement.
        if !didSelectMetadataProcessingTimeZone,
           draft.metadataProcessingTimeZoneIdentifier == savedJob?.metadataProcessingTimeZoneIdentifier,
           let latest {
            draft.metadataProcessingTimeZoneIdentifier = latest.metadataProcessingTimeZoneIdentifier
        }
        if didSelectMetadataProcessingTimeZone, draft.metadataProcessingTimeZoneIdentifier == nil,
           (draft.metadataAutomation?.hasActivatedTemplates == true || draft.metadataGeocoding?.isEnabled == true) {
            store.alertMessage = requiredProcessingTimeZoneMessage
            return false
        }
        do { _ = try draft.validatedMetadataProcessingTimeZone }
        catch {
            store.alertMessage = "Choose a valid processing time zone before saving this job."
            return false
        }
        guard store.saveJob(draft, leftPassword: leftPassword, rightPassword: rightPassword),
              let persistedJob = store.jobs.first(where: { $0.id == draft.id }) else {
            return false
        }
        draft = persistedJob
        savedJob = persistedJob
        didSelectMetadataProcessingTimeZone = false
        savedLeftPassword = leftPassword
        savedRightPassword = rightPassword
        store.selectedJobID = persistedJob.id
        return true
    }

    /// Explicit UI selection only: opening an editor never fills a missing zone.
    func selectMetadataProcessingTimeZone(_ identifier: String?) throws {
        if identifier == nil, (draft.metadataAutomation?.hasActivatedTemplates == true || draft.metadataGeocoding?.isEnabled == true) {
            throw AppError.invalidConfiguration(requiredProcessingTimeZoneMessage)
        }
        var updated = draft
        updated.metadataProcessingTimeZoneIdentifier = identifier
        _ = try updated.validatedMetadataProcessingTimeZone
        draft = updated
        didSelectMetadataProcessingTimeZone = true
    }

    private var requiredProcessingTimeZoneMessage: String {
        draft.metadataGeocoding?.isEnabled == true
            ? "An enabled metadata processor needs a processing time zone. Choose a zone before saving."
            : "A job using metadata variables needs a processing time zone. Choose a zone before saving."
    }

    func markDiscarded() {
        guard hasJob else { return }
        if let savedJob {
            draft = savedJob
            didSelectMetadataProcessingTimeZone = false
            leftPassword = savedLeftPassword
            rightPassword = savedRightPassword
        } else {
            clear()
        }
    }
}
