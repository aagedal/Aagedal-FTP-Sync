import Foundation

struct MetadataCalendarRequest: Encodable, Sendable {
    var action: String
    var calendarID: UUID?
    var deviceID: UUID?
    var deviceName: String?
    var inviteToken: String?
    var name: String?
    var timeZone: String?
    var document: SharedMetadataDocument?
    var expectedRevision: Int64?
    var role: String?
    var rangeStart: Date?
    var rangeEnd: Date?
}

struct MetadataCalendarResponse: Decodable, Sendable {
    var service: String
    var protocolVersion: Int
    var error: String?
    var calendar: SharedMetadataCalendar?
    var calendars: [MetadataCalendarSummary]?
    var inviteToken: String?
    var members: [MetadataCalendarMember]?
}

struct MetadataCalendarClient: Sendable {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    func send(_ body: MetadataCalendarRequest, address: String, deviceID: UUID, key: String, setupKey: String? = nil) async throws -> MetadataCalendarResponse {
        func validKey(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard validKey(key) else { throw MetadataSyncFailure(message: "The saved device key is invalid.") }
        if let setupKey, !validKey(setupKey) { throw MetadataSyncServerError.invalidSetupKey }
        let server = try MetadataSyncServer(address: address)
        var request = URLRequest(url: server.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2", forHTTPHeaderField: "X-Aagedal-Protocol")
        request.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Aagedal-Device-ID")
        request.setValue(key, forHTTPHeaderField: "X-Aagedal-Device-Key")
        if let setupKey { request.setValue(setupKey, forHTTPHeaderField: "X-Aagedal-Setup-Key") }
        request.httpBody = try Self.encoder().encode(body)
        guard (request.httpBody?.count ?? 0) <= 1_048_576 else { throw MetadataSyncFailure(message: "The calendar is too large for this server (1 MB limit).") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: MetadataSyncNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.mimeType == "application/json" else { throw MetadataSyncServerError.invalidResponse }
        guard !(300...399).contains(response.statusCode) else { throw MetadataSyncServerError.redirect }
        guard response.expectedContentLength <= 4_194_304 else { throw MetadataSyncServerError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4_194_304 else { throw MetadataSyncServerError.responseTooLarge }
            data.append(byte)
        }
        return try Self.decodeResponse(data, statusCode: response.statusCode, calendarID: body.calendarID)
    }

    static func decodeResponse(_ data: Data, statusCode: Int, calendarID: UUID?) throws -> MetadataCalendarResponse {
        guard data.count <= 4_194_304 else { throw MetadataSyncServerError.responseTooLarge }
        var result = try Self.decoder().decode(MetadataCalendarResponse.self, from: data)
        guard result.service == "aagedal-metadata-sync" else { throw MetadataSyncServerError.invalidResponse }
        // Older deployments report configuration failures in a protocol-1 envelope.
        // Explain those known installation errors before rejecting the protocol version.
        if [1, 2].contains(result.protocolVersion), statusCode != 200 {
            switch result.error {
            case "not_configured":
                throw MetadataSyncFailure(message: "The server cannot find its private config.php. Check the $configPath setting in the uploaded index.php, and confirm that the private configuration is uploaded as config.php and readable by PHP.")
            case "runtime_unavailable":
                throw MetadataSyncFailure(message: "The server needs PHP 8.2 or newer with the pdo_mysql extension enabled.")
            case "invalid_configuration":
                throw MetadataSyncFailure(message: "The private server configuration contains invalid database settings. Check it on the host.")
            case "live_api_missing":
                throw MetadataSyncFailure(message: "The calendar API file is missing. Upload live.php beside index.php in the endpoint's public directory.")
            default: break
            }
        }
        if result.protocolVersion == 1 {
            throw MetadataSyncFailure(message: "This request reached the hosting-check API instead of calendar sync. Upload the current index.php and live.php to this endpoint, preserving the private $configPath setting in index.php.")
        }
        guard result.protocolVersion == 2 else { throw MetadataSyncServerError.unsupportedProtocol }
        if (statusCode != 200 || result.error != nil) && !(statusCode == 409 && result.error == "revision_conflict" && result.calendar != nil) {
            // Do not display arbitrary server-provided strings or HTML.
            let message: String
            switch result.error {
            case "bootstrap_disabled": message = "First-device setup is disabled or already completed. Join with an invitation, or enable bootstrap in the private server configuration."
            case "invalid_invite": message = "The invitation is invalid, expired, revoked, or already used by another device."
            case "unauthorized": message = "This device credential was rejected."
            case "access_denied": message = "Access to this calendar has been revoked. Local metadata is retained."
            case "read_only": message = "This calendar is read-only. Your local edits are retained."
            case "range_profiles_read_only": message = "Date-range access allows clip edits; photographer details must be changed by someone with full-calendar access."
            case "outside_range": message = "The edit is outside the shared date range."
            case "overlapping_clips": message = "The merged calendar has overlapping clips. Resolve the overlap before syncing."
            case "already_member": message = "This device already has access to that calendar."
            default: message = "Calendar sync failed (HTTP \(statusCode)). Check the server installation and calendar limits. Local edits are retained."
            }
            throw MetadataSyncFailure(message: message)
        }
        if var calendar = result.calendar {
            guard calendar.id == calendarID, calendar.revision > 0,
                  ["owner", "editor", "reader"].contains(calendar.role),
                  TimeZone(identifier: calendar.timeZone) != nil,
                  (calendar.rangeStart == nil) == (calendar.rangeEnd == nil),
                  calendar.range.map({ $0.end > $0.start }) ?? true else { throw MetadataSyncServerError.invalidResponse }
            calendar.document = try calendar.document.validated()
            result.calendar = calendar
        }
        return result
    }
}
