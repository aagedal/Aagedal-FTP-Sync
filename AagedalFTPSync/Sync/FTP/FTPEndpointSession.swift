import Foundation

struct FTPFileNoLongerListed: LocalizedError, Sendable {
    let relativePath: String

    var errorDescription: String? {
        "The FTP source file is no longer listed: \(relativePath). It may have been removed by server cleanup."
    }
}

/// The download failed, but a fresh session could still list its folder.
/// Callers may defer this file without treating the whole server as offline.
struct FTPDownloadFailure: LocalizedError, Sendable {
    let relativePath: String
    let underlyingError: any Error

    var errorDescription: String? { underlyingError.localizedDescription }
}

struct FTPEndpointSession: EndpointSession, Sendable {
    private let endpoint: Endpoint
    private let connection: FTPConnection

    var supportsCompletedDirectoryListings: Bool { true }

    init(endpoint: Endpoint, password: String, tlsTrustRootCertificate: Data? = nil) {
        self.endpoint = endpoint
        connection = FTPConnection(
            endpoint: endpoint,
            password: password,
            tlsTrustRootCertificate: tlsTrustRootCertificate
        )
    }

    func testConnection() async throws {
        _ = try await connection.list(path: normalizedRoot)
    }

    func listFiles() async throws -> [String: SyncFile] {
        try await walkFiles(onCompletedDirectory: nil)
    }

    func listFilesIncrementally(
        onCompletedDirectory: @escaping @Sendable (CompletedDirectoryListing) async throws -> Void
    ) async throws -> [String: SyncFile] {
        try await walkFiles(onCompletedDirectory: onCompletedDirectory)
    }

    private func walkFiles(
        onCompletedDirectory: (@Sendable (CompletedDirectoryListing) async throws -> Void)?
    ) async throws -> [String: SyncFile] {
        try await RemoteTreeWalker.listFiles(
            root: normalizedRoot,
            join: { root, child in
                root.hasSuffix("/") ? root + child : root + "/" + child
            },
            listDirectory: { remoteDirectory in
                let listing = try await connection.list(path: remoteDirectory)
                let isMachineReadable = listing.lowercased().contains("type=")
                var results: [RemoteDirectoryEntry] = []
                for entry in Self.parseMLSD(listing) {
                    let remote = remoteDirectory.hasSuffix("/")
                        ? remoteDirectory + entry.name
                        : remoteDirectory + "/" + entry.name
                    let authoritativeDate: Date?
                    if entry.isDirectory {
                        authoritativeDate = nil
                    } else if isMachineReadable, entry.hasAuthoritativeTimestamp {
                        authoritativeDate = entry.modifiedAt
                    } else {
                        authoritativeDate = try? await connection.modificationDate(path: remote)
                    }
                    results.append(RemoteDirectoryEntry(
                        name: entry.name,
                        isDirectory: entry.isDirectory,
                        size: entry.size,
                        modifiedAt: authoritativeDate ?? entry.modifiedAt,
                        hasAuthoritativeTimestamp: entry.isDirectory || authoritativeDate != nil
                    ))
                }
                return results
            },
            onCompletedDirectory: onCompletedDirectory
        )
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try await exportFile(file, to: temporaryURL, maximumSize: nil)
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL, maximumSize: Int64?) async throws {
        do {
            try await connection.download(
                path: remotePath(for: file.relativePath),
                to: temporaryURL,
                maximumSize: maximumSize
            )
        } catch is CancellationError {
            await connection.disconnect()
            throw CancellationError()
        } catch {
            let downloadError = error
            await connection.disconnect()
            try Task.checkCancellation()
            let replyCode = (error as? FTPCommandFailure)?.code
            guard error is FTPReadTimeout || replyCode == 450 || replyCode == 550 else {
                throw error
            }
            // Check only after a failure: preflighting every file adds latency and
            // cannot prevent deletion between the check and RETR.
            let path = remotePath(for: file.relativePath)
            let listing: String
            do {
                listing = try await connection.list(path: (path as NSString).deletingLastPathComponent)
            } catch is CancellationError {
                await connection.disconnect()
                throw CancellationError()
            } catch {
                await connection.disconnect()
                try Task.checkCancellation()
                throw downloadError
            }
            if Self.listingConfirmsAbsence(of: (path as NSString).lastPathComponent, in: listing) {
                throw FTPFileNoLongerListed(relativePath: file.relativePath)
            }
            // Release the probe session; the caller decides when to retry.
            await connection.disconnect()
            throw FTPDownloadFailure(relativePath: file.relativePath, underlyingError: downloadError)
        }
        try FileManager.default.setAttributes([.modificationDate: file.modifiedAt], ofItemAtPath: temporaryURL.path)
    }

    static func listingConfirmsAbsence(of name: String, in listing: String) -> Bool {
        // Never infer absence from a partial/unrecognized listing. Ignore only
        // standard directory-self entries and Unix LIST's optional block total.
        for line in listing.components(separatedBy: .newlines) where !line.isEmpty {
            let lower = line.lowercased()
            if lower.hasPrefix("type=cdir;") || lower.hasPrefix("type=pdir;") { continue }
            if lower.hasPrefix("total "), Int(line.dropFirst(6)) != nil { continue }
            let entries = parseMLSD(line)
            guard entries.count == 1 else { return false }
            if entries[0].name.caseInsensitiveCompare(name) == .orderedSame { return false }
        }
        return true
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

    func removeFile(_ file: SyncFile) async throws {
        try await connection.delete(path: remotePath(for: file.relativePath))
    }

    func removeFilesTransactionally(_ files: [SyncFile]) async throws {
        try await removeFilesTransactionally(files, expectedContents: nil)
    }

    func removeFilesTransactionally(_ files: [SyncFile], matching contents: [URL]) async throws {
        try await removeFilesTransactionally(files, expectedContents: contents)
    }

    private func removeFilesTransactionally(_ files: [SyncFile], expectedContents: [URL]?) async throws {
        precondition(expectedContents == nil || expectedContents?.count == files.count)
        let sources = files.map { remotePath(for: $0.relativePath) }
        let staged = sources.map { source in
            let parent = (source as NSString).deletingLastPathComponent
            let name = ".aagedal-sync-\(UUID().uuidString).hold"
            return parent == "/" ? "/\(name)" : "\(parent)/\(name)"
        }
        try await TransactionalRemoval.stageAndDelete(
            sources: sources,
            holdings: staged,
            labels: files.map(\.relativePath),
            move: { source, destination in
                try await connection.rename(source, to: destination)
            },
            delete: { holding in try await connection.delete(path: holding) },
            validateStaged: { holdings in
                guard let expectedContents else { return }
                for (holding, expected) in zip(holdings, expectedContents) {
                    try await SourceRemovalVerification.validateRemote(matches: expected) { url, limit in
                        do {
                            try await connection.download(path: holding, to: url, maximumSize: limit)
                        } catch {
                            // An aborted RETR can leave a completion reply pending. Reconnect
                            // before rollback so RNFR/RNTO cannot consume that stale reply.
                            await connection.close()
                            throw error
                        }
                    }
                }
            }
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
        let hasAuthoritativeTimestamp: Bool
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
            let parsedDate = facts["modify"].flatMap { ftpDateFormatter.date(from: String($0.prefix(14))) }
            return Entry(
                name: name,
                isDirectory: type == "dir",
                size: Int64(facts["size"] ?? "0") ?? 0,
                modifiedAt: parsedDate ?? .distantPast,
                hasAuthoritativeTimestamp: type == "dir" || parsedDate != nil
            )
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
            return Entry(
                name: name,
                isDirectory: marker == "d",
                size: size,
                modifiedAt: date,
                hasAuthoritativeTimestamp: marker == "d"
            )
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
