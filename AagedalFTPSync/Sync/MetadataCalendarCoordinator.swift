import Combine
import Foundation
import Security

struct MetadataSyncAccount: Codable, Identifiable {
    var id: UUID
    var address: String
    var registered = false
    var credentialID: String { "metadata-sync-device-" + id.uuidString }
}

struct MetadataCalendarBinding: Codable, Equatable, Identifiable {
    var id: UUID { snapshot.id }
    var accountID: UUID
    var jobID: UUID
    var snapshot: SharedMetadataCalendar
    var publicationRange: MetadataSharingRange?
    var conflict: SharedMetadataCalendar?
    var range: MetadataSharingRange? { publicationRange ?? snapshot.range }
}

/// Local-only receipt journal. Job settings in this record are never sent to the server.
struct MetadataCalendarReceiveProposal: Codable, Identifiable {
    var id: UUID { duplicate.id }
    var accountID: UUID
    var source: SyncJob
    var duplicate: SyncJob
    var calendar: SharedMetadataCalendar
}

struct MetadataCalendarState: Codable {
    var accounts: [MetadataSyncAccount] = []
    var activeAccountID: UUID?
    var bindings: [MetadataCalendarBinding] = []
    var pendingReceive: MetadataCalendarReceiveProposal?
}

struct MetadataCalendarRepository {
    var url: URL
    private let beforeSave: @Sendable () throws -> Void
    init(url: URL? = nil, beforeSave: @escaping @Sendable () throws -> Void = {}) {
        self.beforeSave = beforeSave
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AagedalFTPSync/metadata-sync-v1.json")
    }
    func load() throws -> MetadataCalendarState {
        guard FileManager.default.fileExists(atPath: url.path) else { return MetadataCalendarState() }
        return try MetadataCalendarClient.decoder().decode(MetadataCalendarState.self, from: Data(contentsOf: url))
    }
    func save(_ state: MetadataCalendarState) throws {
        try beforeSave()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MetadataCalendarClient.encoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class MetadataCalendarCoordinator: ObservableObject {
    @Published private(set) var state = MetadataCalendarState()
    @Published private(set) var calendars: [MetadataCalendarSummary] = []
    @Published private(set) var members: [MetadataCalendarMember] = []
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var bindingMessages: [UUID: String] = [:]
    @Published var invitation = ""
    @Published var receiveProposal: MetadataCalendarReceiveProposal?
    @Published private(set) var receivedJobID: UUID?
    private var storageFailed = false
    private let repository: MetadataCalendarRepository
    private let keychain: KeychainStore
    typealias Transport = @Sendable (MetadataCalendarRequest, String, UUID, String, String?) async throws -> MetadataCalendarResponse
    private let transport: Transport
    private weak var store: AppStore?
    private var loop: Task<Void, Never>?

    var account: MetadataSyncAccount? { state.accounts.first { $0.id == state.activeAccountID } }

    init(repository: MetadataCalendarRepository = MetadataCalendarRepository(), keychain: KeychainStore = KeychainStore(),
         transport: @escaping Transport = { body, address, id, key, setup in
             try await MetadataCalendarClient().send(body, address: address, deviceID: id, key: key, setupKey: setup)
         }) {
        self.transport = transport
        self.repository = repository
        self.keychain = keychain
        do { state = try repository.load() }
        catch { storageFailed = true; message = "Sync state could not be read. It has been left intact: \(error.localizedDescription)" }
    }

    func start(store: AppStore, polling: Bool = true) {
        guard loop == nil else { return }
        self.store = store
        guard polling else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
    }

    private func persist(_ next: MetadataCalendarState) throws {
        guard !storageFailed else { throw MetadataSyncFailure(message: "Sync is paused because its saved state could not be read.") }
        try repository.save(next)
        state = next
    }

    private func replace(_ binding: MetadataCalendarBinding) throws {
        if state.bindings.contains(binding) { return }
        var next = state
        next.bindings.removeAll { $0.id == binding.id && $0.accountID == binding.accountID }
        next.bindings.append(binding)
        try persist(next)
    }

    private func request(_ body: MetadataCalendarRequest, account: MetadataSyncAccount, setupKey: String? = nil) async throws -> MetadataCalendarResponse {
        guard let key = try keychain.password(for: account.credentialID) else {
            throw MetadataSyncFailure(message: "This device's sync key is missing from Keychain. Sync is paused; local metadata is retained.")
        }
        return try await transport(body, account.address, account.id, key, setupKey)
    }

    private func prepareAccount(address: String) throws -> MetadataSyncAccount {
        let address = try MetadataSyncServer(address: address).baseURL.absoluteString
        var next = state
        if let existing = next.accounts.first(where: { $0.address == address }) {
            next.activeAccountID = existing.id
            try persist(next)
            return existing
        }
        let account = MetadataSyncAccount(id: UUID(), address: address)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MetadataSyncFailure(message: "A secure device credential could not be generated.")
        }
        try keychain.setPassword(bytes.map { String(format: "%02x", $0) }.joined(), for: account.credentialID)
        next.accounts.append(account)
        next.activeAccountID = account.id
        // Persist the identity before registration, allowing safe retries after a lost response.
        try persist(next)
        return account
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !storageFailed else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }

    func register(address: String, deviceName: String, setupKey: String?, invite: String?) {
        perform {
            let account = try self.prepareAccount(address: address)
            var request = MetadataCalendarRequest(action: invite == nil ? "bootstrap" : "acceptInvite")
            request.deviceName = deviceName
            request.inviteToken = invite
            _ = try await self.request(request, account: account, setupKey: setupKey)
            var next = self.state
            if let i = next.accounts.firstIndex(where: { $0.id == account.id }) { next.accounts[i].registered = true }
            try self.persist(next)
            self.message = "Device connected. The setup key is no longer needed for normal sync."
            try await self.loadCalendars()
        }
    }

    func selectAccount(_ id: UUID) {
        guard !busy else { return }
        do {
            var next = state; next.activeAccountID = id
            try persist(next)
            calendars = []; members = []; invitation = ""
        } catch { message = error.localizedDescription }
    }

    private func loadCalendars() async throws {
        guard let account, account.registered else { return }
        calendars = try await request(MetadataCalendarRequest(action: "listCalendars"), account: account).calendars ?? []
    }

    func refresh() async {
        guard !busy, !storageFailed else { return }
        busy = true
        defer { busy = false }
        if let pending = state.pendingReceive {
            do { try finishReceive(pending) }
            catch { message = "Receiving into the copy is pending: " + error.localizedDescription }
        }
        do { try await loadCalendars() } catch { message = error.localizedDescription }
        for binding in state.bindings {
            guard binding.conflict == nil,
                  let account = state.accounts.first(where: { $0.id == binding.accountID && $0.registered }) else { continue }
            do { try await sync(binding, account: account) }
            catch { bindingMessages[binding.id] = error.localizedDescription }
        }
    }

    private func localDocument(_ binding: MetadataCalendarBinding) throws -> SharedMetadataDocument {
        guard let job = store?.jobs.first(where: { $0.id == binding.jobID }) else {
            throw MetadataSyncFailure(message: "The linked local job no longer exists. Detach this calendar to stop syncing it.")
        }
        var doc = SharedMetadataDocument(job.metadataAutomation ?? MetadataAutomation())
            .restricted(to: binding.range, timeZone: binding.snapshot.timeZone)
        if binding.snapshot.range != nil {
            // Limited editors keep all currently visible profiles, even while deleting the last clip.
            let current = SharedMetadataDocument(job.metadataAutomation ?? MetadataAutomation()).photographers
            doc.photographers = binding.snapshot.document.photographers.map { base in current.first { $0.id == base.id } ?? base }
        }
        if let publicationRange = binding.publicationRange {
            // The published subset belongs to this job; retain other server-side dates unchanged.
            doc = try SharedMetadataDocument(doc.applying(to: binding.snapshot.document.automation,
                replacing: binding.snapshot.document, range: publicationRange, timeZone: binding.snapshot.timeZone))
        }
        return try doc.validated()
    }

    private func apply(_ document: SharedMetadataDocument, binding: MetadataCalendarBinding) throws {
        guard let store, let job = store.jobs.first(where: { $0.id == binding.jobID }) else {
            throw MetadataSyncFailure(message: "The linked local job no longer exists.")
        }
        let incoming = binding.publicationRange == nil ? document : document.restricted(to: binding.publicationRange, timeZone: binding.snapshot.timeZone)
        let automation = try incoming.applying(to: job.metadataAutomation ?? MetadataAutomation(), replacing: binding.snapshot.document,
                                              range: binding.range, timeZone: binding.snapshot.timeZone)
        guard store.applySyncedMetadataAutomation(automation, for: job.id) else {
            throw MetadataSyncFailure(message: "Received metadata could not be saved. Sync will retry; the previous baseline is retained.")
        }
    }

    private func validateRemote(_ remote: SharedMetadataCalendar, for binding: MetadataCalendarBinding) throws {
        // A new membership can hide records without deleting them. Never merge that
        // filtered snapshot against a baseline saved under different access rules.
        guard remote.range == binding.snapshot.range, remote.timeZone == binding.snapshot.timeZone else {
            throw MetadataSyncFailure(message: "The shared date range or calendar time zone changed. Sync is paused and local programming is retained. Detach this calendar, then receive it again to review the new scope.")
        }
        guard remote.revision >= binding.snapshot.revision else {
            throw MetadataSyncFailure(message: "The server returned an older calendar revision, possibly after a backup restore. Sync is paused and local programming is retained. Restore a current server backup, or detach and publish the local calendar as a new calendar.")
        }
    }

    private func sync(_ original: MetadataCalendarBinding, account: MetadataSyncAccount) async throws {
        var binding = original
        var get = MetadataCalendarRequest(action: binding.snapshot.revision == 0 ? "createCalendar" : "getCalendar", calendarID: binding.id)
        if binding.snapshot.revision == 0 {
            get.name = binding.snapshot.name; get.timeZone = binding.snapshot.timeZone; get.document = binding.snapshot.document
        }
        guard var remote = try await request(get, account: account).calendar else { throw MetadataSyncServerError.invalidResponse }
        for _ in 0..<3 {
            try validateRemote(remote, for: binding)
            guard store?.metadataDraftsBeingEdited.contains(binding.jobID) != true else {
                bindingMessages[binding.id] = "Waiting for the open metadata draft to be saved."
                return
            }
            // Read the latest job after every suspension; never overwrite edits made during a request.
            let local = try localDocument(binding)
            let merged: SharedMetadataDocument
            do { merged = try SharedMetadataDocument.merge(base: binding.snapshot.document, local: local, remote: remote.document) }
            catch {
                binding.conflict = remote
                try replace(binding)
                bindingMessages[binding.id] = error.localizedDescription
                return
            }
            if merged != remote.document && remote.role == "reader" {
                binding.conflict = remote; try replace(binding)
                bindingMessages[binding.id] = "This calendar is read-only. Local changes have been retained."
                return
            }
            // Save the merge locally first. The job is the durable queue for offline changes.
            try apply(merged, binding: binding)
            binding.snapshot = remote
            try replace(binding)
            if merged == remote.document {
                bindingMessages[binding.id] = "Up to date · revision \(remote.revision)"
                return
            }
            let put = MetadataCalendarRequest(action: "putCalendar", calendarID: binding.id, document: merged, expectedRevision: remote.revision)
            let result = try await request(put, account: account)
            guard let response = result.calendar else { throw MetadataSyncServerError.invalidResponse }
            try validateRemote(response, for: binding)
            // An acknowledged write becomes the merge base for any newer local edits.
            if result.error == nil {
                binding.snapshot = response
                try replace(binding)
            }
            // A lost response is also safe: the next GET merges against the last persisted baseline.
            remote = response
        }
        bindingMessages[binding.id] = "New changes arrived during sync; retrying shortly."
    }

    func publish(jobID: UUID, name: String, range: MetadataSharingRange?) {
        perform {
            guard let account = self.account, account.registered,
                  let job = self.store?.jobs.first(where: { $0.id == jobID }),
                  !self.state.bindings.contains(where: { $0.jobID == jobID }) else {
                throw MetadataSyncFailure(message: "Choose a connected server and a job that is not already linked.")
            }
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 100,
                  range.map({ $0.end > $0.start }) ?? true else {
                throw MetadataSyncFailure(message: "Use a calendar name of at most 100 UTF-8 bytes and a valid date range.")
            }
            let zone = TimeZone.current.identifier
            let document = try SharedMetadataDocument(job.metadataAutomation ?? MetadataAutomation()).restricted(to: range, timeZone: zone).validated()
            let snapshot = SharedMetadataCalendar(id: UUID(), name: name, timeZone: zone, revision: 0, role: "owner", document: document)
            let binding = MetadataCalendarBinding(accountID: account.id, jobID: jobID, snapshot: snapshot, publicationRange: range)
            try self.replace(binding)
            try await self.sync(binding, account: account)
            try await self.loadCalendars()
            self.message = "Calendar linked. Saved metadata edits sync while the app is running."
        }
    }

    func attach(calendarID: UUID, jobID: UUID) {
        perform {
            self.message = ""
            guard self.state.pendingReceive == nil else {
                throw MetadataSyncFailure(message: "Finish or cancel the pending receive before linking another calendar.")
            }
            guard let account = self.account, account.registered,
                  !self.state.bindings.contains(where: { $0.id == calendarID && $0.accountID == account.id }) else {
                throw MetadataSyncFailure(message: "Choose a connected server and a calendar that is not already linked on this Mac.")
            }
            guard let remote = try await self.request(MetadataCalendarRequest(action: "getCalendar", calendarID: calendarID), account: account).calendar,
                  let store = self.store, let job = store.jobs.first(where: { $0.id == jobID }) else {
                throw MetadataSyncServerError.invalidResponse
            }
            guard !store.metadataDraftsBeingEdited.contains(jobID) else {
                throw MetadataSyncFailure(message: "Save or close this job's open metadata draft before receiving a calendar.")
            }
            let alreadyLinked = self.state.bindings.contains { $0.jobID == jobID }
            if job.hasMetadataProgramming || alreadyLinked {
                var copy = job
                copy.id = UUID()
                let baseName = job.name + " (Shared)"
                var name = baseName, suffix = 2
                while store.jobs.contains(where: { $0.name == name }) {
                    name = "\(baseName) \(suffix)"; suffix += 1
                }
                copy.name = name
                copy.isEnabled = false
                copy.startsOnAppLaunch = false
                copy.metadataAutomation = try remote.document.applying(to: job.metadataAutomation ?? MetadataAutomation(),
                    replacing: SharedMetadataDocument(job.metadataAutomation ?? MetadataAutomation()), range: nil, timeZone: remote.timeZone)
                self.receiveProposal = MetadataCalendarReceiveProposal(accountID: account.id, source: job, duplicate: copy, calendar: remote)
                return
            }
            // A blank baseline makes the first pull recoverable if persistence or the app is interrupted.
            var baseline = remote; baseline.document = SharedMetadataDocument(MetadataAutomation())
            let binding = MetadataCalendarBinding(accountID: account.id, jobID: jobID, snapshot: baseline)
            try self.replace(binding)
            try await self.sync(binding, account: account)
            self.receivedJobID = jobID
        }
    }

    func confirmReceive(_ proposal: MetadataCalendarReceiveProposal) {
        perform {
            self.message = ""
            guard self.receiveProposal?.id == proposal.id, self.state.pendingReceive == nil,
                  !self.state.bindings.contains(where: { $0.id == proposal.calendar.id && $0.accountID == proposal.accountID }),
                  let store = self.store else {
                throw MetadataSyncFailure(message: "The receive selection changed. Select the calendar and job again.")
            }
            try store.validateCalendarReceiveCopy(source: proposal.source, duplicate: proposal.duplicate)
            var next = self.state
            next.pendingReceive = proposal
            // Persist consent and the downloaded snapshot before changing either job.
            try self.persist(next)
            self.receiveProposal = nil
            try self.finishReceive(proposal)
        }
    }

    private func finishReceive(_ proposal: MetadataCalendarReceiveProposal) throws {
        guard let store else { throw MetadataSyncFailure(message: "The job store is unavailable.") }
        _ = try store.installCalendarReceiveCopy(source: proposal.source, duplicate: proposal.duplicate)
        var next = state
        next.bindings.removeAll { $0.id == proposal.calendar.id && $0.accountID == proposal.accountID }
        next.bindings.append(MetadataCalendarBinding(accountID: proposal.accountID, jobID: proposal.duplicate.id, snapshot: proposal.calendar))
        next.pendingReceive = nil
        try persist(next)
        receivedJobID = proposal.duplicate.id
        message = "Received into “\(proposal.duplicate.name)”. The original calendar is preserved. Automatic running and launch startup are off for both jobs; review the copy and enable it when ready."
    }

    func retryPendingReceive() {
        perform {
            if let pending = self.state.pendingReceive { try self.finishReceive(pending) }
        }
    }

    func cancelPendingReceive() {
        guard !busy else { return }
        do {
            var next = state; next.pendingReceive = nil
            try persist(next)
            message = "Pending link cancelled. Any jobs already saved are retained."
        } catch { message = error.localizedDescription }
    }

    func detach(_ binding: MetadataCalendarBinding) {
        guard !busy else { return }
        do {
            var next = state
            next.bindings.removeAll { $0.id == binding.id && $0.accountID == binding.accountID }
            try persist(next)
            message = "Calendar detached. Local programming and server access are retained."
        } catch { message = error.localizedDescription }
    }

    func resolve(_ original: MetadataCalendarBinding, keepLocal: Bool) {
        perform {
            guard self.store?.metadataDraftsBeingEdited.contains(original.jobID) != true else {
                throw MetadataSyncFailure(message: "Save or close the open metadata draft before resolving this conflict.")
            }
            let reviewedLocal = try self.localDocument(original)
            guard let account = self.state.accounts.first(where: { $0.id == original.accountID }),
                  let current = try await self.request(MetadataCalendarRequest(action: "getCalendar", calendarID: original.id), account: account).calendar else { throw MetadataSyncServerError.invalidResponse }
            try self.validateRemote(current, for: original)
            // Resolve only the version the user saw, so newer edits cannot be silently discarded.
            guard current == original.conflict else {
                var updated = original; updated.conflict = current; try self.replace(updated)
                throw MetadataSyncFailure(message: "The server changed again. Review the updated revision before resolving.")
            }
            guard try self.localDocument(original) == reviewedLocal,
                  self.store?.metadataDraftsBeingEdited.contains(original.jobID) != true else {
                throw MetadataSyncFailure(message: "The local calendar changed while resolving. Review it again before choosing a version.")
            }
            var binding = original
            if !keepLocal { try self.apply(current.document, binding: binding) }
            binding.snapshot = current; binding.conflict = nil
            try self.replace(binding)
            try await self.sync(binding, account: account)
        }
    }

    func createInvite(calendarID: UUID, role: String, range: MetadataSharingRange?) {
        perform {
            guard let account = self.account else { return }
            let result = try await self.request(MetadataCalendarRequest(action: "createInvite", calendarID: calendarID,
                                                                       role: role, rangeStart: range?.start, rangeEnd: range?.end), account: account)
            self.invitation = result.inviteToken ?? ""
            self.message = "Invitation created. It expires in 24 hours and can register one device. Share the server URL and invitation privately."
        }
    }

    func clearSharingDetails() {
        invitation = ""
        members = []
    }

    func manageMembers(calendarID: UUID, revoke: UUID? = nil, revokeInvites: Bool = false) {
        perform {
            guard let account = self.account else { return }
            if let revoke {
                _ = try await self.request(MetadataCalendarRequest(action: "revokeMember", calendarID: calendarID, deviceID: revoke), account: account)
            }
            if revokeInvites {
                _ = try await self.request(MetadataCalendarRequest(action: "revokeInvites", calendarID: calendarID), account: account)
                self.invitation = ""
            }
            self.members = try await self.request(MetadataCalendarRequest(action: "listMembers", calendarID: calendarID), account: account).members ?? []
        }
    }
}
