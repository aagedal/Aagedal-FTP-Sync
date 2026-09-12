import AppKit
import Foundation
import SwiftMediaMetadata
import XCTest
@testable import AagedalFTPSync

final class MetadataAuditTests: XCTestCase {
    func testRunReportCountsOutcomesSeparately() {
        let fixture = AuditFixture()
        let report = MetadataRunReport(entries: [
            fixture.entry(status: .applied, path: "one.jpg"),
            fixture.entry(status: .skipped, path: "two.jpg"),
            fixture.entry(status: .failed, path: "three.jpg"),
            fixture.entry(status: .applied, path: "four.jpg"),
        ])

        XCTAssertEqual(report.applied, 2)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.failed, 1)
    }

    func testAuditEntrySnapshotsAssignmentAndDeduplicatesWarnings() {
        let fixture = AuditFixture()
        let entry = MetadataAuditEntry(
            runID: fixture.runID,
            jobID: fixture.jobID,
            occurredAt: fixture.timestamp,
            operation: .transfer,
            relativePath: "incoming/JAD_0001.jpg",
            status: .applied,
            timestampPolicy: .cameraCapture,
            scheduledAt: fixture.timestamp,
            assignment: fixture.assignment,
            swiftExifWarnings: ["MakerNote moved", "MakerNote moved", ""],
            detail: nil
        )

        XCTAssertEqual(entry.photographerID, fixture.photographer.id)
        XCTAssertEqual(entry.photographerName, "Jane Doe")
        XCTAssertEqual(entry.clipID, fixture.clip.id)
        XCTAssertEqual(entry.clipName, "Election night")
        XCTAssertEqual(entry.timestampPolicy, .cameraCapture)
        XCTAssertEqual(entry.swiftExifWarnings, ["MakerNote moved"])
    }

    func testAuditRepositoryRoundTripsAndFiltersByJob() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json"))
        let first = AuditFixture()
        let secondJobID = UUID()
        let firstEntry = first.entry(status: .applied, path: "one.jpg")
        let secondEntry = MetadataAuditEntry(
            runID: UUID(),
            jobID: secondJobID,
            occurredAt: first.timestamp.addingTimeInterval(1),
            operation: .reprocess,
            relativePath: "two.dng",
            status: .failed,
            timestampPolicy: .sourceModification,
            scheduledAt: first.timestamp,
            swiftExifWarnings: ["warning"],
            detail: "Metadata write failed"
        )

        try repository.append(MetadataRunReport(entries: [firstEntry, secondEntry]))

        XCTAssertEqual(try repository.load(), [firstEntry, secondEntry])
        XCTAssertEqual(try repository.load(jobID: first.jobID), [firstEntry])
        XCTAssertEqual(try repository.load(jobID: secondJobID), [secondEntry])
    }

    func testAuditRepositoryRetainsNewestEntriesWithinBound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-audit-bound-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MetadataAuditRepository(
            fileURL: root.appendingPathComponent("audit.json"),
            maximumEntries: 2
        )
        let fixture = AuditFixture()
        let entries = (0..<3).map { index in
            fixture.entry(
                status: .applied,
                path: "\(index).jpg",
                occurredAt: fixture.timestamp.addingTimeInterval(Double(index))
            )
        }

        let retained = try repository.append(MetadataRunReport(entries: entries))

        XCTAssertEqual(retained.map(\.relativePath), ["1.jpg", "2.jpg"])
        XCTAssertEqual(try repository.load().map(\.relativePath), ["1.jpg", "2.jpg"])
    }

    func testAuditRepositoryRecoversFromLastValidBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-audit-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audit.json")
        let repository = MetadataAuditRepository(fileURL: url)
        let fixture = AuditFixture()
        let recoverable = fixture.entry(status: .applied, path: "recoverable.jpg")

        try repository.save([recoverable])
        try repository.save([fixture.entry(status: .skipped, path: "newer.jpg")])
        try Data("not json".utf8).write(to: url, options: .atomic)

        let result = try repository.loadResult()
        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.entries, [recoverable])
    }

    func testProcessingFingerprintDetectsIndependentStalenessDimensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-fingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("published.jpg")
        try Data("published-v1".utf8).write(to: output)
        let fixture = AuditFixture()
        let source = SyncFile(relativePath: "incoming/JAD_0001.jpg", size: 12,
                              modifiedAt: fixture.timestamp)
        let fingerprint = try MetadataProcessingFingerprint(
            sourceFile: source,
            sourceSidecar: nil,
            assignment: fixture.assignment,
            geocoding: nil,
            faceRecognition: nil,
            timestampPolicy: .sourceModification,
            processingTimeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Oslo")),
            dependencyRevisions: ["writer": "SwiftMediaMetadata-2.0.0"],
            outputArtifacts: [.init(role: "primary", relativePath: source.relativePath, fileURL: output)]
        )

        XCTAssertEqual(fingerprint.freshness(
            sourceRevision: fingerprint.sourceRevision,
            settingsRevision: fingerprint.settingsRevision,
            dependencyRevision: fingerprint.dependencyRevision,
            outputRevision: fingerprint.outputRevision
        ), .current)
        XCTAssertEqual(fingerprint.freshness(
            sourceRevision: String(repeating: "0", count: 64),
            settingsRevision: fingerprint.settingsRevision,
            dependencyRevision: fingerprint.dependencyRevision,
            outputRevision: fingerprint.outputRevision
        ), .sourceChanged)
        XCTAssertEqual(fingerprint.freshness(
            sourceRevision: fingerprint.sourceRevision,
            settingsRevision: String(repeating: "1", count: 64),
            dependencyRevision: fingerprint.dependencyRevision,
            outputRevision: fingerprint.outputRevision
        ), .settingsChanged)
        XCTAssertEqual(fingerprint.freshness(
            sourceRevision: fingerprint.sourceRevision,
            settingsRevision: fingerprint.settingsRevision,
            dependencyRevision: String(repeating: "2", count: 64),
            outputRevision: fingerprint.outputRevision
        ), .dependenciesChanged)
        XCTAssertEqual(fingerprint.freshness(
            sourceRevision: fingerprint.sourceRevision,
            settingsRevision: fingerprint.settingsRevision,
            dependencyRevision: fingerprint.dependencyRevision,
            outputRevision: String(repeating: "3", count: 64)
        ), .outputChanged)
    }

    func testProcessingFingerprintIsCanonicalAndSeparatesSourceSettingsDependenciesAndOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-fingerprint-canonical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("primary")
        let sidecar = root.appendingPathComponent("sidecar")
        try Data("primary bytes".utf8).write(to: primary)
        try Data("sidecar bytes".utf8).write(to: sidecar)
        let fixture = AuditFixture()
        let source = SyncFile(relativePath: "photo.dng", size: 10, modifiedAt: fixture.timestamp)
        let companion = SyncFile(relativePath: "photo.xmp", size: 20, modifiedAt: fixture.timestamp)
        let zone = try XCTUnwrap(TimeZone(identifier: "Etc/UTC"))
        let artifacts = [
            MetadataProcessingFingerprint.OutputArtifact(role: "sidecar", relativePath: "photo.xmp", fileURL: sidecar),
            .init(role: "primary", relativePath: "photo.dng", fileURL: primary)
        ]
        func make(
            sourceFile: SyncFile = source,
            assignment: MetadataAssignment? = fixture.assignment,
            dependencies: [String: String] = ["model": "b", "library": "a"],
            outputs: [MetadataProcessingFingerprint.OutputArtifact] = artifacts
        ) throws -> MetadataProcessingFingerprint {
            try MetadataProcessingFingerprint(
                sourceFile: sourceFile, sourceSidecar: companion, assignment: assignment,
                geocoding: nil, faceRecognition: nil, timestampPolicy: .cameraCapture,
                processingTimeZone: zone, dependencyRevisions: dependencies,
                outputArtifacts: outputs
            )
        }

        let first = try make()
        let reordered = try make(
            dependencies: ["library": "a", "model": "b"],
            outputs: Array(artifacts.reversed())
        )
        XCTAssertEqual(first, reordered)

        let changedSource = try make(sourceFile: SyncFile(
            relativePath: source.relativePath, size: source.size + 1, modifiedAt: source.modifiedAt
        ))
        XCTAssertNotEqual(first.sourceRevision, changedSource.sourceRevision)
        XCTAssertEqual(first.settingsRevision, changedSource.settingsRevision)

        let changedAssignment = MetadataAssignment(
            photographer: fixture.assignment.photographer,
            clip: fixture.assignment.clip,
            existingFieldPolicy: .fillEmpty
        )
        let changedSettings = try make(assignment: changedAssignment)
        XCTAssertNotEqual(first.settingsRevision, changedSettings.settingsRevision)
        XCTAssertEqual(first.sourceRevision, changedSettings.sourceRevision)

        let changedDependencies = try make(dependencies: ["library": "a", "model": "c"])
        XCTAssertNotEqual(first.dependencyRevision, changedDependencies.dependencyRevision)

        try Data("user edited bytes".utf8).write(to: primary)
        let changedOutput = try make()
        XCTAssertNotEqual(first.outputRevision, changedOutput.outputRevision)
    }

    func testProcessingFingerprintPersistsAndRejectsMalformedOrFutureReceipts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-fingerprint-codec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("published.jpg")
        try Data("published".utf8).write(to: output)
        let fixture = AuditFixture()
        let source = SyncFile(relativePath: "published.jpg", size: 9, modifiedAt: fixture.timestamp)
        let fingerprint = try MetadataProcessingFingerprint(
            sourceFile: source, sourceSidecar: nil, assignment: fixture.assignment,
            geocoding: nil, faceRecognition: nil, timestampPolicy: .sourceModification,
            processingTimeZone: try XCTUnwrap(TimeZone(identifier: "Etc/UTC")),
            outputArtifacts: [.init(role: "primary", relativePath: source.relativePath, fileURL: output)]
        )
        let entry = MetadataAuditEntry(
            runID: fixture.runID, jobID: fixture.jobID, occurredAt: fixture.timestamp,
            operation: .transfer, relativePath: source.relativePath, status: .applied,
            timestampPolicy: .sourceModification, scheduledAt: fixture.timestamp,
            assignment: fixture.assignment, processingFingerprint: fingerprint
        )
        let encoded = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(MetadataAuditEntry.self, from: encoded), entry)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var receipt = try XCTUnwrap(object["processingFingerprint"] as? [String: Any])
        receipt["sourceRevision"] = "not-a-digest"
        object["processingFingerprint"] = receipt
        XCTAssertThrowsError(try JSONDecoder().decode(
            MetadataAuditEntry.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
        receipt["sourceRevision"] = fingerprint.sourceRevision
        receipt["schemaVersion"] = 2
        object["processingFingerprint"] = receipt
        XCTAssertThrowsError(try JSONDecoder().decode(
            MetadataAuditEntry.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    @MainActor
    func testAppStorePublishesPersistedAuditTrail() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-audit-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auditRepository = MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json"))
        let fixture = AuditFixture()
        let entry = fixture.entry(status: .applied, path: "published.jpg")
        let firstStore = AppStore(
            repository: JobRepository(fileURL: root.appendingPathComponent("jobs.json")),
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            metadataAuditRepository: auditRepository
        )

        firstStore.recordMetadataAudit(MetadataRunReport(entries: [entry]), jobID: fixture.jobID)
        let secondStore = AppStore(
            repository: JobRepository(fileURL: root.appendingPathComponent("jobs.json")),
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            metadataAuditRepository: auditRepository
        )

        XCTAssertEqual(firstStore.metadataAuditTrail(for: fixture.jobID), [entry])
        XCTAssertEqual(secondStore.metadataAuditTrail(for: fixture.jobID), [entry])
    }

    func testMetadataWriterSurfacesSwiftMediaMetadataWriteWarnings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-warning-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeJPEG().write(to: url)

        let fixture = AuditFixture(creator: String(repeating: "a", count: 40))
        let warnings = try MetadataWriter.apply(fixture.assignment, to: url)

        XCTAssertTrue(warnings.contains { $0.contains("By-line") && $0.contains("32") })
    }

    private func makeJPEG() throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = bitmap.representation(using: .jpeg, properties: [:]) else {
            throw AppError.transferFailed("Could not create JPEG fixture")
        }
        return data
    }
}

private struct AuditFixture {
    let jobID = UUID()
    let runID = UUID()
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let photographer: PhotographerProfile
    let clip: MetadataScheduleClip

    init(creator: String = "Jane Doe") {
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: creator,
            copyrightNotice: "Example News"
        )
        self.photographer = photographer
        clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Election night",
            startsAt: timestamp.addingTimeInterval(-60),
            endsAt: timestamp.addingTimeInterval(60),
            fields: ScheduledMetadataFields(headline: "Results")
        )
    }

    var assignment: MetadataAssignment {
        MetadataAssignment(
            photographer: photographer,
            clip: clip,
            existingFieldPolicy: .overwrite
        )
    }

    func entry(
        status: MetadataAuditStatus,
        path: String,
        occurredAt: Date? = nil
    ) -> MetadataAuditEntry {
        MetadataAuditEntry(
            runID: runID,
            jobID: jobID,
            occurredAt: occurredAt ?? timestamp,
            operation: .transfer,
            relativePath: path,
            status: status,
            timestampPolicy: .sourceModification,
            scheduledAt: timestamp,
            assignment: status == .skipped ? nil : assignment,
            detail: status == .failed ? "Metadata write failed" : nil
        )
    }
}
