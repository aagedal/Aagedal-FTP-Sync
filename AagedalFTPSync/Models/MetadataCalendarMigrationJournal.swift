import Foundation

/// A durable intent and recovery receipt, never a record of whether bytes reached
/// the server. The caller must persist each returned value before its next side
/// effect, review unsynced edits, verify capabilities, and retain the old binding
/// until the confirmed new snapshot can be committed atomically with the rebind.
struct MetadataCalendarMigrationJournal: Codable, Equatable, Identifiable {
    enum Phase: String, Codable { case prepared, serverConfirmed, bindingCommitted, bindingDetached, abandoned }
    enum RecoveryAction: Equatable {
        case fetchDestination
        case reconcileBinding
        case retainProvenance
    }

    let schemaVersion: Int
    let source: MetadataCalendarBinding
    let destinationID: UUID
    /// Canonical base URL; no credentials or invitations are copied into a journal.
    let serverAddress: String
    let phase: Phase
    let confirmedSnapshot: SharedMetadataCalendar?
    var id: UUID { destinationID }
    var isPending: Bool { phase == .prepared || phase == .serverConfirmed }
    var isArchived: Bool { phase == .bindingDetached || phase == .abandoned }

    /// This is a proposed create result, not evidence that the server created it.
    var proposedSnapshot: SharedMetadataCalendar {
        SharedMetadataCalendar(id: destinationID, name: source.snapshot.name,
            timeZone: source.snapshot.timeZone, revision: 1, role: "owner",
            document: source.snapshot.document, compatibility: .templates)
    }

    var recoveryAction: RecoveryAction {
        switch phase {
        case .prepared: .fetchDestination
        case .serverConfirmed: .reconcileBinding
        case .bindingCommitted, .bindingDetached, .abandoned: .retainProvenance
        }
    }

    init(source: MetadataCalendarBinding, destinationID: UUID, serverAddress: String) throws {
        self.schemaVersion = 1
        self.source = source
        self.destinationID = destinationID
        self.serverAddress = try MetadataSyncServer(address: serverAddress).baseURL.absoluteString
        self.phase = .prepared
        self.confirmedSnapshot = nil
        try validate()
    }

    private init(source: Self, phase: Phase, confirmedSnapshot: SharedMetadataCalendar?) throws {
        schemaVersion = source.schemaVersion
        self.source = source.source
        destinationID = source.destinationID
        serverAddress = source.serverAddress
        self.phase = phase
        self.confirmedSnapshot = confirmedSnapshot
        try validate()
    }

    /// An uncertain create must recover by fetching destinationID. A changed or
    /// unrelated result requires explicit recovery, rather than a replacement ID.
    func confirmCreated(_ snapshot: SharedMetadataCalendar) throws -> Self {
        try validate()
        guard isPending else { throw MetadataTemplateRecordError.invalidSource }
        return try Self(source: self, phase: .serverConfirmed, confirmedSnapshot: snapshot)
    }

    /// The caller may persist this receipt only together with the exact rebind.
    func markBindingCommitted(_ binding: MetadataCalendarBinding) throws -> Self {
        try validate()
        guard phase == .serverConfirmed || phase == .bindingCommitted, let confirmedSnapshot,
              binding.accountID == source.accountID, binding.jobID == source.jobID,
              binding.snapshot == confirmedSnapshot, binding.conflict == nil,
              binding.publicationRange == source.publicationRange else {
            throw MetadataTemplateRecordError.invalidSource
        }
        return try Self(source: self, phase: .bindingCommitted, confirmedSnapshot: confirmedSnapshot)
    }

    /// Persist atomically with removal of the destination binding. This keeps
    /// provenance without retaining the account or stopping later local work.
    func markBindingDetached() throws -> Self {
        try validate()
        guard phase == .bindingCommitted || phase == .bindingDetached, let confirmedSnapshot else {
            throw MetadataTemplateRecordError.invalidSource
        }
        return try Self(source: self, phase: .bindingDetached, confirmedSnapshot: confirmedSnapshot)
    }

    /// Stops local migration recovery without asserting that remote creation
    /// failed or deleting any remote calendar. Persist while retaining the old
    /// source binding; later ordinary account/job removal may keep this archive.
    func abandon() throws -> Self {
        try validate()
        guard isPending || phase == .abandoned else { throw MetadataTemplateRecordError.invalidSource }
        return try Self(source: self, phase: .abandoned, confirmedSnapshot: confirmedSnapshot)
    }

    func validate() throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard schemaVersion == 1,
              [source.accountID, source.jobID, source.snapshot.id, destinationID].allSatisfy({ $0 != zero }),
              destinationID != source.snapshot.id,
              try MetadataSyncServer(address: serverAddress).baseURL.absoluteString == serverAddress,
              source.conflict == nil, source.snapshot.compatibility == .legacy,
              source.snapshot.role == "owner", source.snapshot.revision > 0,
              source.snapshot.rangeStart == nil, source.snapshot.rangeEnd == nil,
              !source.snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TimeZone(identifier: source.snapshot.timeZone) != nil else {
            throw MetadataTemplateRecordError.invalidSource
        }
        try LegacyMetadataCalendarGate.validate(source.snapshot.document)
        // Bound dates before the existing wire encoder's integer conversion.
        for clip in source.snapshot.document.clips {
            try Self.validateDate(clip.startsAt); try Self.validateDate(clip.endsAt)
        }
        if let range = source.publicationRange {
            try Self.validateDate(range.start); try Self.validateDate(range.end)
            guard range.start < range.end else { throw MetadataTemplateRecordError.invalidSource }
        }
        _ = try source.snapshot.document.validated() // Validation only: never replace the unchanged baseline.
        switch phase {
        case .prepared:
            guard confirmedSnapshot == nil else { throw MetadataTemplateRecordError.invalidSource }
        case .serverConfirmed, .bindingCommitted, .bindingDetached:
            guard confirmedSnapshot == proposedSnapshot else { throw MetadataTemplateRecordError.invalidSource }
        case .abandoned:
            guard confirmedSnapshot == nil || confirmedSnapshot == proposedSnapshot else { throw MetadataTemplateRecordError.invalidSource }
        }
    }

    private static func validateDate(_ date: Date) throws {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds <= 4_102_444_800,
              date == Date(timeIntervalSince1970: (seconds * 1000).rounded() / 1000) else {
            throw MetadataTemplateRecordError.invalidSource
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, source, destinationID, serverAddress, phase, confirmedSnapshot }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        do {
            let keys = try decoder.container(keyedBy: Key.self)
            let known: Set<String> = ["schemaVersion", "source", "destinationID", "serverAddress", "phase", "confirmedSnapshot"]
            guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: known) else { throw MetadataTemplateRecordError.invalidSource }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 1 else { throw MetadataTemplateRecordError.invalidSource }
            phase = try values.decode(Phase.self, forKey: .phase)
            destinationID = try values.decode(UUID.self, forKey: .destinationID)
            serverAddress = try values.decode(String.self, forKey: .serverAddress)
            source = try values.decode(MetadataCalendarBinding.self, forKey: .source)
            // Absence is the only prepared representation; explicit null is not
            // accepted as a substitute for a receipt in any phase.
            confirmedSnapshot = values.contains(.confirmedSnapshot)
                ? try values.decode(SharedMetadataCalendar.self, forKey: .confirmedSnapshot) : nil
            try validate()
        } catch { throw MetadataTemplateRecordError.invalidSource }
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(source, forKey: .source)
        try values.encode(destinationID, forKey: .destinationID)
        try values.encode(serverAddress, forKey: .serverAddress)
        try values.encode(phase, forKey: .phase)
        try values.encodeIfPresent(confirmedSnapshot, forKey: .confirmedSnapshot)
    }
}
