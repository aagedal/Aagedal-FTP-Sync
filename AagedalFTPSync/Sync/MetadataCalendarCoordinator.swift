import Combine
import Foundation
import Security

@MainActor
final class MetadataCalendarCoordinator: ObservableObject {
    @Published private(set) var state = MetadataCalendarState()
    @Published private(set) var discoveryProtocol: MetadataCalendarProtocol = .legacy
    @Published private(set) var calendars: [MetadataCalendarSummary] = []
    @Published private(set) var members: [MetadataCalendarMember] = []
    @Published private(set) var busy = false
    /// Strict startup instances remain inert until start(store:...) is explicit.
    @Published private(set) var isPaused = false
    private var enforcesExplicitStart = false
    @Published private(set) var message = ""
    @Published private(set) var bindingMessages: [UUID: String] = [:]
    @Published var invitation = ""
    @Published var receiveProposal: MetadataCalendarReceiveProposal?
    @Published private(set) var receivedJobID: UUID?
    @Published private(set) var activities: [UUID: MetadataSyncActivity] = [:]
    @Published private(set) var events: [MetadataSyncEvent] = []
    @Published private(set) var eventStorageError = ""
    @Published private(set) var currentOperation: String?
    @Published private(set) var suggestedCalendarID: UUID?
    private let eventRepository: MetadataSyncEventRepository
    private var storageFailed = false
    private var calendarListError: String?
    private let repository: MetadataCalendarRepository
    private let keychain: KeychainStore
    typealias Transport = @Sendable (MetadataCalendarRequest, String, UUID, String, String?) async throws -> MetadataCalendarResponse
    private let transport: Transport
    private weak var store: AppStore?
    private var loop: Task<Void, Never>?
    private var changeObservation: AnyCancellable?
    private var changeTask: Task<Void, Never>?
    private var queuedRefreshTask: Task<Void, Never>?
    private var queuedJobIDs: Set<UUID> = []
    private var queuedManualJobIDs: Set<UUID> = []
    private var refreshAllQueued = false
    private var refreshAllManual = false
    private let changeDebounce: Duration
    private let waitForChangeDebounce: @Sendable (Duration) async throws -> Void
    private let now: () -> Date
    private struct ConnectionRetry {
        var failures: Int
        var retryAfter: Date
    }
    private var connectionRetries: [UUID: ConnectionRetry] = [:]
    private var lastCalendarList: [UUID: Date] = [:]

    var account: MetadataSyncAccount? { state.accounts.first { $0.id == state.activeAccountID } }

    init(repository: MetadataCalendarRepository = MetadataCalendarRepository(), keychain: KeychainStore = KeychainStore(),
         changeDebounce: Duration = .milliseconds(500),
         waitForChangeDebounce: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> Date = Date.init,
         transport: @escaping Transport = { body, address, id, key, setup in
             try await MetadataCalendarClient().send(body, address: address, deviceID: id, key: key, setupKey: setup, protocolVersion: body.routingProtocol)
         }) {
        self.transport = transport
        self.changeDebounce = changeDebounce
        self.waitForChangeDebounce = waitForChangeDebounce
        self.now = now
        self.repository = repository
        self.eventRepository = MetadataSyncEventRepository(url: repository.eventsURL, storageFormat: repository.storageFormat)
        self.keychain = keychain
        if repository.storageFormat == .legacy {
            self.events = eventRepository.load()
        } else {
            do { self.events = try eventRepository.loadResult() }
            catch { eventStorageError = "Saved sync diagnostics could not be read. They have been left intact." }
        }
        do { state = try repository.load() }
        catch { storageFailed = true; message = "Sync state could not be read. It has been left intact: \(error.localizedDescription)" }
    }

    /// The complete root must already have passed v3 admission under writer
    /// exclusion. This factory reloads both required stores strictly before the
    /// coordinator exists; it does not attach an AppStore, read credentials, run
    /// a receipt, observe edits or create a polling task. Admission/lifetime and
    /// release of writer exclusion remain the bootstrap coordinator's job.
    static func makePausedForValidatedStorage(
        _ storage: AppStorageLayout,
        keychain: KeychainStore = KeychainStore(),
        changeDebounce: Duration = .milliseconds(500),
        now: @escaping () -> Date = Date.init,
        transport: @escaping Transport = { body, address, id, key, setup in
            try await MetadataCalendarClient().send(body, address: address, deviceID: id, key: key, setupKey: setup, protocolVersion: body.routingProtocol)
        }
    ) throws -> MetadataCalendarCoordinator {
        guard storage.storageFormat == .version3 else { throw AppPersistenceStartupError.unsupportedStorage }
        let repository = MetadataCalendarRepository(storage: storage)
        let events = MetadataSyncEventRepository(url: repository.eventsURL, storageFormat: .version3)
        let loadedState = try repository.load()
        let loadedEvents = try events.loadResult()
        return MetadataCalendarCoordinator(repository: repository, eventRepository: events, keychain: keychain,
            changeDebounce: changeDebounce, now: now, transport: transport, state: loadedState, events: loadedEvents)
    }

    private init(repository: MetadataCalendarRepository, eventRepository: MetadataSyncEventRepository,
                 keychain: KeychainStore, changeDebounce: Duration, now: @escaping () -> Date,
                 transport: @escaping Transport, state: MetadataCalendarState, events: [MetadataSyncEvent]) {
        self.repository = repository
        self.eventRepository = eventRepository
        self.keychain = keychain
        self.changeDebounce = changeDebounce
        self.waitForChangeDebounce = { try await Task.sleep(for: $0) }
        self.now = now
        self.transport = transport
        self.state = state
        self.events = events
        self.enforcesExplicitStart = true
        self.isPaused = true
    }

    func start(store: AppStore, polling: Bool = true, observingChanges: Bool = true) {
        // stop() is not an await-all-writers barrier. A strict runtime cannot be
        // reactivated until the prior operation has observed the pause and ended;
        // otherwise its suspended response could resume in a later activation.
        guard !enforcesExplicitStart || !isPaused || !busy else { return }
        self.store = store
        isPaused = false
        if observingChanges, changeObservation == nil {
            changeObservation = store.$jobs
                .map { jobs in Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.metadataAutomation ?? MetadataAutomation()) }) }
                .removeDuplicates()
                .combineLatest(store.$metadataDraftsBeingEdited.removeDuplicates())
                .sink { [weak self] _, _ in
                    // Published values arrive before AppStore's setters finish. Read
                    // after the save and any sync-baseline update have completed.
                    self?.changeTask?.cancel()
                    self?.changeTask = Task { @MainActor [weak self] in
                        guard !Task.isCancelled, let self else { return }
                        // Show pending state promptly, but do not retain this work
                        // list: a manual refresh may commit it during the debounce.
                        _ = self.jobsNeedingSyncAfterEdit()
                        do { try await self.waitForChangeDebounce(self.changeDebounce) } catch { return }
                        guard !Task.isCancelled else { return }
                        self.changeTask = nil
                        for id in self.jobsNeedingSyncAfterEdit() {
                            guard !Task.isCancelled else { return }
                            await self.refresh(jobID: id, automatic: true)
                        }
                    }
                }
        }
        guard polling, loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // A slow request already checks for updates. Only user requests
                // and saved edits need to queue work while another sync is busy.
                if self?.busy == false { await self?.refresh(automatic: true) }
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
    }

    func stop() {
        if enforcesExplicitStart { isPaused = true }
        loop?.cancel(); loop = nil
        changeObservation = nil
        changeTask?.cancel(); changeTask = nil
        queuedRefreshTask?.cancel(); queuedRefreshTask = nil
        queuedJobIDs = []; refreshAllQueued = false
        queuedManualJobIDs = []; refreshAllManual = false
    }

    private func jobsNeedingSyncAfterEdit() -> [UUID] {
        guard !storageFailed, !isPaused else { return [] }
        return state.bindings.compactMap { binding in
            guard binding.conflict == nil else { return nil }
            let phase = activities[binding.jobID]?.phase
            // syncOnce rereads this job after every request; its own received
            // changes must not schedule another round trip.
            guard phase?.isActive != true else { return nil }
            if store?.metadataDraftsBeingEdited.contains(binding.jobID) == true {
                setActivity(.paused, jobID: binding.jobID, detail: "Waiting for the metadata draft to save. If autosave is blocked, fix the validation warning in the editor.")
                return nil
            }
            let changed = (try? localDocument(binding)) != binding.snapshot.document
            guard changed || phase == .paused || phase == .pending else { return nil }
            if phase != .failed && phase != .offline {
                setActivity(.pending, jobID: binding.jobID, detail: "Saved on this Mac. Changes will sync shortly.")
            }
            return binding.jobID
        }
    }

    private func finishBusyOperation() {
        busy = false
        guard !isPaused, refreshAllQueued || !queuedJobIDs.isEmpty else { return }
        // Coalesce requests made during a network operation, including saves to a
        // job already visited by this polling pass. Never silently discard them.
        guard queuedRefreshTask == nil else { return }
        queuedRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.queuedRefreshTask = nil
            let all = self.refreshAllQueued
            let ids = self.queuedJobIDs
            let manualIDs = self.queuedManualJobIDs
            let allManual = self.refreshAllManual
            self.refreshAllQueued = false
            self.queuedJobIDs = []
            self.queuedManualJobIDs = []
            self.refreshAllManual = false
            if all {
                await self.refresh(automatic: !allManual)
                // A queued per-job Retry Now must still bypass a background cooldown.
                if !allManual {
                    for id in manualIDs { await self.refresh(jobID: id) }
                }
            } else {
                for id in ids { await self.refresh(jobID: id, automatic: !manualIDs.contains(id)) }
            }
        }
    }

    func binding(for jobID: UUID?) -> MetadataCalendarBinding? {
        state.bindings.first { $0.jobID == jobID }
    }

    func activity(for jobID: UUID) -> MetadataSyncActivity {
        if storageFailed { return MetadataSyncActivity(phase: .failed, detail: message) }
        if let activity = activities[jobID] { return activity }
        if binding(for: jobID)?.conflict != nil {
            return MetadataSyncActivity(phase: .conflict, detail: "Both versions are retained. Open sync settings to review the conflict.")
        }
        return MetadataSyncActivity()
    }

    private func setActivity(_ phase: MetadataSyncPhase, jobID: UUID, detail: String) {
        var activity = activities[jobID] ?? MetadataSyncActivity()
        activity.phase = phase
        activity.detail = detail
        if phase == .current { activity.lastSuccess = Date() }
        activities[jobID] = activity
        if let binding = binding(for: jobID) { bindingMessages[binding.id] = detail }
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        (error as? URLError).map {
            [URLError.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains($0.code)
        } ?? false
    }

    private func setFailureActivity(_ error: Error, jobID: UUID) {
        let connectionError = Self.isConnectionError(error)
        setActivity(connectionError ? .offline : .failed, jobID: jobID,
                    detail: connectionError ? "The server could not be reached. Saved metadata stays on this Mac; sync retries automatically. " + error.localizedDescription : error.localizedDescription)
    }

    private func record(_ event: MetadataSyncEvent) {
        guard !isPaused else { return }
        if let last = events.last, last.jobID == event.jobID, last.operation == event.operation,
           last.detail == event.detail, last.revision == event.revision, last.isError == event.isError {
            events[events.count - 1].date = event.date
            events[events.count - 1].occurrences += 1
        } else {
            events.append(event)
            events = Array(events.suffix(200))
        }
        do { try eventRepository.save(events); eventStorageError = "" }
        catch { eventStorageError = "Sync diagnostics could not be saved. Current-session entries are still available here." }
    }

    func diagnosticText(jobID: UUID? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        let selected = events.filter { jobID == nil || $0.jobID == jobID || $0.jobID == nil }
        return (["Metadata calendar sync diagnostics", "Calendar content, server addresses and credentials are excluded."] + selected.map {
            "\(formatter.string(from: $0.date)) [\($0.isError ? "ERROR" : "INFO")] \($0.operation): \($0.detail)"
                + ($0.revision.map { " (revision \($0))" } ?? "")
                + ($0.occurrences > 1 ? " (\($0.occurrences) occurrences)" : "")
        }).joined(separator: "\n")
    }

    private func persist(_ next: MetadataCalendarState) throws {
        guard !isPaused else { throw CancellationError() }
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

    private func requireNamespace(_ protocolVersion: MetadataCalendarProtocol) throws {
        if protocolVersion == .templates, repository.storageFormat != .version3 {
            throw VersionedStoreCodec.HeaderError.requiresVersion3Storage
        }
    }

    /// Check whole jobs, including private/unshared portions, before credentials.
    /// A template namespace permits activation; a legacy binding never does.
    private func validateBindings(accountID: UUID? = nil) throws {
        guard !state.pendingMigrations.contains(where: { $0.phase != .bindingCommitted }) else {
            throw MetadataSyncFailure(message: "Finish the pending calendar migration before syncing.", diagnosticCode: "calendar_migration_pending")
        }
        if repository.storageFormat == .legacy { try LegacyMetadataCalendarGate.validate(state) }
        else { try MetadataCalendarNamespaceGate.validate(state) }
        for binding in state.bindings where accountID == nil || binding.accountID == accountID {
            try requireNamespace(binding.snapshot.compatibility.protocolVersion)
            if let automation = store?.jobs.first(where: { $0.id == binding.jobID })?.metadataAutomation {
                try MetadataCalendarNamespaceGate.validate(automation, for: binding.snapshot.compatibility.protocolVersion)
            }
        }
    }

    private func validateDocument(_ document: SharedMetadataDocument, for protocolVersion: MetadataCalendarProtocol) throws {
        try requireNamespace(protocolVersion)
        try MetadataCalendarNamespaceGate.validate(document.automation, for: protocolVersion)
    }

    private func request(_ original: MetadataCalendarRequest, account: MetadataSyncAccount, setupKey: String? = nil,
                         protocolVersion: MetadataCalendarProtocol? = nil) async throws -> MetadataCalendarResponse {
        guard !isPaused else { throw CancellationError() }
        try validateBindings(accountID: account.id)
        let linked = state.bindings.first { $0.accountID == account.id && $0.id == original.calendarID }
        let routing = protocolVersion ?? linked?.snapshot.compatibility.protocolVersion
            ?? calendars.first(where: { $0.id == original.calendarID })?.compatibility.protocolVersion ?? .legacy
        try requireNamespace(routing)
        if let linked, linked.snapshot.compatibility.protocolVersion != routing { throw MetadataSyncServerError.unsupportedProtocol }
        var body = original
        body.routingProtocol = routing
        if let document = body.document { try validateDocument(document, for: routing) }
        if routing == .templates {
            body.capabilities = [MetadataCalendarCompatibility.templateCapability]
            if body.document != nil { body.documentSchemaVersion = 3 }
        } else if body.capabilities != nil || body.documentSchemaVersion != nil || body.templateDeactivations != nil {
            throw MetadataSyncServerError.unsupportedProtocol
        }
        let jobID = linked?.jobID
        let operation: String
        switch body.action {
        case "getCalendar": operation = "Fetch calendar"
        case "putCalendar": operation = "Send changes"
        case "createCalendar": operation = "Publish calendar"
        case "listCalendars": operation = "List calendars"
        case "bootstrap": operation = "Connect first device"
        case "acceptInvite": operation = "Join invitation"
        case "createInvite": operation = "Create invitation"
        case "listMembers": operation = "List members"
        case "revokeMember": operation = "Revoke member"
        case "revokeInvites": operation = "Revoke invitations"
        default: operation = "Calendar request"
        }
        currentOperation = operation
        defer { currentOperation = nil }
        if let jobID, ["getCalendar", "putCalendar", "createCalendar"].contains(body.action) {
            let sending = body.action == "putCalendar" || body.action == "createCalendar"
            setActivity(sending ? .sending : .fetching, jobID: jobID, detail: sending ? "Sending saved metadata changes…" : "Checking for calendar updates…")
        }
        do {
            guard let key = try keychain.password(for: account.credentialID) else {
                throw MetadataSyncFailure(message: "This device's sync key is missing from Keychain. Sync is paused; local metadata is retained.", diagnosticCode: "Device key missing from Keychain")
            }
            let result = try await transport(body, account.address, account.id, key, setupKey)
            guard !isPaused else { throw CancellationError() }
            try validateBindings(accountID: account.id)
            guard result.service == "aagedal-metadata-sync", result.protocolVersion == routing.rawValue,
                  routing != .templates || result.capabilities == [MetadataCalendarCompatibility.templateCapability] else {
                throw MetadataSyncServerError.unsupportedProtocol
            }
            guard result.error == nil || (result.error == "revision_conflict" && result.calendar != nil) else {
                throw MetadataSyncServerError.invalidResponse
            }
            if let calendar = result.calendar {
                guard calendar.compatibility.protocolVersion == routing, calendar.id == body.calendarID,
                      calendar.revision > 0, ["owner", "editor", "reader"].contains(calendar.role),
                      TimeZone(identifier: calendar.timeZone) != nil,
                      (calendar.rangeStart == nil) == (calendar.rangeEnd == nil),
                      calendar.range.map({ $0.end > $0.start }) ?? true else { throw MetadataSyncServerError.invalidResponse }
                try MetadataCalendarNamespaceGate.validate(calendar)
                _ = try calendar.document.validated()
            }
            if let listed = result.calendars {
                guard Set(listed.map(\.id)).count == listed.count,
                      listed.allSatisfy({ $0.compatibility.protocolVersion == routing }) else { throw MetadataSyncServerError.invalidResponse }
            }
            if body.action != "listCalendars" && body.action != "getCalendar" {
                record(MetadataSyncEvent(jobID: jobID, operation: operation,
                    detail: result.error == "revision_conflict" ? "A newer server revision arrived; merging before retry." : "Request completed.", revision: result.calendar?.revision))
            }
            return result
        } catch {
            record(MetadataSyncEvent(jobID: jobID, operation: operation, detail: MetadataSyncEvent.errorDetail(error), isError: true))
            throw error
        }
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
        guard !busy, !storageFailed, !isPaused else { return }
        busy = true
        message = ""
        Task { @MainActor in
            defer { finishBusyOperation() }
            do {
                guard !isPaused else { throw CancellationError() }
                try await operation()
            }
            catch {
                message = error.localizedDescription
                self.record(MetadataSyncEvent(operation: "Setup or calendar action", detail: MetadataSyncEvent.errorDetail(error), isError: true))
            }
        }
    }

    func register(address: String, deviceName: String, setupKey: String?, invite: String?, protocolVersion: MetadataCalendarProtocol = .legacy) {
        perform {
            try self.validateBindings()
            let parsed = try invite.map(MetadataSyncInvitation.init)
            let selectedProtocol = parsed?.protocolVersion ?? protocolVersion
            try self.requireNamespace(selectedProtocol)
            let account = try self.prepareAccount(address: parsed?.address ?? address)
            let previousIDs = Set(self.calendars.map(\.id))
            var request = MetadataCalendarRequest(action: invite == nil ? "bootstrap" : "acceptInvite")
            request.deviceName = deviceName
            request.inviteToken = parsed?.token
            _ = try await self.request(request, account: account, setupKey: setupKey?.trimmingCharacters(in: .whitespacesAndNewlines), protocolVersion: selectedProtocol)
            var next = self.state
            if let i = next.accounts.firstIndex(where: { $0.id == account.id }) { next.accounts[i].registered = true }
            try self.persist(next)
            self.discoveryProtocol = selectedProtocol
            try await self.loadCalendars()
            let newCalendars = self.calendars.filter { !previousIDs.contains($0.id) }
            self.suggestedCalendarID = newCalendars.count == 1 ? newCalendars[0].id : (self.calendars.count == 1 ? self.calendars[0].id : nil)
            self.message = invite == nil ? "Server connected. Choose a local job and activate sync." : "Invitation accepted. Choose a local job and activate sync with the shared calendar."

        }
    }

    func selectAccount(_ id: UUID) {
        guard !busy, !isPaused else { return }
        do {
            var next = state; next.activeAccountID = id
            try persist(next)
            calendars = []; members = []; invitation = ""; suggestedCalendarID = nil
            lastCalendarList[id] = nil
        } catch { message = error.localizedDescription }
    }

    func selectProtocol(_ protocolVersion: MetadataCalendarProtocol) {
        guard !busy, !isPaused else { return }
        do {
            try requireNamespace(protocolVersion)
            discoveryProtocol = protocolVersion
            calendars = []; members = []; invitation = ""; suggestedCalendarID = nil
            if let account { lastCalendarList[account.id] = nil }
            Task { await refresh() }
        } catch { message = error.localizedDescription }
    }

    private func loadCalendars() async throws {
        guard let account, account.registered else { return }
        calendars = try await request(MetadataCalendarRequest(action: "listCalendars"), account: account, protocolVersion: discoveryProtocol).calendars ?? []
        lastCalendarList[account.id] = now()
    }

    func refresh(jobID: UUID? = nil, automatic: Bool = false) async {
        guard !storageFailed, !isPaused, !Task.isCancelled else { return }
        guard !busy else {
            if let jobID {
                queuedJobIDs.insert(jobID)
                if !automatic { queuedManualJobIDs.insert(jobID) }
            } else {
                refreshAllQueued = true
                if !automatic { refreshAllManual = true }
            }
            return
        }
        busy = true
        defer { finishBusyOperation() }
        var attemptedAccounts: Set<UUID> = []
        var connectionFailures: [UUID: Error] = [:]
        func canAttempt(_ id: UUID) -> Bool {
            connectionFailures[id] == nil && (!automatic || (connectionRetries[id]?.retryAfter ?? .distantPast) <= now())
        }
        defer {
            for id in attemptedAccounts {
                if connectionFailures[id] != nil {
                    let failures = min((connectionRetries[id]?.failures ?? 0) + 1, 6)
                    let delay = min(10 * pow(2, Double(failures - 1)), 300)
                    connectionRetries[id] = ConnectionRetry(failures: failures, retryAfter: now().addingTimeInterval(delay))
                } else {
                    connectionRetries[id] = nil
                }
            }
        }
        if let pending = state.pendingReceive {
            do { try finishReceive(pending) }
            catch { message = "Receiving into the copy is pending: " + error.localizedDescription }
        }
        if jobID == nil, let account, account.registered, canAttempt(account.id),
           !automatic || now().timeIntervalSince(lastCalendarList[account.id] ?? .distantPast) >= 60 {
            attemptedAccounts.insert(account.id)
            do {
                try await loadCalendars()
                if message == calendarListError { message = "" }
                calendarListError = nil
            } catch {
                calendarListError = error.localizedDescription
                message = error.localizedDescription
                if Self.isConnectionError(error) { connectionFailures[account.id] = error }
            }
        }
        for binding in state.bindings where jobID == nil || binding.jobID == jobID {
            guard binding.conflict == nil,
                  let account = state.accounts.first(where: { $0.id == binding.accountID && $0.registered }) else { continue }
            if let error = connectionFailures[account.id] {
                setFailureActivity(error, jobID: binding.jobID)
                continue
            }
            guard !Task.isCancelled, canAttempt(account.id) else { continue }
            attemptedAccounts.insert(account.id)
            do { try await sync(binding, account: account) }
            catch {
                bindingMessages[binding.id] = error.localizedDescription
                if Self.isConnectionError(error) { connectionFailures[account.id] = error }
            }
        }
    }

    private func localDocument(_ binding: MetadataCalendarBinding) throws -> SharedMetadataDocument {
        guard let job = store?.jobs.first(where: { $0.id == binding.jobID }) else {
            throw MetadataSyncFailure(message: "The linked local job no longer exists. Detach this calendar to stop syncing it.")
        }
        try MetadataCalendarNamespaceGate.validate(binding)
        try requireNamespace(binding.snapshot.compatibility.protocolVersion)
        try MetadataCalendarNamespaceGate.validate(job.metadataAutomation ?? MetadataAutomation(), for: binding.snapshot.compatibility.protocolVersion)
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
        guard !isPaused else { throw CancellationError() }
        guard let store, let job = store.jobs.first(where: { $0.id == binding.jobID }) else {
            throw MetadataSyncFailure(message: "The linked local job no longer exists.")
        }
        try MetadataCalendarNamespaceGate.validate(binding)
        try validateDocument(document, for: binding.snapshot.compatibility.protocolVersion)
        try MetadataCalendarNamespaceGate.validate(job.metadataAutomation ?? MetadataAutomation(), for: binding.snapshot.compatibility.protocolVersion)
        let incoming = binding.publicationRange == nil ? document : document.restricted(to: binding.publicationRange, timeZone: binding.snapshot.timeZone)
        let automation = try incoming.applying(to: job.metadataAutomation ?? MetadataAutomation(), replacing: binding.snapshot.document,
                                              range: binding.range, timeZone: binding.snapshot.timeZone)
        guard store.applySyncedMetadataAutomation(automation, for: job.id, protocolVersion: binding.snapshot.compatibility.protocolVersion) else {
            throw MetadataSyncFailure(message: "Received metadata could not be saved. Sync will retry; the previous baseline is retained.")
        }
    }

    private func validateRemote(_ remote: SharedMetadataCalendar, for binding: MetadataCalendarBinding) throws {
        guard remote.id == binding.id, remote.compatibility == binding.snapshot.compatibility else {
            throw MetadataSyncServerError.invalidResponse
        }
        try MetadataCalendarNamespaceGate.validate(remote)
        try MetadataCalendarNamespaceGate.validate(binding)
        try requireNamespace(remote.compatibility.protocolVersion)
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
        let previous = activities[original.jobID]
        do {
            try await syncOnce(original, account: account)
            if activities[original.jobID]?.phase == .current, message == previous?.detail { message = "" }
            if activities[original.jobID]?.phase == .current,
               previous?.lastSuccess == nil || previous?.phase == .failed || previous?.phase == .offline || original.snapshot != binding(for: original.jobID)?.snapshot {
                record(MetadataSyncEvent(jobID: original.jobID, operation: "Calendar sync", detail: "Local and server calendars are up to date.", revision: binding(for: original.jobID)?.snapshot.revision))
            }
        } catch {
            setFailureActivity(error, jobID: original.jobID)
            // The request already recorded this network failure. A second event
            // both exaggerates the incident and prevents repeated-event coalescing.
            if !Self.isConnectionError(error) {
                record(MetadataSyncEvent(jobID: original.jobID, operation: "Calendar sync", detail: MetadataSyncEvent.errorDetail(error), isError: true))
            }
            throw error
        }
    }

    private func syncOnce(_ original: MetadataCalendarBinding, account: MetadataSyncAccount) async throws {
        var binding = original
        var get = MetadataCalendarRequest(action: binding.snapshot.revision == 0 ? "createCalendar" : "getCalendar", calendarID: binding.id)
        if binding.snapshot.revision == 0 {
            get.name = binding.snapshot.name; get.timeZone = binding.snapshot.timeZone; get.document = binding.snapshot.document
        }
        guard var remote = try await request(get, account: account).calendar else { throw MetadataSyncServerError.invalidResponse }
        for _ in 0..<3 {
            try validateRemote(remote, for: binding)
            guard store?.metadataDraftsBeingEdited.contains(binding.jobID) != true else {
                setActivity(.paused, jobID: binding.jobID, detail: "Waiting for the open metadata draft to be saved. Fix any validation warning in the editor to resume sync.")
                return
            }
            // Read the latest job after every suspension; never overwrite edits made during a request.
            let local = try localDocument(binding)
            let merged: SharedMetadataDocument
            do { merged = try SharedMetadataDocument.merge(base: binding.snapshot.document, local: local, remote: remote.document) }
            catch {
                binding.conflict = remote
                try replace(binding)
                setActivity(.conflict, jobID: binding.jobID, detail: error.localizedDescription)
                record(MetadataSyncEvent(jobID: binding.jobID, operation: "Merge calendar", detail: "Competing edits require conflict resolution. Both versions are retained.", isError: true))
                return
            }
            if merged != remote.document && remote.role == "reader" {
                binding.conflict = remote; try replace(binding)
                setActivity(.conflict, jobID: binding.jobID, detail: "This calendar is read-only. Local changes have been retained.")
                return
            }
            // Save the merge locally first. The job is the durable queue for offline changes.
            try apply(merged, binding: binding)
            binding.snapshot = remote
            try replace(binding)
            if merged == remote.document {
                setActivity(.current, jobID: binding.jobID, detail: "Up to date · revision \(remote.revision)")
                return
            }
            var put = MetadataCalendarRequest(action: "putCalendar", calendarID: binding.id, document: merged, expectedRevision: remote.revision)
            if binding.snapshot.compatibility.protocolVersion == .templates {
                put.templateDeactivations = try MetadataTemplateDeactivation.required(from: remote.document, to: merged)
            }
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
        setActivity(.waiting, jobID: binding.jobID, detail: "New changes arrived during sync; retrying shortly.")
    }

    func publish(jobID: UUID, name: String, range: MetadataSharingRange?, protocolVersion: MetadataCalendarProtocol = .legacy) {
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
            try self.validateBindings()
            try self.requireNamespace(protocolVersion)
            try MetadataCalendarNamespaceGate.validate(job.metadataAutomation ?? MetadataAutomation(), for: protocolVersion)
            let zone = TimeZone.current.identifier
            let document = try SharedMetadataDocument(job.metadataAutomation ?? MetadataAutomation()).restricted(to: range, timeZone: zone).validated()
            let snapshot = SharedMetadataCalendar(id: UUID(), name: name, timeZone: zone, revision: 0, role: "owner", document: document, compatibility: protocolVersion == .templates ? .templates : .legacy)
            let binding = MetadataCalendarBinding(accountID: account.id, jobID: jobID, snapshot: snapshot, publicationRange: range)
            try self.replace(binding)
            try await self.sync(binding, account: account)
            self.discoveryProtocol = protocolVersion
            try await self.loadCalendars()
            self.message = "Calendar linked. Saved metadata edits sync while the app is running."
        }
    }

    func attach(calendarID: UUID, jobID: UUID, protocolVersion: MetadataCalendarProtocol = .legacy) {
        perform {
            self.message = ""
            guard self.state.pendingReceive == nil else {
                throw MetadataSyncFailure(message: "Finish or cancel the pending receive before linking another calendar.")
            }
            guard let account = self.account, account.registered,
                  !self.state.bindings.contains(where: { $0.id == calendarID && $0.accountID == account.id }) else {
                throw MetadataSyncFailure(message: "Choose a connected server and a calendar that is not already linked on this Mac.")
            }
            try self.requireNamespace(protocolVersion)
            if let automation = self.store?.jobs.first(where: { $0.id == jobID })?.metadataAutomation {
                try MetadataCalendarNamespaceGate.validate(automation, for: protocolVersion)
            }
            guard let remote = try await self.request(MetadataCalendarRequest(action: "getCalendar", calendarID: calendarID), account: account, protocolVersion: protocolVersion).calendar,
                  let store = self.store, let job = store.jobs.first(where: { $0.id == jobID }) else {
                throw MetadataSyncServerError.invalidResponse
            }
            guard !store.metadataDraftsBeingEdited.contains(jobID) else {
                throw MetadataSyncFailure(message: "Save or close this job's open metadata draft before receiving a calendar.")
            }
            try MetadataCalendarNamespaceGate.validate(job.metadataAutomation ?? MetadataAutomation(), for: protocolVersion)
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
                if copy.metadataAutomation?.hasActivatedTemplates == true, copy.metadataProcessingTimeZoneIdentifier == nil {
                    copy.metadataProcessingTimeZoneIdentifier = TimeZone.current.identifier
                }
                try copy.validateMetadataTemplateActivationContext()
                self.receiveProposal = MetadataCalendarReceiveProposal(accountID: account.id, source: job, duplicate: copy, calendar: remote)
                return
            }
            // A blank baseline makes the first pull recoverable if persistence or the app is interrupted.
            var baseline = remote; baseline.document = SharedMetadataDocument(MetadataAutomation())
            let binding = MetadataCalendarBinding(accountID: account.id, jobID: jobID, snapshot: baseline)
            try self.replace(binding)
            try await self.sync(binding, account: account)
            self.receivedJobID = jobID
            store.selectedJobID = jobID
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
            try self.validateBindings()
            try self.requireNamespace(proposal.calendar.compatibility.protocolVersion)
            try MetadataCalendarNamespaceGate.validate(proposal)
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
        guard !isPaused else { throw CancellationError() }
        guard let store else { throw MetadataSyncFailure(message: "The job store is unavailable.") }
        try validateBindings()
        try requireNamespace(proposal.calendar.compatibility.protocolVersion)
        try MetadataCalendarNamespaceGate.validate(proposal)
        if let current = store.jobs.first(where: { $0.id == proposal.source.id })?.metadataAutomation {
            try MetadataCalendarNamespaceGate.validate(current, for: proposal.calendar.compatibility.protocolVersion)
        }
        if let current = store.jobs.first(where: { $0.id == proposal.duplicate.id })?.metadataAutomation {
            try MetadataCalendarNamespaceGate.validate(current, for: proposal.calendar.compatibility.protocolVersion)
        }
        _ = try store.installCalendarReceiveCopy(source: proposal.source, duplicate: proposal.duplicate)
        var next = state
        next.bindings.removeAll { $0.id == proposal.calendar.id && $0.accountID == proposal.accountID }
        next.bindings.append(MetadataCalendarBinding(accountID: proposal.accountID, jobID: proposal.duplicate.id, snapshot: proposal.calendar))
        next.pendingReceive = nil
        try persist(next)
        receivedJobID = proposal.duplicate.id
        store.selectedJobID = proposal.duplicate.id
        setActivity(.waiting, jobID: proposal.duplicate.id, detail: "Calendar received. Checking for newer changes shortly.")
        record(MetadataSyncEvent(jobID: proposal.duplicate.id, operation: "Receive calendar", detail: "Calendar linked to a paused copy of the local job.", revision: proposal.calendar.revision))
        message = "Received into “\(proposal.duplicate.name)”. The original calendar is preserved. Automatic running and launch startup are off for both jobs; review the copy and enable it when ready."
    }

    func retryPendingReceive() {
        perform {
            if let pending = self.state.pendingReceive { try self.finishReceive(pending) }
        }
    }

    func cancelPendingReceive() {
        guard !busy, !isPaused else { return }
        do {
            var next = state; next.pendingReceive = nil
            try persist(next)
            message = "Pending link cancelled. Any jobs already saved are retained."
        } catch { message = error.localizedDescription }
    }

    func detach(_ binding: MetadataCalendarBinding) {
        guard !busy, !isPaused else { return }
        do {
            var next = state
            next.bindings.removeAll { $0.id == binding.id && $0.accountID == binding.accountID }
            try persist(next)
            activities.removeValue(forKey: binding.jobID)
            record(MetadataSyncEvent(jobID: binding.jobID, operation: "Detach calendar", detail: "Sync stopped; local programming retained."))
            message = "Calendar detached. Local programming and server access are retained."
        } catch { message = error.localizedDescription }
    }

    func conflictReview(_ binding: MetadataCalendarBinding) throws -> MetadataCalendarConflictReview {
        guard state.bindings.contains(binding), let remote = binding.conflict else {
            throw MetadataSyncFailure(message: "This conflict changed. Open its current review again.")
        }
        guard store?.metadataDraftsBeingEdited.contains(binding.jobID) != true else {
            throw MetadataSyncFailure(message: "Save the open metadata draft before reviewing conflicts.")
        }
        return MetadataCalendarConflictReview(binding: binding, local: try localDocument(binding), remote: remote)
    }

    func resolve(_ review: MetadataCalendarConflictReview, choices: [String: MetadataConflictChoice]) {
        perform {
            do { try await self.resolveReview(review, choices: choices) }
            catch {
                if self.binding(for: review.binding.jobID)?.conflict != nil {
                    self.setActivity(.conflict, jobID: review.binding.jobID, detail: error.localizedDescription)
                } else {
                    self.setFailureActivity(error, jobID: review.binding.jobID)
                }
                throw error
            }
        }
    }

    private func resolveReview(_ review: MetadataCalendarConflictReview, choices: [String: MetadataConflictChoice]) async throws {
        let original = review.binding
        guard state.bindings.contains(original), store?.metadataDraftsBeingEdited.contains(original.jobID) != true,
              try localDocument(original) == review.local else {
            throw MetadataSyncFailure(message: "The local calendar changed. Refresh the conflict review before applying your choices.")
        }
        guard let account = state.accounts.first(where: { $0.id == original.accountID }),
              let current = try await request(MetadataCalendarRequest(action: "getCalendar", calendarID: original.id), account: account).calendar else {
            throw MetadataSyncServerError.invalidResponse
        }
        try validateRemote(current, for: original)
        guard state.bindings.contains(original) else {
            throw MetadataSyncFailure(message: "The calendar link changed. Open its current conflict review again.")
        }
        guard current == review.remote else {
            var updated = original; updated.conflict = current; try replace(updated)
            throw MetadataSyncFailure(message: "The server changed again. Refresh the conflict review before applying your choices.")
        }
        guard try localDocument(original) == review.local,
              store?.metadataDraftsBeingEdited.contains(original.jobID) != true else {
            throw MetadataSyncFailure(message: "The local calendar changed. Refresh the conflict review before applying your choices.")
        }
        let resolved = try review.plan(choices: choices).resolved()
        if current.role == "reader", resolved != current.document {
            throw MetadataSyncFailure(message: "This calendar is read-only. Choose the server values for local changes.")
        }
        var binding = original
        // The job remains the durable queue; only the reviewed conflicts are resolved.
        try apply(resolved, binding: binding)
        binding.snapshot = current; binding.conflict = nil
        try replace(binding)
        record(MetadataSyncEvent(jobID: binding.jobID, operation: "Resolve conflicts", detail: "Selected conflicts resolved; independent changes retained."))
        try await sync(binding, account: account)
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
