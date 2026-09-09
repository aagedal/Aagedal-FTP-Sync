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
            PhotographerProfile(id: profile.id, name: profile.name, filenamePrefix: profile.filenamePrefix,
                                creator: profile.creator, copyrightNotice: profile.copyrightNotice)
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
}

struct MetadataCalendarMember: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var role: String
}
