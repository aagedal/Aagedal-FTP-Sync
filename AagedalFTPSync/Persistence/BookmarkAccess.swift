import Foundation

final class BookmarkAccess: @unchecked Sendable {
    let url: URL
    private let hasScope: Bool

    init(endpoint: Endpoint) throws {
        guard endpoint.kind == .local, let data = endpoint.bookmark else {
            throw AppError.folderPermissionLost("The folder must be selected again.")
        }
        var stale = false
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw AppError.folderPermissionLost("Folder access could not be restored. Edit the job and choose the folder again.")
        }
        guard !stale else {
            throw AppError.folderPermissionLost("The saved folder permission is stale. Edit the job and choose the folder again.")
        }
        hasScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasScope { url.stopAccessingSecurityScopedResource() }
    }
}
