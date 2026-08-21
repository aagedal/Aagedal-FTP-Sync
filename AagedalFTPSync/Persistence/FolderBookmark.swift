import Foundation

enum FolderBookmark {
    static func create(for url: URL) throws -> (data: Data, resolvedURL: URL) {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else {
            throw AppError.folderPermissionLost("macOS returned a stale folder permission. Please choose the folder again.")
        }
        return (data, resolvedURL)
    }
}
