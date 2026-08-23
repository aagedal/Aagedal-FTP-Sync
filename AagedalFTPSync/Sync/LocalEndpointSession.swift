import Foundation

struct LocalEndpointSession: EndpointSession, @unchecked Sendable {
    private let access: BookmarkAccess
    private let fileManager = FileManager.default

    init(endpoint: Endpoint) throws {
        access = try BookmarkAccess(endpoint: endpoint)
    }

    func listFiles() async throws -> [String: SyncFile] {
        let root = access.url.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            throw AppError.folderPermissionLost("Could not read \(root.path).")
        }

        var files: [String: SyncFile] = [:]
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalURL.path.hasPrefix(root.path + "/") else { continue }
            let relative = String(canonicalURL.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty, !PathSafety.isInternalStagingPath(relative) else { continue }
            if let existing = files[relative],
               !PathSafety.hasIdenticalRepresentation(existing.relativePath, relative) {
                throw AppError.transferFailed(
                    "Two file paths differ only by Unicode representation: \(existing.relativePath) and \(relative)."
                )
            }
            files[relative] = SyncFile(
                relativePath: relative,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        return files
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        let source = try safeURL(for: file.relativePath)
        try fileManager.copyItem(at: source, to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        let destination = try safeURL(for: file.relativePath)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".aagedal-sync-\(UUID().uuidString).part")
        do {
            try fileManager.copyItem(at: localURL, to: staging)
            if verifySize {
                let attributes = try fileManager.attributesOfItem(atPath: staging.path)
                let copiedSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard copiedSize == file.size else {
                    throw AppError.transferFailed(
                        "Size verification failed for \(file.relativePath): expected \(file.size) bytes, copied \(copiedSize) bytes."
                    )
                }
            }
            if preserveDate {
                try fileManager.setAttributes([.modificationDate: file.modifiedAt], ofItemAtPath: staging.path)
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func deleteFile(_ file: SyncFile, ifOlderThan cutoff: Date) async throws -> Bool {
        let target = try safeURL(for: file.relativePath)
        guard fileManager.fileExists(atPath: target.path) else { return false }
        let root = access.url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedTarget = target.resolvingSymlinksInPath()
        guard resolvedTarget.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("A target path attempted to leave its selected folder.")
        }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let modifiedAt = values.contentModificationDate,
              modifiedAt < cutoff else { return false }
        try fileManager.removeItem(at: target)
        return true
    }

    private func safeURL(for relativePath: String) throws -> URL {
        guard PathSafety.isSafeRelativePath(relativePath) else {
            throw AppError.transferFailed("A file contained an unsafe relative path and was skipped.")
        }
        let root = access.url.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("A file path attempted to leave its selected folder.")
        }

        var existingComponent = root
        for component in relativePath.split(separator: "/") {
            existingComponent.appendPathComponent(String(component))
            if (try? fileManager.destinationOfSymbolicLink(atPath: existingComponent.path)) != nil {
                throw AppError.transferFailed(
                    "A file path contained a symbolic link and was rejected: \(relativePath)"
                )
            }
            if !fileManager.fileExists(atPath: existingComponent.path) { break }
        }

        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard resolvedParent == root || resolvedParent.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("A file path attempted to leave its selected folder through a symbolic link.")
        }
        return candidate
    }
}
