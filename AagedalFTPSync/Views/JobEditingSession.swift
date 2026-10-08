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
        credentialsLoaded = true
        do {
            leftPassword = try store.password(for: draft.left)
            rightPassword = try store.password(for: draft.right)
            savedLeftPassword = leftPassword
            savedRightPassword = rightPassword
            credentialLoadError = nil
        } catch {
            credentialLoadError = "Saved passwords could not be loaded from Keychain. No password changes will be saved until this is resolved. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(using store: AppStore) -> Bool {
        guard hasJob, credentialLoadError == nil else { return false }
        // Metadata is edited in its own window. Merge the latest persisted programming
        // so an older job-settings draft cannot overwrite it.
        let latest = store.jobs.first(where: { $0.id == draft.id })
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
