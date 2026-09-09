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
    case allMedia
    case jpeg
    case raw
    case photos
    case video
    case audio
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All files"
        case .allMedia: "All Media"
        case .jpeg: "JPEG"
        case .raw: "Camera RAW"
        case .photos: "All photos"
        case .video: "Video"
        case .audio: "Audio"
        case .custom: "Custom extensions"
        }
    }

    var extensions: Set<String>? {
        switch self {
        case .all: return nil
        case .allMedia:
            return (FilterPreset.photos.extensions ?? [])
                .union(FilterPreset.video.extensions ?? [])
                .union(FilterPreset.audio.extensions ?? [])
        case .jpeg: return ["jpg", "jpeg"]
        case .raw: return ["3fr", "arw", "cr2", "cr3", "dng", "erf", "fff", "iiq", "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "x3f"]
        case .photos:
            return Set(["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"] + Array(FilterPreset.raw.extensions ?? []))
        case .video: return ["3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "mxf", "webm"]
        case .audio: return ["aac", "aif", "aiff", "alac", "bwf", "caf", "flac", "m4a", "mp3", "oga", "ogg", "opus", "wav", "wave", "wma"]
        case .custom: return []
        }
    }
}

struct FileFilter: Codable, Hashable, Sendable {
    var preset: FilterPreset = .photos
    var customExtensions = "jpg, jpeg, png, heic, dng, cr2, cr3, nef, arw, raf"
    var includeHiddenFiles = false
    var recentHours: Int? = nil
    // Optional to preserve jobs and export packages saved before filename filtering.
    var photographerInitials: String? = nil
    var excludedFilenamePrefixes: String? = nil
    var excludedFilenameSuffixes: String? = nil
    var ignoreAFTPSyncUploads: Bool? = nil

    var ignoresAFTPSyncUploads: Bool {
        get { ignoreAFTPSyncUploads ?? false }
        set { ignoreAFTPSyncUploads = newValue }
    }

    private func filenameValues(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }.filter { !$0.isEmpty }
    }

    func includesFilename(path: String) -> Bool {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.uppercased()
        if ignoresAFTPSyncUploads, stem.hasSuffix(UploadNaming.standardSuffix.uppercased()) { return false }
        if filenameValues(excludedFilenamePrefixes).contains(where: { stem.hasPrefix($0) }) { return false }
        if filenameValues(excludedFilenameSuffixes).contains(where: { stem.hasSuffix($0) }) { return false }
        let initials = filenameValues(photographerInitials)
        // Match the photographer library's camera-prefix convention.
        return initials.isEmpty || initials.contains { stem.hasPrefix($0) }
    }

    var allowedExtensions: Set<String>? {
        if preset != .custom { return preset.extensions }
        let values = customExtensions
            .components(separatedBy: CharacterSet(charactersIn: ",; \n\t"))
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        return Set(values)
    }

    func includesFileType(path: String) -> Bool {
        guard includesFilename(path: path) else { return false }
        if !includeHiddenFiles, path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        guard let allowedExtensions else { return true }
        let lexicalPath = path as NSString
        let ext: String
        switch lexicalPath.lastPathComponent {
        case "", ".", "..":
            // Preserve the old current-directory resolution for directory-only
            // inputs. Valid scanner filenames never take this fallback.
            ext = URL(fileURLWithPath: path).pathExtension
        default:
            // A file extension is lexical: constructing a relative file URL asks
            // Foundation to resolve the working directory for every scanned file.
            ext = lexicalPath.pathExtension
        }
        return allowedExtensions.contains(ext.lowercased())
    }

    func includes(path: String, modifiedAt: Date, now: Date = Date()) -> Bool {
        guard includesFileType(path: path) else { return false }
        if let recentHours, modifiedAt < now.addingTimeInterval(-Double(recentHours) * 3_600) {
            return false
        }
        return true
    }
}

struct UploadNaming: Codable, Hashable, Sendable {
    static let standardSuffix = "_aftpsync"

    var prefix = ""
    var suffix = ""
    // Missing in older jobs: keep the shared marker off.
    var addStandardSuffix: Bool? = nil

    var addsStandardSuffix: Bool {
        get { addStandardSuffix ?? false }
        set { addStandardSuffix = newValue }
    }

    var isEnabled: Bool { !prefix.isEmpty || !suffix.isEmpty || addsStandardSuffix }

    var validationMessage: String? {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        if (prefix + suffix).unicodeScalars.contains(where: { forbidden.contains($0) }) {
            return "Upload prefixes and suffixes cannot contain slashes, colons, or control characters."
        }
        if prefix != prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            || suffix != suffix.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "Remove spaces at the start or end of the upload prefix and suffix."
        }
        return nil
    }

    func relativePath(for original: String) throws -> String {
        if let validationMessage { throw AppError.invalidConfiguration(validationMessage) }
        guard PathSafety.isSafeRelativePath(original) else {
            throw AppError.transferFailed("The upload source has an unsafe filename.")
        }
        let path = original as NSString
        let filename = path.lastPathComponent as NSString
        let ext = filename.pathExtension
        var stem = prefix + filename.deletingPathExtension + suffix
        if addsStandardSuffix, !stem.lowercased().hasSuffix(Self.standardSuffix) {
            stem += Self.standardSuffix
        }
        let renamed = stem + (ext.isEmpty ? "" : "." + ext)
        let directory = path.deletingLastPathComponent
        let result = directory.isEmpty ? renamed : directory + "/" + renamed
        guard PathSafety.isSafeServerName(renamed), renamed.utf8.count <= 255,
              !PathSafety.isInternalStagingPath(result) else {
            throw AppError.transferFailed("The upload filename is reserved, unsafe, or longer than 255 bytes: \(renamed)")
        }
        return result
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
    var hasMetadataProgramming: Bool {
        guard let metadataAutomation else { return false }
        return !metadataAutomation.clips.isEmpty || !metadataAutomation.photographerTracks.isEmpty
            || !metadataAutomation.photographers.isEmpty
    }

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
    // Missing in older jobs: preserve case variants as separate downloads.
    var overwriteCaseVariantDownloads: Bool? = nil
    var uploadNaming: UploadNaming? = nil
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

    var overwritesCaseVariantDownloads: Bool {
        get { overwriteCaseVariantDownloads ?? false }
        set { overwriteCaseVariantDownloads = newValue }
    }

    var supportsCaseVariantDownloads: Bool {
        (direction == .leftToRight && left.kind.isRemote && right.kind == .local)
            || (direction == .rightToLeft && right.kind.isRemote && left.kind == .local)
    }

    var supportsUploadNaming: Bool {
        sourceEndpoint?.kind == .local && destinationEndpoint?.kind.isRemote == true
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

    var usesDownloadModificationTime: Bool {
        destinationEndpoint?.kind == .local && !preserveModificationDates
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

    func imageOutputFolder(for photographer: PhotographerProfile) -> (
        endpoint: Endpoint, managedFolder: ManagedOutputFolder?, photographerFolder: String?
    )? {
        let endpoint: Endpoint?
        let managedFolder: ManagedOutputFolder?
        if movesProcessedFiles {
            switch effectiveProcessedFilesLocation {
            case .customFolder:
                endpoint = processedFolder
                managedFolder = nil
            case .processedSubfolder:
                endpoint = destinationEndpoint
                managedFolder = .processedFiles
            }
        } else {
            endpoint = destinationEndpoint
            managedFolder = nil
        }
        guard let endpoint, endpoint.kind == .local else { return nil }
        let photographerFolder = movesProcessedFiles && sortsProcessedFilesByPhotographer
            ? PhotographerOutputFolder.name(
                for: photographer,
                photographers: metadataAutomation?.photographers ?? [photographer]
            )
            : nil
        return (endpoint, managedFolder, photographerFolder)
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this job a name." }
        if let message = left.validationMessage { return "Left side: \(message)" }
        if let message = right.validationMessage { return "Right side: \(message)" }
        if left.kind.isRemote && right.kind.isRemote { return "Version 2.0 supports remote ↔ local and local ↔ local jobs." }
        if intervalSeconds < 5 { return "The interval must be at least 5 seconds." }
        if let uploadNaming, uploadNaming.isEnabled {
            guard supportsUploadNaming else {
                return "Upload filename changes require a one-way job from a local folder to a server. Clear the upload prefix and suffix and turn off the _aftpsync suffix before changing direction."
            }
            if let message = uploadNaming.validationMessage { return message }
        }
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
            // Folder preferences can be saved before metadata is configured.
            // The engine only moves source files after metadata is applied.

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
    var originalRelativePath: String? = nil
    var tracksRepeatedDownload = false
    var filterPath: String { originalRelativePath ?? relativePath }
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
        nextRun: Date?,
        pendingSourceFiles: [String] = []
    )
    case failed(String, retryAt: Date?)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .waiting: return "Waiting"
        case .syncing: return "Syncing…"
        case .succeeded(_, let transferred, let deleted, let processed, let conflicts, let metadataReport, _, let pendingSourceFiles):
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
            if !pendingSourceFiles.isEmpty {
                parts.append(pendingSourceFiles.count == 1
                    ? "1 changing source file deferred until next sync"
                    : "\(pendingSourceFiles.count) changing source files deferred until next sync")
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
    let pendingSourceFiles: [String]

    init(
        transferred: Int,
        deleted: Int,
        processed: Int = 0,
        conflicts: [String] = [],
        metadataReport: MetadataRunReport = .empty,
        pendingSourceFiles: [String] = []
    ) {
        self.transferred = transferred
        self.deleted = deleted
        self.processed = processed
        self.conflicts = conflicts
        self.metadataReport = metadataReport
        self.pendingSourceFiles = pendingSourceFiles
    }

    var hasActivity: Bool {
        transferred > 0
            || deleted > 0
            || processed > 0
            || !conflicts.isEmpty
            || metadataReport.hasActivity
            || !pendingSourceFiles.isEmpty
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
        if !pendingSourceFiles.isEmpty {
            parts.append("\(pendingSourceFiles.count) changing source file(s) deferred until next sync")
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
            metadataReport: combinedMetadataReport,
            pendingSourceFiles: Array(Set(pendingSourceFiles).union(other.pendingSourceFiles)).sorted()
        )
    }
}

struct SyncRunFailure: LocalizedError, Sendable {
    let failureDescription: String
    let partialResult: SyncResult
    let completedWithSourceFailures: Bool

    init(_ error: any Error, partialResult: SyncResult) {
        failureDescription = error.localizedDescription
        self.partialResult = partialResult
        completedWithSourceFailures = false
    }

    init(failureDescription: String, partialResult: SyncResult, completedWithSourceFailures: Bool = false) {
        self.failureDescription = failureDescription
        self.partialResult = partialResult
        self.completedWithSourceFailures = completedWithSourceFailures
    }

    var errorDescription: String? { failureDescription }
}

/// Shared with file publishing so Finder opens the exact photographer directory.
enum PhotographerOutputFolder {
    static func name(
        for photographer: PhotographerProfile,
        photographers: [PhotographerProfile]
    ) -> String {
        let readableName = readablePhotographerFolderName(for: photographer)
        let comparisonKey = folderComparisonKey(readableName)
        let matchingFolders = photographers.filter {
            folderComparisonKey(readablePhotographerFolderName(for: $0)) == comparisonKey
        }
        guard matchingFolders.contains(where: { $0.id != photographer.id }) else {
            return readableName
        }

        let shortIdentifier = String(photographer.id.uuidString.prefix(8)).lowercased()
        let shortIdentifierIsUnique = !matchingFolders.contains {
            $0.id != photographer.id
                && $0.id.uuidString.prefix(8).lowercased() == shortIdentifier
        }
        let identifier = shortIdentifierIsUnique
            ? shortIdentifier
            : photographer.id.uuidString.lowercased()
        return "\(readableName) [\(identifier)]"
    }

    private static func readablePhotographerFolderName(for photographer: PhotographerProfile) -> String {
        let base = safeFolderComponent(
            photographer.photographerName,
            fallback: "Photographer",
            maximumScalars: 36
        )
        let identifier = photographer.normalizedPrefixes.first
            ?? "ID-\(photographer.id.uuidString.prefix(8))"
        let readableIdentifier = safeFolderComponent(
            identifier,
            fallback: "ID-\(photographer.id.uuidString.prefix(8))",
            maximumScalars: 12
        )
        return "\(base) (\(readableIdentifier))"
    }

    private static func safeFolderComponent(
        _ value: String,
        fallback: String,
        maximumScalars: Int = 60
    ) -> String {
        let replacedScalars = value.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return " "
            }
            return Character(String(scalar))
        }
        let collapsed = String(replacedScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        var limited = String(collapsed.unicodeScalars.prefix(maximumScalars))
        if limited.isEmpty || limited == "." || limited == ".." {
            return fallback
        }
        if PathSafety.isInternalStagingPath(limited) {
            let visibleName = limited.drop(while: { $0 == "." })
            limited = String("Photographer \(visibleName)".unicodeScalars.prefix(maximumScalars))
        }
        return limited
    }

    private static func folderComparisonKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

}
