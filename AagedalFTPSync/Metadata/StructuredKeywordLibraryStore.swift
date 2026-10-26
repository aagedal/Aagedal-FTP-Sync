import AppKit
import Foundation

/// Reads Aagedal Photo Agent's Lists folder through a user-granted bookmark.
/// Without a linked folder, only the bundled IPTC Media Topics list is active,
/// matching Photo Agent's defaults. Nothing is ever written to the folder.
@MainActor
final class StructuredKeywordLibraryStore: ObservableObject {
    static let shared = StructuredKeywordLibraryStore()

    @Published private(set) var catalog = StructuredKeywordCatalog.empty
    @Published private(set) var linkedFolderPath: String?
    @Published private(set) var activeListNames: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let defaults: UserDefaults
    private let bookmarkKey = "structuredKeywords.listsFolderBookmark"
    private var vocabulary: IPTCMediaTopics?
    private var loadGeneration = 0
    private var activationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    /// Photo Agent's local Lists folder, used as the panel's starting point.
    static var photoAgentListsFolder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Aagedal Photo Agent/Lists", isDirectory: true)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Photo Agent’s Lists Folder"
        panel.message = "Choose the Lists folder in Aagedal Photo Agent’s Application Support or iCloud Drive folder. FTP Sync only reads it."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.directoryURL = Self.photoAgentListsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try FolderBookmark.create(for: url)
            defaults.set(bookmark.data, forKey: bookmarkKey)
            reload()
        } catch {
            errorMessage = "The folder could not be linked: \(error.localizedDescription)"
        }
    }

    func unlinkFolder() {
        defaults.removeObject(forKey: bookmarkKey)
        reload()
    }

    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let bookmark = defaults.data(forKey: bookmarkKey)
        let cachedVocabulary = vocabulary
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = Self.load(bookmark: bookmark, vocabulary: cachedVocabulary)
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.vocabulary = result.vocabulary ?? self.vocabulary
                self.catalog = result.catalog
                self.linkedFolderPath = result.folderPath
                self.activeListNames = result.catalog.roots.map(\.name)
                self.errorMessage = result.error
                self.isLoading = false
            }
        }
    }

    private struct LoadResult: Sendable {
        var catalog: StructuredKeywordCatalog
        var vocabulary: IPTCMediaTopics?
        var folderPath: String?
        var error: String?
    }

    nonisolated private static func load(bookmark: Data?, vocabulary cached: IPTCMediaTopics?) -> LoadResult {
        var vocabulary = cached
        var problems: [String] = []
        if vocabulary == nil {
            do { vocabulary = try IPTCMediaTopics.bundled() }
            catch { problems.append(StructuredKeywordLibraryError.missingVocabulary.localizedDescription) }
        }
        guard let bookmark else {
            return LoadResult(catalog: StructuredKeywordCatalog(document: .init(), myKeywords: [], vocabulary: vocabulary),
                              vocabulary: vocabulary, error: problems.first)
        }
        var isStale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                    relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            problems.append("The linked Photo Agent folder is no longer available. Choose it again.")
            return LoadResult(catalog: StructuredKeywordCatalog(document: .init(), myKeywords: [], vocabulary: vocabulary),
                              vocabulary: vocabulary, error: problems.joined(separator: " "))
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let structured = structuredFolder(in: folder)
        var document = StructuredKeywordLibraryDocument()
        var myKeywords: [StructuredKeyword] = []
        if let structured {
            let libraryURL = structured.appendingPathComponent("library.json")
            if let data = try? Data(contentsOf: libraryURL) {
                do { document = try StructuredKeywordLibraryDocument.decode(data) }
                catch { problems.append("library.json: \(error.localizedDescription) Using the default lists.") }
            }
            if let data = try? Data(contentsOf: structured.appendingPathComponent("keywords.txt")) {
                do { myKeywords = try StructuredKeywordParser.parse(data: data) }
                catch { problems.append("keywords.txt: \(error.localizedDescription)") }
            }
        } else {
            problems.append("The linked folder has no “structured” folder. Choose Photo Agent’s Lists folder.")
        }
        if isStale { problems.append("macOS reports a stale folder permission. Choose the folder again.") }
        return LoadResult(
            catalog: StructuredKeywordCatalog(document: document, myKeywords: myKeywords, vocabulary: vocabulary),
            vocabulary: vocabulary, folderPath: folder.path,
            error: problems.isEmpty ? nil : problems.joined(separator: " "))
    }

    /// Accepts the Lists folder itself or a parent that contains it.
    nonisolated private static func structuredFolder(in folder: URL) -> URL? {
        let candidates = [folder, folder.appendingPathComponent("Lists", isDirectory: true),
                          folder.appendingPathComponent("Documents/Lists", isDirectory: true)]
        return candidates.lazy.map { $0.appendingPathComponent("structured", isDirectory: true) }.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
