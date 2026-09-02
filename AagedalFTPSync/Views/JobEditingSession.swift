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

    var jobID: UUID? { hasJob ? draft.id : nil }
    var isNewJob: Bool { hasJob && savedJob == nil }

    var hasUnsavedChanges: Bool {
        guard hasJob else { return false }
        guard let savedJob else { return true }
        return draft != savedJob
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
        hasJob = true
    }

    func clear() {
        hasJob = false
        savedJob = nil
        credentialLoadError = nil
        credentialsLoaded = false
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
        draft.metadataAutomation = store.jobs.first(where: { $0.id == draft.id })?.metadataAutomation
        guard store.saveJob(draft, leftPassword: leftPassword, rightPassword: rightPassword),
              let persistedJob = store.jobs.first(where: { $0.id == draft.id }) else {
            return false
        }
        draft = persistedJob
        savedJob = persistedJob
        savedLeftPassword = leftPassword
        savedRightPassword = rightPassword
        store.selectedJobID = persistedJob.id
        return true
    }

    func markDiscarded() {
        guard hasJob else { return }
        if let savedJob {
            draft = savedJob
            leftPassword = savedLeftPassword
            rightPassword = savedRightPassword
        } else {
            clear()
        }
    }
}
