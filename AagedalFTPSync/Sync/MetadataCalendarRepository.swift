import Foundation
import Darwin

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
    var pendingMigrations: [MetadataCalendarMigrationJournal] = []
}

extension MetadataCalendarState {
    private enum CodingKeys: String, CodingKey { case accounts, activeAccountID, bindings, pendingReceive, pendingMigrations }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try values.decode([MetadataSyncAccount].self, forKey: .accounts)
        activeAccountID = try values.decodeIfPresent(UUID.self, forKey: .activeAccountID)
        bindings = try values.decode([MetadataCalendarBinding].self, forKey: .bindings)
        pendingReceive = try values.decodeIfPresent(MetadataCalendarReceiveProposal.self, forKey: .pendingReceive)
        if values.contains(.pendingMigrations) {
            do {
                pendingMigrations = try values.decode([MetadataCalendarMigrationJournal].self, forKey: .pendingMigrations)
                try validateMigrationJournals()
            } catch { throw MetadataTemplateRecordError.invalidSource }
        }
    }

    func encode(to encoder: Encoder) throws {
        try validateMigrationJournals()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accounts, forKey: .accounts)
        try values.encodeIfPresent(activeAccountID, forKey: .activeAccountID)
        try values.encode(bindings, forKey: .bindings)
        try values.encodeIfPresent(pendingReceive, forKey: .pendingReceive)
        if !pendingMigrations.isEmpty { try values.encode(pendingMigrations, forKey: .pendingMigrations) }
    }

    /// Pending creation freezes the old binding and endpoint. This foundation
    /// deliberately does not yet admit a rebind or a protocol-3 live binding.
    func validateMigrationJournals() throws {
        guard !pendingMigrations.isEmpty else { return }
        guard Set(accounts.map(\.id)).count == accounts.count,
              Set(pendingMigrations.map(\.destinationID)).count == pendingMigrations.count,
              Set(pendingMigrations.map { $0.source.jobID }).count == pendingMigrations.count else {
            throw MetadataTemplateRecordError.invalidSource
        }
        for journal in pendingMigrations {
            try journal.validate()
            guard journal.phase != .bindingCommitted,
                  bindings.filter({ $0.jobID == journal.source.jobID }) == [journal.source],
                  let account = accounts.first(where: { $0.id == journal.source.accountID }),
                  try MetadataSyncServer(address: account.address).baseURL.absoluteString == journal.serverAddress,
                  !bindings.contains(where: { $0.id == journal.destinationID }),
                  pendingReceive?.calendar.id != journal.destinationID,
                  pendingReceive?.source.id != journal.source.jobID,
                  pendingReceive?.duplicate.id != journal.source.jobID else {
                throw MetadataTemplateRecordError.invalidSource
            }
        }
    }
}

struct MetadataCalendarRepository {
    var url: URL
    let storageFormat: AppStorageFormat
    private var codec: VersionedStoreCodec { VersionedStoreCodec(format: storageFormat, store: .metadataCalendar) }
    private let beforeSave: @Sendable () throws -> Void
    init(url: URL? = nil, storage: AppStorageLayout = .legacy, beforeSave: @escaping @Sendable () throws -> Void = {}) {
        self.beforeSave = beforeSave
        self.url = url ?? storage.metadataCalendar
        self.storageFormat = storage.storageFormat
    }
    /// Keep events beside an explicitly injected calendar file, including custom filenames.
    var eventsURL: URL { AppStorageLayout(root: url.deletingLastPathComponent()).metadataSyncEvents }

    func load() throws -> MetadataCalendarState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try codec.validateExistingStore(at: url)
            return MetadataCalendarState()
        }
        let state = try codec.decode(MetadataCalendarState.self, from: Data(contentsOf: url), decoder: MetadataCalendarClient.decoder())
        try validate(state)
        return state
    }
    func save(_ state: MetadataCalendarState, replacingMigrations expected: [MetadataCalendarMigrationJournal]? = nil) throws {
        try validate(state)
        try codec.validateExistingStore(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Serialize read/compare/write across cooperating processes. Keep the
        // lock inode in place: unlinking it could split waiting writers.
        let descriptor: Int32
        if storageFormat == .version3 {
            descriptor = open(url.path + ".migration-lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw MetadataTemplateRecordError.invalidSource }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw MetadataSyncFailure(message: "Calendar state is being saved by another process. Retry after it finishes.", diagnosticCode: "migration_store_busy")
            }
        } else { descriptor = -1 }
        defer {
            if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        }
        try codec.validateExistingStore(at: url)
        var existingMigrations: [MetadataCalendarMigrationJournal] = []
        var existingState: MetadataCalendarState?
        if let bytes = try? Data(contentsOf: url),
           let existing = try? codec.decode(MetadataCalendarState.self, from: bytes, decoder: MetadataCalendarClient.decoder()) {
            // A cached literal in-memory state cannot overwrite a subsequently
            // installed active protocol-incompatible snapshot.
            try validate(existing)
            existingMigrations = existing.pendingMigrations
            existingState = existing
        }
        // Ordinary saves may preserve journals but cannot initiate, erase or
        // advance them. A migration writer must supply its exact prior snapshot.
        guard existingMigrations == (expected ?? state.pendingMigrations) else {
            throw MetadataSyncFailure(message: "Calendar migration state changed. Reload it before saving.", diagnosticCode: "migration_state_changed")
        }
        if expected != nil {
            try validateTransition(from: existingMigrations, to: state.pendingMigrations)
            for added in state.pendingMigrations where !existingMigrations.contains(where: { $0.destinationID == added.destinationID }) {
                guard let existingState,
                      existingState.bindings.filter({ $0.jobID == added.source.jobID }) == [added.source],
                      let account = existingState.accounts.first(where: { $0.id == added.source.accountID }),
                      try MetadataSyncServer(address: account.address).baseURL.absoluteString == added.serverAddress else {
                    throw MetadataTemplateRecordError.invalidSource
                }
            }
        }
        try beforeSave()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try codec.encode(state, encoder: MetadataCalendarClient.encoder()).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validate(_ state: MetadataCalendarState) throws {
        try state.validateMigrationJournals()
        if storageFormat == .legacy, !state.pendingMigrations.isEmpty { throw VersionedStoreCodec.HeaderError.requiresVersion3Storage }
        var legacy = state
        legacy.pendingMigrations = []
        try LegacyMetadataCalendarGate.validate(legacy)
    }

    private func validateTransition(from previous: [MetadataCalendarMigrationJournal], to proposed: [MetadataCalendarMigrationJournal]) throws {
        for old in previous {
            guard let next = proposed.first(where: { $0.destinationID == old.destinationID }),
                  old.source == next.source, old.serverAddress == next.serverAddress,
                  old.phase == .prepared || old == next else { throw MetadataTemplateRecordError.invalidSource }
        }
        for added in proposed where !previous.contains(where: { $0.destinationID == added.destinationID }) {
            guard added.phase == .prepared else { throw MetadataTemplateRecordError.invalidSource }
        }
    }
}
