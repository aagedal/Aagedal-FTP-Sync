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
            guard !relative.isEmpty else { continue }
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

    func importFile(from localURL: URL, as file: SyncFile, preserveDate: Bool) async throws {
        let destination = try safeURL(for: file.relativePath)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".aagedal-sync-\(UUID().uuidString).part")
        do {
            try fileManager.copyItem(at: localURL, to: staging)
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

    private func safeURL(for relativePath: String) throws -> URL {
        guard PathSafety.isSafeRelativePath(relativePath) else {
            throw AppError.transferFailed("A file contained an unsafe relative path and was skipped.")
        }
        let root = access.url.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw AppError.transferFailed("A file path attempted to leave its selected folder.")
        }
        return candidate
    }
}
