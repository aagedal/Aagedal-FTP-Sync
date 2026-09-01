import Network
import XCTest
@testable import AagedalFTPSync

final class FTPListingTests: XCTestCase {
    func testFastStartPublishesFiveNewestFilesBeforeFullListing() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let files = Dictionary(uniqueKeysWithValues: (0..<8).map { index in
            let path = "NEWS_\(index).JPG"
            return (path, SyncFile(
                relativePath: path,
                size: Int64(index + 1),
                modifiedAt: baseDate.addingTimeInterval(Double(index))
            ))
        })
        let timeline = FastStartTimeline()
        let source = FastStartSource(files: files, timeline: timeline)
        let destination = FastStartDestination(timeline: timeline)
        let signatureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-start-signatures-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: signatureURL)
            try? FileManager.default.removeItem(at: signatureURL.appendingPathExtension("backup"))
        }
        let engine = SyncEngine(
            sourceSignatureRepository: SourceSignatureRepository(fileURL: signatureURL),
            sessionFactory: { endpoint, _, _ in
                if endpoint.kind.isRemote { return source }
                return destination
            }
        )
        var job = SyncJob()
        job.left = Endpoint(
            kind: .ftp,
            host: "photos.example.com",
            username: "reporter",
            remotePath: "/incoming"
        )
        job.right = Endpoint(
            kind: .local,
            localPath: "/mock-downloads",
            bookmark: Data("mock".utf8)
        )
        job.direction = .leftToRight
        job.filter = FileFilter(preset: .photos)
        job.isEnabled = false

        let result = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
        let events = await timeline.events
        let importedPaths = await destination.importedPaths
        let importCount = await destination.importCount
        let firstFullListingIndex = try XCTUnwrap(events.firstIndex(of: "source-full-list"))
        let earlyImports = events[..<firstFullListingIndex].filter { $0.hasPrefix("import:") }

        XCTAssertEqual(
            Array(earlyImports),
            ["import:NEWS_7.JPG", "import:NEWS_6.JPG", "import:NEWS_5.JPG", "import:NEWS_4.JPG", "import:NEWS_3.JPG"]
        )
        XCTAssertEqual(result.transferred, 8)
        XCTAssertEqual(importedPaths, Set(files.keys))
        XCTAssertEqual(importCount, 8)

        let secondResult = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
        let secondImportCount = await destination.importCount
        XCTAssertEqual(secondResult.transferred, 0)
        XCTAssertEqual(secondImportCount, 8)
    }

    func testParsesMachineReadableListing() throws {
        let listing = """
        modify=20260821122345;size=43121;type=file; NEWS_001.JPG\r
        modify=20260821122350;size=98122;type=file; NEWS 002.CR3\r
        modify=20260821122000;type=dir; selects\r
        type=cdir; .\r
        """
        let entries = FTPEndpointSession.parseMLSD(listing)
        XCTAssertEqual(entries.map(\.name), ["NEWS_001.JPG", "NEWS 002.CR3", "selects"])
        XCTAssertEqual(entries[0].size, 43_121)
        XCTAssertTrue(entries[2].isDirectory)
    }

    func testParsesMDTMModificationDateAsUTC() throws {
        let date = try XCTUnwrap(FTPConnection.parseModificationDate("213 20260830080942.125"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date),
                       DateComponents(year: 2026, month: 8, day: 30, hour: 8, minute: 9, second: 42))
    }

    func testNoDataNetworkErrorIsTreatedAsEndOfStream() {
        XCTAssertTrue(NetworkStream.isEndOfStream(.posix(.ENODATA)))
        XCTAssertFalse(NetworkStream.isEndOfStream(.posix(.ECONNRESET)))
    }

    func testDirectoryListingAccumulatorEnforcesMaximumSize() throws {
        var accumulator = BoundedDataAccumulator(maximumBytes: 5)
        try accumulator.append(Data("123".utf8), context: "test listing")
        try accumulator.append(Data("45".utf8), context: "test listing")

        XCTAssertEqual(String(decoding: accumulator.data, as: UTF8.self), "12345")
        XCTAssertThrowsError(try accumulator.append(Data("6".utf8), context: "test listing"))
    }

    func testFTPLineBufferRejectsOverlongLineWithoutDelimiter() {
        var buffer = FTPLineBuffer()
        buffer.append(Data("123456".utf8))

        XCTAssertThrowsError(try buffer.nextLine(maximumBytes: 5))
    }

    func testFTPLineBufferRejectsOverlongCompletedLine() {
        var buffer = FTPLineBuffer()
        buffer.append(Data("123456\r\n".utf8))

        XCTAssertThrowsError(try buffer.nextLine(maximumBytes: 5))
    }

    func testFTPLineBufferPreservesFollowingReply() throws {
        var buffer = FTPLineBuffer()
        buffer.append(Data("220 hello\r\n221 bye\r\n".utf8))

        XCTAssertEqual(try buffer.nextLine(maximumBytes: 64), "220 hello")
        XCTAssertEqual(try buffer.nextLine(maximumBytes: 64), "221 bye")
        XCTAssertNil(try buffer.nextLine(maximumBytes: 64))
    }
}

private actor FastStartTimeline {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor FastStartSource: FastStartSourceSession {
    let files: [String: SyncFile]
    let timeline: FastStartTimeline

    init(files: [String: SyncFile], timeline: FastStartTimeline) {
        self.files = files
        self.timeline = timeline
    }

    func listFilesForFastStart(
        filter: FileFilter,
        minimumCount: Int
    ) async throws -> [String: SyncFile] {
        await timeline.append("source-fast-list")
        return files
    }

    func refreshMetadataForFastStart(_ files: [SyncFile]) async throws -> [SyncFile] {
        files
    }

    func listFiles() async throws -> [String: SyncFile] {
        await timeline.append("source-full-list")
        return files
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        await timeline.append("export:\(file.relativePath)")
        try Data(repeating: UInt8(file.size), count: Int(file.size)).write(to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {}
}

private actor FastStartDestination: EndpointFileLookupSession {
    private var files: [String: SyncFile] = [:]
    private(set) var importCount = 0
    let timeline: FastStartTimeline

    init(timeline: FastStartTimeline) {
        self.timeline = timeline
    }

    var importedPaths: Set<String> { Set(files.keys) }

    func fileInfo(relativePath: String) async throws -> SyncFile? {
        files[relativePath]
    }

    func listFiles() async throws -> [String: SyncFile] {
        await timeline.append("destination-full-list")
        return files
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try Data(repeating: UInt8(file.size), count: Int(file.size)).write(to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        files[file.relativePath] = file
        importCount += 1
        await timeline.append("import:\(file.relativePath)")
    }
}
