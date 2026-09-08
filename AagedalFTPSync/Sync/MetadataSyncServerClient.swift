import Foundation

/// Hosting preflight only. No calendar data or job credentials are transmitted.
struct MetadataSyncServerClient: Sendable {
    func check(server: MetadataSyncServer, setupKey: String? = nil) async throws -> MetadataSyncServerInfo {
        var request = URLRequest(url: server.endpointURL)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let setupKey {
            guard setupKey.count == 64, setupKey.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw MetadataSyncServerError.invalidSetupKey }
            request.httpMethod = "POST"
            request.setValue(setupKey, forHTTPHeaderField: "X-Aagedal-Setup-Key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"action":"checkDatabase"}"#.utf8)
        }
        let delegate = MetadataSyncNoRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MetadataSyncServerError.invalidResponse
        }
        guard !(300...399).contains(response.statusCode) else { throw MetadataSyncServerError.redirect }
        guard response.statusCode == 200 else { throw MetadataSyncServerError.httpStatus(response.statusCode) }
        guard response.mimeType == "application/json" else { throw MetadataSyncServerError.invalidResponse }
        guard response.expectedContentLength <= 65_536 else { throw MetadataSyncServerError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw MetadataSyncServerError.responseTooLarge }
            data.append(byte)
        }
        return try MetadataSyncServerInfo.decode(data)
    }
}

/// Never forward a setup credential to a redirect destination, including another path.
final class MetadataSyncNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
