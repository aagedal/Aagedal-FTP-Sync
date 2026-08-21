import Foundation

protocol EndpointSession: Sendable {
    func listFiles() async throws -> [String: SyncFile]
    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws
    func importFile(from localURL: URL, as file: SyncFile, preserveDate: Bool) async throws
    func close() async
}

extension EndpointSession {
    func close() async {}
}

enum EndpointSessionFactory {
    static func make(endpoint: Endpoint, password: String?) throws -> any EndpointSession {
        switch endpoint.kind {
        case .local:
            return try LocalEndpointSession(endpoint: endpoint)
        case .ftp, .ftps:
            guard let password else {
                throw AppError.invalidConfiguration("No password is saved for \(endpoint.host).")
            }
            return FTPEndpointSession(endpoint: endpoint, password: password)
        case .sftp:
            guard let password else {
                throw AppError.invalidConfiguration("No password is saved for \(endpoint.host).")
            }
            return SFTPEndpointSession(endpoint: endpoint, password: password)
        }
    }
}
