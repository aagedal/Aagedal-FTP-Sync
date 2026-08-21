import Foundation
import Network

final class NetworkStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "no.aagedal.ftpsync.network")
    private var buffer = Data()

    init(host: String, port: Int, tls: Bool) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw AppError.invalidConfiguration("Invalid port \(port).")
        }
        let parameters = tls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receiveChunk(maximum: Int = 512 * 1_024) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    func receiveLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let line = buffer[..<range.lowerBound]
                buffer.removeSubrange(..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            guard let data = try await receiveChunk(maximum: 64 * 1_024) else {
                throw AppError.transferFailed("The FTP server closed the connection unexpectedly.")
            }
            buffer.append(data)
        }
    }

    func receiveAll() async throws -> Data {
        var result = Data()
        while let data = try await receiveChunk() { result.append(data) }
        return result
    }

    func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
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

    func upload(localURL: URL, path: String, modifiedAt: Date?) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        try await ensureDirectory(parent)
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        _ = try await withDataConnection(command: "STOR \(escaped(path))") { stream in
            while true {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 512 * 1_024), !data.isEmpty else { break }
                try await stream.send(data)
            }
        }
        if let modifiedAt {
            let timestamp = Self.ftpDateFormatter.string(from: modifiedAt)
            _ = try? await command("MFMT \(timestamp) \(escaped(path))", accepting: 200..<300)
        }
    }

    func close() async {
        if control != nil { _ = try? await command("QUIT", accepting: 200..<300) }
        control?.cancel()
        control = nil
    }

    private func ensureDirectory(_ path: String) async throws {
        guard path != "/", !path.isEmpty else { return }
        var current = ""
        for component in path.split(separator: "/") {
            current += "/\(component)"
            _ = try? await command("MKD \(escaped(current))", accepting: 200..<300)
        }
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
        if first.dropFirst(3).first == "-" {
            while true {
                let line = try await control.receiveLine()
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
