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

    func includes(path: String, modifiedAt: Date, now: Date = Date()) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if !includeHiddenFiles, path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        if let allowedExtensions, !allowedExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
            return false
        }
        if let recentHours, modifiedAt < now.addingTimeInterval(-Double(recentHours) * 3_600) {
            return false
        }
        return true
    }
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
    var preserveModificationDates = true
    var verifyFileSizes = true

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this job a name." }
        if let message = left.validationMessage { return "Left side: \(message)" }
        if let message = right.validationMessage { return "Right side: \(message)" }
        if left.kind.isRemote && right.kind.isRemote { return "Version 2.0 supports remote ↔ local and local ↔ local jobs." }
        if intervalSeconds < 2 { return "The interval must be at least 2 seconds." }
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
    case succeeded(Date, transferred: Int)
    case failed(String)

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .waiting: "Waiting"
        case .syncing: "Syncing…"
        case .succeeded(_, let count): count == 1 ? "1 file transferred" : "\(count) files transferred"
        case .failed(let message): message
        }
    }
}
