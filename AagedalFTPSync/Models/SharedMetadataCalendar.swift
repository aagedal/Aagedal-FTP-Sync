import Foundation

struct MetadataSyncFailure: LocalizedError {
    let message: String
    var diagnosticCode: String? = nil
    var errorDescription: String? { message }
}

/// Explicit allowlist: never encode a SyncJob or its automation policies for transport.
struct SharedMetadataDocument: Codable, Equatable, Sendable {
    var photographers: [PhotographerProfile]
    var photographerTracks: [MetadataPhotographerTrack]
    var clips: [MetadataScheduleClip]

    init(_ automation: MetadataAutomation) {
        photographers = automation.photographers.map { profile in
            var shared = PhotographerProfile(id: profile.id, name: profile.name, filenamePrefix: profile.filenamePrefix,
                                creator: profile.creator, copyrightNotice: profile.copyrightNotice)
            shared.copyingCopyright(from: profile)
            return shared
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let rows = Dictionary(grouping: automation.photographerTracks, by: \.date)
        photographerTracks = rows.keys.sorted().flatMap { rows[$0] ?? [] }
        clips = automation.clips.map { clip in
            var clip = clip
            clip.startsAt = Self.millisecondDate(clip.startsAt)
            clip.endsAt = Self.millisecondDate(clip.endsAt)
            return clip
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func millisecondDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    var automation: MetadataAutomation {
        MetadataAutomation(photographers: photographers, photographerTracks: photographerTracks, clips: clips)
    }

    func validated() throws -> Self {
        guard Set(photographers.map(\.id)).count == photographers.count,
              Set(clips.map(\.id)).count == clips.count,
              Set(photographerTracks).count == photographerTracks.count,
              photographerTracks.allSatisfy({ track in photographers.contains { $0.id == track.photographerID } }),
              clips.allSatisfy({ $0.startsAt.timeIntervalSince1970.isFinite && $0.endsAt.timeIntervalSince1970.isFinite }) else {
            throw MetadataSyncFailure(message: "The shared calendar contains duplicate or invalid records.")
        }
        if let message = automation.validationMessage { throw MetadataSyncFailure(message: message) }
        return SharedMetadataDocument(automation)
    }

    func restricted(to range: MetadataSharingRange?, timeZone: String) -> Self {
        guard let range else { return self }
        var result = self
        result.clips = clips.filter { range.contains($0) }
        result.photographerTracks = photographerTracks.filter { range.contains($0, timeZone: timeZone) }
        let ids = Set(result.clips.map(\.photographerID) + result.photographerTracks.map(\.photographerID))
        result.photographers = photographers.filter { ids.contains($0.id) }
        return result
    }

    /// Three-way merge treats deletion as a value, so an offline edit cannot resurrect a deletion silently.
    static func merge(base: Self, local: Self, remote: Self) throws -> Self {
        try MetadataCalendarMerge.plan(base: base, local: local, remote: remote).resolved()
    }

    /// Keeps processing policies and private work hours on this Mac.
    func applying(to original: MetadataAutomation, replacing base: Self, range: MetadataSharingRange?, timeZone: String) throws -> MetadataAutomation {
        var result = original
        if let range {
            result.clips = original.clips.filter { !range.contains($0) } + clips
            result.photographerTracks = original.photographerTracks.filter { !range.contains($0, timeZone: timeZone) } + photographerTracks
            let replacedIDs = Set(base.photographers.map(\.id)).union(photographers.map(\.id))
            let requiredIDs = Set(result.clips.map(\.photographerID) + result.photographerTracks.map(\.photographerID))
            result.photographers = original.photographers.filter { !replacedIDs.contains($0.id) || requiredIDs.contains($0.id) }
            for profile in photographers {
                result.photographers.removeAll { $0.id == profile.id }
                result.photographers.append(profile)
            }
        } else {
            result.clips = clips
            result.photographerTracks = photographerTracks
            result.photographers = photographers
        }
        for index in result.photographers.indices {
            if let previous = original.photographers.first(where: { $0.id == result.photographers[index].id }) {
                result.photographers[index].workHours = previous.workHours
                result.photographers[index].workHourOverrides = previous.workHourOverrides
            }
        }
        // An empty remote calendar is valid even if local automatic processing was enabled.
        if result.clips.isEmpty || result.photographers.isEmpty { result.isEnabled = false }
        if let message = result.validationMessage { throw MetadataSyncFailure(message: message) }
        return result
    }
}

struct MetadataSharingRange: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    func contains(_ clip: MetadataScheduleClip) -> Bool { clip.startsAt >= start && clip.endsAt <= end }
    func contains(_ track: MetadataPhotographerTrack, timeZone: String) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        guard let date = track.date.date(calendar: calendar), let day = calendar.dateInterval(of: .day, for: date) else { return false }
        return day.start >= start && day.end <= end
    }
}

struct SharedMetadataCalendar: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var timeZone: String
    var revision: Int64
    var role: String
    var rangeStart: Date?
    var rangeEnd: Date?
    var document: SharedMetadataDocument
    var compatibility: MetadataCalendarCompatibility = .legacy
    var range: MetadataSharingRange? {
        guard let rangeStart, let rangeEnd else { return nil }
        return MetadataSharingRange(start: rangeStart, end: rangeEnd)
    }
}

struct MetadataCalendarSummary: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var timeZone: String
    var role: String
    var compatibility: MetadataCalendarCompatibility = .legacy
}

extension SharedMetadataCalendar {
    private enum CodingKeys: String, CodingKey {
        case id, name, timeZone, revision, role, rangeStart, rangeEnd, document
    }

    init(from decoder: Decoder) throws {
        compatibility = try MetadataCalendarCompatibility.decodeHeaders(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        timeZone = try values.decode(String.self, forKey: .timeZone)
        revision = try values.decode(Int64.self, forKey: .revision)
        role = try values.decode(String.self, forKey: .role)
        rangeStart = try values.decodeIfPresent(Date.self, forKey: .rangeStart)
        rangeEnd = try values.decodeIfPresent(Date.self, forKey: .rangeEnd)
        document = try values.decode(SharedMetadataDocument.self, forKey: .document)
    }

    func encode(to encoder: Encoder) throws {
        try compatibility.encodeHeaders(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(timeZone, forKey: .timeZone)
        try values.encode(revision, forKey: .revision)
        try values.encode(role, forKey: .role)
        try values.encodeIfPresent(rangeStart, forKey: .rangeStart)
        try values.encodeIfPresent(rangeEnd, forKey: .rangeEnd)
        try values.encode(document, forKey: .document)
    }

    func validateCompatibility(for selectedProtocol: MetadataCalendarProtocol) throws {
        guard compatibility.protocolVersion == selectedProtocol else {
            throw MetadataTemplateRecordError.invalidSource
        }
        if selectedProtocol == .legacy { try LegacyMetadataCalendarGate.validate(document) }
    }
}

extension MetadataCalendarSummary {
    private enum CodingKeys: String, CodingKey { case id, name, timeZone, role }
    init(from decoder: Decoder) throws {
        compatibility = try MetadataCalendarCompatibility.decodeHeaders(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        timeZone = try values.decode(String.self, forKey: .timeZone)
        role = try values.decode(String.self, forKey: .role)
    }
    func encode(to encoder: Encoder) throws {
        try compatibility.encodeHeaders(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(timeZone, forKey: .timeZone)
        try values.encode(role, forKey: .role)
    }
}

struct MetadataCalendarMember: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var role: String
}

/// Protocol 2 cannot preserve activation semantics. Keep this gate separate from
/// pure local document validation/merging so detached copies retain their pairs.
enum LegacyMetadataCalendarGate {
    static func validate(_ automation: MetadataAutomation) throws {
        guard !automation.photographers.contains(where: { $0.copyrightTemplateVersion != nil }),
              !automation.clips.contains(where: { !$0.fields.templateVersions.isEmpty }) else {
            throw MetadataSyncFailure(message: "Activated metadata templates cannot use this calendar sync protocol. Detach the calendar and keep activation in a local copy until compatible sharing is available.", diagnosticCode: "template_protocol_required")
        }
    }

    static func validate(_ document: SharedMetadataDocument) throws { try validate(document.automation) }

    static func validate(_ calendar: SharedMetadataCalendar) throws {
        // A literal document in the new namespace must never reopen via old routing.
        guard calendar.compatibility == .legacy else { throw MetadataTemplateRecordError.invalidSource }
        try validate(calendar.document)
    }

    static func validate(_ proposal: MetadataCalendarReceiveProposal) throws {
        try validate(proposal.calendar)
        if let source = proposal.source.metadataAutomation { try validate(source) }
        if let duplicate = proposal.duplicate.metadataAutomation { try validate(duplicate) }
    }

    static func validate(_ state: MetadataCalendarState) throws {
        guard state.pendingMigrations.isEmpty else {
            throw MetadataSyncFailure(message: "A calendar migration is pending. Live sync stays paused until migration recovery is available.", diagnosticCode: "migration_pending")
        }
        for binding in state.bindings {
            try validate(binding.snapshot)
            if let conflict = binding.conflict { try validate(conflict) }
        }
        if let pending = state.pendingReceive { try validate(pending) }
    }
}

/// Namespace-aware validation does not activate sync or choose a storage format.
/// Protocol 2 remains literal even inside a version-3 local store.
enum MetadataCalendarNamespaceGate {
    static func validate(_ automation: MetadataAutomation, for protocolVersion: MetadataCalendarProtocol) throws {
        if protocolVersion == .legacy { try LegacyMetadataCalendarGate.validate(automation); return }
        for profile in automation.photographers { _ = try profile.validatedCopyright }
        for clip in automation.clips {
            _ = try clip.fields.validatedHeadline
            _ = try clip.fields.validatedDescription
            _ = try clip.fields.validatedKeywords
            try validateDate(clip.startsAt, requireMilliseconds: false)
            try validateDate(clip.endsAt, requireMilliseconds: false)
        }
        _ = try SharedMetadataDocument(automation).validated()
    }

    static func validate(_ calendar: SharedMetadataCalendar) throws {
        if calendar.compatibility == .legacy { try LegacyMetadataCalendarGate.validate(calendar); return }
        guard calendar.compatibility == .templates, calendar.revision >= 0,
              ["owner", "editor", "reader"].contains(calendar.role),
              TimeZone(identifier: calendar.timeZone) != nil,
              !calendar.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (calendar.rangeStart == nil) == (calendar.rangeEnd == nil) else {
            throw MetadataTemplateRecordError.invalidSource
        }
        // A durable local create intent uses revision zero. Network responses
        // must still pass the client's positive-revision check before storage.
        if calendar.revision == 0 {
            guard calendar.role == "owner", calendar.rangeStart == nil, calendar.rangeEnd == nil else {
                throw MetadataTemplateRecordError.invalidSource
            }
        }
        if let start = calendar.rangeStart, let end = calendar.rangeEnd {
            try validateDate(start); try validateDate(end)
            guard start < end else { throw MetadataTemplateRecordError.invalidSource }
        }
        for clip in calendar.document.clips {
            try validateDate(clip.startsAt); try validateDate(clip.endsAt)
        }
        try validate(calendar.document.automation, for: .templates)
    }

    static func validate(_ binding: MetadataCalendarBinding) throws {
        try validate(binding.snapshot)
        if let range = binding.publicationRange {
            try validateDate(range.start); try validateDate(range.end)
            guard range.start < range.end else { throw MetadataTemplateRecordError.invalidSource }
        }
        if let conflict = binding.conflict {
            try validate(conflict)
            guard conflict.revision > 0, conflict.id == binding.snapshot.id,
                  conflict.compatibility == binding.snapshot.compatibility else {
                throw MetadataTemplateRecordError.invalidSource
            }
            if binding.snapshot.compatibility == .templates {
                guard conflict.timeZone == binding.snapshot.timeZone,
                      conflict.range == binding.snapshot.range,
                      conflict.revision >= binding.snapshot.revision else { throw MetadataTemplateRecordError.invalidSource }
            }
        }
    }

    static func validate(_ proposal: MetadataCalendarReceiveProposal) throws {
        try validate(proposal.calendar)
        if proposal.calendar.compatibility == .templates {
            guard proposal.calendar.revision > 0, proposal.source.id != proposal.duplicate.id else {
                throw MetadataTemplateRecordError.invalidSource
            }
        }
        if let source = proposal.source.metadataAutomation {
            try validate(source, for: proposal.calendar.compatibility.protocolVersion)
        }
        if let duplicate = proposal.duplicate.metadataAutomation {
            try validate(duplicate, for: proposal.calendar.compatibility.protocolVersion)
        }
    }

    static func validate(_ state: MetadataCalendarState) throws {
        for binding in state.bindings { try validate(binding) }
        if let proposal = state.pendingReceive { try validate(proposal) }
        for binding in state.bindings where binding.snapshot.compatibility == .templates {
            guard state.accounts.filter({ $0.id == binding.accountID }).count == 1 else {
                throw MetadataTemplateRecordError.invalidSource
            }
        }
        if let proposal = state.pendingReceive, proposal.calendar.compatibility == .templates {
            guard state.accounts.filter({ $0.id == proposal.accountID }).count == 1 else {
                throw MetadataTemplateRecordError.invalidSource
            }
        }
        // The same remote identity cannot be cached under different namespaces.
        var namespaces: [String: MetadataCalendarCompatibility] = [:]
        func register(_ snapshot: SharedMetadataCalendar, accountID: UUID) throws {
            let key = accountID.uuidString + "/" + snapshot.id.uuidString
            if let previous = namespaces[key], previous != snapshot.compatibility { throw MetadataTemplateRecordError.invalidSource }
            namespaces[key] = snapshot.compatibility
        }
        for binding in state.bindings { try register(binding.snapshot, accountID: binding.accountID) }
        if let proposal = state.pendingReceive { try register(proposal.calendar, accountID: proposal.accountID) }
        for receipt in state.pendingMigrations {
            try register(receipt.source.snapshot, accountID: receipt.source.accountID)
            try register(receipt.proposedSnapshot, accountID: receipt.source.accountID)
        }
    }

    private static func validateDate(_ date: Date, requireMilliseconds: Bool = true) throws {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds <= 4_102_444_800,
              !requireMilliseconds || date == Date(timeIntervalSince1970: (seconds * 1000).rounded() / 1000) else {
            throw MetadataTemplateRecordError.invalidSource
        }
    }
}
