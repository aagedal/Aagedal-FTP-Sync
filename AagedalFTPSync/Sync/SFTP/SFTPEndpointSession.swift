import Foundation

// Implemented with Citadel in SFTPEndpointSession+Citadel.swift. Keeping the
// endpoint wrapper separate makes the sync engine independent of SSH details.
struct SFTPEndpointSession: EndpointSession, Sendable {
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

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try await transport.download(file: file, to: temporaryURL)
    }

    func importFile(from localURL: URL, as file: SyncFile, preserveDate: Bool) async throws {
        try await transport.upload(
            localURL: localURL,
            file: file,
            preserveDate: preserveDate
        )
    }

    func close() async { await transport.close() }
}
