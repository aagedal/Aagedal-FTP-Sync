import Foundation

/// Maps a local source into its remote output namespace before comparison, so
/// repeated runs find the renamed upload and RAW/XMP companions stay together.
actor UploadNamingSession: EndpointSession {
    private let source: any EndpointSession
    private let naming: UploadNaming
    private let filter: FileFilter
    private var originals: [String: SyncFile] = [:]

    init(source: any EndpointSession, naming: UploadNaming, filter: FileFilter) {
        self.source = source
        self.naming = naming
        self.filter = filter
    }

    func listFiles() async throws -> [String: SyncFile] {
        let files = try await source.listFiles()
        var result: [String: SyncFile] = [:]
        var mappedOriginals: [String: SyncFile] = [:]
        // Keep companions even when XMP is not selected by the extension filter.
        let selected = files.values.filter { filter.includes(path: $0.relativePath, modifiedAt: $0.modifiedAt) }
        let selectedPaths = Set(selected.map(\.relativePath))
        let companions = Set(selected.filter { MetadataWriter.usesXMPSidecar(for: $0.relativePath) }
            .map { MetadataWriter.sidecarRelativePath(for: $0.relativePath) })
        for file in files.values where selectedPaths.contains(file.relativePath) || companions.contains(file.relativePath) {
            let path = try naming.relativePath(for: file.relativePath)
            guard mappedOriginals.updateValue(file, forKey: path) == nil else {
                throw AppError.transferFailed("Two source files would use the upload name \(path). Change the upload prefix or suffix.")
            }
            result[path] = SyncFile(relativePath: path, size: file.size, modifiedAt: file.modifiedAt,
                originalRelativePath: file.relativePath)
        }
        if let collision = PathSafety.localPathCollision(in: Array(result.keys)) {
            throw AppError.transferFailed("Two upload names cannot safely coexist: \(collision[0]) and \(collision[1]).")
        }
        let outputPaths = Set(result.keys.map(PathSafety.localComparisonKey))
        for path in result.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !outputPaths.contains(PathSafety.localComparisonKey(parent)) else {
                    throw AppError.transferFailed("An upload filename conflicts with an output folder: \(parent).")
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        originals = mappedOriginals
        return result
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try await exportFile(file, to: temporaryURL, maximumSize: nil)
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL, maximumSize: Int64?) async throws {
        guard let original = originals[file.relativePath] else {
            throw AppError.transferFailed("The original upload source filename is unavailable.")
        }
        try await source.exportFile(original, to: temporaryURL, maximumSize: maximumSize)
    }

    func importFile(from localURL: URL, as file: SyncFile, preserveDate: Bool, verifySize: Bool) async throws {
        throw AppError.invalidConfiguration("Upload filename mappings can only read from the local source.")
    }

    func close() async { await source.close() }
}
