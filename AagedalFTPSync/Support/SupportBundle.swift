import Foundation

/// A deliberately closed export format for customer-support diagnostics.
/// Free-form strings and persistent identifiers are excluded so job names,
/// endpoints, paths, filenames, usernames, credentials, and raw errors cannot
/// enter the bundle.
struct RedactedSupportBundle: Codable, Equatable, Sendable {
    struct ApplicationVersion: Codable, Equatable, Sendable {
        let version: String
        let build: String
    }

    struct SystemVersion: Codable, Equatable, Sendable {
        let operatingSystem: String
    }

    struct ConfigurationShape: Codable, Equatable, Sendable {
        let jobCount: Int
        let enabledJobCount: Int
        let metadataPresetCount: Int
        let photographerCount: Int
        let jobs: [JobShape]
    }

    struct JobShape: Codable, Equatable, Sendable {
        let jobNumber: Int
        let left: EndpointShape
        let right: EndpointShape
        let direction: SyncDirection
        let filterPreset: FilterPreset
        let customExtensionCount: Int?
        let intervalSeconds: Double
        let startsOnAppLaunch: Bool
        let preservesModificationDates: Bool
        let verifiesFileSizes: Bool
        let verifiesMatchingFileContents: Bool?
        let cleanupEnabled: Bool
        let processedFilesEnabled: Bool
        let processedFilesLocation: ProcessedFilesLocation?
        let metadataAutomationEnabled: Bool
    }

    struct EndpointShape: Codable, Equatable, Sendable {
        let kind: EndpointKind
        let connectionConfigured: Bool
        let hostKeyTrusted: Bool?
    }

    struct RecentError: Codable, Equatable, Sendable {
        let occurredAt: Date
        let jobNumber: Int?
        let category: String
    }

    let schemaVersion: Int
    let generatedAt: Date
    let application: ApplicationVersion
    let system: SystemVersion
    let configuration: ConfigurationShape
    let recentErrors: [RecentError]
}

enum SupportBundleCodec {
    static let maximumRecentErrors = 50

    static func encode(
        jobs: [SyncJob],
        metadataPresetCount: Int,
        photographerCount: Int,
        failures: [UUID: [SyncFailureRecord]],
        applicationVersion: String,
        build: String,
        operatingSystem: String,
        generatedAt: Date = Date()
    ) throws -> Data {
        let jobNumbers = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { index, job in
            (job.id, index + 1)
        })
        let bundle = RedactedSupportBundle(
            schemaVersion: 1,
            generatedAt: generatedAt,
            application: .init(version: applicationVersion, build: build),
            system: .init(operatingSystem: operatingSystem),
            configuration: .init(
                jobCount: jobs.count,
                enabledJobCount: jobs.filter(\.isEnabled).count,
                metadataPresetCount: metadataPresetCount,
                photographerCount: photographerCount,
                jobs: jobs.enumerated().map { index, job in
                    jobShape(job, number: index + 1)
                }
            ),
            recentErrors: failures.values
                .flatMap { $0 }
                .sorted(by: newestFailureFirst)
                .prefix(maximumRecentErrors)
                .map { failure in
                    .init(
                        occurredAt: failure.occurredAt,
                        jobNumber: jobNumbers[failure.jobID],
                        category: "sync-run-failure"
                    )
                }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    static func decode(_ data: Data) throws -> RedactedSupportBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RedactedSupportBundle.self, from: data)
    }

    private static func jobShape(_ job: SyncJob, number: Int) -> RedactedSupportBundle.JobShape {
        .init(
            jobNumber: number,
            left: endpointShape(job.left),
            right: endpointShape(job.right),
            direction: job.direction,
            filterPreset: job.filter.preset,
            customExtensionCount: job.filter.preset == .custom ? job.filter.allowedExtensions?.count : nil,
            intervalSeconds: job.intervalSeconds,
            startsOnAppLaunch: job.startsOnAppLaunch,
            preservesModificationDates: job.preserveModificationDates,
            verifiesFileSizes: job.verifyFileSizes,
            verifiesMatchingFileContents: job.verifiesMatchingFileContents,
            cleanupEnabled: job.targetCleanup != nil,
            processedFilesEnabled: job.movesProcessedFiles,
            processedFilesLocation: job.movesProcessedFiles ? job.effectiveProcessedFilesLocation : nil,
            metadataAutomationEnabled: job.metadataAutomation?.isEnabled == true
        )
    }

    private static func endpointShape(_ endpoint: Endpoint) -> RedactedSupportBundle.EndpointShape {
        .init(
            kind: endpoint.kind,
            connectionConfigured: endpoint.connectionValidationMessage == nil,
            hostKeyTrusted: endpoint.kind == .sftp
                ? SSHHostKeyFingerprint.normalized(endpoint.hostKeyFingerprint) != nil
                : nil
        )
    }

    private static func newestFailureFirst(_ lhs: SyncFailureRecord, _ rhs: SyncFailureRecord) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}
