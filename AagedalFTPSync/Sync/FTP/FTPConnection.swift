import Foundation
import Network

enum FTPNetworkLimits {
    static let connectionTimeout: TimeInterval = 20
    static let operationTimeout: TimeInterval = 30
    static let maximumReplyLineBytes = 64 * 1_024
    static let maximumReplyLines = 100
    static let maximumReplyBytes = 256 * 1_024
    static let maximumListingBytes = 32 * 1_024 * 1_024
}

struct BoundedDataAccumulator {
    let maximumBytes: Int
    private(set) var data = Data()

    mutating func append(_ chunk: Data, context: String) throws {
        guard maximumBytes >= data.count,
              chunk.count <= maximumBytes - data.count else {
            throw AppError.transferFailed("The FTP server's \(context) exceeded the \(maximumBytes)-byte safety limit.")
        }
        data.append(chunk)
    }
}

struct FTPLineBuffer {
    private var data = Data()

    mutating func append(_ chunk: Data) {
        data.append(chunk)
    }

    mutating func nextLine(maximumBytes: Int) throws -> String? {
        if let range = data.range(of: Data([13, 10])) {
            let line = data[..<range.lowerBound]
            guard line.count <= maximumBytes else {
                throw AppError.transferFailed("The FTP server sent an overlong response line.")
            }
            data.removeSubrange(..<range.upperBound)
            return String(decoding: line, as: UTF8.self)
        }
        guard data.count <= maximumBytes else {
            throw AppError.transferFailed("The FTP server sent an overlong response line.")
        }
        return nil
    }
}

final class NetworkStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "no.aagedal.ftpsync.network")
    private let address: String
    private var lineBuffer = FTPLineBuffer()
    private let operationTimeout: TimeInterval

    init(host: String, port: Int, tls: Bool, operationTimeout: TimeInterval = FTPNetworkLimits.operationTimeout) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw AppError.invalidConfiguration("Invalid port \(port).")
        }
        let parameters = tls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        address = "\(host):\(port)"
        self.operationTimeout = operationTimeout
    }

    func start() async throws {
        let connection = self.connection
        let address = self.address
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = ContinuationGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard gate.claim() else { return }
                        continuation.resume()
                    case .failed(let error):
                        guard gate.claim() else { return }
                        continuation.resume(throwing: error)
                    case .cancelled:
                        guard gate.claim() else { return }
                        continuation.resume(throwing: CancellationError())
                    case .waiting:
                        // Waiting is recoverable and may transition to ready when a path becomes available.
                        break
                    default:
                        break
                    }
                }
                queue.asyncAfter(deadline: .now() + FTPNetworkLimits.connectionTimeout) {
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(throwing: AppError.transferFailed("Timed out connecting to \(address)."))
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        let connection = self.connection
        let address = self.address
        let queue = self.queue
        let timeout = self.operationTimeout
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = ContinuationGate()
                connection.send(content: data, completion: .contentProcessed { error in
                    guard gate.claim() else { return }
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
                queue.asyncAfter(deadline: .now() + timeout) {
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(throwing: AppError.transferFailed("Timed out writing to \(address)."))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receiveChunk(maximum: Int = 512 * 1_024) async throws -> Data? {
        let connection = self.connection
        let address = self.address
        let queue = self.queue
        let timeout = self.operationTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate()
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                    guard gate.claim() else { return }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        if Self.isEndOfStream(error) { continuation.resume(returning: nil) }
                        else { continuation.resume(throwing: error) }
                    } else if complete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(throwing: AppError.transferFailed("Timed out reading from \(address)."))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func isEndOfStream(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .ENODATA
    }

    func receiveLine(maximumBytes: Int = FTPNetworkLimits.maximumReplyLineBytes) async throws -> String {
        while true {
            if let line = try lineBuffer.nextLine(maximumBytes: maximumBytes) { return line }
            guard let data = try await receiveChunk(maximum: 64 * 1_024) else {
                throw AppError.transferFailed("The FTP server closed the connection unexpectedly.")
            }
            lineBuffer.append(data)
        }
    }

    func receiveAll(maximumBytes: Int = FTPNetworkLimits.maximumListingBytes) async throws -> Data {
        var result = BoundedDataAccumulator(maximumBytes: maximumBytes)
        while let data = try await receiveChunk() {
            try result.append(data, context: "directory listing")
        }
        return result.data
    }

    func finishWriting() async throws {
        let connection = self.connection
        let address = self.address
        let queue = self.queue
        let timeout = self.operationTimeout
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = ContinuationGate()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    guard gate.claim() else { return }
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
                queue.asyncAfter(deadline: .now() + timeout) {
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(throwing: AppError.transferFailed("Timed out finishing a write to \(address)."))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func cancel() { connection.cancel() }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

private struct FTPReply {
    let code: Int
    let lines: [String]
}

actor FTPConnection {
    private let endpoint: Endpoint
    private let password: String
    private var control: NetworkStream?

    init(endpoint: Endpoint, password: String) {
        self.endpoint = endpoint
        self.password = password
    }

    deinit { control?.cancel() }

    func list(path: String) async throws -> String {
        let data: Data
        do {
            data = try await withDataConnection(command: "MLSD \(escaped(path))") { stream in
                try await stream.receiveAll()
            }
        } catch {
            data = try await withDataConnection(command: "LIST \(escaped(path))") { stream in
                try await stream.receiveAll()
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    func modificationDate(path: String) async throws -> Date {
        try await connectIfNeeded()
        let reply = try await command("MDTM \(escaped(path))", accepting: 200..<300)
        guard let date = Self.parseModificationDate(reply.lines.joined(separator: " ")) else {
            throw AppError.transferFailed("The FTP server returned an invalid MDTM response for \(path).")
        }
        return date
    }

    static func parseModificationDate(_ response: String) -> Date? {
        let pattern = #"(?:^|\s)(\d{14})(?:\.\d+)?(?:\s|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: response,
                range: NSRange(response.startIndex..., in: response)
              ),
              let timestampRange = Range(match.range(at: 1), in: response) else {
            return nil
        }
        return ftpDateFormatter.date(from: String(response[timestampRange]))
    }

    func download(path: String, to outputURL: URL) async throws {
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        _ = try await withDataConnection(command: "RETR \(escaped(path))") { stream in
            while let data = try await stream.receiveChunk() {
                try Task.checkCancellation()
                try handle.write(contentsOf: data)
            }
        }
    }

    func upload(localURL: URL, path: String, modifiedAt: Date?, expectedSize: Int64?) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        try await ensureDirectory(parent)
        let temporaryPath = stagingPath(nextTo: path, suffix: "part")
        do {
            let handle = try FileHandle(forReadingFrom: localURL)
            defer { try? handle.close() }
            _ = try await withDataConnection(command: "STOR \(escaped(temporaryPath))") { stream in
                while true {
                    try Task.checkCancellation()
                    guard let data = try handle.read(upToCount: 512 * 1_024), !data.isEmpty else { break }
                    try await stream.send(data)
                }
            }

            if let expectedSize {
                let uploadedSize = try await size(of: temporaryPath)
                guard uploadedSize == expectedSize else {
                    throw AppError.transferFailed(
                        "Size verification failed for \(path): expected \(expectedSize) bytes, uploaded \(uploadedSize) bytes."
                    )
                }
            }
            if let modifiedAt {
                let timestamp = Self.ftpDateFormatter.string(from: modifiedAt)
                _ = try? await command("MFMT \(timestamp) \(escaped(temporaryPath))", accepting: 200..<300)
            }
            try await replaceUploadedFile(at: temporaryPath, destination: path)
        } catch {
            _ = try? await command("DELE \(escaped(temporaryPath))", accepting: 200..<300)
            throw error
        }
    }

    func close() async {
        if control != nil { _ = try? await command("QUIT", accepting: 200..<300) }
        control?.cancel()
        control = nil
    }

    func delete(path: String) async throws {
        _ = try await command("DELE \(escaped(path))", accepting: 200..<300)
    }

    private func ensureDirectory(_ path: String) async throws {
        guard path != "/", !path.isEmpty else { return }
        var current = ""
        for component in path.split(separator: "/") {
            current += "/\(component)"
            _ = try? await command("MKD \(escaped(current))", accepting: 200..<300)
        }
    }

    private func size(of path: String) async throws -> Int64 {
        let reply = try await command("SIZE \(escaped(path))", accepting: 200..<300)
        let values = reply.lines
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }
            .compactMap { Int64($0) }
        guard let size = values.last else {
            throw AppError.transferFailed("The FTP server returned an invalid SIZE response for \(path).")
        }
        return size
    }

    private func replaceUploadedFile(at temporaryPath: String, destination: String) async throws {
        do {
            try await rename(temporaryPath, to: destination)
            return
        } catch let directRenameError {
            let backupPath = stagingPath(nextTo: destination, suffix: "backup")
            do {
                try await rename(destination, to: backupPath)
            } catch {
                throw directRenameError
            }

            do {
                try await rename(temporaryPath, to: destination)
                _ = try? await command("DELE \(escaped(backupPath))", accepting: 200..<300)
            } catch let replacementError {
                do {
                    try await rename(backupPath, to: destination)
                } catch {
                    throw AppError.transferFailed(
                        "Could not replace \(destination). The previous file remains at \(backupPath)."
                    )
                }
                throw replacementError
            }
        }
    }

    func rename(_ source: String, to destination: String) async throws {
        _ = try await command("RNFR \(escaped(source))", accepting: 300..<400)
        _ = try await command("RNTO \(escaped(destination))", accepting: 200..<300)
    }

    private func stagingPath(nextTo path: String, suffix: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let name = ".aagedal-sync-\(UUID().uuidString).\(suffix)"
        return parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    private func withDataConnection<T: Sendable>(
        command dataCommand: String,
        operation: (NetworkStream) async throws -> T
    ) async throws -> T {
        try await connectIfNeeded()
        let port: Int
        do {
            let reply = try await command("EPSV", accepting: 200..<300)
            guard let parsed = Self.parseExtendedPassivePort(reply.lines.joined(separator: " ")) else {
                throw AppError.transferFailed("The FTP server returned an invalid EPSV response.")
            }
            port = parsed
        } catch {
            let reply = try await command("PASV", accepting: 200..<300)
            guard let parsed = Self.parsePassivePort(reply.lines.joined(separator: " ")) else {
                throw AppError.transferFailed("The FTP server returned an invalid passive-mode response.")
            }
            port = parsed
        }
        let dataStream = try NetworkStream(host: endpoint.host, port: port, tls: endpoint.kind == .ftps)
        try await dataStream.start()
        do {
            let opening = try await command(dataCommand, accepting: 100..<200)
            guard opening.code == 125 || opening.code == 150 else {
                throw AppError.transferFailed("FTP transfer was not accepted (\(opening.code)).")
            }
            let result = try await operation(dataStream)
            try? await dataStream.finishWriting()
            dataStream.cancel()
            _ = try await readReply(accepting: 200..<300)
            return result
        } catch {
            dataStream.cancel()
            throw error
        }
    }

    private func connectIfNeeded() async throws {
        guard control == nil else { return }
        let stream = try NetworkStream(host: endpoint.host, port: endpoint.port, tls: endpoint.kind == .ftps)
        try await stream.start()
        control = stream
        _ = try await readReply(accepting: 200..<300)
        let userReply = try await command("USER \(escaped(endpoint.username))", accepting: 200..<400)
        if userReply.code == 331 {
            _ = try await command("PASS \(escaped(password))", accepting: 200..<300)
        }
        if endpoint.kind == .ftps {
            _ = try await command("PBSZ 0", accepting: 200..<300)
            _ = try await command("PROT P", accepting: 200..<300)
        }
        _ = try? await command("OPTS UTF8 ON", accepting: 200..<300)
        _ = try await command("TYPE I", accepting: 200..<300)
    }

    @discardableResult
    private func command(_ value: String, accepting range: Range<Int>) async throws -> FTPReply {
        guard let control else { throw AppError.transferFailed("FTP is not connected.") }
        try await control.send(Data("\(value)\r\n".utf8))
        return try await readReply(accepting: range)
    }

    private func readReply(accepting range: Range<Int>) async throws -> FTPReply {
        guard let control else { throw AppError.transferFailed("FTP is not connected.") }
        let first = try await control.receiveLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw AppError.transferFailed("Invalid FTP response: \(first)")
        }
        var lines = [first]
        var responseBytes = first.utf8.count
        if first.dropFirst(3).first == "-" {
            while true {
                guard lines.count < FTPNetworkLimits.maximumReplyLines else {
                    throw AppError.transferFailed("The FTP server sent too many response lines.")
                }
                let line = try await control.receiveLine()
                guard line.utf8.count <= FTPNetworkLimits.maximumReplyBytes - responseBytes else {
                    throw AppError.transferFailed("The FTP server response exceeded the safety limit.")
                }
                responseBytes += line.utf8.count
                lines.append(line)
                if line.hasPrefix("\(code) ") { break }
            }
        }
        guard range.contains(code) else {
            throw AppError.transferFailed(lines.joined(separator: "\n"))
        }
        return FTPReply(code: code, lines: lines)
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private static func parseExtendedPassivePort(_ text: String) -> Int? {
        guard let start = text.lastIndex(of: "("), let end = text[start...].firstIndex(of: ")") else { return nil }
        let payload = text[text.index(after: start)..<end]
        return payload.split(separator: "|", omittingEmptySubsequences: true).last.flatMap { Int($0) }
    }

    private static func parsePassivePort(_ text: String) -> Int? {
        guard let start = text.lastIndex(of: "("), let end = text[start...].firstIndex(of: ")") else { return nil }
        let numbers = text[text.index(after: start)..<end].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else { return nil }
        return numbers[4] * 256 + numbers[5]
    }

    private static let ftpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()
}
