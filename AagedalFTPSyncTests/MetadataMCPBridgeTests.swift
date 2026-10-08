import Foundation
import XCTest
@testable import AagedalFTPSync

@MainActor
final class MetadataMCPBridgeTests: XCTestCase {
    func testRequestsReadLiveJobsAndWriteThroughAppValidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-mcp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        var job = SyncJob(name: "MCP job")
        job.isEnabled = false
        job.startsOnAppLaunch = false
        job.left = Endpoint(kind: .local, localPath: root.appendingPathComponent("input").path,
                            bookmark: Data([1]))
        job.right = Endpoint(kind: .local, localPath: root.appendingPathComponent("output").path,
                             bookmark: Data([1]))
        let jobs = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        try jobs.save([job])
        let photographers = PhotographerProfileRepository(fileURL: root.appendingPathComponent("photographers.json"))
        let store = AppStore(repository: jobs,
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            photographerProfileRepository: photographers,
            serverProfileRepository: ServerProfileRepository(fileURL: root.appendingPathComponent("servers.json")),
            metadataAuditRepository: MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json")),
            syncFailureRepository: SyncFailureRepository(fileURL: root.appendingPathComponent("failures.json")),
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.json")),
            downloadManifestRepository: DownloadManifestRepository(fileURL: root.appendingPathComponent("manifest.json")),
            startsJobsOnInitialization: false)
        let calendar = MetadataCalendarCoordinator(
            repository: MetadataCalendarRepository(url: root.appendingPathComponent("calendar.json")),
            transport: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) })
        let directory = root.appendingPathComponent("mcp-bridge", isDirectory: true)
        let bridge = MetadataMCPBridge(directory: directory, store: store, calendar: calendar)
        bridge.start()
        defer { bridge.stop() }
        XCTAssertNil(store.alertMessage)

        func send(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let id = UUID().uuidString
            let request: [String: Any] = [
                "id": id, "tool": tool, "arguments": arguments,
                "expires_at": Date().addingTimeInterval(10).timeIntervalSince1970
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            try data.write(to: directory.appendingPathComponent("requests/\(id).json"), options: .atomic)
            let response = directory.appendingPathComponent("responses/\(id).json")
            for _ in 0..<40 {
                if let data = try? Data(contentsOf: response),
                   let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    try? FileManager.default.removeItem(at: response)
                    return value
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NSError(domain: "MetadataMCPBridgeTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The bridge did not answer in four seconds."])
        }

        let fetched = try await send("fetch_jobs", [:])
        XCTAssertEqual(fetched["ok"] as? Bool, true)
        let summaries = try XCTUnwrap(fetched["data"] as? [[String: Any]])
        XCTAssertEqual(summaries.first?["id"] as? String, job.id.uuidString)

        let added = try await send("add_photographer", [
            "job_id": job.id.uuidString, "name": "Desk", "filename_initials": "DSK"])
        XCTAssertEqual(added["ok"] as? Bool, true, added["error"] as? String ?? "No app error")
        let profile = try XCTUnwrap(added["data"] as? [String: Any])
        let photographerID = try XCTUnwrap(profile["id"] as? String)
        XCTAssertEqual(try photographers.load().map(\.id.uuidString), [photographerID])

        let clipArguments: [String: Any] = [
            "job_id": job.id.uuidString, "photographer_id": photographerID,
            "name": "Assignment", "starts_at": "2026-09-15T10:00:00+02:00",
            "ends_at": "2026-09-15T11:00:00+02:00", "headline": "Desk assignment"
        ]
        let clipped = try await send("add_metadata_clip", clipArguments)
        XCTAssertEqual(clipped["ok"] as? Bool, true)
        let saved = try XCTUnwrap(jobs.load().first?.metadataAutomation)
        XCTAssertEqual(saved.clips.count, 1)
        XCTAssertFalse(saved.photographerTracks.isEmpty)

        let overlap = try await send("add_metadata_clip", clipArguments)
        XCTAssertEqual(overlap["ok"] as? Bool, false)
        XCTAssertEqual(try jobs.load().first?.metadataAutomation?.clips.count, 1)

        store.metadataDraftsBeingEdited.insert(job.id)
        let dirty = try await send("add_metadata_clip", [
            "job_id": job.id.uuidString, "photographer_id": photographerID,
            "name": "Later", "starts_at": "2026-09-15T12:00:00+02:00",
            "ends_at": "2026-09-15T13:00:00+02:00"])
        XCTAssertEqual(dirty["ok"] as? Bool, false)
        XCTAssertTrue((dirty["error"] as? String ?? "").contains("unsaved metadata draft"))
    }
}
