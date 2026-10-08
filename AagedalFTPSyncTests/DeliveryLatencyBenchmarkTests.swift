import Foundation
import Darwin
import XCTest
@testable import AagedalFTPSync

final class DeliveryLatencyBenchmarkTests: XCTestCase {
    func testLargeTreeBenchmark() async throws {
        var environment = ProcessInfo.processInfo.environment
        var configurationPath = environment["AFTPSYNC_BENCHMARK_CONFIG_PATH"]
        if configurationPath == nil || configurationPath == "$(AFTPSYNC_BENCHMARK_CONFIG_PATH)" {
            configurationPath = Self.discoveredConfigurationPath()
        }
        if let configurationPath,
           !configurationPath.isEmpty,
           configurationPath != "$(AFTPSYNC_BENCHMARK_CONFIG_PATH)",
           let configurationData = FileManager.default.contents(atPath: configurationPath),
           let configuration = try JSONSerialization.jsonObject(with: configurationData) as? [String: String] {
            environment.merge(configuration) { _, configuredValue in configuredValue }
        }
        guard environment["AFTPSYNC_RUN_DELIVERY_BENCHMARK"] == "1" else {
            throw XCTSkip("Set AFTPSYNC_RUN_DELIVERY_BENCHMARK=1 and use the benchmark runner.")
        }

        let iterations = try requiredInteger("AFTPSYNC_BENCHMARK_ITERATIONS", in: environment)
        let expectedFiles = try requiredInteger("AFTPSYNC_BENCHMARK_FILE_COUNT", in: environment)
        let username = try required("AFTPSYNC_BENCHMARK_USERNAME", in: environment)
        let password = try required("AFTPSYNC_BENCHMARK_PASSWORD", in: environment)
        let recentPaths: [String]
        if let recentPathsJSON = environment["AFTPSYNC_BENCHMARK_RECENT_PATHS"],
           !recentPathsJSON.isEmpty {
            recentPaths = try JSONDecoder().decode(
                [String].self,
                from: Data(recentPathsJSON.utf8)
            )
        } else {
            // Retain direct compatibility with configuration files created by
            // the original single-publication benchmark runner.
            recentPaths = [try required("AFTPSYNC_BENCHMARK_NEWEST_PATH", in: environment)]
        }
        guard !recentPaths.isEmpty else {
            throw BenchmarkConfigurationError.emptyRecentPaths
        }
        let expectedPublishedPaths = Set(recentPaths)
        let host = environment["AFTPSYNC_BENCHMARK_HOST"] ?? "127.0.0.1"
        let remotePath = environment["AFTPSYNC_BENCHMARK_REMOTE_PATH"] ?? "/"

        let endpoints = [
            Endpoint(
                kind: .ftp,
                host: host,
                port: try requiredInteger("AFTPSYNC_BENCHMARK_FTP_PORT", in: environment),
                username: username,
                remotePath: remotePath
            ),
            Endpoint(
                kind: .sftp,
                host: host,
                port: try requiredInteger("AFTPSYNC_BENCHMARK_SFTP_PORT", in: environment),
                username: username,
                remotePath: remotePath,
                hostKeyFingerprint: try required("AFTPSYNC_BENCHMARK_SFTP_FINGERPRINT", in: environment)
            ),
        ]

        var results: [ProtocolBenchmarkResult] = []
        for endpoint in endpoints {
            results.append(try await benchmark(
                endpoint: endpoint,
                password: password,
                iterations: iterations,
                expectedFiles: expectedFiles,
                expectedPublishedPaths: expectedPublishedPaths
            ))
        }

        let payload = BenchmarkPayload(
            iterations: iterations,
            expectedFiles: expectedFiles,
            expectedPublishedFiles: expectedPublishedPaths.count,
            results: results
        )
        let data = try JSONEncoder().encode(payload)
        print("AFTPSYNC_BENCHMARK_RESULT \(String(decoding: data, as: UTF8.self))")
    }

    private func benchmark(
        endpoint: Endpoint,
        password: String,
        iterations: Int,
        expectedFiles: Int,
        expectedPublishedPaths: Set<String>
    ) async throws -> ProtocolBenchmarkResult {
        let coldScan = try await measure(iterations: iterations) {
            let session = try EndpointSessionFactory.make(endpoint: endpoint, password: password)
            do {
                let files = try await session.listFiles()
                try Self.validate(
                    files,
                    expectedCount: expectedFiles,
                    expectedPublishedPaths: expectedPublishedPaths
                )
                await session.close()
            } catch {
                await session.close()
                throw error
            }
        }

        let warmScanSession = try EndpointSessionFactory.make(endpoint: endpoint, password: password)
        _ = try await warmScanSession.listFiles()
        let warmScan = try await measure(iterations: iterations, includesWarmUp: false) {
            let files = try await warmScanSession.listFiles()
            try Self.validate(
                files,
                expectedCount: expectedFiles,
                expectedPublishedPaths: expectedPublishedPaths
            )
        }
        await warmScanSession.close()

        let coldPublication = try await measurePublication(iterations: iterations) {
            let source = try EndpointSessionFactory.make(endpoint: endpoint, password: password)
            return try await self.runPublication(
                endpoint: endpoint,
                password: password,
                source: source,
                expectedPublishedPaths: expectedPublishedPaths,
                keepSourceOpen: false
            )
        }

        let warmPublicationSource = try EndpointSessionFactory.make(endpoint: endpoint, password: password)
        _ = try await runPublication(
            endpoint: endpoint,
            password: password,
            source: warmPublicationSource,
            expectedPublishedPaths: expectedPublishedPaths,
            keepSourceOpen: true
        )
        let warmPublication = try await measurePublication(iterations: iterations, includesWarmUp: false) {
            try await self.runPublication(
                endpoint: endpoint,
                password: password,
                source: warmPublicationSource,
                expectedPublishedPaths: expectedPublishedPaths,
                keepSourceOpen: true
            )
        }
        await warmPublicationSource.close()

        return ProtocolBenchmarkResult(
            protocolName: endpoint.kind.rawValue,
            coldFullScan: Summary(samples: coldScan),
            warmFullScan: Summary(samples: warmScan),
            coldFirstPublication: Summary(samples: coldPublication.map(\.firstPublication)),
            warmFirstPublication: Summary(samples: warmPublication.map(\.firstPublication)),
            coldBurstCompletion: Summary(samples: coldPublication.map(\.completion)),
            warmBurstCompletion: Summary(samples: warmPublication.map(\.completion)),
            coldPeakResidentMiB: Summary(samples: coldPublication.map(\.peakResidentMiB)),
            warmPeakResidentMiB: Summary(samples: warmPublication.map(\.peakResidentMiB)),
            cancellationLatency: Summary(samples: try await measureCancellation(
                endpoint: endpoint,
                password: password,
                iterations: iterations
            ))
        )
    }

    private func measureCancellation(
        endpoint: Endpoint,
        password: String,
        iterations: Int
    ) async throws -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let source = try EndpointSessionFactory.make(endpoint: endpoint, password: password)
            let destination = BenchmarkDestination(importDelayNanoseconds: 60_000_000_000)
            let stateDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("delivery-benchmark-cancel-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stateDirectory) }
            let engine = makeEngine(
                stateDirectory: stateDirectory,
                source: source,
                destination: destination
            )
            let job = makeJob(endpoint: endpoint)
            let runTask = Task {
                try await engine.run(job: job, leftPassword: password, rightPassword: nil)
            }
            do {
                try await destination.waitUntilImportStarts(timeoutNanoseconds: 30_000_000_000)
            } catch {
                runTask.cancel()
                _ = await runTask.result
                throw error
            }
            let cancelledAt = DispatchTime.now().uptimeNanoseconds
            runTask.cancel()
            do {
                _ = try await runTask.value
                XCTFail("The benchmark run must remain cancelled.")
            } catch is CancellationError {
                // Expected. The latency includes rollback, session close and task draining.
            }
            let finishedAt = DispatchTime.now().uptimeNanoseconds
            let importedPaths = await destination.importedPaths
            XCTAssertTrue(importedPaths.isEmpty)
            samples.append(Double(finishedAt - cancelledAt) / 1_000_000_000)
        }
        return samples
    }

    private func runPublication(
        endpoint: Endpoint,
        password: String,
        source: any EndpointSession,
        expectedPublishedPaths: Set<String>,
        keepSourceOpen: Bool
    ) async throws -> PublicationTiming {
        let destination = BenchmarkDestination()
        let sourceForRun: any EndpointSession = keepSourceOpen
            ? NonClosingEndpointSession(base: source)
            : source
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-benchmark-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let engine = makeEngine(
            stateDirectory: stateDirectory,
            source: sourceForRun,
            destination: destination
        )
        let job = makeJob(endpoint: endpoint)

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await engine.run(job: job, leftPassword: password, rightPassword: nil)
        let completion = DispatchTime.now().uptimeNanoseconds
        let recordedFirstImport = await destination.firstImportUptimeNanoseconds
        let firstImport = try XCTUnwrap(recordedFirstImport)
        let importedPaths = await destination.importedPaths
        XCTAssertEqual(result.transferred, expectedPublishedPaths.count)
        XCTAssertEqual(importedPaths, expectedPublishedPaths)
        return PublicationTiming(
            firstPublication: Double(firstImport - start) / 1_000_000_000,
            completion: Double(completion - start) / 1_000_000_000,
            peakResidentMiB: Double(await destination.peakResidentBytes) / (1024 * 1024)
        )
    }

    private func makeEngine(
        stateDirectory: URL,
        source: any EndpointSession,
        destination: BenchmarkDestination
    ) -> SyncEngine {
        SyncEngine(
            sourceSignatureRepository: SourceSignatureRepository(
                fileURL: stateDirectory.appendingPathComponent("signatures.json")
            ),
            downloadManifestRepository: DownloadManifestRepository(
                fileURL: stateDirectory.appendingPathComponent("manifest.json")
            ),
            sessionFactory: { requestedEndpoint, _, _ in
                requestedEndpoint.kind.isRemote ? source : destination
            }
        )
    }

    private func makeJob(endpoint: Endpoint) -> SyncJob {
        var job = SyncJob()
        job.left = endpoint
        job.right = Endpoint(
            kind: .local,
            localPath: "/benchmark-output",
            bookmark: Data("benchmark".utf8)
        )
        job.direction = .leftToRight
        job.filter = FileFilter(preset: .photos, recentHours: 1)
        job.isEnabled = false
        job.preserveModificationDates = true
        return job
    }

    private func measure(
        iterations: Int,
        includesWarmUp: Bool = true,
        operation: () async throws -> Void
    ) async throws -> [Double] {
        precondition(iterations > 0)
        if includesWarmUp { try await operation() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let clock = ContinuousClock()
            let start = clock.now
            try await operation()
            let elapsed = start.duration(to: clock.now).components
            samples.append(
                Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            )
        }
        return samples
    }

    private func measurePublication(
        iterations: Int,
        includesWarmUp: Bool = true,
        operation: () async throws -> PublicationTiming
    ) async throws -> [PublicationTiming] {
        precondition(iterations > 0)
        if includesWarmUp { _ = try await operation() }
        var samples: [PublicationTiming] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            samples.append(try await operation())
        }
        return samples
    }

    private static func validate(
        _ files: [String: SyncFile],
        expectedCount: Int,
        expectedPublishedPaths: Set<String>
    ) throws {
        XCTAssertEqual(files.count, expectedCount)
        XCTAssertTrue(expectedPublishedPaths.isSubset(of: files.keys))
    }

    private func required(_ name: String, in environment: [String: String]) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw BenchmarkConfigurationError.missing(name)
        }
        return value
    }

    private func requiredInteger(_ name: String, in environment: [String: String]) throws -> Int {
        let value = try required(name, in: environment)
        guard let integer = Int(value), integer > 0 else {
            throw BenchmarkConfigurationError.invalidInteger(name, value)
        }
        return integer
    }

    private static func discoveredConfigurationPath() -> String? {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return candidates
            .filter { $0.lastPathComponent.hasPrefix("aftpsync-delivery-benchmark-") }
            .map { $0.appendingPathComponent("benchmark-configuration.json") }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { return nil }
                return (url, date)
            }
            .filter { Date().timeIntervalSince($0.1) < 600 }
            .max { $0.1 < $1.1 }?
            .0.path
    }
}

private enum BenchmarkConfigurationError: LocalizedError {
    case missing(String)
    case invalidInteger(String, String)
    case emptyRecentPaths
    case importDidNotStart

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Missing benchmark environment variable \(name)."
        case .invalidInteger(let name, let value): "Benchmark variable \(name) is not a positive integer: \(value)."
        case .emptyRecentPaths: "Benchmark recent paths must contain at least one path."
        case .importDidNotStart: "Benchmark cancellation import did not start before the deadline."
        }
    }
}

private struct BenchmarkPayload: Encodable {
    let iterations: Int
    let expectedFiles: Int
    let expectedPublishedFiles: Int
    let results: [ProtocolBenchmarkResult]
}

private struct ProtocolBenchmarkResult: Encodable {
    let protocolName: String
    let coldFullScan: Summary
    let warmFullScan: Summary
    let coldFirstPublication: Summary
    let warmFirstPublication: Summary
    let coldBurstCompletion: Summary
    let warmBurstCompletion: Summary
    let coldPeakResidentMiB: Summary
    let warmPeakResidentMiB: Summary
    let cancellationLatency: Summary
}

private struct PublicationTiming {
    let firstPublication: Double
    let completion: Double
    let peakResidentMiB: Double
}

private struct Summary: Encodable {
    let samples: [Double]
    let median: Double
    let p95: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
        self.samples = samples
        if sorted.count.isMultiple(of: 2) {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }
        let percentileIndex = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        p95 = sorted[percentileIndex]
    }
}

private struct NonClosingEndpointSession: EndpointSession {
    let base: any EndpointSession

    var supportsCompletedDirectoryListings: Bool {
        base.supportsCompletedDirectoryListings
    }

    func testConnection() async throws { try await base.testConnection() }
    func listFiles() async throws -> [String: SyncFile] { try await base.listFiles() }
    func listFilesIncrementally(
        onCompletedDirectory: @escaping @Sendable (CompletedDirectoryListing) async throws -> Void
    ) async throws -> [String: SyncFile] {
        try await base.listFilesIncrementally(onCompletedDirectory: onCompletedDirectory)
    }
    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try await base.exportFile(file, to: temporaryURL)
    }
    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        try await base.importFile(
            from: localURL,
            as: file,
            preserveDate: preserveDate,
            verifySize: verifySize
        )
    }
    func close() async {}
}

private actor BenchmarkDestination: EndpointSession {
    private(set) var importedPaths: Set<String> = []
    private(set) var firstImportUptimeNanoseconds: UInt64?
    private(set) var peakResidentBytes = currentResidentMemoryBytes()
    private let importDelayNanoseconds: UInt64

    init(importDelayNanoseconds: UInt64 = 0) {
        self.importDelayNanoseconds = importDelayNanoseconds
    }

    func waitUntilImportStarts(timeoutNanoseconds: UInt64) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while firstImportUptimeNanoseconds == nil {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw BenchmarkConfigurationError.importDidNotStart
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func listFiles() async throws -> [String: SyncFile] { [:] }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        throw AppError.invalidConfiguration("The benchmark destination cannot export files.")
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        if firstImportUptimeNanoseconds == nil {
            firstImportUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        if importDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: importDelayNanoseconds)
        }
        let payload = try Data(contentsOf: localURL)
        peakResidentBytes = max(peakResidentBytes, currentResidentMemoryBytes())
        _ = payload.count
        importedPaths.insert(file.relativePath)
    }

    func importFilesTransactionallyIfAbsent(
        _ imports: [EndpointFileImport],
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        for item in imports {
            guard !importedPaths.contains(item.file.relativePath) else {
                throw AppError.transferFailed("The benchmark destination received a duplicate path.")
            }
            try await importFile(
                from: item.localURL,
                as: item.file,
                preserveDate: preserveDate,
                verifySize: verifySize
            )
        }
    }
}

private func currentResidentMemoryBytes() -> UInt64 {
    var information = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(information.resident_size)
}
