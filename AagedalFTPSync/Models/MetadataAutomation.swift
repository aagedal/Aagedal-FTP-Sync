import Foundation

enum MetadataTimestampPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case sourceModification
    case localArrival
    case cameraCapture

    var id: Self { self }

    var title: String {
        switch self {
        case .sourceModification: "Source modification time"
        case .localArrival: "Local arrival time"
        case .cameraCapture: "Camera capture time"
        }
    }

    var explanation: String {
        switch self {
        case .sourceModification:
            "Match the schedule using the timestamp reported by the source."
        case .localArrival:
            "Match the schedule when the file finishes downloading to this Mac."
        case .cameraCapture:
            "Match the schedule using Exif DateTimeOriginal. Files without a valid capture time are transferred without scheduled metadata."
        }
    }
}

enum MetadataExistingFieldPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case fillEmpty
    case overwrite

    var id: Self { self }

    var title: String {
        switch self {
        case .fillEmpty: "Fill empty fields"
        case .overwrite: "Always overwrite"
        }
    }

    var explanation: String {
        switch self {
        case .fillEmpty:
            "Preserve existing metadata and write a programmed value only when that field is empty."
        case .overwrite:
            "Replace existing metadata whenever the schedule provides a non-empty value."
        }
    }
}

struct PhotographerWorkHours: Codable, Hashable, Sendable {
    static let standard = PhotographerWorkHours(startMinutes: 9 * 60, endMinutes: 17 * 60)

    var startMinutes: Int
    var endMinutes: Int

    func interval(on day: Date, calendar: Calendar = .current) -> DateInterval? {
        guard (0..<(24 * 60)).contains(startMinutes),
              (0..<(24 * 60)).contains(endMinutes),
              endMinutes > startMinutes,
              let start = calendar.date(
                bySettingHour: startMinutes / 60,
                minute: startMinutes % 60,
                second: 0,
                of: day
              ),
              let end = calendar.date(
                bySettingHour: endMinutes / 60,
                minute: endMinutes % 60,
                second: 0,
                of: day
              ),
              end > start else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }
}

struct PhotographerWorkDate: Codable, Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    func date(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    static func < (lhs: PhotographerWorkDate, rhs: PhotographerWorkDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

struct PhotographerWorkHoursOverride: Codable, Identifiable, Hashable, Sendable {
    var date: PhotographerWorkDate
    /// `nil` is an explicit day off. A missing override uses the profile's default hours.
    var hours: PhotographerWorkHours?

    var id: PhotographerWorkDate { date }
}

struct PhotographerProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var filenamePrefix: String
    var creator: String
    var copyrightNotice: String
    var workHours: PhotographerWorkHours? = nil
    var workHourOverrides: [PhotographerWorkHoursOverride]? = nil

    init(
        id: UUID = UUID(),
        name: String,
        filenamePrefix: String,
        creator: String,
        copyrightNotice: String
    ) {
        self.id = id
        self.name = name
        self.filenamePrefix = filenamePrefix
        self.creator = creator
        self.copyrightNotice = copyrightNotice
    }

    init(
        id: UUID = UUID(),
        name: String,
        filenamePrefix: String,
        creator: String,
        copyrightNotice: String,
        workHours: PhotographerWorkHours
    ) {
        self.id = id
        self.name = name
        self.filenamePrefix = filenamePrefix
        self.creator = creator
        self.copyrightNotice = copyrightNotice
        self.workHours = workHours
    }

    init(
        id: UUID = UUID(),
        name: String,
        filenamePrefix: String,
        creator: String,
        copyrightNotice: String,
        workHours: PhotographerWorkHours?,
        workHourOverrides: [PhotographerWorkHoursOverride]
    ) {
        self.id = id
        self.name = name
        self.filenamePrefix = filenamePrefix
        self.creator = creator
        self.copyrightNotice = copyrightNotice
        self.workHours = workHours
        self.workHourOverrides = workHourOverrides
    }

    /// Comma-separated camera filename initials, normalized for matching.
    /// Keeping the persisted value as a string preserves profiles created by
    /// versions that supported only one prefix.
    var normalizedPrefixes: [String] {
        var seen = Set<String>()
        return filenamePrefix
            .split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { value in
                let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !prefix.isEmpty, seen.insert(prefix).inserted else { return nil }
                return prefix
            }
    }

    var formattedFilenamePrefixes: String {
        normalizedPrefixes.joined(separator: ", ")
    }

    /// The IPTC Creator is also the photographer's display name. Falling back to
    /// the legacy name keeps profiles created by older versions readable.
    var photographerName: String {
        let trimmedCreator = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCreator.isEmpty ? name : creator
    }

    func usingCreatorAsPhotographerName() -> PhotographerProfile {
        var profile = self
        let canonicalName = photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = canonicalName
        profile.creator = canonicalName
        return profile
    }

    func matchingPrefixLength(relativePath: String) -> Int? {
        guard !normalizedPrefixes.isEmpty else { return nil }
        let filename = URL(fileURLWithPath: relativePath)
            .deletingPathExtension()
            .lastPathComponent
            .uppercased()
        return normalizedPrefixes
            .filter { filename.hasPrefix($0) }
            .map(\.count)
            .max()
    }

    func matches(relativePath: String) -> Bool {
        matchingPrefixLength(relativePath: relativePath) != nil
    }

    func workHoursOverride(
        on date: Date,
        calendar: Calendar = .current
    ) -> PhotographerWorkHoursOverride? {
        let workDate = PhotographerWorkDate(date, calendar: calendar)
        return workHourOverrides?.first { $0.date == workDate }
    }

    func workHours(on date: Date, calendar: Calendar = .current) -> PhotographerWorkHours? {
        if let override = workHoursOverride(on: date, calendar: calendar) {
            return override.hours
        }
        return workHours
    }

    mutating func setWorkHoursOverride(
        _ hours: PhotographerWorkHours?,
        on date: Date,
        calendar: Calendar = .current
    ) {
        let workDate = PhotographerWorkDate(date, calendar: calendar)
        var overrides = workHourOverrides ?? []
        overrides.removeAll { $0.date == workDate }
        overrides.append(PhotographerWorkHoursOverride(date: workDate, hours: hours))
        workHourOverrides = overrides.sorted { $0.date < $1.date }
    }

    mutating func clearWorkHoursOverride(on date: Date, calendar: Calendar = .current) {
        let workDate = PhotographerWorkDate(date, calendar: calendar)
        guard var overrides = workHourOverrides else { return }
        overrides.removeAll { $0.date == workDate }
        workHourOverrides = overrides.isEmpty ? nil : overrides
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

enum MetadataClipResizeEdge: Sendable {
    case start
    case end
}

enum MetadataTimelineEditing {
    static let minimumClipDuration: TimeInterval = 5 * 60

    static func creationInterval(
        on day: Date,
        from startFraction: Double,
        to endFraction: Double,
        snapMinutes: Int,
        calendar: Calendar = .current
    ) -> DateInterval {
        let dayStart = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let dayDuration = nextDay.timeIntervalSince(dayStart)
        let lowerFraction = min(max(min(startFraction, endFraction), 0), 1)
        let upperFraction = min(max(max(startFraction, endFraction), 0), 1)
        var start = snapped(
            dayStart.addingTimeInterval(lowerFraction * dayDuration),
            toMinutes: snapMinutes,
            calendar: calendar
        )
        var end = snapped(
            dayStart.addingTimeInterval(upperFraction * dayDuration),
            toMinutes: snapMinutes,
            calendar: calendar
        )

        start = min(max(start, dayStart), nextDay)
        end = min(max(end, dayStart), nextDay)
        let snappedMinimum = max(minimumClipDuration, TimeInterval(max(snapMinutes, 1) * 60))
        if end.timeIntervalSince(start) < snappedMinimum {
            if endFraction < startFraction {
                start = max(dayStart, end.addingTimeInterval(-snappedMinimum))
                if end.timeIntervalSince(start) < snappedMinimum {
                    end = min(nextDay, start.addingTimeInterval(snappedMinimum))
                }
            } else {
                end = min(nextDay, start.addingTimeInterval(snappedMinimum))
                if end.timeIntervalSince(start) < snappedMinimum {
                    start = max(dayStart, end.addingTimeInterval(-snappedMinimum))
                }
            }
        }

        return DateInterval(start: start, end: end)
    }

    static func snapped(
        _ date: Date,
        toMinutes minutes: Int,
        calendar: Calendar = .current
    ) -> Date {
        guard minutes > 0 else { return date }
        let dayStart = calendar.startOfDay(for: date)
        let interval = TimeInterval(minutes * 60)
        let elapsed = date.timeIntervalSince(dayStart)
        return dayStart.addingTimeInterval((elapsed / interval).rounded() * interval)
    }

    static func moving(
        _ clip: MetadataScheduleClip,
        by interval: TimeInterval,
        snapMinutes: Int,
        calendar: Calendar = .current
    ) -> MetadataScheduleClip {
        var result = clip
        let duration = clip.endsAt.timeIntervalSince(clip.startsAt)
        result.startsAt = snapped(
            clip.startsAt.addingTimeInterval(interval),
            toMinutes: snapMinutes,
            calendar: calendar
        )
        result.endsAt = result.startsAt.addingTimeInterval(duration)
        return result
    }

    static func copies(
        of clips: [MetadataScheduleClip],
        anchoredAt targetStart: Date,
        on targetPhotographerID: UUID?
    ) -> [MetadataScheduleClip] {
        guard let sourceStart = clips.map(\.startsAt).min() else { return [] }
        let sourcePhotographerIDs = Set(clips.map(\.photographerID))
        let remappedPhotographerID = sourcePhotographerIDs.count == 1 ? targetPhotographerID : nil
        let offset = targetStart.timeIntervalSince(sourceStart)

        return clips.map { source in
            var copy = source
            copy.id = UUID()
            copy.photographerID = remappedPhotographerID ?? source.photographerID
            copy.startsAt = source.startsAt.addingTimeInterval(offset)
            copy.endsAt = source.endsAt.addingTimeInterval(offset)
            return copy
        }
    }

    static func clips(
        from clips: [MetadataScheduleClip],
        restrictedTo day: Date,
        calendar: Calendar = .current
    ) -> [MetadataScheduleClip] {
        let dayStart = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        return clips.compactMap { clip in
            let start = max(clip.startsAt, dayStart)
            let end = min(clip.endsAt, nextDay)
            guard start < end else { return nil }
            var restricted = clip
            restricted.startsAt = start
            restricted.endsAt = end
            return restricted
        }
        .sorted { lhs, rhs in
            if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
            return lhs.photographerID.uuidString < rhs.photographerID.uuidString
        }
    }

    static func copies(
        of clips: [MetadataScheduleClip],
        fromDay sourceDay: Date,
        toDay targetDay: Date,
        calendar: Calendar = .current
    ) -> [MetadataScheduleClip] {
        let sourceStart = calendar.startOfDay(for: sourceDay)
        let targetStart = calendar.startOfDay(for: targetDay)
        return clips.compactMap { source in
            let startOffset = calendar.dateComponents(
                [.day, .hour, .minute, .second, .nanosecond],
                from: sourceStart,
                to: source.startsAt
            )
            let endOffset = calendar.dateComponents(
                [.day, .hour, .minute, .second, .nanosecond],
                from: sourceStart,
                to: source.endsAt
            )
            guard let startsAt = calendar.date(byAdding: startOffset, to: targetStart),
                  let endsAt = calendar.date(byAdding: endOffset, to: targetStart),
                  startsAt < endsAt else {
                return nil
            }
            var copy = source
            copy.id = UUID()
            copy.startsAt = startsAt
            copy.endsAt = endsAt
            return copy
        }
    }

    static func resizing(
        _ clip: MetadataScheduleClip,
        edge: MetadataClipResizeEdge,
        by interval: TimeInterval,
        snapMinutes: Int,
        calendar: Calendar = .current
    ) -> MetadataScheduleClip {
        var result = clip
        switch edge {
        case .start:
            let proposed = snapped(
                clip.startsAt.addingTimeInterval(interval),
                toMinutes: snapMinutes,
                calendar: calendar
            )
            result.startsAt = min(proposed, clip.endsAt.addingTimeInterval(-minimumClipDuration))
        case .end:
            let proposed = snapped(
                clip.endsAt.addingTimeInterval(interval),
                toMinutes: snapMinutes,
                calendar: calendar
            )
            result.endsAt = max(proposed, clip.startsAt.addingTimeInterval(minimumClipDuration))
        }
        return result
    }
}

enum MetadataTimelineAnalysis {
    static func gaps(
        in clips: [MetadataScheduleClip],
        for photographerID: UUID,
        on day: Date,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        let bounds = dayBounds(for: day, calendar: calendar)
        let intervals = mergedIntervals(
            clips: clips,
            photographerID: photographerID,
            bounds: bounds
        )
        var cursor = bounds.start
        var result: [DateInterval] = []
        for interval in intervals {
            if cursor < interval.start {
                result.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if cursor < bounds.end {
            result.append(DateInterval(start: cursor, end: bounds.end))
        }
        return result
    }

    static func overlaps(
        in clips: [MetadataScheduleClip],
        for photographerID: UUID,
        on day: Date,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        let bounds = dayBounds(for: day, calendar: calendar)
        let intervals = clips
            .filter { $0.photographerID == photographerID && $0.startsAt < bounds.end && $0.endsAt > bounds.start }
            .map { DateInterval(start: max($0.startsAt, bounds.start), end: min($0.endsAt, bounds.end)) }
            .sorted { $0.start < $1.start }

        var result: [DateInterval] = []
        for (index, interval) in intervals.enumerated() {
            for other in intervals.dropFirst(index + 1) {
                guard other.start < interval.end else { break }
                let overlap = DateInterval(start: other.start, end: min(interval.end, other.end))
                if overlap.duration > 0 { result.append(overlap) }
            }
        }
        return result
    }

    private static func dayBounds(for day: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    private static func mergedIntervals(
        clips: [MetadataScheduleClip],
        photographerID: UUID,
        bounds: DateInterval
    ) -> [DateInterval] {
        let intervals = clips
            .filter { $0.photographerID == photographerID && $0.startsAt < bounds.end && $0.endsAt > bounds.start }
            .map { DateInterval(start: max($0.startsAt, bounds.start), end: min($0.endsAt, bounds.end)) }
            .sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for interval in intervals {
            guard let last = result.last, interval.start <= last.end else {
                result.append(interval)
                continue
            }
            result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
        }
        return result
    }
}

struct MetadataAssignment: Equatable, Sendable {
    let photographer: PhotographerProfile
    let clip: MetadataScheduleClip
    let existingFieldPolicy: MetadataExistingFieldPolicy
}

struct MetadataAutomation: Codable, Hashable, Sendable {
    var isEnabled = false
    var timestampPolicy: MetadataTimestampPolicy = .sourceModification
    var existingFieldPolicy: MetadataExistingFieldPolicy = .fillEmpty
    var photographers: [PhotographerProfile] = []
    var clips: [MetadataScheduleClip] = []

    init(
        isEnabled: Bool = false,
        timestampPolicy: MetadataTimestampPolicy = .sourceModification,
        existingFieldPolicy: MetadataExistingFieldPolicy = .fillEmpty,
        photographers: [PhotographerProfile] = [],
        clips: [MetadataScheduleClip] = []
    ) {
        self.isEnabled = isEnabled
        self.timestampPolicy = timestampPolicy
        self.existingFieldPolicy = existingFieldPolicy
        self.photographers = photographers
        self.clips = clips
    }

    func restricted(to days: Set<Date>, calendar: Calendar = .current) -> MetadataAutomation {
        let dayIntervals = Self.mergedDayIntervals(for: days, calendar: calendar)
        var restrictedClips: [MetadataScheduleClip] = []

        for clip in clips {
            let intersections = dayIntervals.compactMap { interval -> DateInterval? in
                let start = max(clip.startsAt, interval.start)
                let end = min(clip.endsAt, interval.end)
                return start < end ? DateInterval(start: start, end: end) : nil
            }
            for (index, intersection) in intersections.enumerated() {
                var restrictedClip = clip
                if index > 0 {
                    restrictedClip.id = UUID()
                }
                restrictedClip.startsAt = intersection.start
                restrictedClip.endsAt = intersection.end
                restrictedClips.append(restrictedClip)
            }
        }

        let referencedPhotographerIDs = Set(restrictedClips.map(\.photographerID))
        var result = self
        result.photographers = photographers.filter { referencedPhotographerIDs.contains($0.id) }
        result.clips = restrictedClips
        return result
    }

    private static func mergedDayIntervals(
        for days: Set<Date>,
        calendar: Calendar
    ) -> [DateInterval] {
        let intervals = Set(days.map { calendar.startOfDay(for: $0) })
            .sorted()
            .compactMap { start -> DateInterval? in
                guard let end = calendar.date(byAdding: .day, value: 1, to: start), end > start else {
                    return nil
                }
                return DateInterval(start: start, end: end)
            }

        return intervals.reduce(into: []) { merged, interval in
            guard let last = merged.last, interval.start <= last.end else {
                merged.append(interval)
                return
            }
            merged[merged.count - 1] = DateInterval(
                start: last.start,
                end: max(last.end, interval.end)
            )
        }
    }

    func matchesPhotographer(relativePath: String) -> Bool {
        isEnabled && photographers.contains { $0.matches(relativePath: relativePath) }
    }

    func assignment(for relativePath: String, scheduledAt: Date) -> MetadataAssignment? {
        guard isEnabled else { return nil }

        let matchingPhotographers = photographers
            .filter { $0.matches(relativePath: relativePath) }
            .sorted {
                let lhsLength = $0.matchingPrefixLength(relativePath: relativePath) ?? 0
                let rhsLength = $1.matchingPrefixLength(relativePath: relativePath) ?? 0
                if lhsLength != rhsLength {
                    return lhsLength > rhsLength
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        for photographer in matchingPhotographers {
            if let clip = clips
                .filter({ $0.photographerID == photographer.id && $0.contains(scheduledAt) })
                .sorted(by: Self.preferredClip)
                .first {
                return MetadataAssignment(
                    photographer: photographer,
                    clip: clip,
                    existingFieldPolicy: existingFieldPolicy
                )
            }
        }
        return nil
    }

    var validationMessage: String? {
        if isEnabled, photographers.isEmpty {
            return "Add at least one photographer before enabling automatic metadata."
        }

        let namedPhotographers = photographers.filter {
            !$0.photographerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.normalizedPrefixes.isEmpty
        }
        if let photographer = namedPhotographers.first(where: {
            $0.photographerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return "Give the photographer using initials \(photographer.formattedFilenamePrefixes) a name."
        }
        if let photographer = namedPhotographers.first(where: { $0.normalizedPrefixes.isEmpty }) {
            return "Give \(photographer.photographerName) filename initials."
        }

        var prefixOwners: [String: Set<UUID>] = [:]
        for photographer in namedPhotographers {
            for prefix in photographer.normalizedPrefixes {
                prefixOwners[prefix, default: []].insert(photographer.id)
            }
        }
        if let duplicate = prefixOwners.keys.sorted().first(where: { prefixOwners[$0, default: []].count > 1 }) {
            return "The filename initials \(duplicate) are assigned to more than one photographer."
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
                let photographerName = photographers.first(where: { $0.id == photographerID })?.photographerName
                    ?? "A photographer"
                return "\(photographerName) has overlapping metadata clips."
            }
        }
        return nil
    }

    private static func preferredClip(_ lhs: MetadataScheduleClip, _ rhs: MetadataScheduleClip) -> Bool {
        if lhs.startsAt != rhs.startsAt { return lhs.startsAt > rhs.startsAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case timestampPolicy
        case existingFieldPolicy
        case photographers
        case clips
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        timestampPolicy = try container.decodeIfPresent(MetadataTimestampPolicy.self, forKey: .timestampPolicy)
            ?? .sourceModification
        existingFieldPolicy = try container.decodeIfPresent(MetadataExistingFieldPolicy.self, forKey: .existingFieldPolicy)
            ?? .overwrite
        photographers = try container.decodeIfPresent([PhotographerProfile].self, forKey: .photographers) ?? []
        clips = try container.decodeIfPresent([MetadataScheduleClip].self, forKey: .clips) ?? []
    }
}
