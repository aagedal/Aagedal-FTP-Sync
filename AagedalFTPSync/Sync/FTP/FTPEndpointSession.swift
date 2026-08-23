import Foundation

struct FTPEndpointSession: EndpointSession, Sendable {
    private let endpoint: Endpoint
    private let connection: FTPConnection

    init(endpoint: Endpoint, password: String) {
        self.endpoint = endpoint
        connection = FTPConnection(endpoint: endpoint, password: password)
    }

    func testConnection() async throws {
        _ = try await connection.list(path: normalizedRoot)
    }

    func listFiles() async throws -> [String: SyncFile] {
        var result: [String: SyncFile] = [:]
        var directories: [(remote: String, relative: String)] = [(normalizedRoot, "")]
        while !directories.isEmpty {
            try Task.checkCancellation()
            let directory = directories.removeFirst()
            let listing = try await connection.list(path: directory.remote)
            for entry in Self.parseMLSD(listing) {
                guard !PathSafety.isInternalStagingPath(entry.name) else { continue }
                let relative = directory.relative.isEmpty ? entry.name : "\(directory.relative)/\(entry.name)"
                let remote = directory.remote.hasSuffix("/") ? directory.remote + entry.name : directory.remote + "/" + entry.name
                if entry.isDirectory {
                    directories.append((remote, relative))
                } else {
                    if let existing = result[relative],
                       !PathSafety.hasIdenticalRepresentation(existing.relativePath, relative) {
                        throw AppError.transferFailed(
                            "Two server paths differ only by Unicode representation: \(existing.relativePath) and \(relative)."
                        )
                    }
                    result[relative] = SyncFile(relativePath: relative, size: entry.size, modifiedAt: entry.modifiedAt)
                }
            }
        }
        return result
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try await connection.download(path: remotePath(for: file.relativePath), to: temporaryURL)
        try FileManager.default.setAttributes([.modificationDate: file.modifiedAt], ofItemAtPath: temporaryURL.path)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        try await connection.upload(
            localURL: localURL,
            path: remotePath(for: file.relativePath),
            modifiedAt: preserveDate ? file.modifiedAt : nil,
            expectedSize: verifySize ? file.size : nil
        )
    }

    func close() async { await connection.close() }

    private var normalizedRoot: String {
        let root = endpoint.remotePath.isEmpty ? "/" : endpoint.remotePath
        return root.hasPrefix("/") ? root : "/" + root
    }

    private func remotePath(for relative: String) -> String {
        normalizedRoot.hasSuffix("/") ? normalizedRoot + relative : normalizedRoot + "/" + relative
    }

    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modifiedAt: Date
    }

    static func parseMLSD(_ listing: String) -> [Entry] {
        if !listing.lowercased().contains("type=") {
            return parseUnixListing(listing)
        }
        return listing.components(separatedBy: .newlines).compactMap { line -> Entry? in
            guard let separator = line.firstIndex(of: " ") else { return nil }
            let factsText = line[..<separator]
            let name = String(line[line.index(after: separator)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard PathSafety.isSafeServerName(name) else { return nil }
            var facts: [String: String] = [:]
            for fact in factsText.split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
            }
            let type = facts["type"]?.lowercased() ?? "file"
            guard type != "cdir", type != "pdir" else { return nil }
            let date = facts["modify"].flatMap { ftpDateFormatter.date(from: String($0.prefix(14))) } ?? .distantPast
            return Entry(name: name, isDirectory: type == "dir", size: Int64(facts["size"] ?? "0") ?? 0, modifiedAt: date)
        }
    }

    private static func parseUnixListing(_ listing: String) -> [Entry] {
        return listing.components(separatedBy: .newlines).compactMap { line -> Entry? in
            let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 9, let marker = fields.first?.first, marker == "-" || marker == "d" else { return nil }
            let name = String(fields[8])
            guard PathSafety.isSafeServerName(name) else { return nil }
            let size = Int64(fields[4]) ?? 0
            let dateText = "\(fields[5]) \(fields[6]) \(fields[7])"
            let formatter = fields[7].contains(":") ? unixRecentDateFormatter : unixOldDateFormatter
            var date = formatter.date(from: dateText) ?? .distantPast
            if fields[7].contains(":"), date > Date().addingTimeInterval(86_400) {
                date = Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: date) ?? date
            }
            return Entry(name: name, isDirectory: marker == "d", size: size, modifiedAt: date)
        }
    }

    private static let ftpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    private static let unixRecentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        formatter.defaultDate = Date()
        return formatter
    }()

    private static let unixOldDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }()
}
