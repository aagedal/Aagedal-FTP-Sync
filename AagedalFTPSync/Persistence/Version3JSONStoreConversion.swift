import CryptoKit
import Foundation

/// Pure conversion of an explicitly selected, coherent 2.9 JSON store set. No
/// repository is opened, no backup is selected, and no files or credentials change.
/// The driver must select/reconcile sources under writer exclusion and preserve
/// original bytes and backup provenance. Credential IDs returned here cover these
/// selected bytes only: the driver must also union reachability from every retained
/// backup/snapshot before enabling any credential cleanup.
///
/// Uses stable payload models for validation, then wraps present payload bytes
/// unchanged, retaining literal fields, order, optional defaults and date precision.
/// Unknown legacy fields are preserved but are not claimed to be semantically
/// understood. Older implicit tracks require an explicit caller-frozen calendar;
/// inference is bounded and patches only the track member, retaining unrelated
/// bytes. SQLite and mapping/registry stores are separate adapters.
enum Version3JSONStoreConversion {
    struct Result: Sendable {
        let stores: [String: Data]
        let retainedCredentialIDs: Set<String>
        let summary: ValidationSummary
    }

    struct CurrentValidation: Sendable {
        let summary: ValidationSummary
        /// Current JSON stores only; retained archives require separate accounting.
        let retainedCredentialIDs: Set<String>
    }

    struct ValidationSummary: Sendable {
        let recordCounts: [String: Int]
        let selectedSourceSHA256: [String: String]
        let initializedAbsentStores: Set<String>
        /// Historical records are retained even after their job is removed.
        let historicalJobIDsWithoutCurrentJob: [String: Set<UUID>]
        /// A stale binding is an existing recoverable state: the UI can detach it.
        let calendarBindingJobIDsWithoutCurrentJob: Set<UUID>
        let pendingReceiptPhase: PendingReceiptPhase
        let trackInference: TrackInferenceSummary?
    }

    struct TrackInferenceSummary: Sendable {
        let calendarIdentifier: String
        let timeZoneIdentifier: String
        let adaptedObjects: Int
        let inferredTracks: Int
        let dayIterations: Int
    }

    enum PendingReceiptPhase: String, Sendable { case none, beforeInstallation, jobsInstalled }
    enum ConversionError: Error, Equatable {
        case unsupportedSource(String), missingCurrentStore(String), inputLimitExceeded, duplicateIdentity(String)
        case invalidReference(String), invalidPendingReceipt, invalidRecord(String)
        case explicitPhotographerTracksRequired(String)
        case unsupportedJSONEncoding(String)
        case invalidTrackInferenceOptions, trackInferenceLimitExceeded, ambiguousTrackInference(String)
    }

    private static let layout = AppStorageLayout(root: URL(fileURLWithPath: "/", isDirectory: true))
    private static var storeIdentifiers: [String: VersionedStoreCodec.Store] {
        [layout.jobs.lastPathComponent: .jobs, layout.metadataPresets.lastPathComponent: .metadataPresets,
         layout.photographers.lastPathComponent: .photographers, layout.serverProfiles.lastPathComponent: .serverProfiles,
         layout.metadataCalendar.lastPathComponent: .metadataCalendar, layout.metadataSyncEvents.lastPathComponent: .metadataSyncEvents,
         layout.metadataAudit.lastPathComponent: .metadataAudit, layout.syncFailures.lastPathComponent: .syncFailures,
         layout.downloadManifest.lastPathComponent: .downloadManifest]
    }
    static var primaryFilenames: Set<String> { Set(storeIdentifiers.keys) }

    /// Validates the complete current JSON set without writing, converting or
    /// reserializing its payloads. Other store families in `stores` belong to the
    /// caller's separate validators and are ignored here. The caller excludes all
    /// writers and accounts for credentials reachable from retained archives.
    /// All headers and raw payload spans are checked before any domain decoding;
    /// nonempty implicit tracks are forbidden. Empty legacy automation retains
    /// the converter's compatible default without entering the day-inference loop.
    static func validateCurrentStores(_ stores: [String: Data], maximumInputBytes: Int = 256 * 1024 * 1024) throws -> CurrentValidation {
        guard maximumInputBytes > 0 else { throw ConversionError.inputLimitExceeded }
        var payloads: [String: Data] = [:]
        var sourceHashes: [String: String] = [:]
        var remaining = maximumInputBytes
        for name in primaryFilenames.sorted() {
            guard let bytes = stores[name] else { throw ConversionError.missingCurrentStore(name) }
            guard bytes.count <= remaining else { throw ConversionError.inputLimitExceeded }
            remaining -= bytes.count
            try validateSourceEncoding(bytes, source: name)
            // This generic value cannot run MetadataAutomation's legacy inference.
            _ = try VersionedStoreCodec(format: .version3, store: storeIdentifiers[name]!)
                .decode(PreflightValue.self, from: bytes, decoder: JSONDecoder())
            var scanner = RawScanner(bytes: Array(bytes))
            let root = try scanner.parse()
            guard let members = root.members,
                  Set(members.map(\.key)).count == members.count,
                  let payload = members.first(where: { $0.key == "payload" }) else {
                throw VersionedStoreCodec.HeaderError.invalidEnvelope
            }
            payloads[name] = Data(scanner.bytes[payload.value.range])
            sourceHashes[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        let validated = try process(selectedLegacyPrimaries: payloads, maximumInputBytes: maximumInputBytes,
            implicitTrackCalendar: nil, maximumInferredDayIterations: 50_000, emitStores: false,
            sourceHashes: sourceHashes)
        return CurrentValidation(summary: validated.summary, retainedCredentialIDs: validated.retainedCredentialIDs)
    }

    static func convert(selectedLegacyPrimaries input: [String: Data], maximumInputBytes: Int = 256 * 1024 * 1024,
                        implicitTrackCalendar: Calendar? = nil, maximumInferredDayIterations: Int = 50_000) throws -> Result {
        try process(selectedLegacyPrimaries: input, maximumInputBytes: maximumInputBytes,
            implicitTrackCalendar: implicitTrackCalendar, maximumInferredDayIterations: maximumInferredDayIterations,
            emitStores: true, sourceHashes: nil)
    }

    private static func process(selectedLegacyPrimaries input: [String: Data], maximumInputBytes: Int,
                                implicitTrackCalendar: Calendar?, maximumInferredDayIterations: Int,
                                emitStores: Bool, sourceHashes: [String: String]?) throws -> Result {
        guard maximumInputBytes > 0 else { throw ConversionError.inputLimitExceeded }
        guard (1...50_000).contains(maximumInferredDayIterations) else { throw ConversionError.invalidTrackInferenceOptions }
        var adapter = TrackAdapter(calendar: implicitTrackCalendar, remainingDays: maximumInferredDayIterations)
        var selected = input
        var remaining = maximumInputBytes
        for name in input.keys.sorted() {
            guard primaryFilenames.contains(name) else { throw ConversionError.unsupportedSource(name) }
            guard input[name]!.count <= remaining else { throw ConversionError.inputLimitExceeded }
            remaining -= input[name]!.count
            if emitStores {
                try validateSourceEncoding(input[name]!, source: name)
                try VersionedStoreCodec.rejectLegacyTemplateMarkers(in: input[name]!)
            }
            let policy: DatePolicy = name == layout.metadataCalendar.lastPathComponent ? .calendar
                : [layout.jobs, layout.metadataPresets, layout.metadataAudit, layout.syncFailures].contains(where: { $0.lastPathComponent == name }) ? .iso8601 : .foundation
            selected[name] = try adapter.adapt(input[name]!, source: name, policy: policy)
            try preflightTrackInference(selected[name]!, source: name)
        }
        func read<T: Decodable>(_ type: T.Type, at url: URL, empty: T, policy: DatePolicy) throws -> T {
            guard let data = selected[url.lastPathComponent] else { return empty }
            return try policy.decoder.decode(type, from: data)
        }
        let jobs = try read([SyncJob].self, at: layout.jobs, empty: [], policy: .iso8601)
        let presets = try read([MetadataPreset].self, at: layout.metadataPresets, empty: [], policy: .iso8601)
        let photographers = try read([PhotographerProfile].self, at: layout.photographers, empty: [], policy: .foundation)
        let profiles = try read([ServerProfile].self, at: layout.serverProfiles, empty: [], policy: .foundation)
        let calendar = try read(MetadataCalendarState.self, at: layout.metadataCalendar, empty: MetadataCalendarState(), policy: .calendar)
        let events = try read([MetadataSyncEvent].self, at: layout.metadataSyncEvents, empty: [], policy: .foundation)
        let audit = try read([MetadataAuditEntry].self, at: layout.metadataAudit, empty: [], policy: .iso8601)
        let failures = try read([SyncFailureRecord].self, at: layout.syncFailures, empty: [], policy: .iso8601)
        let manifest = try read([DownloadManifestRepository.Record].self, at: layout.downloadManifest, empty: [], policy: .foundation)

        try unique(jobs.map(\.id), label: "jobs")
        try unique(presets.map(\.id), label: "presets")
        try unique(photographers.map(\.id), label: "photographers")
        try unique(profiles.map(\.id), label: "server profiles")
        try unique(calendar.accounts.map(\.id), label: "calendar accounts")
        var profileNames = Set<String>()
        for profile in profiles {
            guard profile.validationMessage == nil else { throw ConversionError.invalidRecord("server profile") }
            let folded = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard profileNames.insert(folded).inserted else { throw ConversionError.duplicateIdentity("server profile name") }
        }
        let profileIDs = Set(profiles.map(\.id))
        let jobIDs = Set(jobs.map(\.id))
        let accountIDs = Set(calendar.accounts.map(\.id))
        for job in jobs { try validateJob(job, profileIDs: profileIDs) }
        if let active = calendar.activeAccountID, !accountIDs.contains(active) { throw ConversionError.invalidReference("active account") }
        var bindingIDs = Set<String>()
        var boundJobs = Set<UUID>()
        for binding in calendar.bindings {
            guard accountIDs.contains(binding.accountID) else { throw ConversionError.invalidReference("calendar binding account") }
            guard bindingIDs.insert(binding.accountID.uuidString + "/" + binding.snapshot.id.uuidString).inserted,
                  boundJobs.insert(binding.jobID).inserted else { throw ConversionError.duplicateIdentity("calendar binding") }
            try validateCalendar(binding.snapshot)
            try validateRange(binding.publicationRange)
            if let conflict = binding.conflict {
                guard conflict.id == binding.snapshot.id else { throw ConversionError.invalidReference("calendar conflict identity") }
                try validateCalendar(conflict)
            }
        }
        let phase = try validatePending(calendar.pendingReceive, jobs: jobs, profileIDs: profileIDs,
                                        accountIDs: accountIDs, bindings: calendar.bindings)
        for record in manifest {
            guard PathSafety.isSafeRelativePath(record.relativePath), !PathSafety.isInternalStagingPath(record.relativePath),
                  record.destination.localPath.hasPrefix("/"), !record.destination.localPath.utf8.contains(0) else {
                throw ConversionError.invalidRecord("download manifest")
            }
        }

        var credentials = Set(profiles.map(\.credentialID))
        var credentialJobs = jobs
        if let pending = calendar.pendingReceive { credentialJobs += [pending.source, pending.duplicate] }
        for job in credentialJobs {
            for endpoint in [job.left, job.right] + (job.processedFolder.map { [$0] } ?? []) where endpoint.kind.isRemote {
                // Keep embedded projection IDs as well as profile IDs: retained 2.9
                // bytes can still refer to either, even when current resolution differs.
                if !endpoint.credentialID.isEmpty { credentials.insert(endpoint.credentialID) }
            }
        }
        credentials.formUnion(calendar.accounts.map(\.credentialID))

        var output: [String: Data] = [:]
        var counts: [String: Int] = [:]
        func write<T: Codable>(_ value: T, at url: URL, store: VersionedStoreCodec.Store, policy: DatePolicy, count: Int) throws {
            counts[url.lastPathComponent] = count
            guard emitStores else { return }
            let encoded = try VersionedStoreCodec(format: .version3, store: store).encode(value, encoder: policy.encoder)
            if let original = selected[url.lastPathComponent] {
                // The header fields are fixed identifiers, never user-supplied text.
                var wrapped = Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":3,\"store\":\"\(store.rawValue)\",\"payload\":".utf8)
                wrapped.append(original)
                wrapped.append(Data("}".utf8))
                _ = try VersionedStoreCodec(format: .version3, store: store).decode(T.self, from: wrapped, decoder: policy.decoder)
                output[url.lastPathComponent] = wrapped
            } else { output[url.lastPathComponent] = encoded }
        }
        try write(jobs, at: layout.jobs, store: .jobs, policy: .iso8601, count: jobs.count)
        try write(presets, at: layout.metadataPresets, store: .metadataPresets, policy: .iso8601, count: presets.count)
        try write(photographers, at: layout.photographers, store: .photographers, policy: .foundation, count: photographers.count)
        try write(profiles, at: layout.serverProfiles, store: .serverProfiles, policy: .foundation, count: profiles.count)
        try write(calendar, at: layout.metadataCalendar, store: .metadataCalendar, policy: .calendar, count: calendar.bindings.count)
        try write(events, at: layout.metadataSyncEvents, store: .metadataSyncEvents, policy: .foundation, count: events.count)
        try write(audit, at: layout.metadataAudit, store: .metadataAudit, policy: .iso8601, count: audit.count)
        try write(failures, at: layout.syncFailures, store: .syncFailures, policy: .iso8601, count: failures.count)
        try write(manifest, at: layout.downloadManifest, store: .downloadManifest, policy: .foundation, count: manifest.count)
        let history = [layout.metadataAudit.lastPathComponent: Set(audit.map(\.jobID)).subtracting(jobIDs),
                       layout.syncFailures.lastPathComponent: Set(failures.map(\.jobID)).subtracting(jobIDs),
                       layout.downloadManifest.lastPathComponent: Set(manifest.map(\.jobID)).subtracting(jobIDs),
                       layout.metadataSyncEvents.lastPathComponent: Set(events.compactMap(\.jobID)).subtracting(jobIDs)]
        return Result(stores: output, retainedCredentialIDs: credentials, summary: ValidationSummary(
            recordCounts: counts,
            selectedSourceSHA256: sourceHashes ?? input.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
            initializedAbsentStores: primaryFilenames.subtracting(input.keys),
            historicalJobIDsWithoutCurrentJob: history,
            calendarBindingJobIDsWithoutCurrentJob: Set(calendar.bindings.map(\.jobID)).subtracting(jobIDs),
            pendingReceiptPhase: phase, trackInference: adapter.summary))
    }

    private static func unique<T: Hashable>(_ values: [T], label: String) throws {
        guard Set(values).count == values.count else { throw ConversionError.duplicateIdentity(label) }
    }

    private struct TrackAdapter {
        let calendar: Calendar?
        var remainingDays: Int
        private var objects = 0
        private var tracks = 0
        private var iterations = 0

        init(calendar supplied: Calendar?, remainingDays: Int) {
            if let supplied {
                // Snapshot autoupdating calendar/zone values at the call boundary.
                var fixed = Calendar(identifier: supplied.identifier)
                fixed.locale = supplied.locale
                fixed.timeZone = TimeZone(identifier: supplied.timeZone.identifier) ?? supplied.timeZone
                fixed.firstWeekday = supplied.firstWeekday
                fixed.minimumDaysInFirstWeek = supplied.minimumDaysInFirstWeek
                calendar = fixed
            } else { calendar = nil }
            self.remainingDays = remainingDays
        }

        var summary: TrackInferenceSummary? {
            calendar.map { TrackInferenceSummary(calendarIdentifier: String(describing: $0.identifier),
                timeZoneIdentifier: $0.timeZone.identifier, adaptedObjects: objects,
                inferredTracks: tracks, dayIterations: iterations) }
        }

        mutating func adapt(_ data: Data, source: String, policy: DatePolicy) throws -> Data {
            guard let calendar else { return data }
            try validateSourceEncoding(data, source: source)
            // Grammar/type validation before the small byte-span scanner. The
            // scanner never invents or reserializes scalar values/unknown members.
            _ = try JSONDecoder().decode(PreflightValue.self, from: data)
            var scanner = RawScanner(bytes: Array(data))
            let root = try scanner.parse()
            var pending: [RawScanner.Node] = []
            for path in trackObjectPaths(source: source) {
                var nodes = [root]
                for component in path {
                    var selected: [RawScanner.Node] = []
                    for node in nodes {
                        if component == "*" { selected += node.elements ?? [] }
                        else if let value = try member(component, in: node, source: source) { selected.append(value) }
                    }
                    nodes = selected
                }
                pending += nodes
            }
            var patches: [(range: Range<Int>, bytes: Data)] = []
            while let node = pending.popLast() {
                if node.members != nil {
                    if let clipNode = try member("clips", in: node, source: source),
                       let clips = clipNode.elements, !clips.isEmpty {
                        let priorTracks = try member("photographerTracks", in: node, source: source)
                        if priorTracks == nil || scanner.bytes[priorTracks!.range].elementsEqual(Array("null".utf8)) {
                            let clips = try policy.decoder.decode([MetadataScheduleClip].self, from: Data(scanner.bytes[clipNode.range]))
                            let inferred = try infer(clips, calendar: calendar)
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.sortedKeys]
                            let encoded = try encoder.encode(inferred)
                            if let priorTracks { patches.append((priorTracks.range, encoded)) }
                            else {
                                var insertion = Data(",\"photographerTracks\":".utf8)
                                insertion.append(encoded)
                                patches.append(((node.range.upperBound - 1)..<(node.range.upperBound - 1), insertion))
                            }
                            objects += 1
                            tracks += inferred.count
                        }
                    }
                }
            }
            guard !patches.isEmpty else { return data }
            var result = Data()
            var cursor = 0
            for patch in patches.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                guard patch.range.lowerBound >= cursor else { throw ConversionError.ambiguousTrackInference(source) }
                result.append(contentsOf: scanner.bytes[cursor..<patch.range.lowerBound])
                result.append(patch.bytes)
                cursor = patch.range.upperBound
            }
            result.append(contentsOf: scanner.bytes[cursor...])
            return result
        }

        private func member(_ key: String, in node: RawScanner.Node, source: String) throws -> RawScanner.Node? {
            let values = node.members?.filter { $0.key == key } ?? []
            // Refuse ambiguous model paths/track members without touching unrelated
            // duplicate keys in extension data that the payload model ignores.
            guard values.count <= 1 else { throw ConversionError.ambiguousTrackInference(source) }
            return values.first?.value
        }

        private mutating func infer(_ clips: [MetadataScheduleClip], calendar: Calendar) throws -> [MetadataPhotographerTrack] {
            var result: [MetadataPhotographerTrack] = []
            var seen = Set<MetadataPhotographerTrack>()
            // Explicit conversion policy bounds absolute dates to Gregorian years
            // 1..<10000, independently of the selected calendar's year numbering.
            let lower = Date(timeIntervalSince1970: -62_135_596_800)
            let upper = Date(timeIntervalSince1970: 253_402_300_800)
            for clip in clips {
                guard clip.startsAt.timeIntervalSince1970.isFinite, clip.endsAt.timeIntervalSince1970.isFinite,
                      clip.startsAt >= lower, clip.endsAt < upper, clip.endsAt > clip.startsAt else {
                    throw ConversionError.invalidRecord("implicit track date range")
                }
                var day = calendar.startOfDay(for: clip.startsAt)
                while day < clip.endsAt {
                    guard remainingDays > 0 else { throw ConversionError.trackInferenceLimitExceeded }
                    remainingDays -= 1
                    iterations += 1
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day,
                          next.timeIntervalSince1970.isFinite else { throw ConversionError.invalidRecord("implicit track day") }
                    let track = MetadataPhotographerTrack(photographerID: clip.photographerID,
                                                         date: PhotographerWorkDate(day, calendar: calendar))
                    if clip.startsAt < next, clip.endsAt > day, seen.insert(track).inserted { result.append(track) }
                    day = next
                }
            }
            return result
        }
    }

    /// JSON spans only; the Foundation decoder above validates syntax and UTF-8.
    /// Parsing is bounded separately from calendar inference to avoid unbounded
    /// recursion or per-node work in malformed/oversized legacy object graphs.
    private struct RawScanner {
        struct Member { let key: String; let value: Node }
        struct Node { let range: Range<Int>; let members: [Member]?; let elements: [Node]? }
        let bytes: [UInt8]
        var offset = 0
        var remainingNodes = 1_000_000

        mutating func parse() throws -> Node {
            let parsed = try value(depth: 0)
            whitespace()
            guard offset == bytes.count else { throw ConversionError.invalidRecord("legacy JSON") }
            return parsed
        }

        private mutating func value(depth: Int) throws -> Node {
            guard depth <= 128, remainingNodes > 0 else { throw ConversionError.trackInferenceLimitExceeded }
            remainingNodes -= 1
            whitespace()
            let start = offset
            guard offset < bytes.count else { throw ConversionError.invalidRecord("legacy JSON") }
            if bytes[offset] == 123 {
                offset += 1
                whitespace()
                var members: [Member] = []
                if offset < bytes.count, bytes[offset] != 125 {
                    while true {
                        whitespace()
                        let keyRange = try string()
                        let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyRange]))
                        whitespace()
                        try consume(58)
                        members.append(Member(key: key, value: try value(depth: depth + 1)))
                        whitespace()
                        if offset < bytes.count, bytes[offset] == 44 { offset += 1 } else { break }
                    }
                }
                try consume(125)
                return Node(range: start..<offset, members: members, elements: nil)
            }
            if bytes[offset] == 91 {
                offset += 1
                whitespace()
                var elements: [Node] = []
                if offset < bytes.count, bytes[offset] != 93 {
                    while true {
                        elements.append(try value(depth: depth + 1))
                        whitespace()
                        if offset < bytes.count, bytes[offset] == 44 { offset += 1 } else { break }
                    }
                }
                try consume(93)
                return Node(range: start..<offset, members: nil, elements: elements)
            }
            if bytes[offset] == 34 { _ = try string() }
            else {
                while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            }
            guard offset > start else { throw ConversionError.invalidRecord("legacy JSON") }
            return Node(range: start..<offset, members: nil, elements: nil)
        }

        private mutating func string() throws -> Range<Int> {
            let start = offset
            try consume(34)
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == 34 { return start..<offset }
                if byte == 92 { offset += 1 }
            }
            throw ConversionError.invalidRecord("legacy JSON string")
        }

        private mutating func consume(_ byte: UInt8) throws {
            guard offset < bytes.count, bytes[offset] == byte else { throw ConversionError.invalidRecord("legacy JSON") }
            offset += 1
        }
        private mutating func whitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }
    }

    private static func validateSourceEncoding(_ data: Data, source: String) throws {
        // Stable 2.9 JSON encoders emit BOM-free UTF-8. Embedded UTF-16/32 or
        // a BOM would make an otherwise readable legacy payload invalid inside
        // the UTF-8 envelope; do not transcode selected source bytes implicitly.
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0),
              !data.starts(with: [0xEF, 0xBB, 0xBF]) else { throw ConversionError.unsupportedJSONEncoding(source) }
    }

    private static func preflightTrackInference(_ data: Data, source: String) throws {
        try validateSourceEncoding(data, source: source)
        let root = try JSONDecoder().decode(PreflightValue.self, from: data)
        var pending: [PreflightValue] = []
        for path in trackObjectPaths(source: source) {
            var nodes = [root]
            for component in path {
                nodes = nodes.flatMap { node -> [PreflightValue] in
                    if component == "*", case .array(let values) = node { return values }
                    if case .object(let members) = node, let value = members[component] { return [value] }
                    return []
                }
            }
            pending += nodes
        }
        while let value = pending.popLast() {
            switch value {
            case .object(let object):
                if object["photographerTracks"] == nil || object["photographerTracks"]?.isNull == true {
                    if let clipsValue = object["clips"], case .array(let clips) = clipsValue, !clips.isEmpty {
                        throw ConversionError.explicitPhotographerTracksRequired(source)
                    }
                }
            case .array: break
            case .null, .scalar: break
            }
        }
    }

    /// Only locations actually decoded as automation/documents participate. A
    /// similarly named object inside an unknown extension remains opaque bytes.
    private static func trackObjectPaths(source: String) -> [[String]] {
        if source == layout.jobs.lastPathComponent { return [["*", "metadataAutomation"]] }
        if source == layout.metadataCalendar.lastPathComponent {
            return [["bindings", "*", "snapshot", "document"], ["bindings", "*", "conflict", "document"],
                    ["pendingReceive", "source", "metadataAutomation"], ["pendingReceive", "duplicate", "metadataAutomation"],
                    ["pendingReceive", "calendar", "document"]]
        }
        return []
    }

    /// Use the same Foundation keyed decoder as payload models, including its
    /// duplicate-key selection. A separate JSONSerialization traversal can choose
    /// a different duplicate and miss the value that triggers model inference.
    private enum PreflightValue: Decodable {
        case object([String: PreflightValue]), array([PreflightValue]), null, scalar
        var isNull: Bool { if case .null = self { return true }; return false }
        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: Key.self) {
                var object: [String: PreflightValue] = [:]
                for key in container.allKeys { object[key.stringValue] = try container.decode(Self.self, forKey: key) }
                self = .object(object)
            } else if var container = try? decoder.unkeyedContainer() {
                var values: [PreflightValue] = []
                while !container.isAtEnd { values.append(try container.decode(Self.self)) }
                self = .array(values)
            } else {
                self = try decoder.singleValueContainer().decodeNil() ? .null : .scalar
            }
        }
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }

    private static func validateJob(_ job: SyncJob, profileIDs: Set<UUID>) throws {
        for endpoint in [job.left, job.right] + (job.processedFolder.map { [$0] } ?? []) {
            if let id = endpoint.serverProfileID, !profileIDs.contains(id) { throw ConversionError.invalidReference("job server profile") }
        }
        if let automation = job.metadataAutomation { try validateAutomation(automation) }
    }

    private static func validateAutomation(_ automation: MetadataAutomation) throws {
        try unique(automation.photographers.map(\.id), label: "embedded photographers")
        try unique(automation.clips.map(\.id), label: "embedded clips")
        let ids = Set(automation.photographers.map(\.id))
        guard automation.clips.allSatisfy({ ids.contains($0.photographerID) && $0.startsAt.timeIntervalSince1970.isFinite && $0.endsAt.timeIntervalSince1970.isFinite }),
              automation.photographerTracks.allSatisfy({ ids.contains($0.photographerID) }) else {
            throw ConversionError.invalidReference("embedded photographer")
        }
        // Do not normalize or reject saved drafts merely for overlapping clips,
        // missing names/prefixes or disabled/incomplete connection settings.
    }

    private static func validateCalendarDate(_ date: Date) throws {
        // Calendar persistence writes integer milliseconds. Validate explicitly so
        // current-store validation cannot admit a later Int64 conversion trap.
        guard Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()) != nil else {
            throw ConversionError.invalidRecord("calendar date")
        }
    }

    private static func validateCalendarClips(_ clips: [MetadataScheduleClip]) throws {
        for clip in clips {
            try validateCalendarDate(clip.startsAt)
            try validateCalendarDate(clip.endsAt)
        }
    }

    private static func validateRange(_ range: MetadataSharingRange?) throws {
        if let range {
            try validateCalendarDate(range.start)
            try validateCalendarDate(range.end)
            guard range.end > range.start else { throw ConversionError.invalidRecord("calendar range") }
        }
    }

    private static func validateCalendar(_ calendar: SharedMetadataCalendar) throws {
        guard calendar.revision >= 0, TimeZone(identifier: calendar.timeZone) != nil,
              ["owner", "editor", "reader"].contains(calendar.role),
              (calendar.rangeStart == nil) == (calendar.rangeEnd == nil) else { throw ConversionError.invalidRecord("calendar") }
        try validateRange(calendar.range)
        try validateCalendarClips(calendar.document.clips)
        // Construct the value directly; transport .validated() canonicalizes dates,
        // sorts records and strips private profile data, which migration must retain.
        try validateAutomation(MetadataAutomation(photographers: calendar.document.photographers,
            photographerTracks: calendar.document.photographerTracks, clips: calendar.document.clips))
    }

    private static func validatePending(_ pending: MetadataCalendarReceiveProposal?, jobs: [SyncJob], profileIDs: Set<UUID>,
                                        accountIDs: Set<UUID>, bindings: [MetadataCalendarBinding]) throws -> PendingReceiptPhase {
        guard let pending else { return .none }
        guard accountIDs.contains(pending.accountID), pending.source.id != pending.duplicate.id,
              !pending.duplicate.isEnabled, !pending.duplicate.startsOnAppLaunch,
              !bindings.contains(where: { $0.accountID == pending.accountID && $0.snapshot.id == pending.calendar.id }),
              let actualSource = jobs.first(where: { $0.id == pending.source.id }) else { throw ConversionError.invalidPendingReceipt }
        try validateJob(pending.source, profileIDs: profileIDs)
        try validateJob(pending.duplicate, profileIDs: profileIDs)
        try validateCalendarClips(pending.source.metadataAutomation?.clips ?? [])
        try validateCalendarClips(pending.duplicate.metadataAutomation?.clips ?? [])
        try validateCalendar(pending.calendar)
        // Job files use ISO seconds; receipt snapshots use calendar milliseconds.
        // Compare the persisted job representation without changing either output.
        func persisted(_ job: SyncJob) throws -> SyncJob {
            try DatePolicy.iso8601.decoder.decode(SyncJob.self, from: DatePolicy.iso8601.encoder.encode(job))
        }
        if let duplicate = jobs.first(where: { $0.id == pending.duplicate.id }) {
            var pausedSource = pending.source
            pausedSource.isEnabled = false
            pausedSource.startsOnAppLaunch = false
            guard actualSource == (try persisted(pausedSource)), duplicate == (try persisted(pending.duplicate)) else {
                throw ConversionError.invalidPendingReceipt
            }
            return .jobsInstalled
        }
        guard actualSource == (try persisted(pending.source)) else { throw ConversionError.invalidPendingReceipt }
        return .beforeInstallation
    }

    private enum DatePolicy {
        case iso8601, foundation, calendar
        var decoder: JSONDecoder {
            let decoder = JSONDecoder()
            if self == .iso8601 { decoder.dateDecodingStrategy = .iso8601 }
            if self == .calendar { decoder.dateDecodingStrategy = .millisecondsSince1970 }
            return decoder
        }
        var encoder: JSONEncoder {
            let encoder = JSONEncoder()
            if self != .calendar { encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] }
            if self == .iso8601 { encoder.dateEncodingStrategy = .iso8601 }
            if self == .calendar {
                // Same rounded integer milliseconds as MetadataCalendarClient, with
                // a throwing bound check instead of trapping on corrupt date input.
                encoder.dateEncodingStrategy = .custom { date, encoder in
                    let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
                    guard let value = Int64(exactly: milliseconds) else {
                        throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Calendar date is out of range"))
                    }
                    var container = encoder.singleValueContainer()
                    try container.encode(value)
                }
            }
            return encoder
        }
    }
}
