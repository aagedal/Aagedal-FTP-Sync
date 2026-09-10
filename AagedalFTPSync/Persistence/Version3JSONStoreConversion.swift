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
/// understood. Older nonempty calendars without explicit photographer tracks need
/// a separate, frozen-timezone reconciliation adapter before conversion. SQLite
/// and mapping/registry stores are separate adapters.
enum Version3JSONStoreConversion {
    struct Result: Sendable {
        let stores: [String: Data]
        let retainedCredentialIDs: Set<String>
        let summary: ValidationSummary
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
    }

    enum PendingReceiptPhase: String, Sendable { case none, beforeInstallation, jobsInstalled }
    enum ConversionError: Error, Equatable {
        case unsupportedSource(String), inputLimitExceeded, duplicateIdentity(String)
        case invalidReference(String), invalidPendingReceipt, invalidRecord(String)
        case explicitPhotographerTracksRequired(String)
        case unsupportedJSONEncoding(String)
    }

    private static let layout = AppStorageLayout(root: URL(fileURLWithPath: "/", isDirectory: true))
    static var primaryFilenames: Set<String> {
        Set([layout.jobs, layout.metadataPresets, layout.photographers, layout.serverProfiles,
             layout.metadataCalendar, layout.metadataSyncEvents, layout.metadataAudit,
             layout.syncFailures, layout.downloadManifest].map(\.lastPathComponent))
    }

    static func convert(selectedLegacyPrimaries input: [String: Data], maximumInputBytes: Int = 256 * 1024 * 1024) throws -> Result {
        guard maximumInputBytes > 0 else { throw ConversionError.inputLimitExceeded }
        var remaining = maximumInputBytes
        for name in input.keys.sorted() {
            guard primaryFilenames.contains(name) else { throw ConversionError.unsupportedSource(name) }
            guard input[name]!.count <= remaining else { throw ConversionError.inputLimitExceeded }
            remaining -= input[name]!.count
            try preflightTrackInference(input[name]!, source: name)
        }
        func read<T: Decodable>(_ type: T.Type, at url: URL, empty: T, policy: DatePolicy) throws -> T {
            guard let data = input[url.lastPathComponent] else { return empty }
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
            let encoded = try VersionedStoreCodec(format: .version3, store: store).encode(value, encoder: policy.encoder)
            if let original = input[url.lastPathComponent] {
                // The header fields are fixed identifiers, never user-supplied text.
                var wrapped = Data("{\"format\":\"AagedalFTPSync.store\",\"schemaVersion\":3,\"store\":\"\(store.rawValue)\",\"payload\":".utf8)
                wrapped.append(original)
                wrapped.append(Data("}".utf8))
                _ = try VersionedStoreCodec(format: .version3, store: store).decode(T.self, from: wrapped, decoder: policy.decoder)
                output[url.lastPathComponent] = wrapped
            } else { output[url.lastPathComponent] = encoded }
            counts[url.lastPathComponent] = count
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
            selectedSourceSHA256: input.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
            initializedAbsentStores: primaryFilenames.subtracting(input.keys),
            historicalJobIDsWithoutCurrentJob: history,
            calendarBindingJobIDsWithoutCurrentJob: Set(calendar.bindings.map(\.jobID)).subtracting(jobIDs),
            pendingReceiptPhase: phase))
    }

    private static func unique<T: Hashable>(_ values: [T], label: String) throws {
        guard Set(values).count == values.count else { throw ConversionError.duplicateIdentity(label) }
    }

    private static func preflightTrackInference(_ data: Data, source: String) throws {
        // Stable 2.9 JSON encoders emit BOM-free UTF-8. Embedded UTF-16/32 or
        // a BOM would make an otherwise readable legacy payload invalid inside
        // the UTF-8 envelope; do not transcode selected source bytes implicitly.
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0),
              !data.starts(with: [0xEF, 0xBB, 0xBF]) else { throw ConversionError.unsupportedJSONEncoding(source) }
        let root = try JSONDecoder().decode(PreflightValue.self, from: data)
        var pending = [root]
        while let value = pending.popLast() {
            switch value {
            case .object(let object):
                if let clipsValue = object["clips"], case .array(let clips) = clipsValue, !clips.isEmpty,
                   object["photographerTracks"] == nil || object["photographerTracks"]?.isNull == true {
                    throw ConversionError.explicitPhotographerTracksRequired(source)
                }
                pending.append(contentsOf: object.values)
            case .array(let values): pending.append(contentsOf: values)
            case .null, .scalar: break
            }
        }
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

    private static func validateRange(_ range: MetadataSharingRange?) throws {
        if let range, !(range.start.timeIntervalSince1970.isFinite && range.end.timeIntervalSince1970.isFinite && range.end > range.start) {
            throw ConversionError.invalidRecord("calendar range")
        }
    }

    private static func validateCalendar(_ calendar: SharedMetadataCalendar) throws {
        guard calendar.revision >= 0, TimeZone(identifier: calendar.timeZone) != nil,
              ["owner", "editor", "reader"].contains(calendar.role),
              (calendar.rangeStart == nil) == (calendar.rangeEnd == nil) else { throw ConversionError.invalidRecord("calendar") }
        try validateRange(calendar.range)
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
