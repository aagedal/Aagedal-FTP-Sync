import Foundation
import MetadataTemplates
import ServiceManagement
import XCTest
@testable import AagedalFTPSync

private actor NamespaceCalendarServer {
    var calendar: SharedMetadataCalendar
    var requests: [MetadataCalendarRequest] = []
    var wireRequests: [URLRequest] = []
    var offline = false
    var wrongNamespace = false
    init(_ calendar: SharedMetadataCalendar) { self.calendar = calendar }
    func setOffline() { offline = true }
    func setWrongNamespace() { wrongNamespace = true }
    func captured() -> [MetadataCalendarRequest] { requests }
    func capturedWire() -> [URLRequest] { wireRequests }
    func refuseCapabilities(_ request: URLRequest) throws -> (Data, Int) {
        wireRequests.append(request)
        return (try JSONSerialization.data(withJSONObject: ["service": "aagedal-metadata-sync", "protocolVersion": 3,
            "capabilities": [], "documentSchemaVersions": [1, 3], "templateLanguageVersions": [1]]), 200)
    }
    func send(_ body: MetadataCalendarRequest) throws -> MetadataCalendarResponse {
        requests.append(body)
        if offline { throw URLError(.notConnectedToInternet) }
        let version = wrongNamespace ? MetadataCalendarProtocol.legacy : body.routingProtocol
        if body.action == "listCalendars" {
            return .init(service: "aagedal-metadata-sync", protocolVersion: version.rawValue,
                calendars: [.init(id: calendar.id, name: calendar.name, timeZone: calendar.timeZone, role: calendar.role,
                    compatibility: version == .templates ? .templates : .legacy)],
                capabilities: version == .templates ? ["metadata-templates-v1"] : nil)
        }
        if body.action == "putCalendar", !wrongNamespace {
            guard body.expectedRevision == calendar.revision, let document = body.document else {
                return .init(service: "aagedal-metadata-sync", protocolVersion: version.rawValue,
                    error: "revision_conflict", calendar: calendar,
                    capabilities: version == .templates ? ["metadata-templates-v1"] : nil)
            }
            calendar.document = document
            calendar.revision += 1
        }
        var returned = calendar
        if wrongNamespace { returned.compatibility = .legacy }
        return .init(service: "aagedal-metadata-sync", protocolVersion: version.rawValue, calendar: returned,
            capabilities: version == .templates ? ["metadata-templates-v1"] : nil)
    }
}

@MainActor
final class MetadataCalendarNamespaceCoordinatorTests: XCTestCase {
    private struct Fixture {
        let store: AppStore
        let sync: MetadataCalendarCoordinator
        let repository: MetadataCalendarRepository
        let server: NamespaceCalendarServer
        let job: SyncJob
        let calendar: SharedMetadataCalendar
    }

    private func fixture(protocolVersion: MetadataCalendarProtocol = .templates,
                         activeBaseline: Bool = true, localHeadline: MetadataTemplateText? = nil,
                         revision: Int64 = 1, capabilityFailure: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("namespace-coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorageLayout(root: root, storageFormat: .version3)
        let profile = PhotographerProfile(name: "Fixture", filenamePrefix: "FX", creator: "Fixture", copyrightNotice: "Literal")
        let clip = MetadataScheduleClip(photographerID: profile.id, name: "Fixture",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_000_600),
            fields: .init(headline: "Literal {photographer}"))
        var job = SyncJob(name: "Namespace fixture", left: .init(kind: .local, localPath: root.appendingPathComponent("in").path, bookmark: Data([1])),
            right: .init(kind: .local, localPath: root.appendingPathComponent("out").path, bookmark: Data([2])), isEnabled: false,
            metadataAutomation: .init(photographers: [profile], photographerTracks: [], clips: [clip]))
        job.startsOnAppLaunch = false
        job.metadataProcessingTimeZoneIdentifier = "Etc/UTC"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let converted = try Version3JSONStoreConversion.convert(selectedLegacyPrimaries: [storage.jobs.lastPathComponent: encoder.encode([job])])
        for (name, bytes) in converted.stores { try bytes.write(to: root.appendingPathComponent(name)) }
        var baseline = try XCTUnwrap(job.metadataAutomation)
        if activeBaseline { baseline.clips[0].fields.setHeadline(try .activated("{photographer}")) }
        var local = baseline
        if let localHeadline { local.clips[0].fields.setHeadline(localHeadline) }
        job.metadataAutomation = local
        try JobRepository(storage: storage).save([job])
        let calendar = SharedMetadataCalendar(id: UUID(), name: "Fixture", timeZone: "Etc/UTC", revision: revision,
            role: "owner", document: SharedMetadataDocument(baseline), compatibility: protocolVersion == .templates ? .templates : .legacy)
        let account = MetadataSyncAccount(id: UUID(), address: "https://fixture.invalid/", registered: true)
        let repository = MetadataCalendarRepository(storage: storage)
        try repository.save(.init(accounts: [account], activeAccountID: account.id,
            bindings: [.init(accountID: account.id, jobID: job.id, snapshot: calendar)]))
        let keychain = KeychainStore(passwordReader: { _ in String(repeating: "a", count: 64) },
            passwordWriter: { _, _ in XCTFail("Bound sync must not replace credentials") },
            passwordRemover: { _ in XCTFail("Bound sync must not remove credentials") })
        let store = try AppStore.makePausedForValidatedStorage(storage, retainedCredentialIDs: [],
            allowsCredentialGarbageCollection: false, keychain: keychain, launchAtLoginCoordinator: NamespaceLaunchStub())
        let server = NamespaceCalendarServer(calendar)
        let sync = MetadataCalendarCoordinator(repository: repository, keychain: keychain,
            transport: { body, address, id, key, setup in
                if capabilityFailure {
                    let client = MetadataCalendarClient(transport: { try await server.refuseCapabilities($0) })
                    return try await client.send(body, address: address, deviceID: id, key: key,
                        setupKey: setup, protocolVersion: body.routingProtocol)
                }
                return try await server.send(body)
            })
        sync.start(store: store, polling: false, observingChanges: false)
        addTeardownBlock { await MainActor.run { sync.stop() } }
        return .init(store: store, sync: sync, repository: repository, server: server, job: job, calendar: calendar)
    }

    func testOfflineTemplateBindingRetainsActiveLocalEditAndBaseline() async throws {
        let f = try fixture(localHeadline: .activated("Saved {gps:city}"))
        await f.server.setOffline()
        let bytes = try Data(contentsOf: f.repository.url)
        await f.sync.refresh(jobID: f.job.id)
        let requests = await f.server.captured()
        XCTAssertEqual(requests.map(\.routingProtocol), [.templates])
        XCTAssertEqual(requests.map(\.action), ["getCalendar"])
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation?.clips.first?.fields.headline, "Saved {gps:city}")
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation?.clips.first?.fields.templateVersions["headline"], 1)
        XCTAssertEqual(try f.repository.load().bindings.first?.snapshot, f.calendar)
        XCTAssertEqual(try Data(contentsOf: f.repository.url), bytes)
    }

    func testWrongNamespaceResponseNeverAppliesOrPublishesLocalChanges() async throws {
        let f = try fixture(localHeadline: .activated("Local {photographer}"))
        await f.server.setWrongNamespace()
        let original = try Data(contentsOf: f.repository.url)
        await f.sync.refresh(jobID: f.job.id)
        let requests = await f.server.captured()
        XCTAssertEqual(requests.map(\.action), ["getCalendar"])
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation?.clips.first?.fields.headline, "Local {photographer}")
        XCTAssertEqual(try Data(contentsOf: f.repository.url), original)
        XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.compatibility, .templates)
    }

    func testExplicitDeactivationSendsExactDeclarationAndKeepsTemplateNamespace() async throws {
        let f = try fixture(localHeadline: .literal("Literal {photographer}"))
        await f.sync.refresh(jobID: f.job.id)
        let requests = await f.server.captured()
        let put = try XCTUnwrap(requests.first { $0.action == "putCalendar" })
        XCTAssertEqual(put.routingProtocol, .templates)
        XCTAssertEqual(put.documentSchemaVersion, 3)
        XCTAssertEqual(put.expectedRevision, 1)
        XCTAssertEqual(put.templateDeactivations, [try .init(recordKind: .clip,
            recordID: f.calendar.document.clips[0].id, field: .headline)])
        XCTAssertTrue(try XCTUnwrap(put.document?.clips.first).fields.templateVersions.isEmpty)
        let saved = try XCTUnwrap(f.repository.load().bindings.first)
        XCTAssertEqual(saved.snapshot.compatibility, .templates)
        XCTAssertEqual(saved.snapshot.revision, 2)
        XCTAssertEqual(saved.snapshot.document.clips.first?.fields.headline, "Literal {photographer}")
    }

    func testCapabilityRefusalBeforeCreateRetainsPendingLocalBindingWithoutSendingSource() async throws {
        let f = try fixture(revision: 0, capabilityFailure: true)
        let original = try Data(contentsOf: f.repository.url)
        await f.sync.refresh(jobID: f.job.id)
        let requests = await f.server.capturedWire()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "getCapabilities")
        XCTAssertNil(body["document"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Aagedal-Protocol"), "3")
        XCTAssertEqual(f.store.jobs.first?.metadataAutomation, f.job.metadataAutomation)
        XCTAssertEqual(try Data(contentsOf: f.repository.url), original)
        XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.revision, 0)
    }

    func testDiscoverySelectionDoesNotChangeExistingBindingNamespace() async throws {
        let f = try fixture()
        await f.sync.refresh()
        XCTAssertEqual(f.sync.discoveryProtocol, .legacy)
        XCTAssertEqual(f.sync.calendars.first?.compatibility, .legacy)
        XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.compatibility, .templates)
        f.sync.selectProtocol(.templates)
        let deadline = Date().addingTimeInterval(5)
        while f.sync.calendars.first?.compatibility != .templates, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(f.sync.calendars.first?.compatibility, .templates)
        let requests = await f.server.captured()
        XCTAssertTrue(requests.contains { $0.action == "listCalendars" && $0.routingProtocol == .legacy })
        XCTAssertTrue(requests.contains { $0.action == "listCalendars" && $0.routingProtocol == .templates })
        XCTAssertTrue(requests.filter { $0.action == "getCalendar" }.allSatisfy { $0.routingProtocol == .templates })
        XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.compatibility, .templates)
    }

    func testLiteralTemplateCalendarNeverDowngradesWhileLegacyBindingStaysProtocol2() async throws {
        for protocolVersion in [MetadataCalendarProtocol.legacy, .templates] {
            let f = try fixture(protocolVersion: protocolVersion, activeBaseline: false, localHeadline: .literal("Changed literal"))
            await f.sync.refresh(jobID: f.job.id)
            let requests = await f.server.captured()
            XCTAssertEqual(requests.map(\.action), ["getCalendar", "putCalendar"])
            XCTAssertTrue(requests.allSatisfy { $0.routingProtocol == protocolVersion })
            XCTAssertEqual(f.sync.binding(for: f.job.id)?.snapshot.compatibility.protocolVersion, protocolVersion)
            if protocolVersion == .legacy {
                XCTAssertNil(requests.last?.capabilities)
                XCTAssertNil(requests.last?.documentSchemaVersion)
                XCTAssertNil(requests.last?.templateDeactivations)
            }
        }
    }
}

@MainActor
private final class NamespaceLaunchStub: LaunchAtLoginCoordinating {
    var status: SMAppService.Status { .notRegistered }
    func setEnabled(_ enabled: Bool) throws { XCTFail("Fixture must not change launch at login") }
    func openSettings() { XCTFail("Fixture must not open system settings") }
}
