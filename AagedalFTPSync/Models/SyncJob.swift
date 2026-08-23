import Foundation

enum SyncDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftToRight
    case rightToLeft
    case bidirectional

    var id: String { rawValue }
    var title: String {
        switch self {
        case .leftToRight: "Left → Right"
        case .rightToLeft: "Right → Left"
        case .bidirectional: "Two-way"
        }
    }
    var symbol: String {
        switch self {
        case .leftToRight: "arrow.right"
        case .rightToLeft: "arrow.left"
        case .bidirectional: "arrow.left.arrow.right"
        }
    }
}

enum FilterPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case jpeg
    case raw
    case photos
    case video
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All files"
        case .jpeg: "JPEG"
        case .raw: "Camera RAW"
        case .photos: "All photos"
        case .video: "Video"
        case .custom: "Custom extensions"
        }
    }

    var extensions: Set<String>? {
        switch self {
        case .all: return nil
        case .jpeg: return ["jpg", "jpeg"]
        case .raw: return ["3fr", "arw", "cr2", "cr3", "dng", "erf", "fff", "iiq", "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "x3f"]
        case .photos:
            return Set(["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"] + Array(FilterPreset.raw.extensions ?? []))
        case .video: return ["3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "mxf", "webm"]
        case .custom: return []
        }
    }
}

struct FileFilter: Codable, Hashable, Sendable {
    var preset: FilterPreset = .photos
    var customExtensions = "jpg, jpeg, png, heic, dng, cr2, cr3, nef, arw, raf"
    var includeHiddenFiles = false
    var recentHours: Int? = nil

    var allowedExtensions: Set<String>? {
        if preset != .custom { return preset.extensions }
        let values = customExtensions
            .components(separatedBy: CharacterSet(charactersIn: ",; \n\t"))
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        return Set(values)
    }

    func includesFileType(path: String) -> Bool {
        if !includeHiddenFiles, path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        guard let allowedExtensions else { return true }
        return allowedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    func includes(path: String, modifiedAt: Date, now: Date = Date()) -> Bool {
        guard includesFileType(path: path) else { return false }
        if let recentHours, modifiedAt < now.addingTimeInterval(-Double(recentHours) * 3_600) {
            return false
        }
        return true
    }
}

struct TargetCleanup: Codable, Hashable, Sendable {
    var olderThanHours: Int = 2
}

struct SyncJob: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = "Newsroom photos"
    var left = Endpoint.remote
    var right = Endpoint.local
    var direction = SyncDirection.leftToRight
    var filter = FileFilter()
    var intervalSeconds: Double = 5
    var isEnabled = true
    // Optional so jobs saved by earlier versions can inherit their previous enabled state.
    var startOnAppLaunch: Bool? = true
    // Optional so jobs saved by earlier versions keep the cumulative counter behavior.
    var latestSessionTransferCountOnly: Bool? = false
    var preserveModificationDates = true
    var verifyFileSizes = true
    var targetCleanup: TargetCleanup? = nil

    var startsOnAppLaunch: Bool {
        get { startOnAppLaunch ?? isEnabled }
        set { startOnAppLaunch = newValue }
    }

    var showsLatestSessionTransferCountOnly: Bool {
        get { latestSessionTransferCountOnly ?? false }
        set { latestSessionTransferCountOnly = newValue }
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this job a name." }
        if let message = left.validationMessage { return "Left side: \(message)" }
        if let message = right.validationMessage { return "Right side: \(message)" }
        if left.kind.isRemote && right.kind.isRemote { return "Version 2.0 supports remote ↔ local and local ↔ local jobs." }
        if intervalSeconds < 2 { return "The interval must be at least 2 seconds." }
        if let targetCleanup {
            guard direction != .bidirectional else { return "Automatic cleanup is only available for one-way jobs." }
            let target = direction == .leftToRight ? right : left
            guard target.kind == .local else { return "Automatic cleanup is only available when the target is a local folder." }
            guard let recentHours = filter.recentHours else {
                return "Choose a source file-age window before enabling automatic cleanup."
            }
            guard targetCleanup.olderThanHours > recentHours else {
                return "The cleanup age must be greater than the source file-age window."
            }
            if left.kind == .local, right.kind == .local {
                let leftURL = URL(fileURLWithPath: left.localPath).standardizedFileURL.resolvingSymlinksInPath()
                let rightURL = URL(fileURLWithPath: right.localPath).standardizedFileURL.resolvingSymlinksInPath()
                let foldersOverlap = leftURL == rightURL
                    || leftURL.path.hasPrefix(rightURL.path + "/")
                    || rightURL.path.hasPrefix(leftURL.path + "/")
                guard !foldersOverlap else {
                    return "Source and target folders must not overlap when cleanup is enabled."
                }
            }
        }
        return nil
    }
}

struct SyncFile: Hashable, Sendable {
    let relativePath: String
    let size: Int64
    let modifiedAt: Date
}

enum JobPhase: Equatable, Sendable {
    case stopped
    case waiting(Date)
    case syncing
    case succeeded(Date, transferred: Int, deleted: Int, conflicts: [String], nextRun: Date?)
    case failed(String, retryAt: Date?)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .waiting: return "Waiting"
        case .syncing: return "Syncing…"
        case .succeeded(_, let transferred, let deleted, let conflicts, _):
            let transferText = transferred == 1 ? "1 file transferred" : "\(transferred) files transferred"
            var parts = [transferText]
            if deleted > 0 { parts.append("\(deleted) deleted") }
            if conflicts.count == 1 { parts.append("1 conflict skipped: \(conflicts[0])") }
            else if conflicts.count > 1 { parts.append("\(conflicts.count) conflicts skipped") }
            return parts.joined(separator: ", ")
        case .failed(let message, let retryAt):
            guard let retryAt else { return message }
            return "\(message) Retry at \(retryAt.formatted(date: .omitted, time: .shortened))."
        }
    }
}

struct SyncResult: Equatable, Sendable {
    let transferred: Int
    let deleted: Int
    let conflicts: [String]

    init(transferred: Int, deleted: Int, conflicts: [String] = []) {
        self.transferred = transferred
        self.deleted = deleted
        self.conflicts = conflicts
    }
}
