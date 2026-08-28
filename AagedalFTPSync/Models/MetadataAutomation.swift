import Foundation

struct PhotographerProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var filenamePrefix: String
    var creator: String
    var copyrightNotice: String

    var normalizedPrefix: String {
        filenamePrefix.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func matches(relativePath: String) -> Bool {
        guard !normalizedPrefix.isEmpty else { return false }
        let filename = URL(fileURLWithPath: relativePath)
            .deletingPathExtension()
            .lastPathComponent
            .uppercased()
        return filename.hasPrefix(normalizedPrefix)
    }
}

struct ScheduledMetadataFields: Codable, Hashable, Sendable {
    var headline = ""
    var description = ""
    var keywords: [String] = []

    var normalizedKeywords: [String] {
        var seen = Set<String>()
        return keywords.compactMap { keyword in
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    var isEmpty: Bool {
        headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalizedKeywords.isEmpty
    }
}

struct MetadataScheduleClip: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var photographerID: UUID
    var name: String
    var startsAt: Date
    var endsAt: Date
    var fields = ScheduledMetadataFields()

    func contains(_ date: Date) -> Bool {
        startsAt <= date && date < endsAt
    }

    func overlaps(dayContaining date: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return startsAt < nextDay && endsAt > dayStart
    }
}

struct MetadataAssignment: Equatable, Sendable {
    let photographer: PhotographerProfile
    let clip: MetadataScheduleClip
}

struct MetadataAutomation: Codable, Hashable, Sendable {
    var isEnabled = false
    var photographers: [PhotographerProfile] = []
    var clips: [MetadataScheduleClip] = []

    func assignment(for relativePath: String, modifiedAt: Date) -> MetadataAssignment? {
        guard isEnabled else { return nil }

        let matchingPhotographers = photographers
            .filter { $0.matches(relativePath: relativePath) }
            .sorted {
                if $0.normalizedPrefix.count != $1.normalizedPrefix.count {
                    return $0.normalizedPrefix.count > $1.normalizedPrefix.count
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        for photographer in matchingPhotographers {
            if let clip = clips
                .filter({ $0.photographerID == photographer.id && $0.contains(modifiedAt) })
                .sorted(by: Self.preferredClip)
                .first {
                return MetadataAssignment(photographer: photographer, clip: clip)
            }
        }
        return nil
    }

    var validationMessage: String? {
        if isEnabled, photographers.isEmpty {
            return "Add at least one photographer before enabling automatic metadata."
        }

        let namedPhotographers = photographers.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.normalizedPrefix.isEmpty
        }
        if let photographer = namedPhotographers.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return "Give the photographer using prefix \(photographer.normalizedPrefix) a name."
        }
        if let photographer = namedPhotographers.first(where: { $0.normalizedPrefix.isEmpty }) {
            return "Give \(photographer.name) a filename prefix."
        }

        let groupedPrefixes = Dictionary(grouping: namedPhotographers, by: \PhotographerProfile.normalizedPrefix)
        if let duplicate = groupedPrefixes.first(where: { $0.value.count > 1 })?.key {
            return "The filename prefix \(duplicate) is assigned to more than one photographer."
        }
        if isEnabled, clips.isEmpty {
            return "Add at least one metadata clip before enabling automatic metadata."
        }

        let photographerIDs = Set(photographers.map(\.id))
        if clips.contains(where: { !photographerIDs.contains($0.photographerID) }) {
            return "A metadata clip refers to a photographer that no longer exists."
        }
        if clips.contains(where: { $0.endsAt <= $0.startsAt }) {
            return "Every metadata clip must end after it starts."
        }
        if clips.contains(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return "Give every metadata clip a name."
        }

        for photographerID in photographerIDs {
            let photographerClips = clips
                .filter { $0.photographerID == photographerID }
                .sorted { $0.startsAt < $1.startsAt }
            for pair in zip(photographerClips, photographerClips.dropFirst()) where pair.0.endsAt > pair.1.startsAt {
                let photographerName = photographers.first(where: { $0.id == photographerID })?.name ?? "A photographer"
                return "\(photographerName) has overlapping metadata clips."
            }
        }
        return nil
    }

    private static func preferredClip(_ lhs: MetadataScheduleClip, _ rhs: MetadataScheduleClip) -> Bool {
        if lhs.startsAt != rhs.startsAt { return lhs.startsAt > rhs.startsAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
