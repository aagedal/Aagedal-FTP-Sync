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

enum ProcessedFilesLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case customFolder
    case processedSubfolder

    var id: Self { self }

    var title: String {
        switch self {
        case .customFolder: "Custom Folder"
        case .processedSubfolder: "Processed sub-folder"
        }
    }
}

enum ManagedOutputFolder: Sendable {
    case syncedFiles
    case processedFiles

    var directoryName: String {
        switch self {
        case .syncedFiles: "Synced Files"
        case .processedFiles: "Processed Files"
        }
    }

    func url(
        inside selectedRoot: URL,
        createIfNeeded: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = selectedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(directoryName, isDirectory: true).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("The managed folder structure attempted to leave its selected main folder.")
        }

        if fileManager.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw AppError.transferFailed("The managed folder \(directoryName) cannot be a symbolic link.")
            }
            guard values.isDirectory == true else {
                throw AppError.transferFailed("The main folder already contains a file named \(directoryName).")
            }
        } else if createIfNeeded {
            try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        } else {
            throw AppError.invalidConfiguration("The managed folder \(directoryName) has not been created yet.")
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("The managed folder \(directoryName) attempted to leave its selected main folder.")
        }
        return resolvedCandidate
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
    // Optional so jobs saved by earlier versions can inherit their previous enabled state.
    var startOnAppLaunch: Bool? = true
    // Optional so jobs saved by earlier versions keep the cumulative counter behavior.
    var latestSessionTransferCountOnly: Bool? = false
    var preserveModificationDates = true
    var verifyFileSizes = true
    // Optional so jobs saved by earlier versions retain metadata-only comparisons.
    var verifyMatchingFileContents: Bool? = false
    var targetCleanup: TargetCleanup? = nil
    // Optional so jobs saved by earlier versions continue to decode.
    var processedFolder: Endpoint? = nil
    // Optional so 2.5 jobs with a processed folder retain the custom-folder behavior.
    var processedFilesLocation: ProcessedFilesLocation? = nil
    // Optional so jobs saved before 2.6 retain their flat processed-folder behavior.
    var sortProcessedFilesByPhotographer: Bool? = nil
    // Optional so jobs saved by earlier versions continue to decode.
    var metadataAutomation: MetadataAutomation? = nil

    var startsOnAppLaunch: Bool {
        get { startOnAppLaunch ?? isEnabled }
        set { startOnAppLaunch = newValue }
    }

    var showsLatestSessionTransferCountOnly: Bool {
        get { latestSessionTransferCountOnly ?? false }
        set { latestSessionTransferCountOnly = newValue }
    }

    var verifiesMatchingFileContents: Bool {
        get { verifyMatchingFileContents ?? false }
        set { verifyMatchingFileContents = newValue }
    }

    var movesProcessedFiles: Bool {
        processedFolder != nil || processedFilesLocation != nil
    }

    var effectiveProcessedFilesLocation: ProcessedFilesLocation {
        processedFilesLocation ?? .customFolder
    }

    var sortsProcessedFilesByPhotographer: Bool {
        get { sortProcessedFilesByPhotographer ?? false }
        set { sortProcessedFilesByPhotographer = newValue }
    }

    var usesManagedFolderStructure: Bool {
        movesProcessedFiles && effectiveProcessedFilesLocation == .processedSubfolder
    }

    var destinationEndpoint: Endpoint? {
        switch direction {
        case .leftToRight: right
        case .rightToLeft: left
        case .bidirectional: nil
        }
    }

    var sourceEndpoint: Endpoint? {
        switch direction {
        case .leftToRight: left
        case .rightToLeft: right
        case .bidirectional: nil
        }
    }

    var localDestinationSubdirectory: String? {
        usesManagedFolderStructure ? ManagedOutputFolder.syncedFiles.directoryName : nil
    }

    var localDestinationDisplayPath: String? {
        guard let destinationEndpoint, destinationEndpoint.kind == .local else { return nil }
        guard let localDestinationSubdirectory else { return destinationEndpoint.localPath }
        return URL(fileURLWithPath: destinationEndpoint.localPath)
            .appendingPathComponent(localDestinationSubdirectory, isDirectory: true)
            .path
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
        if movesProcessedFiles {
            guard direction != .bidirectional else {
                return "Moving processed files is only available for one-way jobs."
            }
            guard metadataAutomation?.isEnabled == true else {
                return "Enable automatic metadata before moving files to a processed folder."
            }

            switch effectiveProcessedFilesLocation {
            case .customFolder:
                guard let processedFolder else {
                    return "Choose a custom processed folder."
                }
                guard processedFolder.kind == .local else {
                    return "The processed-files location must be a local folder."
                }
                if let message = processedFolder.validationMessage {
                    return "Processed folder: \(message)"
                }
                let processedURL = URL(fileURLWithPath: processedFolder.localPath)
                    .standardizedFileURL.resolvingSymlinksInPath()
                for endpoint in [left, right] where endpoint.kind == .local {
                    let endpointURL = URL(fileURLWithPath: endpoint.localPath)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    let foldersOverlap = processedURL == endpointURL
                        || processedURL.path.hasPrefix(endpointURL.path + "/")
                        || endpointURL.path.hasPrefix(processedURL.path + "/")
                    guard !foldersOverlap else {
                        return "The processed folder must be separate from the source and destination folders."
                    }
                }

            case .processedSubfolder:
                guard let destinationEndpoint, destinationEndpoint.kind == .local else {
                    return "The managed folder structure requires a local destination folder."
                }
                if let sourceEndpoint, sourceEndpoint.kind == .local {
                    let sourceURL = URL(fileURLWithPath: sourceEndpoint.localPath)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    let mainURL = URL(fileURLWithPath: destinationEndpoint.localPath)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    let foldersOverlap = sourceURL == mainURL
                        || sourceURL.path.hasPrefix(mainURL.path + "/")
                        || mainURL.path.hasPrefix(sourceURL.path + "/")
                    guard !foldersOverlap else {
                        return "The managed main folder must be separate from the local source folder."
                    }
                }
            }
        }
        if let metadataAutomation, metadataAutomation.isEnabled {
            guard direction != .bidirectional else {
                return "Automatic metadata is only available for one-way jobs."
            }
            let target = direction == .leftToRight ? right : left
            guard target.kind == .local else {
                return "Automatic metadata requires a local destination folder."
            }
            if let message = metadataAutomation.validationMessage { return message }
        }
        if left.kind == .local, right.kind == .local {
            let leftURL = URL(fileURLWithPath: left.localPath).standardizedFileURL.resolvingSymlinksInPath()
            let rightURL = URL(fileURLWithPath: right.localPath).standardizedFileURL.resolvingSymlinksInPath()
            let leftComponents = leftURL.pathComponents
            let rightComponents = rightURL.pathComponents
            if leftComponents.starts(with: rightComponents) || rightComponents.starts(with: leftComponents) {
                return "Source and destination folders must not overlap."
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
    case succeeded(
        Date,
        transferred: Int,
        deleted: Int,
        processed: Int,
        conflicts: [String],
        metadataReport: MetadataRunReport,
        nextRun: Date?
    )
    case failed(String, retryAt: Date?)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .waiting: return "Waiting"
        case .syncing: return "Syncing…"
        case .succeeded(_, let transferred, let deleted, let processed, let conflicts, let metadataReport, _):
            let transferText = transferred == 1 ? "1 file transferred" : "\(transferred) files transferred"
            var parts = [transferText]
            if deleted > 0 { parts.append("\(deleted) deleted") }
            if processed > 0 {
                parts.append(processed == 1 ? "1 moved to processed" : "\(processed) moved to processed")
            }
            if conflicts.count == 1 { parts.append("1 conflict skipped: \(conflicts[0])") }
            else if conflicts.count > 1 { parts.append("\(conflicts.count) conflicts skipped") }
            if metadataReport.hasActivity {
                parts.append(
                    "metadata: \(metadataReport.applied) applied, \(metadataReport.skipped) skipped, \(metadataReport.failed) failed"
                )
            }
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
    let processed: Int
    let conflicts: [String]
    let metadataReport: MetadataRunReport

    init(
        transferred: Int,
        deleted: Int,
        processed: Int = 0,
        conflicts: [String] = [],
        metadataReport: MetadataRunReport = .empty
    ) {
        self.transferred = transferred
        self.deleted = deleted
        self.processed = processed
        self.conflicts = conflicts
        self.metadataReport = metadataReport
    }

    var hasActivity: Bool {
        transferred > 0
            || deleted > 0
            || processed > 0
            || !conflicts.isEmpty
            || metadataReport.hasActivity
    }

    var summary: String? {
        guard hasActivity else { return nil }
        var parts: [String] = []
        if transferred > 0 {
            parts.append(transferred == 1 ? "1 file transferred" : "\(transferred) files transferred")
        }
        if deleted > 0 {
            parts.append(deleted == 1 ? "1 target file deleted" : "\(deleted) target files deleted")
        }
        if processed > 0 {
            parts.append(processed == 1 ? "1 source moved to processed" : "\(processed) sources moved to processed")
        }
        if conflicts.count == 1 {
            parts.append("1 conflict skipped")
        } else if conflicts.count > 1 {
            parts.append("\(conflicts.count) conflicts skipped")
        }
        if metadataReport.hasActivity, transferred == 0 {
            parts.append(metadataReport.entries.count == 1
                ? "1 metadata decision recorded"
                : "\(metadataReport.entries.count) metadata decisions recorded")
        }
        return parts.joined(separator: ", ")
    }

    func adding(_ other: SyncResult) -> SyncResult {
        var combinedMetadataReport = metadataReport
        combinedMetadataReport.append(contentsOf: other.metadataReport)
        return SyncResult(
            transferred: transferred + other.transferred,
            deleted: deleted + other.deleted,
            processed: processed + other.processed,
            conflicts: Array(Set(conflicts).union(other.conflicts)).sorted(),
            metadataReport: combinedMetadataReport
        )
    }
}

struct SyncRunFailure: LocalizedError, Sendable {
    let failureDescription: String
    let partialResult: SyncResult

    init(_ error: any Error, partialResult: SyncResult) {
        failureDescription = error.localizedDescription
        self.partialResult = partialResult
    }

    init(failureDescription: String, partialResult: SyncResult) {
        self.failureDescription = failureDescription
        self.partialResult = partialResult
    }

    var errorDescription: String? { failureDescription }
}
