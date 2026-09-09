import Foundation

enum MetadataConflictChoice: String, Sendable { case local, server }

struct MetadataCalendarConflict: Identifiable, Sendable {
    let id: String
    let title: String
    var local: String
    var server: String
}

struct MetadataCalendarMergePlan: Sendable {
    var document: SharedMetadataDocument
    var conflicts: [MetadataCalendarConflict]
    var validationMessage: String?
    var unresolvedCount: Int

    func resolved() throws -> SharedMetadataDocument {
        guard unresolvedCount == 0 else {
            throw MetadataSyncFailure(message: "Choose a resolution for each conflicting clip or calendar item.")
        }
        return try document.validated()
    }
}

struct MetadataCalendarConflictReview: Identifiable {
    var id: UUID { binding.id }
    let binding: MetadataCalendarBinding
    let local: SharedMetadataDocument
    let remote: SharedMetadataCalendar

    func plan(choices: [String: MetadataConflictChoice] = [:]) throws -> MetadataCalendarMergePlan {
        try MetadataCalendarMerge.plan(base: binding.snapshot.document, local: local, remote: remote.document,
                                      choices: choices, readOnly: remote.role == "reader")
    }
}

/// Conflict choices apply only to the conflicting values. Every plan is rebuilt
/// from the three immutable snapshots, never from a partially resolved preview.
enum MetadataCalendarMerge {
    static func plan(base: SharedMetadataDocument, local: SharedMetadataDocument, remote: SharedMetadataDocument,
                     choices: [String: MetadataConflictChoice] = [:], readOnly: Bool = false) throws -> MetadataCalendarMergePlan {
        let base = try base.validated(), local = try local.validated(), remote = try remote.validated()
        var builder = Builder(choices: choices, readOnly: readOnly)
        var merged = local
        merged.photographers = builder.records(base.photographers, local.photographers, remote.photographers,
            id: \.id, kind: "photographer", title: { $0.photographerName }, summary: { "\($0.photographerName) · \($0.filenamePrefix)" }) { b, l, r, key, title, builder in
                var p = l
                p.name = builder.value(b.name, l.name, r.name, key: key, title: title, field: "Name")
                p.creator = builder.value(b.creator, l.creator, r.creator, key: key, title: title, field: "Creator")
                p.filenamePrefix = builder.value(b.filenamePrefix, l.filenamePrefix, r.filenamePrefix, key: key, title: title, field: "Initials")
                p.copyrightNotice = builder.value(b.copyrightNotice, l.copyrightNotice, r.copyrightNotice, key: key, title: title, field: "Copyright")
                return p
            }
        merged.clips = builder.records(base.clips, local.clips, remote.clips, id: \.id, kind: "clip", title: { "\($0.name) · \($0.startsAt.formatted(date: .abbreviated, time: .shortened))" }, summary: { clipSummary($0, photographers: local.photographers + remote.photographers + base.photographers) }) { b, l, r, key, title, builder in
            var c = l
            c.name = builder.value(b.name, l.name, r.name, key: key, title: title, field: "Name")
            c.photographerID = builder.value(b.photographerID, l.photographerID, r.photographerID, key: key, title: title, field: "Photographer", describe: { id in
                (local.photographers + remote.photographers + base.photographers).first { $0.id == id }?.photographerName ?? "Removed photographer"
            })
            let time = builder.value([b.startsAt, b.endsAt], [l.startsAt, l.endsAt], [r.startsAt, r.endsAt],
                key: key, title: title, field: "Time", describe: { $0.map { $0.formatted() }.joined(separator: " – ") })
            c.startsAt = time[0]; c.endsAt = time[1]
            c.fields.headline = builder.value(b.fields.headline, l.fields.headline, r.fields.headline, key: key, title: title, field: "Headline")
            c.fields.description = builder.value(b.fields.description, l.fields.description, r.fields.description, key: key, title: title, field: "Description")
            c.fields.keywords = builder.value(b.fields.keywords, l.fields.keywords, r.fields.keywords, key: key, title: title, field: "Keywords", describe: { $0.joined(separator: ", ") })
            c.gpsPosition = builder.value(b.gpsPosition, l.gpsPosition, r.gpsPosition, key: key, title: title, field: "Location", describe: { gps in
                gps.map { "\($0.label ?? "") · \($0.latitude), \($0.longitude)" + ($0.altitudeMeters.map { " · \($0) m" } ?? "") } ?? "No location"
            })
            return c
        }
        let b = Dictionary(grouping: base.photographerTracks, by: \.date)
        let l = Dictionary(grouping: local.photographerTracks, by: \.date)
        let r = Dictionary(grouping: remote.photographerTracks, by: \.date)
        merged.photographerTracks = Set(b.keys).union(l.keys).union(r.keys).sorted().flatMap { date in
            builder.value(b[date] ?? [], l[date] ?? [], r[date] ?? [], key: "rows/\(date.year)-\(date.month)-\(date.day)",
                title: "Photographer rows · \(date.year)-\(date.month)-\(date.day)", field: "Order", describe: { tracks in
                    tracks.map { track in (local.photographers + remote.photographers).first { $0.id == track.photographerID }?.photographerName ?? "Removed photographer" }.joined(separator: ", ")
                })
        }

        // Independent edits can produce overlapping clips. Resolve only scheduling
        // for the affected group; independently merged text and GPS stay intact.
        for group in schedulingConflictGroups(merged.clips, local: local.clips, remote: remote.clips) {
            let ids = Set(group.map(\.id))
            let key = "overlap/" + ids.map(\.uuidString).sorted().joined(separator: "/")
            let localClips = local.clips.filter { ids.contains($0.id) }
            let remoteClips = remote.clips.filter { ids.contains($0.id) }
            let choice = builder.conflict(key: key, title: "Overlapping clips: " + group.map(\.name).joined(separator: ", "),
                local: scheduleSummary(group: group, side: localClips), server: scheduleSummary(group: group, side: remoteClips))
            let selected = choice == .local ? localClips : remoteClips
            merged.clips = merged.clips.compactMap { clip in
                guard ids.contains(clip.id) else { return clip }
                guard let schedule = selected.first(where: { $0.id == clip.id }) else { return nil }
                var result = clip
                result.photographerID = schedule.photographerID
                result.startsAt = schedule.startsAt; result.endsAt = schedule.endsAt
                return result
            }
        }

        // A photographer removed on one Mac may still be required by a clip or row
        // added on another. Offer retention or removal of just that dependency.
        let required = Set(merged.clips.map(\.photographerID) + merged.photographerTracks.map(\.photographerID))
        let present = Set(merged.photographers.map(\.id))
        for id in required.subtracting(present).sorted(by: { $0.uuidString < $1.uuidString }) {
            let lp = local.photographers.first { $0.id == id }, rp = remote.photographers.first { $0.id == id }
            let name = (lp ?? rp)?.photographerName ?? "Photographer"
            let choice = builder.conflict(key: "reference/" + id.uuidString, title: "\(name): deletion conflicts with programming",
                local: lp == nil ? "Remove photographer and their clips and rows" : "Keep photographer and merged programming",
                server: rp == nil ? "Remove photographer and their clips and rows" : "Keep photographer and merged programming")
            if let profile = choice == .local ? lp : rp { merged.photographers.append(profile) }
            else {
                merged.clips.removeAll { $0.photographerID == id }
                merged.photographerTracks.removeAll { $0.photographerID == id }
            }
        }
        merged = SharedMetadataDocument(merged.automation)
        return MetadataCalendarMergePlan(document: merged, conflicts: builder.conflicts,
                                         validationMessage: merged.automation.validationMessage,
                                         unresolvedCount: builder.conflicts.filter { choices[$0.id] == nil || (readOnly && choices[$0.id] != .server) }.count)
    }

    private static func clipSummary(_ clip: MetadataScheduleClip, photographers: [PhotographerProfile]) -> String {
        let photographer = photographers.first { $0.id == clip.photographerID }?.photographerName ?? "Removed photographer"
        var summary = "\(clip.name) · \(photographer)\n\(clip.startsAt.formatted()) – \(clip.endsAt.formatted())\nHeadline: \(clip.fields.headline)\nDescription: \(clip.fields.description)\nKeywords: \(clip.fields.keywords.joined(separator: ", "))"
        if let gps = clip.gpsPosition {
            summary += "\nLocation: \(gps.label ?? "") · \(gps.latitude), \(gps.longitude)"
            if let altitude = gps.altitudeMeters { summary += " · \(altitude) m" }
        }
        return summary
    }

    private static func scheduleSummary(group: [MetadataScheduleClip], side: [MetadataScheduleClip]) -> String {
        group.map { clip in
            if let value = side.first(where: { $0.id == clip.id }) {
                return "\(clip.name): \(value.startsAt.formatted()) – \(value.endsAt.formatted())"
            }
            return "\(clip.name): not present (remove this clip)"
        }.joined(separator: "\n")
    }

    /// Expand each overlap to include schedules that either choice could affect.
    /// This prevents resolving one pair from creating another overlap just outside it.
    private static func schedulingConflictGroups(_ clips: [MetadataScheduleClip], local: [MetadataScheduleClip], remote: [MetadataScheduleClip]) -> [[MetadataScheduleClip]] {
        var groups = overlapGroups(clips).map { Set($0.map(\.id)) }
        var changed = true
        while changed {
            changed = false
            for index in groups.indices {
                let schedules = (local + remote).filter { groups[index].contains($0.id) }
                for clip in clips where !groups[index].contains(clip.id) {
                    if schedules.contains(where: { $0.photographerID == clip.photographerID && $0.startsAt < clip.endsAt && clip.startsAt < $0.endsAt }) {
                        groups[index].insert(clip.id)
                        changed = true
                    }
                }
            }
            var united: [Set<UUID>] = []
            for var group in groups {
                let touching = united.indices.filter { !united[$0].isDisjoint(with: group) }
                for index in touching.reversed() { group.formUnion(united.remove(at: index)); changed = true }
                united.append(group)
            }
            groups = united
        }
        return groups.map { ids in clips.filter { ids.contains($0.id) } }
    }

    private static func overlapGroups(_ clips: [MetadataScheduleClip]) -> [[MetadataScheduleClip]] {
        var result: [[MetadataScheduleClip]] = []
        for (_, clips) in Dictionary(grouping: clips, by: \.photographerID).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            var group: [MetadataScheduleClip] = []
            var end = Date.distantPast
            for clip in clips.sorted(by: { $0.startsAt == $1.startsAt ? $0.id.uuidString < $1.id.uuidString : $0.startsAt < $1.startsAt }) {
                if clip.startsAt >= end {
                    if group.count > 1 { result.append(group) }
                    group = []; end = .distantPast
                }
                group.append(clip); end = max(end, clip.endsAt)
            }
            if group.count > 1 { result.append(group) }
        }
        return result
    }

    private struct Builder {
        let choices: [String: MetadataConflictChoice]
        let readOnly: Bool
        var conflicts: [MetadataCalendarConflict] = []

        mutating func conflict(key: String, title: String, local: String, server: String) -> MetadataConflictChoice {
            if let index = conflicts.firstIndex(where: { $0.id == key }) {
                conflicts[index].local += "\n\n" + local
                conflicts[index].server += "\n\n" + server
            } else { conflicts.append(MetadataCalendarConflict(id: key, title: title, local: local, server: server)) }
            return choices[key] ?? (readOnly ? .server : .local)
        }

        mutating func value<T: Equatable>(_ base: T, _ local: T, _ remote: T, key: String, title: String, field: String,
                                         describe: (T) -> String = { String(describing: $0) }) -> T {
            if local == base || local == remote { return remote }
            if remote == base && !readOnly { return local }
            return conflict(key: key, title: title, local: field + ": " + describe(local), server: field + ": " + describe(remote)) == .local ? local : remote
        }

        mutating func records<T: Equatable>(_ base: [T], _ local: [T], _ remote: [T], id: KeyPath<T, UUID>, kind: String,
            title: (T) -> String, summary: (T) -> String,
            fields: (T, T, T, String, String, inout Builder) -> T) -> [T] {
            // Inputs are validated before indexing, so duplicate UUIDs cannot trap.
            let b = Dictionary(uniqueKeysWithValues: base.map { ($0[keyPath: id], $0) })
            let l = Dictionary(uniqueKeysWithValues: local.map { ($0[keyPath: id], $0) })
            let r = Dictionary(uniqueKeysWithValues: remote.map { ($0[keyPath: id], $0) })
            return Set(b.keys).union(l.keys).union(r.keys).sorted(by: { $0.uuidString < $1.uuidString }).compactMap { id in
                let bv = b[id], lv = l[id], rv = r[id]
                if lv == bv || lv == rv { return rv }
                let key = kind + "/" + id.uuidString
                let label = kind.capitalized + ": " + title(lv ?? rv ?? bv!)
                if let bv, let lv, let rv { return fields(bv, lv, rv, key, label, &self) }
                if rv == bv && !readOnly { return lv }
                return conflict(key: key, title: label, local: lv.map(summary) ?? "Deleted",
                                server: rv.map(summary) ?? "Deleted") == .local ? lv : rv
            }
        }
    }
}
