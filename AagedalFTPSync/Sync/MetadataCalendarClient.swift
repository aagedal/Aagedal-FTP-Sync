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
    var capabilities: [String]?
    var documentSchemaVersion: Int?
    var templateDeactivations: [MetadataTemplateDeactivation]?
    /// Local transport selection, never serialized into the protocol body.
    var routingProtocol: MetadataCalendarProtocol = .legacy

    private enum CodingKeys: String, CodingKey {
        case action, calendarID, deviceID, deviceName, inviteToken, name, timeZone, document
        case expectedRevision, role, rangeStart, rangeEnd, capabilities, documentSchemaVersion, templateDeactivations
    }
}

struct MetadataCalendarResponse: Decodable, Sendable {
    var service: String
    var protocolVersion: Int
    var error: String?
    var calendar: SharedMetadataCalendar?
    var calendars: [MetadataCalendarSummary]?
    var inviteToken: String?
    var members: [MetadataCalendarMember]?
    var capabilities: [String]?
    var documentSchemaVersions: [Int]?
    var templateLanguageVersions: [Int]?
}

struct MetadataCalendarClient: Sendable {
    /// Test transport never receives production credentials unless explicitly supplied.
    var transport: (@Sendable (URLRequest) async throws -> (Data, Int))? = nil
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

    func send(_ body: MetadataCalendarRequest, address: String, deviceID: UUID, key: String, setupKey: String? = nil,
              protocolVersion: MetadataCalendarProtocol = .legacy) async throws -> MetadataCalendarResponse {
        var body = body
        switch protocolVersion {
        case .legacy:
            guard body.capabilities == nil, body.documentSchemaVersion == nil, body.templateDeactivations == nil else {
                throw MetadataSyncServerError.unsupportedProtocol
            }
            if let document = body.document { try LegacyMetadataCalendarGate.validate(document) }
        case .templates:
            body.capabilities = ["metadata-templates-v1"]
            if let document = body.document {
                guard body.documentSchemaVersion == 3 else { throw MetadataSyncServerError.unsupportedProtocol }
                _ = try document.validated()
            }
        }
        func validKey(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard validKey(key) else { throw MetadataSyncFailure(message: "The saved device key is invalid.") }
        if let setupKey, !validKey(setupKey) { throw MetadataSyncServerError.invalidSetupKey }
        let server = try MetadataSyncServer(address: address)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: MetadataSyncNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        if protocolVersion == .templates, body.document != nil {
            // Never use a cached declaration or send source while discovering support.
            let probe = MetadataCalendarRequest(action: "getCapabilities", capabilities: ["metadata-templates-v1"])
            let response = try await sendPrepared(probe, server: server, deviceID: deviceID, key: key,
                setupKey: setupKey, protocolVersion: protocolVersion, session: session)
            try Self.validateCapabilities(response)
        }
        try Task.checkCancellation()
        return try await sendPrepared(body, server: server, deviceID: deviceID, key: key,
            setupKey: setupKey, protocolVersion: protocolVersion, session: session)
    }

    static func validateCapabilities(_ response: MetadataCalendarResponse) throws {
        guard response.protocolVersion == 3, response.error == nil,
              response.capabilities == ["metadata-templates-v1"],
              response.documentSchemaVersions == [1, 3], response.templateLanguageVersions == [1],
              response.calendar == nil, response.calendars == nil else {
            throw MetadataSyncServerError.unsupportedProtocol
        }
    }

    private func sendPrepared(_ body: MetadataCalendarRequest, server: MetadataSyncServer,
                              deviceID: UUID, key: String, setupKey: String?,
                              protocolVersion: MetadataCalendarProtocol, session: URLSession) async throws -> MetadataCalendarResponse {
        var request = URLRequest(url: server.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(protocolVersion.rawValue), forHTTPHeaderField: "X-Aagedal-Protocol")
        request.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Aagedal-Device-ID")
        request.setValue(key, forHTTPHeaderField: "X-Aagedal-Device-Key")
        if let setupKey { request.setValue(setupKey, forHTTPHeaderField: "X-Aagedal-Setup-Key") }
        request.httpBody = try Self.encoder().encode(body)
        guard (request.httpBody?.count ?? 0) <= 1_048_576 else { throw MetadataSyncFailure(message: "The calendar is too large for this server (1 MB limit).") }
        if let transport {
            let (data, status) = try await transport(request)
            return try Self.decodeResponse(data, statusCode: status, calendarID: body.calendarID, protocolVersion: protocolVersion)
        }
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
        return try Self.decodeResponse(data, statusCode: response.statusCode, calendarID: body.calendarID, protocolVersion: protocolVersion)
    }

    static func decodeResponse(_ data: Data, statusCode: Int, calendarID: UUID?,
                               protocolVersion: MetadataCalendarProtocol = .legacy) throws -> MetadataCalendarResponse {
        guard data.count <= 4_194_304 else { throw MetadataSyncServerError.responseTooLarge }
        // Establish the wire contract before decoding any template-bearing domain record.
        struct Envelope: Decodable { let service: String; let protocolVersion: Int; let capabilities: [String]?; let error: String? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.service == "aagedal-metadata-sync" else { throw MetadataSyncServerError.invalidResponse }
        if envelope.error == "client_upgrade_required" || envelope.error == "namespace_collision" {
            throw MetadataSyncFailure(message: "This calendar requires a compatible version 3 app and server. Local edits are retained.",
                diagnosticCode: "HTTP \(statusCode): \(envelope.error!)")
        }
        if protocolVersion == .templates {
            guard envelope.protocolVersion == 3, envelope.capabilities == ["metadata-templates-v1"] else {
                throw MetadataSyncServerError.unsupportedProtocol
            }
        } else if ![1, 2].contains(envelope.protocolVersion) {
            throw MetadataSyncServerError.unsupportedProtocol
        }
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
        guard result.protocolVersion == protocolVersion.rawValue else { throw MetadataSyncServerError.unsupportedProtocol }
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
            case "template_activation_lost": message = "The calendar edit would remove variable activation without an explicit conversion. Local edits are retained."
            case "invalid_template": message = "The calendar contains an unsupported or malformed variable template. Local edits are retained."
            default: message = "Calendar sync failed (HTTP \(statusCode)). Check the server installation and calendar limits. Local edits are retained."
            }
            let knownCodes: Set<String> = ["bootstrap_disabled", "invalid_invite", "unauthorized", "access_denied", "read_only",
                "range_profiles_read_only", "outside_range", "overlapping_clips", "already_member", "duplicate_prefix",
                "invalid_text", "invalid_date", "invalid_reference", "calendar_limit", "invite_limit", "calendar_too_large",
                "request_too_large", "owner_required", "sync_unavailable", "invalid_time_zone", "unknown_fields",
                "template_activation_lost", "invalid_template", "client_upgrade_required", "namespace_collision"]
            let code = result.error.flatMap { knownCodes.contains($0) ? $0 : nil } ?? "unexpected_response"
            throw MetadataSyncFailure(message: message, diagnosticCode: "HTTP \(statusCode): \(code)")
        }
        if var calendar = result.calendar {
            guard calendar.id == calendarID, calendar.revision > 0,
                  ["owner", "editor", "reader"].contains(calendar.role),
                  TimeZone(identifier: calendar.timeZone) != nil,
                  (calendar.rangeStart == nil) == (calendar.rangeEnd == nil),
                  calendar.range.map({ $0.end > $0.start }) ?? true else { throw MetadataSyncServerError.invalidResponse }
            guard calendar.compatibility.protocolVersion == protocolVersion else { throw MetadataSyncServerError.unsupportedProtocol }
            if protocolVersion == .legacy { try LegacyMetadataCalendarGate.validate(calendar.document) }
            calendar.document = try calendar.document.validated()
            result.calendar = calendar
        }
        if let calendars = result.calendars {
            guard calendars.allSatisfy({ $0.compatibility.protocolVersion == protocolVersion }) else {
                throw MetadataSyncServerError.unsupportedProtocol
            }
        }
        return result
    }
}
