import Foundation

/// A deployment's base URL, independent of any particular hosting provider.
struct MetadataSyncServer: Equatable, Sendable {
    let baseURL: URL

    init(address: String) throws {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw MetadataSyncServerError.invalidAddress }
        if !address.contains("://") { address = "https://" + address }
        guard var components = URLComponents(string: address),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw MetadataSyncServerError.invalidAddress
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.path.hasSuffix("/index.php") {
            components.path = String(components.path.dropLast("index.php".count))
        }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let url = components.url else { throw MetadataSyncServerError.invalidAddress }
        baseURL = url
    }

    var endpointURL: URL { baseURL.appendingPathComponent("index.php") }
}

enum MetadataSyncServerError: LocalizedError, Equatable {
    case invalidAddress
    case invalidResponse
    case unsupportedProtocol
    case redirect
    case responseTooLarge
    case httpStatus(Int)
    case invalidSetupKey

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Enter an HTTPS server address, optionally with a folder path, without credentials, a query, or a fragment."
        case .invalidResponse:
            "This address did not return an Aagedal metadata sync server response. Check where the server files were uploaded."
        case .unsupportedProtocol:
            "This server uses an unsupported protocol version. Update the app or server."
        case .redirect:
            "The server redirected the request. Enter its final HTTPS address and test again."
        case .responseTooLarge:
            "The server returned an unexpectedly large response."
        case .httpStatus(401):
            "The hosting check key was rejected. Check the key and the server configuration."
        case .httpStatus(503):
            "The hosting check failed. Check PHP, database configuration, and the imported probe table on the server."
        case .httpStatus(let code):
            "The server returned HTTP \(code). Check the server installation."
        case .invalidSetupKey:
            "Enter the 64-character hosting check key generated during server setup."
        }
    }
}

struct MetadataSyncServerCheck: Decodable, Equatable, Sendable {
    let name: String
    let passed: Bool
}

struct MetadataSyncServerInfo: Decodable, Equatable, Sendable {
    let service: String
    let protocolVersion: Int
    let stage: String
    let checks: [MetadataSyncServerCheck]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw MetadataSyncServerError.responseTooLarge }
        guard let result = try? JSONDecoder().decode(Self.self, from: data),
              result.service == "aagedal-metadata-sync",
              result.stage == "hosting-check" else { throw MetadataSyncServerError.invalidResponse }
        guard result.protocolVersion == 1 else { throw MetadataSyncServerError.unsupportedProtocol }
        return result
    }
}
