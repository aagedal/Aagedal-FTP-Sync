import Combine
import Foundation

@MainActor
final class PeopleLibraryController: ObservableObject {
    struct Summary: Equatable, Sendable {
        let libraryID: UUID
        let peopleCount: Int
        let embeddingCount: Int
        let exportedAt: String
        let revision: String
        let includesEditorMetadata: Bool
        let upgradeSourceCount: Int
        init(_ manifest: PeopleLibraryManifest) {
            libraryID = manifest.libraryID; peopleCount = manifest.peopleCount
            embeddingCount = manifest.embeddingCount; exportedAt = manifest.exportedAt
            revision = manifest.revision; includesEditorMetadata = manifest.editorPayload != nil
            upgradeSourceCount = manifest.files.filter { $0.path.hasPrefix("upgrade_sources/") }.count
        }
    }
    enum State: Equatable { case unavailable, unselected, selected(Summary), failure }
    @Published private(set) var state: State = .unavailable
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var suspended = false
    private let repository: PeopleLibraryRepository
    private let service: PeopleLibraryPackageService
    private var cancellation: (() -> Void)?
    private var generation = UUID()
    private var snapshot: PeopleLibrarySnapshot?

    init(repository: PeopleLibraryRepository, packageService: PeopleLibraryPackageService = .init()) {
        self.repository = repository; self.service = packageService
    }
    func refresh() async {
        let repository = repository
        await perform(failure: "The people library could not be read.", mutation: false) {
            try repository.currentSnapshot()
        }
    }
    func importPackage(at url: URL) async {
        let repository = repository, service = service
        await perform(failure: "The people library could not be imported. The previous selection was retained.") {
            try service.importPackage(at: url, into: repository)
        }
    }
    func exportPackage(to url: URL) async {
        guard let snapshot else { return }
        let service = service
        await perform(failure: "The people library could not be exported. Choose a new name and try again.") {
            _ = try service.export(snapshot, to: url)
            return snapshot
        }
    }
    func removeCurrentLibrary() async {
        let repository = repository
        await perform(failure: "The current library could not be removed.") {
            try repository.removeCurrentSnapshot()
            return nil
        }
    }
    func suspend() {
        suspended = true; cancellation?()
        // Keep the operation busy until its actual synchronous work returns.
        // A committed operation is reconciled by the next app session's refresh.
        generation = UUID()
    }
    func cancel() { cancellation?() }

    private func perform(failure: String, mutation: Bool = true,
                         operation: @escaping @Sendable () throws -> PeopleLibrarySnapshot?) async {
        guard !busy, !suspended, !Task.isCancelled else { return }
        busy = true; message = nil
        let token = UUID(); generation = token
        let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try operation() }
        cancellation = { worker.cancel() }
        defer { busy = false; cancellation = nil }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard generation == token, !suspended else { return }
            snapshot = result
            state = result.map { .selected(Summary($0.manifest)) } ?? .unselected
        } catch {
            guard generation == token, !suspended else { return }
            if error is CancellationError { return }
            if let repositoryFailure = error as? PeopleLibraryRepository.Failure {
                if repositoryFailure == .cleanupFailed {
                    let repository = self.repository
                    let refreshed = try? await Task.detached(priority: .userInitiated) {
                        try repository.currentSnapshot()
                    }.value
                    snapshot = refreshed
                    state = refreshed.map { .selected(Summary($0.manifest)) } ?? .unselected
                    message = "The selection changed, but an older local face-crop snapshot could not be removed. Retry the library operation to finish cleanup."
                    return
                }
                if repositoryFailure == .invalidUpgradeSource {
                    message = "The package contains an invalid face crop. Each upgrade source must be a complete 320×320 JPEG no larger than 1 MB."
                    return
                }
            }
            if let packageFailure = error as? PeopleLibraryPackageService.Failure,
               packageFailure == .busy {
                message = "The people library is changing. Retry the export after the current library operation finishes."
                return
            }
            message = failure
            if !mutation, snapshot == nil { state = .failure }
        }
    }
}
