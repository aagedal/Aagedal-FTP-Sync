import CryptoKit
import Foundation

/// Presents stable local names to the transfer pipeline and translates reads and
/// verified source removals back to the exact server names. Never used for uploads.
actor DownloadNamingSession: EndpointSession {
    private let source: any EndpointSession
    private let destination: any EndpointSession
    private let mappingURL: URL
    private let overwriteCaseVariants: Bool
    private let filter: FileFilter
    private var replacementDates: [String: Date] = [:]
    private struct ReplacementState: Codable {
        var names: [String: String]
        var newestDates: [String: Date]
    }
    private var names: [String: String] = [:]
    private var namesNeedCheckpoint = false
    private var occupied: Set<String> = []
    private var existingLocalPaths: Set<String> = []
    private var occupiedByKey: [String: String] = [:]
    private var originalByLocal: [String: String] = [:]
    private var prepared = false
    nonisolated let supportsCompletedDirectoryListings: Bool

    init(source: any EndpointSession, destination: any EndpointSession, overwriteCaseVariants: Bool = false, mappingURL: URL,
         filter: FileFilter = FileFilter()) {
        self.source = source
        self.destination = destination
        self.overwriteCaseVariants = overwriteCaseVariants
        self.filter = filter
        self.mappingURL = overwriteCaseVariants ? mappingURL.appendingPathExtension("replace") : mappingURL
        supportsCompletedDirectoryListings = !overwriteCaseVariants && source.supportsCompletedDirectoryListings
    }

    static func mappingURL(directory: URL, job: SyncJob, source: Endpoint, destination: Endpoint) -> URL {
        let identity = [job.id.uuidString, source.kind.rawValue, source.host.lowercased(), String(source.port),
                        source.username, source.remotePath, destination.localPath, String(job.usesManagedFolderStructure)]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return directory.appendingPathComponent(digest(identity) + ".json")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func prepare() async throws {
        guard !prepared else { return }
        if FileManager.default.fileExists(atPath: mappingURL.path) {
            do {
                if overwriteCaseVariants {
                    let saved = try JSONDecoder().decode(ReplacementState.self, from: Data(contentsOf: mappingURL))
                    names = saved.names
                    replacementDates = saved.newestDates
                } else {
                    names = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingURL))
                }
                guard names.allSatisfy({ original, local in
                    PathSafety.isSafeRelativePath(original) && PathSafety.isSafeRelativePath(local)
                        && !PathSafety.isInternalStagingPath(original) && !PathSafety.isInternalStagingPath(local)
                        && (original as NSString).deletingLastPathComponent == (local as NSString).deletingLastPathComponent
                        && (overwriteCaseVariants
                            ? PathSafety.localComparisonKey(original) == PathSafety.localComparisonKey(local)
                            : (original as NSString).pathExtension == (local as NSString).pathExtension)
                }), Set(names.values.map(PathSafety.localComparisonKey)).count == names.count else {
                    throw AppError.transferFailed("Invalid download name mapping.")
                }
            } catch {
                throw AppError.transferFailed("Saved download names could not be read safely. Restore the download name mapping before syncing. \(error.localizedDescription)")
            }
        }
        occupied = Set(try await destination.listFiles().keys)
        existingLocalPaths = occupied
        occupied.formUnion(names.values)
        for path in occupied {
            let key = PathSafety.localComparisonKey(path)
            if let previous = occupiedByKey[key], !PathSafety.hasIdenticalRepresentation(previous, path) {
                throw AppError.transferFailed("A local filename conflicts with a saved download name: \(previous) and \(path). Rename the local file before syncing.")
            }
            occupiedByKey[key] = path
        }
        originalByLocal = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
        prepared = true
    }

    func listFiles() async throws -> [String: SyncFile] {
        try await listFilesIncrementally { _ in }
    }

    func listFilesIncrementally(onCompletedDirectory: @escaping @Sendable (CompletedDirectoryListing) async throws -> Void) async throws -> [String: SyncFile] {
        try await prepare()
        if overwriteCaseVariants {
            // Select once from the complete listing so order and partial snapshots
            // cannot publish an older variant before a newer one is discovered.
            let files: [String: SyncFile]
            if let source = source as? any DownloadListingSession {
                files = try await source.listDownloadFiles(onCompletedDirectory: nil)
            } else { files = try await source.listFiles() }
            return try replacingFiles(files.values.filter { filter.includesFilename(path: $0.relativePath) })
        }
        let callback: @Sendable (CompletedDirectoryListing) async throws -> Void = { listing in
            let mapped = try await self.map(listing)
            try await onCompletedDirectory(mapped)
        }
        let files: [String: SyncFile]
        if let source = source as? any DownloadListingSession {
            files = try await source.listDownloadFiles(onCompletedDirectory: callback)
        } else {
            files = try await source.listFilesIncrementally(onCompletedDirectory: callback)
        }
        // Some sessions can only report part of the listing incrementally.
        let includedFiles = files.values.filter { filter.includesFilename(path: $0.relativePath) }
        let missing = includedFiles.filter { names[$0.relativePath] == nil }
        for (directory, pending) in Dictionary(grouping: missing, by: { ($0.relativePath as NSString).deletingLastPathComponent }) {
            _ = try map(CompletedDirectoryListing(relativeDirectory: directory,
                entries: pending.map { RemoteTreeEntry(relativePath: $0.relativePath, file: $0, hasAuthoritativeTimestamp: true) },
                validatedAncestors: []))
        }
        var result: [String: SyncFile] = [:]
        for file in includedFiles {
            let mapped = try localFile(file)
            guard result.updateValue(mapped, forKey: mapped.relativePath) == nil else {
                throw AppError.transferFailed("The server returned duplicate download files.")
            }
        }
        // Commit discoveries that did not need an early transfer before exposing
        // the authoritative listing. Export/removal checkpoint earlier when needed.
        try checkpointNames()
        return result
    }

    private func replacingFiles(_ files: [SyncFile]) throws -> [String: SyncFile] {
        let grouped = Dictionary(grouping: files, by: { PathSafety.localComparisonKey($0.relativePath) })
        var updated = names
        var dates = replacementDates
        let previousOriginals = Dictionary(uniqueKeysWithValues: names.keys.map { (PathSafety.localComparisonKey($0), $0) })
        var result: [String: SyncFile] = [:]
        for key in grouped.keys.sorted() {
            let candidates = grouped[key]!.sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
            }
            let winner = candidates[0]
            guard PathSafety.isSafeRelativePath(winner.relativePath),
                  Set(candidates.map(\.relativePath)).count == candidates.count else {
                throw AppError.transferFailed("The server returned duplicate or unsafe download files.")
            }
            let local = occupiedByKey[key] ?? winner.relativePath
            let repeated = candidates.count > 1 || !PathSafety.hasIdenticalRepresentation(local, winner.relativePath) || dates[key] != nil
            if repeated {
                guard !MetadataWriter.usesXMPSidecar(for: winner.relativePath),
                      (winner.relativePath as NSString).pathExtension.lowercased() != "xmp" else {
                    throw AppError.transferFailed("The RAW/XMP filename \(winner.relativePath) conflicts with another file. Rename the image and its companion on the server before syncing.")
                }
            }
            // Do not revert to a stale resend after the newest server variant is
            // removed. A missing local copy may still be recovered from the source.
            if let newest = dates[key], winner.modifiedAt < newest,
               existingLocalPaths.contains(local) { continue }
            if let previous = previousOriginals[key] { updated.removeValue(forKey: previous) }
            updated[winner.relativePath] = local
            if repeated { dates[key] = max(dates[key] ?? .distantPast, winner.modifiedAt) }
            result[local] = SyncFile(relativePath: local, size: winner.size, modifiedAt: winner.modifiedAt,
                originalRelativePath: local == winner.relativePath ? nil : winner.relativePath, tracksRepeatedDownload: repeated)
        }
        if updated != names || dates != replacementDates {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: mappingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(ReplacementState(names: updated, newestDates: dates)).write(to: mappingURL, options: .atomic)
            names = updated
            replacementDates = dates
        }
        originalByLocal = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
        return result
    }

    private func map(_ listing: CompletedDirectoryListing) throws -> CompletedDirectoryListing {
        try Task.checkCancellation()
        // Ignore excluded return uploads before allocating names or validating
        // RAW/XMP aliases; they must not prevent matching originals downloading.
        let entries = listing.entries.filter { $0.file == nil || filter.includesFilename(path: $0.relativePath) }
        let paths = Set(entries.map { PathSafety.localComparisonKey($0.relativePath) })
        // Preserve existing exact local names before allocating names for newcomers.
        let files = entries.compactMap(\.file).sorted {
            let firstExists = occupied.contains($0.relativePath), secondExists = occupied.contains($1.relativePath)
            if firstExists != secondExists { return firstExists }
            return $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }
        for file in files {
            try Task.checkCancellation()
            let path = file.relativePath
            guard PathSafety.isSafeRelativePath(path) else { throw AppError.transferFailed("Unsafe download name.") }
            if let saved = names[path] {
                if let existing = occupiedByKey[PathSafety.localComparisonKey(saved)], !PathSafety.hasIdenticalRepresentation(existing, saved) {
                    throw AppError.transferFailed("A local file conflicts with the saved download name \(saved). Rename that local file before syncing.")
                }
                continue
            }
            var local = path
            let existing = occupiedByKey[PathSafety.localComparisonKey(path)]
            let conflicting = existing.map { !PathSafety.hasIdenticalRepresentation($0, path) } ?? false
            let claimed = originalByLocal[path].map { $0 != path } ?? false
            if conflicting || claimed {
                // Renaming RAW/XMP independently could associate metadata with the
                // wrong image. Keep these ambiguous companion groups explicit.
                guard !MetadataWriter.usesXMPSidecar(for: path), (path as NSString).pathExtension.lowercased() != "xmp" else {
                    throw AppError.transferFailed("The RAW/XMP filename \(path) conflicts with another file. Rename the image and its companion on the server before syncing.")
                }
                let ns = path as NSString
                let ext = ns.pathExtension
                let stem = (ns.lastPathComponent as NSString).deletingPathExtension
                let folder = ns.deletingLastPathComponent
                var shortStem = stem
                while shortStem.utf8.count > 160 { shortStem.removeLast() }
                let suffix = String(Self.digest(path).prefix(10))
                var counter = 0
                repeat {
                    let name = shortStem + "~" + suffix + (counter == 0 ? "" : "-\(counter)") + (ext.isEmpty ? "" : "." + ext)
                    guard name.utf8.count <= 255 else { throw AppError.transferFailed("The download filename is too long to rename safely: \(path)") }
                    local = folder.isEmpty ? name : folder + "/" + name
                    counter += 1
                } while occupiedByKey[PathSafety.localComparisonKey(local)] != nil || paths.contains(PathSafety.localComparisonKey(local))
            }
            // Associations are append-only during a normal naming session. Keep
            // the actor's indexes together without copying the cumulative map for
            // every directory. No source read/removal can use a new association
            // until checkpointNames() has durably saved it.
            names[path] = local
            namesNeedCheckpoint = true
            occupied.insert(local)
            occupiedByKey[PathSafety.localComparisonKey(local)] = local
            originalByLocal[local] = path
        }
        return CompletedDirectoryListing(relativeDirectory: listing.relativeDirectory,
            entries: try entries.map { entry in
                guard let file = entry.file else { return entry }
                let mapped = try localFile(file)
                return RemoteTreeEntry(relativePath: mapped.relativePath, file: mapped, hasAuthoritativeTimestamp: entry.hasAuthoritativeTimestamp)
            }, validatedAncestors: listing.validatedAncestors)
    }

    /// Synchronous actor-isolated save: no mapping can change between encoding,
    /// atomic replacement and clearing the dirty bit. A failure retains the dirty
    /// state and prevents the delegated source operation from starting. The flat
    /// JSON format stays compatible with existing installations.
    private func checkpointNames() throws {
        try Task.checkCancellation()
        guard namesNeedCheckpoint else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: mappingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(names).write(to: mappingURL, options: .atomic)
        namesNeedCheckpoint = false
    }

    private func localFile(_ file: SyncFile) throws -> SyncFile {
        guard let path = names[file.relativePath] else { throw AppError.transferFailed("A download name was not saved before transfer.") }
        return SyncFile(relativePath: path, size: file.size, modifiedAt: file.modifiedAt,
                        originalRelativePath: path == file.relativePath ? nil : file.relativePath)
    }

    private func remoteFile(_ file: SyncFile) throws -> SyncFile {
        guard let original = originalByLocal[file.relativePath] else {
            throw AppError.transferFailed("The original server filename is unavailable; the source was left untouched.")
        }
        return SyncFile(relativePath: original, size: file.size, modifiedAt: file.modifiedAt)
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try await exportFile(file, to: temporaryURL, maximumSize: nil)
    }
    func exportFile(_ file: SyncFile, to temporaryURL: URL, maximumSize: Int64?) async throws {
        let original = try remoteFile(file)
        try checkpointNames()
        try await source.exportFile(original, to: temporaryURL, maximumSize: maximumSize)
    }
    func removeFile(_ file: SyncFile) async throws {
        let original = try remoteFile(file)
        try checkpointNames()
        try await source.removeFile(original)
    }
    func removeFilesTransactionally(_ files: [SyncFile]) async throws {
        let originals = try files.map(remoteFile)
        try checkpointNames()
        try await source.removeFilesTransactionally(originals)
    }
    func removeFilesTransactionally(_ files: [SyncFile], matching contents: [URL]) async throws {
        let originals = try files.map(remoteFile)
        try checkpointNames()
        try await source.removeFilesTransactionally(originals, matching: contents)
    }
    func importFile(from localURL: URL, as file: SyncFile, preserveDate: Bool, verifySize: Bool) async throws {
        throw AppError.invalidConfiguration("Download filename mappings cannot be used for uploads.")
    }
    func close() async { await source.close() }
}
