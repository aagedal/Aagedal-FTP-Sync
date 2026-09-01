import Foundation

// Implemented with Citadel in SFTPEndpointSession+Citadel.swift. Keeping the
// endpoint wrapper separate makes the sync engine independent of SSH details.
struct SFTPEndpointSession: EndpointSession, FastStartSourceSession, Sendable {
    private let transport: SFTPTransport

    init(endpoint: Endpoint, password: String) {
        transport = SFTPTransport(endpoint: endpoint, password: password)
    }

    func testConnection() async throws {
        try await transport.testConnection()
    }

    func listFiles() async throws -> [String: SyncFile] {
        try await transport.listFiles()
    }

    func listFilesForFastStart(
        filter: FileFilter,
        minimumCount: Int
    ) async throws -> [String: SyncFile] {
        try await transport.listFilesForFastStart(filter: filter, minimumCount: minimumCount)
    }

    func refreshMetadataForFastStart(_ files: [SyncFile]) async throws -> [SyncFile] {
        files
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try await transport.download(file: file, to: temporaryURL)
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

    func close() async { await transport.close() }
}
