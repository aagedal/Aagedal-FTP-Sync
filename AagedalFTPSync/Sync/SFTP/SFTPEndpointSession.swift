import Foundation

// Implemented with Citadel in SFTPEndpointSession+Citadel.swift. Keeping the
// endpoint wrapper separate makes the sync engine independent of SSH details.
struct SFTPEndpointSession: EndpointSession, Sendable {
    private let transport: SFTPTransport

    var supportsCompletedDirectoryListings: Bool { true }

    init(endpoint: Endpoint, password: String) {
        transport = SFTPTransport(endpoint: endpoint, password: password)
    }

    func testConnection() async throws {
        try await transport.testConnection()
    }

    func listFiles() async throws -> [String: SyncFile] {
        try await transport.listFiles()
    }

    func listFilesIncrementally(
        onCompletedDirectory: @escaping @Sendable (CompletedDirectoryListing) async throws -> Void
    ) async throws -> [String: SyncFile] {
        try await transport.listFilesIncrementally(onCompletedDirectory: onCompletedDirectory)
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try await exportFile(file, to: temporaryURL, maximumSize: nil)
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL, maximumSize: Int64?) async throws {
        try await transport.download(file: file, to: temporaryURL, maximumSize: maximumSize)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        try await transport.upload(
            localURL: localURL,
            file: file,
            preserveDate: preserveDate,
            verifySize: verifySize
        )
    }

    func removeFile(_ file: SyncFile) async throws {
        try await transport.remove(file: file)
    }

    func removeFilesTransactionally(_ files: [SyncFile]) async throws {
        try await transport.removeTransactionally(files: files)
    }

    func removeFilesTransactionally(_ files: [SyncFile], matching contents: [URL]) async throws {
        try await transport.removeTransactionally(files: files, expectedContents: contents)
    }

    func close() async { await transport.close() }
}
