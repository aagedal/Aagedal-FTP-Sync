import Darwin
import Foundation

/// The MCP adapter exchanges private files with the admitted app runtime. Only
/// AppStore owns mutations, so job/library transactions and calendar observation
/// follow the same path as edits made in the UI.
@MainActor
final class MetadataMCPBridge {
    private let directory: URL
    private let store: AppStore
    private let calendar: MetadataCalendarCoordinator
    private let validateRuntime: @MainActor () throws -> Void
    private var loop: Task<Void, Never>?
    private let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        value.timeZone = .gmt
        return value
    }()

    init(directory: URL, store: AppStore, calendar: MetadataCalendarCoordinator,
         validateRuntime: @escaping @MainActor () throws -> Void = {}) {
        self.directory = directory
        self.store = store
        self.calendar = calendar
        self.validateRuntime = validateRuntime
    }

    func start() {
        guard loop == nil else { return }
        do {
            try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try validatePrivateDirectory(directory)
            try validatePrivateDirectory(requests)
            try validatePrivateDirectory(responses)
        } catch {
            store.alertMessage = "The metadata MCP bridge could not start: \(error.localizedDescription)"
            return
        }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.processPendingRequests()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private var requests: URL { directory.appendingPathComponent("requests", isDirectory: true) }
    private var responses: URL { directory.appendingPathComponent("responses", isDirectory: true) }

    private func validatePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw BridgeError("An MCP bridge directory is not a regular directory.")
        }
        guard info.st_mode & 0o077 == 0 else {
            throw BridgeError("An MCP bridge directory must be private to this user.")
        }
    }

    private func processPendingRequests() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: requests,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            process(file)
        }
    }

    private func process(_ file: URL) {
        let id = file.deletingPathExtension().lastPathComponent
        let result: [String: Any]
        do {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_size >= 0, info.st_size <= 65_536 else {
                throw BridgeError("The MCP request file is invalid or too large.")
            }
            let data = try Data(contentsOf: file)
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  request["id"] as? String == id,
                  let expiresAt = request["expires_at"] as? Double,
                  expiresAt > Date().timeIntervalSince1970,
                  let tool = request["tool"] as? String,
                  let arguments = request["arguments"] as? [String: Any] else {
                throw BridgeError("The MCP request is malformed or expired.")
            }
            result = ["ok": true, "data": try execute(tool, arguments: arguments)]
        } catch {
            result = ["ok": false, "error": error.localizedDescription]
        }
        // A failed response must not cause a write request to execute a second time.
        defer { try? FileManager.default.removeItem(at: file) }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            try? data.write(to: responses.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }

    private func execute(_ tool: String, arguments: [String: Any]) throws -> Any {
        guard !store.isSuspendedForExternalWriter else {
            throw BridgeError("The app has paused its storage session. Relaunch it before using metadata MCP tools.")
        }
        switch tool {
        case "fetch_jobs":
            return store.jobs.map { job -> [String: Any] in
                let automation = job.metadataAutomation
                var summary: [String: Any] = [
                    "id": job.id.uuidString, "name": job.name,
                    "metadata_enabled": automation?.isEnabled ?? false,
                    "photographer_count": automation?.photographers.count ?? 0,
                    "clip_count": automation?.clips.count ?? 0,
                    "has_unsaved_metadata_draft": store.metadataDraftsBeingEdited.contains(job.id)
                ]
                if let binding = calendar.binding(for: job.id) {
                    summary["calendar_id"] = binding.id.uuidString
                }
                return summary
            }

        case "fetch_photographers":
            if let jobID = try optionalJobID(arguments) {
                let job = try requireJob(jobID)
                return (job.metadataAutomation?.photographers ?? []).map(photographerResult)
            }
            return store.photographerLibrary.map(photographerResult)

        case "fetch_metadata_clips":
            let jobID = try requireUUID(arguments, "job_id")
            let job = try requireJob(jobID)
            let start = try optionalDate(arguments, "starts_before")
            let end = try optionalDate(arguments, "ends_after")
            if let start, let end, end >= start {
                throw BridgeError("ends_after must be before starts_before.")
            }
            return (job.metadataAutomation?.clips ?? [])
                .filter { (start == nil || $0.startsAt < start!) && (end == nil || $0.endsAt > end!) }
                .sorted { $0.startsAt < $1.startsAt }
                .map(clipResult)

        case "add_photographer":
            let jobID = try requireUUID(arguments, "job_id")
            try requireCleanDraft(jobID)
            let job = try requireJob(jobID)
            let name = try requireString(arguments, "name").trimmingCharacters(in: .whitespacesAndNewlines)
            let initials = try requireString(arguments, "filename_initials")
            guard !name.isEmpty else { throw BridgeError("Give the photographer a name.") }
            let profile = PhotographerProfile(name: name, filenamePrefix: initials, creator: name,
                copyrightNotice: try optionalString(arguments, "copyright_notice") ?? "")
            var automation = job.metadataAutomation ?? MetadataAutomation()
            automation.photographers.append(profile)
            if let message = automation.validationMessage { throw BridgeError(message) }
            guard store.saveMetadataAutomation(automation, for: jobID) else {
                throw BridgeError(store.alertMessage ?? "The photographer could not be saved.")
            }
            return photographerResult(profile)

        case "add_metadata_clip":
            let jobID = try requireUUID(arguments, "job_id")
            try requireCleanDraft(jobID)
            let job = try requireJob(jobID)
            let photographerID = try requireUUID(arguments, "photographer_id")
            var automation = job.metadataAutomation ?? MetadataAutomation()
            guard automation.photographers.contains(where: { $0.id == photographerID }) else {
                throw BridgeError("This photographer is not assigned to the job.")
            }
            let name = try requireString(arguments, "name")
            let start = try requireDate(arguments, "starts_at")
            let end = try requireDate(arguments, "ends_at")
            let keywords = try optionalStringArray(arguments, "keywords") ?? []
            let fields = ScheduledMetadataFields(
                headline: try optionalString(arguments, "headline") ?? "",
                description: try optionalString(arguments, "description") ?? "",
                keywords: keywords)
            var clip = MetadataScheduleClip(photographerID: photographerID, name: name,
                startsAt: start, endsAt: end, fields: fields)
            if let gps = arguments["gps"] as? [String: Any] {
                guard let latitude = gps["latitude"] as? Double,
                      let longitude = gps["longitude"] as? Double else {
                    throw BridgeError("GPS needs numeric latitude and longitude.")
                }
                clip.gpsPosition = ScheduledGPSPosition(latitude: latitude, longitude: longitude,
                    altitudeMeters: gps["altitude_meters"] as? Double, label: gps["label"] as? String)
            }
            automation.clips.append(clip)
            automation.ensurePhotographerTracks(for: clip)
            if let message = automation.validationMessage { throw BridgeError(message) }
            guard store.saveMetadataAutomation(automation, for: jobID) else {
                throw BridgeError(store.alertMessage ?? "The metadata clip could not be saved.")
            }
            return clipResult(clip)

        default:
            throw BridgeError("Unknown metadata MCP tool: \(tool)")
        }
    }

    private func requireCleanDraft(_ jobID: UUID) throws {
        try validateRuntime()
        guard !store.metadataDraftsBeingEdited.contains(jobID) else {
            throw BridgeError("This job has an unsaved metadata draft. Save or close it before adding records through MCP.")
        }
    }

    private func requireJob(_ id: UUID) throws -> SyncJob {
        guard let job = store.jobs.first(where: { $0.id == id }) else {
            throw BridgeError("No job has ID \(id.uuidString).")
        }
        return job
    }

    private func optionalJobID(_ arguments: [String: Any]) throws -> UUID? {
        guard arguments["job_id"] != nil else { return nil }
        return try requireUUID(arguments, "job_id")
    }

    private func requireUUID(_ arguments: [String: Any], _ key: String) throws -> UUID {
        guard let raw = arguments[key] as? String, let value = UUID(uuidString: raw) else {
            throw BridgeError("\(key) must be a UUID.")
        }
        return value
    }

    private func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String else { throw BridgeError("\(key) must be text.") }
        return value
    }

    private func optionalString(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard arguments[key] != nil else { return nil }
        return try requireString(arguments, key)
    }

    private func optionalStringArray(_ arguments: [String: Any], _ key: String) throws -> [String]? {
        guard let value = arguments[key] else { return nil }
        guard let array = value as? [String] else { throw BridgeError("\(key) must be a text list.") }
        return array
    }

    private func requireDate(_ arguments: [String: Any], _ key: String) throws -> Date {
        guard let text = arguments[key] as? String,
              let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            throw BridgeError("\(key) must be an ISO 8601 timestamp with a time zone.")
        }
        return date
    }

    private func optionalDate(_ arguments: [String: Any], _ key: String) throws -> Date? {
        guard arguments[key] != nil else { return nil }
        return try requireDate(arguments, key)
    }

    private func photographerResult(_ profile: PhotographerProfile) -> [String: Any] {
        ["id": profile.id.uuidString, "name": profile.photographerName,
         "filename_initials": profile.formattedFilenamePrefixes,
         "creator": profile.creator, "copyright_notice": profile.copyrightNotice]
    }

    private func clipResult(_ clip: MetadataScheduleClip) -> [String: Any] {
        var result: [String: Any] = [
            "id": clip.id.uuidString, "photographer_id": clip.photographerID.uuidString,
            "name": clip.name, "starts_at": formatter.string(from: clip.startsAt),
            "ends_at": formatter.string(from: clip.endsAt),
            "headline": clip.fields.headline, "description": clip.fields.description,
            "keywords": clip.fields.keywords
        ]
        if let position = clip.gpsPosition {
            var gps: [String: Any] = ["latitude": position.latitude, "longitude": position.longitude]
            if let altitude = position.altitudeMeters { gps["altitude_meters"] = altitude }
            if let label = position.label { gps["label"] = label }
            result["gps"] = gps
        }
        return result
    }
}

private struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
