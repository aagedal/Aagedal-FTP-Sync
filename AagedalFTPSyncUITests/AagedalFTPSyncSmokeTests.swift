import AppKit
import XCTest
import ImageIO

@MainActor
final class AagedalFTPSyncSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    func testJobsWindowReopensFromStatusMenuAfterClosing() {
        launch(seedJob: true)
        let jobsWindow = app.windows["jobs"]
        for _ in 0..<2 {
            jobsWindow.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(jobsWindow.waitForNonExistence(timeout: 5))
            openStatusMenu()
            element("open-jobs-window").click()
            XCTAssertTrue(jobsWindow.waitForExistence(timeout: 5))
            dismissStatusPanelIfNeeded()
            XCTAssertTrue(element("job-name").waitForExistence(timeout: 5))
        }
    }

    func testRetainedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry() throws {
        try verifyRetainedMetadataRecovery(managed: false)
    }

    func testManagedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry() throws {
        try verifyRetainedMetadataRecovery(managed: true)
    }

    func testImageRecoveryPublishesAndRetainsResultAcrossRelaunch() throws {
        try verifyRetainedMetadataRecovery(managed: false, images: true)
    }

    func testManagedImageRecoveryPublishesAndRetainsResultAcrossRelaunch() throws {
        try verifyRetainedMetadataRecovery(managed: true, images: true)
    }

    func testInterruptedImagePublicationReconcilesAndRetriesAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false)
    }

    func testManagedInterruptedImagePublicationReconcilesAndRetriesAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true)
    }

    func testCameraRawPublicationReconcilesAndRetriesAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true)
    }

    func testManagedCameraRawPublicationReconcilesAndRetriesAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true)
    }

    func testCanonRawPublicationReconcilesAndRetriesAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, rawExtension: "cr3")
    }

    func testManagedCanonRawPublicationReconcilesAndRetriesAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, rawExtension: "cr3")
    }

    func testCameraRawHeldOriginalsReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, phase: "originalsHeld")
    }

    func testManagedCameraRawHeldOriginalsReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, phase: "originalsHeld")
    }

    func testCanonRawHeldOriginalsReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, rawExtension: "cr3", phase: "originalsHeld")
    }

    func testManagedCanonRawHeldOriginalsReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, rawExtension: "cr3", phase: "originalsHeld")
    }

    func testCameraRawPreparedReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, rawExtension: "arw", phase: "prepared")
    }

    func testCameraRawFirstPublishedReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, rawExtension: "arw", phase: "published-0")
    }

    func testManagedCameraRawPreparedReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, rawExtension: "arw", phase: "prepared")
    }

    func testManagedCameraRawFirstPublishedReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, rawExtension: "arw", phase: "published-0")
    }

    func testCanonRawPreparedReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, rawExtension: "cr3", phase: "prepared")
    }

    func testCanonRawFirstPublishedReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, rawExtension: "cr3", phase: "published-0")
    }

    func testManagedCanonRawPreparedReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, rawExtension: "cr3", phase: "prepared")
    }

    func testManagedCanonRawFirstPublishedReconcileAndRetryAcrossRelaunch() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, rawExtension: "cr3", phase: "published-0")
    }

    func testSyncNowRejectsInterruptedCameraRawAndResumesAfterRecovery() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, ordinarySyncRecovery: true)
    }

    func testManagedSyncNowRejectsInterruptedCameraRawAndResumesAfterRecovery() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, ordinarySyncRecovery: true)
    }

    func testSyncNowRejectsInterruptedCanonRawAndResumesAfterRecovery() throws {
        try verifyInterruptedImagePublication(managed: false, raw: true, rawExtension: "cr3", ordinarySyncRecovery: true)
    }

    func testManagedSyncNowRejectsInterruptedCanonRawAndResumesAfterRecovery() throws {
        try verifyInterruptedImagePublication(managed: true, raw: true, rawExtension: "cr3", ordinarySyncRecovery: true)
    }

    func testOrdinarySyncPublicationRetainsRecoveryAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: false)
    }

    func testManagedOrdinarySyncPublicationRetainsRecoveryAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: true)
    }

    func testOrdinaryCameraRawSyncRetainsPartialPairAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: false, rawExtension: "arw")
    }

    func testManagedOrdinaryCanonRawSyncRetainsPartialPairAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: true, rawExtension: "cr3")
    }

    func testManagedOrdinaryCameraRawSyncRetainsPartialPairAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: true, rawExtension: "arw")
    }

    func testOrdinaryCanonRawSyncRetainsPartialPairAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: false, rawExtension: "cr3")
    }

    func testManagedProcessedHandoffRetainsRecoveryAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: true, processedHandoff: true)
    }

    func testManagedCameraRawProcessedHandoffRetainsPartialPairAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: true, rawExtension: "arw", processedHandoff: true)
    }

    func testManagedCanonRawProcessedHandoffRetainsPartialPairAfterInterruption() throws {
        try verifyInterruptedOrdinarySync(managed: true, rawExtension: "cr3", processedHandoff: true)
    }

    private func verifyInterruptedOrdinarySync(managed: Bool, rawExtension: String? = nil, processedHandoff: Bool = false) throws {
        let raw = rawExtension != nil
        if raw && ProcessInfo.processInfo.environment["AAGEDAL_NATIVE_RAW_RECOVERY"] != "1" {
            throw XCTSkip("Stage authorized camera RAW in the DEBUG bundle and opt in")
        }
        launch(seedJob: true, recoveryFixture: true, managedRecovery: managed,
               imageRecovery: true, interruptPublication: true, rawRecovery: raw,
               rawExtension: rawExtension ?? "arw", interruptionPhase: "published-0",
               ordinarySyncInterruption: !processedHandoff, processedHandoffInterruption: processedHandoff)
        app.buttons["Sync Now"].click()
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.app.state == .notRunning }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 20), .completed)
        app.launchEnvironment.removeValue(forKey: "AAGEDAL_UI_TEST_INTERRUPT_PUBLICATION")
        app.launchEnvironment.removeValue(forKey: "AAGEDAL_UI_TEST_INTERRUPT_ORDINARY_SYNC")
        app.launchEnvironment.removeValue(forKey: "AAGEDAL_UI_TEST_INTERRUPT_PROCESSED_HANDOFF")
        app.launch()
        waitForJobsWindow(seedJob: true)
        app.buttons["Sync Now"].click()
        let failure = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "remains at ", "remains at "
        )).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        let message = failure.value as? String ?? failure.label
        let start = try XCTUnwrap(message.range(of: "remains at "))
        let end = try XCTUnwrap(message.range(of: ". Recover the retained files"))
        let recovery = URL(fileURLWithPath: String(message[start.upperBound..<end.lowerBound]))
        let destination = recovery.deletingLastPathComponent()
        let endpoint = managed ? destination.deletingLastPathComponent() : destination
        let root = endpoint.deletingLastPathComponent()
        guard root.lastPathComponent == app.launchEnvironment["AAGEDAL_UI_TEST_SESSION"],
              root.deletingLastPathComponent().lastPathComponent == "AagedalFTPSyncUITests",
              endpoint.lastPathComponent == "Destination",
              destination.lastPathComponent == (processedHandoff ? "Processed Files" : (managed ? "Synced Files" : "Destination")),
              recovery.lastPathComponent.hasPrefix(".aagedal-sync-"),
              recovery.pathExtension == "transaction" else {
            XCTFail("Refusing recovery outside the isolated fixture")
            return
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("native-image-interruption"), encoding: .utf8), "published-0")
        let manifestBytes = try Data(contentsOf: recovery.appendingPathComponent("recovery.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
        XCTAssertEqual((manifest["originals"] as? [[String: Any]])?.count, 0)
        let names = raw ? ["recovery." + rawExtension!, "recovery.xmp"] : ["recovery.jpg"]
        let outputs = try XCTUnwrap(manifest["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.compactMap { $0["relativePath"] as? String }, names)
        let sourceFiles = names.map { root.appendingPathComponent("Source/" + $0) }
        let sourceBytes = try sourceFiles.map { try Data(contentsOf: $0) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let published = destination.appendingPathComponent(names[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("output-stage-0").path))
        XCTAssertEqual(try Data(contentsOf: published), try Data(contentsOf: recovery.appendingPathComponent("output-copy-0")))
        if raw {
            XCTAssertEqual(try Data(contentsOf: published), sourceBytes[0])
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(names[1]).path))
            try assertRecoveryCity(recovery.appendingPathComponent("output-stage-1"), raw: true)
        } else {
            try assertRecoveryCity(published, raw: false)
        }
        let retained = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
        let syncedFiles = processedHandoff ? names.map { endpoint.appendingPathComponent("Synced Files/" + $0) } : []
        for (index, synced) in syncedFiles.enumerated() {
            XCTAssertEqual(try Data(contentsOf: synced), try Data(contentsOf: recovery.appendingPathComponent("output-copy-\(index)")))
            XCTAssertEqual(try synced.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        }
        let evidence = try (retained + [published] + sourceFiles + syncedFiles).map { url in
            (url, try Data(contentsOf: url), try FileManager.default.attributesOfItem(atPath: url.path))
        }
        let journals = ["metadata-audit-v1.json", "download-manifest-v1.json"].map { root.appendingPathComponent($0) }
        let journalBytes = journals.map { try? Data(contentsOf: $0) }
        let errors = root.appendingPathComponent("sync-errors-v1.json")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["Sync Now"].isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let priorErrors = try Data(contentsOf: errors)
        app.buttons["Sync Now"].click()
        let recorded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: errors)) != priorErrors && self.app.buttons["Sync Now"].isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [recorded], timeout: 10), .completed)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: recovery.path)), Set(retained.map(\.lastPathComponent)))
        for (url, bytes, attributes) in evidence {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
            XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
        }
        for (url, bytes) in zip(journals, journalBytes) { XCTAssertEqual(try? Data(contentsOf: url), bytes) }
        // Explicit test-assisted choice: preserve the partial publication and
        // entire transaction outside admission, then retry the intact source.
        app.terminate()
        let preserved = root.appendingPathComponent(processedHandoff ? "reconciled-processed-handoff" : "reconciled-ordinary-sync")
        app.launchEnvironment[processedHandoff ? "AAGEDAL_UI_TEST_RECONCILE_PROCESSED_HANDOFF" : "AAGEDAL_UI_TEST_RECONCILE_ORDINARY_SYNC"] = "1"
        app.launch()
        waitForJobsWindow(seedJob: true)
        for (url, bytes, attributes) in evidence where syncedFiles.contains(url) {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
            XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
        }
        app.buttons["Sync Now"].click()
        XCTAssertTrue(app.staticTexts["The latest sync completed."].waitForExistence(timeout: 15))
        let output = destination.appendingPathComponent(raw ? names[1] : names[0])
        try assertRecoveryCity(output, raw: raw)
        if raw { XCTAssertEqual(try Data(contentsOf: published), sourceBytes[0]) }
        for name in names {
            XCTAssertEqual(try destination.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        }
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("recovery.json")), manifestBytes)
        for (source, bytes) in zip(sourceFiles, sourceBytes) {
            if managed { XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)) }
            else { XCTAssertEqual(try Data(contentsOf: source), bytes) }
        }
        var publicationURLs = names.map { destination.appendingPathComponent($0) } + syncedFiles
        if managed && !processedHandoff {
            let processed = endpoint.appendingPathComponent("Processed Files")
            let processedMetadata = processed.appendingPathComponent(raw ? names[1] : names[0])
            try assertRecoveryCity(processedMetadata, raw: raw)
            if raw { XCTAssertEqual(try Data(contentsOf: processed.appendingPathComponent(names[0])), sourceBytes[0]) }
            for name in names {
                let url = processed.appendingPathComponent(name)
                XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
                publicationURLs.append(url)
            }
        }
        for (index, url) in syncedFiles.enumerated() {
            if raw && index == 0 { XCTAssertEqual(try Data(contentsOf: url), sourceBytes[0]) }
            else { try assertRecoveryCity(url, raw: raw) }
            XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        }
        let rescued = root.appendingPathComponent(processedHandoff ? "rescued-processed-publication" : "rescued-ordinary-publication")
        for (url, bytes, attributes) in evidence where url == published || retained.contains(url) {
            let moved = url == published ? rescued : preserved.appendingPathComponent(url.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: moved), bytes)
            let after = try FileManager.default.attributesOfItem(atPath: moved.path)
            XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
            XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
        }
        publicationURLs.append(rescued)
        publicationURLs += retained.map { preserved.appendingPathComponent($0.lastPathComponent) }
        let completed = try publicationURLs.map { url in
            (url, try Data(contentsOf: url), try FileManager.default.attributesOfItem(atPath: url.path))
        }
        app.terminate()
        app.launch()
        waitForJobsWindow(seedJob: true)
        app.buttons["Sync Now"].click()
        XCTAssertTrue(app.staticTexts["The latest sync completed."].waitForExistence(timeout: 15))
        openStatusMenu()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "0 files transferred", "0 files transferred"
        )).firstMatch.waitForExistence(timeout: 15))
        dismissStatusPanelIfNeeded()
        for (url, bytes, attributes) in completed {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
            XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
        }
    }

    private func verifyInterruptedImagePublication(managed: Bool, raw: Bool = false, rawExtension: String = "arw", phase: String = "beforeCommit", ordinarySyncRecovery: Bool = false) throws {
        if raw && ProcessInfo.processInfo.environment["AAGEDAL_NATIVE_RAW_RECOVERY"] != "1" {
            throw XCTSkip("Stage the authorized camera RAW in the DEBUG test bundle and set AAGEDAL_NATIVE_RAW_RECOVERY=1")
        }
        let published = phase == "beforeCommit" || phase == "published-0"
        let prepared = phase == "prepared"
        let filename = raw ? "recovery.xmp" : "recovery.jpg"
        launch(seedJob: true, recoveryFixture: true, managedRecovery: managed,
               imageRecovery: true, interruptPublication: true, rawRecovery: raw, rawExtension: rawExtension, interruptionPhase: phase)
        element("Metadata").firstMatch.click()
        element("reprocess-geocoding").click()
        let review = app.sheets.firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 8))
        let publish = review.buttons["Reprocess Saved Files"]
        XCTAssertTrue(publish.waitForExistence(timeout: 8))
        XCTAssertTrue(publish.isEnabled)
        publish.click()
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.app.state == .notRunning }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 15), .completed)

        app.launchEnvironment.removeValue(forKey: "AAGEDAL_UI_TEST_INTERRUPT_PUBLICATION")
        app.launch()
        waitForJobsWindow(seedJob: true)
        element("Metadata").firstMatch.click()
        element("reprocess-geocoding").click()
        let blocked = app.sheets.firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 8))
        let message = blocked.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "remains at ", "remains at "
        )).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 8))
        let text = message.value as? String ?? message.label
        let start = try XCTUnwrap(text.range(of: "remains at "))
        let end = try XCTUnwrap(text.range(of: ". Recover the retained files"))
        let recovery = URL(fileURLWithPath: String(text[start.upperBound..<end.lowerBound]))
        let destination = recovery.deletingLastPathComponent()
        let endpoint = managed ? destination.deletingLastPathComponent() : destination
        let root = endpoint.deletingLastPathComponent()
        XCTAssertEqual(root.lastPathComponent, app.launchEnvironment["AAGEDAL_UI_TEST_SESSION"])
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "AagedalFTPSyncUITests")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("native-image-interruption"), encoding: .utf8), phase)
        XCTAssertTrue(recovery.lastPathComponent.hasPrefix(".aagedal-sync-"))
        XCTAssertNotEqual(recovery.lastPathComponent, ".aagedal-sync-ui-fixture.transaction")
        let manifestBytes = try Data(contentsOf: recovery.appendingPathComponent("recovery.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any]
        let originals = try XCTUnwrap(manifest?["originals"] as? [[String: Any]])
        XCTAssertEqual(originals.count, raw ? 2 : 1)
        let original = originals[raw ? 1 : 0]
        XCTAssertEqual(original["relativePath"] as? String, "nested/" + filename)
        let heldPath = recovery.appendingPathComponent(try XCTUnwrap(original["heldFilename"] as? String))
        let held = prepared ? destination.appendingPathComponent("nested/" + filename) : heldPath
        XCTAssertEqual(FileManager.default.fileExists(atPath: heldPath.path), !prepared)
        let source = root.appendingPathComponent("Source/" + filename)
        XCTAssertEqual(try Data(contentsOf: held), try Data(contentsOf: source))
        let output = destination.appendingPathComponent("nested/" + filename)
        let publicationEvidence = published ? output : recovery.appendingPathComponent("output-stage-0")
        XCTAssertEqual(FileManager.default.fileExists(atPath: output.path), published || prepared)
        XCTAssertEqual(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("output-stage-0").path), !published)
        try assertRecoveryCity(publicationEvidence, raw: raw)
        let rawSource = root.appendingPathComponent("Source/recovery." + rawExtension)
        let rawOutput = destination.appendingPathComponent("nested/recovery." + rawExtension)
        let rawHeld = prepared ? rawOutput : recovery.appendingPathComponent("original-held-0")
        let rawBytes = raw ? try Data(contentsOf: rawSource) : nil
        if raw {
            XCTAssertEqual(FileManager.default.fileExists(atPath: rawOutput.path), prepared)
            XCTAssertEqual(try Data(contentsOf: rawHeld), rawBytes)
        }
        XCTAssertEqual(try publicationEvidence.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(blocked.buttons["Reprocess Saved Files"].exists)
        blocked.buttons["Cancel"].click()
        waitForSheetTransition()
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
        XCTAssertEqual(try Data(contentsOf: held), try Data(contentsOf: source))
        let publishedBytes = try Data(contentsOf: publicationEvidence)
        let originalBytes = try Data(contentsOf: source)
        let date = try publicationEvidence.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if ordinarySyncRecovery {
            // The crash occurred in reprocessing. Exercise ordinary run admission
            // against that real retained transaction before any listing can publish.
            let evidenceFiles = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
            let protectedFiles = evidenceFiles + [publicationEvidence, rawHeld, source, rawSource]
            let evidence = try protectedFiles.map { url in
                (url, try Data(contentsOf: url), try FileManager.default.attributesOfItem(atPath: url.path))
            }
            let journals = ["metadata-audit-v1.json", "download-manifest-v1.json"].map { root.appendingPathComponent($0) }
            let journalBytes = journals.map { try? Data(contentsOf: $0) }
            element("Server & Sync").firstMatch.click()
            for _ in 0..<2 {
                let sync = app.buttons["Sync Now"]
                XCTAssertTrue(sync.isEnabled)
                let failureJournal = root.appendingPathComponent("sync-errors-v1.json")
                let priorFailures = try? Data(contentsOf: failureJournal)
                sync.click()
                let recorded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (try? Data(contentsOf: failureJournal)) != priorFailures && sync.isEnabled
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [recorded], timeout: 8), .completed)
                let failure = app.staticTexts.matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@", recovery.path, recovery.path
                )).firstMatch
                XCTAssertTrue(failure.waitForExistence(timeout: 8))
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: recovery.path)),
                               Set(evidenceFiles.map(\.lastPathComponent)))
                for (url, bytes, attributes) in evidence {
                    XCTAssertEqual(try Data(contentsOf: url), bytes)
                    let after = try FileManager.default.attributesOfItem(atPath: url.path)
                    XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
                    XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
                }
                for (url, bytes) in zip(journals, journalBytes) { XCTAssertEqual(try? Data(contentsOf: url), bytes) }
                XCTAssertEqual(try Data(contentsOf: source), originalBytes)
                XCTAssertEqual(try Data(contentsOf: rawSource), rawBytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(filename).path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("recovery." + rawExtension).path))
                if managed {
                    for name in [filename, "recovery." + rawExtension] {
                        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.appendingPathComponent("Processed Files/" + name).path))
                    }
                }
            }
        }
        let preparedOriginals = prepared ? try (raw ? [rawOutput, output] : [output]).map { url in
            (url, try FileManager.default.attributesOfItem(atPath: url.path))
        } : []
        // Explicitly choose the retained original in this disposable sandbox.
        // The launch helper preserves both versions and the actual transaction.
        app.terminate()
        app.launchEnvironment["AAGEDAL_UI_TEST_RECONCILE_INTERRUPTED_IMAGE"] = "1"
        app.launch()
        waitForJobsWindow(seedJob: true)
        let preserved = root.appendingPathComponent("reconciled-image-recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        for (url, attributes) in preparedOriginals {
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
        }
        if !published {
            let retainedStage = preserved.appendingPathComponent("output-stage-0")
            XCTAssertEqual(try Data(contentsOf: retainedStage), publishedBytes)
            XCTAssertEqual(try retainedStage.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        }
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent(prepared ? "original-copy-\(raw ? 1 : 0)" : held.lastPathComponent)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("recovery.json")), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(raw ? "rescued-publication.xmp" : "rescued-publication.jpg")), publishedBytes)
        XCTAssertEqual(try Data(contentsOf: output), originalBytes)
        XCTAssertEqual(try output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)

        if raw {
            XCTAssertEqual(try Data(contentsOf: rawOutput), rawBytes)
            XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent(prepared ? "original-copy-0" : "original-held-0")), rawBytes)
        }
        element("Metadata").firstMatch.click()
        element("reprocess-geocoding").click()
        let retry = app.sheets.firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertTrue(retry.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Preflight checked 1 files", "Preflight checked 1 files"
        )).firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(try Data(contentsOf: output), originalBytes, "Recovery retry preflight must be read-only")
        XCTAssertTrue(retry.buttons["Reprocess Saved Files"].isEnabled)
        retry.buttons["Reprocess Saved Files"].click()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Reprocessed 1 of 1 files; 0 skipped, 0 failed", "Reprocessed 1 of 1 files; 0 skipped, 0 failed"
        )).firstMatch.waitForExistence(timeout: 15))
        try assertRecoveryCity(output, raw: raw)
        if raw {
            XCTAssertEqual(try Data(contentsOf: rawOutput), rawBytes)
            XCTAssertEqual(try rawOutput.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        }
        let retryBytes = try Data(contentsOf: output)
        XCTAssertNotEqual(retryBytes, originalBytes)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)

        app.terminate()
        app.launch()
        waitForJobsWindow(seedJob: true)
        element("Metadata").firstMatch.click()
        element("reprocess-geocoding").click()
        let repeated = app.sheets.firstMatch
        XCTAssertTrue(repeated.waitForExistence(timeout: 8))
        XCTAssertTrue(repeated.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Preflight checked 1 files", "Preflight checked 1 files"
        )).firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(repeated.buttons["Reprocess Saved Files"].isEnabled)
        repeated.buttons["Cancel"].click()
        if raw {
            XCTAssertEqual(try Data(contentsOf: rawOutput), rawBytes)
            XCTAssertEqual(try Data(contentsOf: rawSource), rawBytes)
        }
        XCTAssertEqual(try Data(contentsOf: output), retryBytes)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent(prepared ? "original-copy-\(raw ? 1 : 0)" : held.lastPathComponent)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(raw ? "rescued-publication.xmp" : "rescued-publication.jpg")), publishedBytes)
        if ordinarySyncRecovery {
            waitForSheetTransition()
            element("Server & Sync").firstMatch.click()
            app.buttons["Sync Now"].click()
            let completed = app.staticTexts["The latest sync completed."]
            XCTAssertTrue(completed.waitForExistence(timeout: 15))
            let syncedRaw = destination.appendingPathComponent("recovery." + rawExtension)
            let syncedXMP = destination.appendingPathComponent(filename)
            XCTAssertEqual(try Data(contentsOf: syncedRaw), rawBytes)
            try assertRecoveryCity(syncedXMP, raw: true)
            XCTAssertEqual(try syncedRaw.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
            XCTAssertEqual(try syncedXMP.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
            var publications = [syncedRaw, syncedXMP, rawOutput, output]
            if managed {
                let processed = endpoint.appendingPathComponent("Processed Files")
                let processedRaw = processed.appendingPathComponent("recovery." + rawExtension)
                let processedXMP = processed.appendingPathComponent(filename)
                XCTAssertEqual(try Data(contentsOf: processedRaw), rawBytes)
                try assertRecoveryCity(processedXMP, raw: true)
                for url in [processedRaw, processedXMP] {
                    XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
                }
                publications += [processedRaw, processedXMP]
                // This job explicitly moves successful outputs to Processed Files.
                XCTAssertFalse(FileManager.default.fileExists(atPath: rawSource.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: rawSource), rawBytes)
                XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            }
            let snapshots = try publications.map { url in
                (url, try Data(contentsOf: url), try FileManager.default.attributesOfItem(atPath: url.path))
            }
            app.terminate()
            app.launch()
            waitForJobsWindow(seedJob: true)
            app.buttons["Sync Now"].click()
            openStatusMenu()
            let idle = app.staticTexts.matching(NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "0 files transferred", "0 files transferred"
            )).firstMatch
            XCTAssertTrue(idle.waitForExistence(timeout: 15))
            dismissStatusPanelIfNeeded()
            for (url, bytes, attributes) in snapshots {
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                let after = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
                XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber,
                               "Idle ordinary sync must not republish an output")
            }
            XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("recovery.json")), manifestBytes)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("rescued-publication.xmp")), publishedBytes)
        }
    }

    private func assertRecoveryCity(_ output: URL, raw: Bool) throws {
        if raw {
            let xml = try XMLDocument(contentsOf: output)
            let city = try xml.nodes(forXPath: "//*[local-name()='City'] | //@*[local-name()='City']")
            XCTAssertEqual(city.first?.stringValue, "Recovery Venue")
            let description = try xml.nodes(forXPath: "//*[local-name()='description']//*[local-name()='li']")
            XCTAssertEqual(description.first?.stringValue, "Preserve camera sidecar — æøå")
            XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='subject']//*[local-name()='li']").map(\.stringValue),
                           ["Recovery keyword æøå", "Desk & camera"])
            XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='rights']//*[local-name()='li']").first?.stringValue,
                           "© Recovery fixture")
            XCTAssertEqual(try xml.nodes(forXPath: "//@*[local-name()='Rating']").first?.stringValue, "4")
            XCTAssertEqual(try xml.nodes(forXPath: "//@*[local-name()='Keep']").first?.stringValue, "Camera & desk")
        } else {
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
            let iptc = try XCTUnwrap(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
            XCTAssertEqual(iptc[kCGImagePropertyIPTCCity as String] as? String, "Recovery Venue")
        }
    }

    private func verifyRetainedMetadataRecovery(managed: Bool, images: Bool = false) throws {
        launch(seedJob: true, recoveryFixture: true, managedRecovery: managed, imageRecovery: images)
        element("Metadata").firstMatch.click()
        let reprocess = element("reprocess-geocoding")
        XCTAssertTrue(reprocess.waitForExistence(timeout: 5))
        XCTAssertTrue(reprocess.isEnabled)
        var recoveryURL: URL?
        for _ in 0..<2 {
            reprocess.click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8))
            let message = sheet.staticTexts.matching(NSPredicate(
                format: "(label CONTAINS %@ OR value CONTAINS %@)",
                ".aagedal-sync-ui-fixture.transaction", ".aagedal-sync-ui-fixture.transaction"
            )).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 8))
            let messageText = message.value as? String ?? message.label
            let pathStart = try XCTUnwrap(messageText.range(of: "remains at "))
            let pathEnd = try XCTUnwrap(messageText.range(of: ". Recover the retained files"))
            recoveryURL = URL(fileURLWithPath: String(messageText[pathStart.upperBound..<pathEnd.lowerBound]))
            XCTAssertFalse(sheet.buttons["Reprocess Saved Files"].exists)
            sheet.buttons["Cancel"].click()
            waitForSheetTransition()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            XCTAssertTrue(reprocess.isEnabled)
        }

        // Reconcile only this launch's disposable fixture, preserving both the
        // chosen visible output and the retained original outside the transaction.
        let recovery = try XCTUnwrap(recoveryURL)
        let destination = recovery.deletingLastPathComponent()
        let endpoint = managed ? destination.deletingLastPathComponent() : destination
        let root = endpoint.deletingLastPathComponent()
        let session = try XCTUnwrap(app.launchEnvironment["AAGEDAL_UI_TEST_SESSION"])
        guard root.lastPathComponent == session,
              root.deletingLastPathComponent().lastPathComponent == "AagedalFTPSyncUITests",
              endpoint.lastPathComponent == "Destination",
              destination.lastPathComponent == (managed ? "Synced Files" : "Destination"),
              recovery.lastPathComponent == ".aagedal-sync-ui-fixture.transaction" else {
            XCTFail("Refusing to reconcile a folder outside this isolated fixture")
            return
        }
        let manager = FileManager.default
        let original = recovery.appendingPathComponent("original-held-0")
        let visible = destination.appendingPathComponent("preserved.txt")
        let rescued = root.appendingPathComponent("rescued-original.txt")
        let originalBytes = try Data(contentsOf: original)
        XCTAssertEqual(originalBytes, Data("retained original fixture bytes".utf8))
        let reviewedBytes = Data("reviewed visible fixture bytes".utf8)
        let image = destination.appendingPathComponent("nested/recovery.jpg")
        let source = root.appendingPathComponent("Source/recovery.jpg")
        let imageBefore = images ? try Data(contentsOf: image) : nil
        let imageDate = images ? try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate : nil
        var imagePublished: Data?

        // The runner cannot write the app container. An explicit isolated launch
        // option performs fixture reconciliation inside its owning sandbox.
        app.terminate()
        app.launchEnvironment["AAGEDAL_UI_TEST_RECONCILE_RECOVERY"] = "1"
        app.launch()
        waitForJobsWindow(seedJob: true)

        for relaunch in [false, true] {
            if relaunch {
                app.terminate()
                app.launch()
                waitForJobsWindow(seedJob: true)
            }
            element("Metadata").firstMatch.click()
            element("reprocess-geocoding").click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8))
            let success = sheet.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                images ? "Preflight checked 1 files" : "Preflight checked 0 files",
                images ? "Preflight checked 1 files" : "Preflight checked 0 files"
            )).firstMatch
            XCTAssertTrue(success.waitForExistence(timeout: 8))
            if images && !relaunch {
                XCTAssertEqual(try Data(contentsOf: image), imageBefore, "Preflight must not publish")
                XCTAssertTrue(sheet.buttons["Reprocess Saved Files"].isEnabled)
                sheet.buttons["Reprocess Saved Files"].click()
                XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
                let completion = app.staticTexts.matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "Reprocessed 1 of 1 files; 0 skipped, 0 failed", "Reprocessed 1 of 1 files; 0 skipped, 0 failed"
                )).firstMatch
                XCTAssertTrue(completion.waitForExistence(timeout: 15))
                let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(image as CFURL, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
                let iptc = try XCTUnwrap(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
                XCTAssertEqual(iptc[kCGImagePropertyIPTCCity as String] as? String, "Recovery Venue")
                imagePublished = try Data(contentsOf: image)
                XCTAssertNotEqual(imagePublished, imageBefore)
            } else {
                XCTAssertFalse(sheet.buttons["Reprocess Saved Files"].isEnabled)
                sheet.buttons["Cancel"].click()
                waitForSheetTransition()
                XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            }
            if images {
                XCTAssertEqual(try Data(contentsOf: image), imagePublished)
                XCTAssertEqual(try Data(contentsOf: source), imageBefore)
                XCTAssertEqual(try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, imageDate)
            }
            XCTAssertFalse(manager.fileExists(atPath: recovery.path))
            XCTAssertEqual(try Data(contentsOf: rescued), originalBytes)
            XCTAssertEqual(try Data(contentsOf: visible), reviewedBytes)
        }
    }

    func testProgrammingRecoveryReviewShowsFailureForAllAndClipScopesThenRetries() {
        verifyProgrammingRecoveryReview(managed: false)
    }

    func testManagedProgrammingRecoveryReviewShowsFailureForAllAndClipScopesThenRetries() {
        verifyProgrammingRecoveryReview(managed: true)
    }

    func testProgrammingPublishesRecoveredImageAndPreservesItAcrossRelaunch() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false)
    }

    func testManagedProgrammingPublishesRecoveredImageAndPreservesItAcrossRelaunch() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true)
    }

    func testProgrammingPublishesMatchingClipImageAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: true)
    }

    func testManagedProgrammingPublishesMatchingClipImageAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: true)
    }

    func testProgrammingPublishesCameraRawAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: false, rawExtension: "arw")
    }

    func testProgrammingPublishesMatchingClipCameraRawAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: true, rawExtension: "arw")
    }

    func testManagedProgrammingPublishesCameraRawAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: false, rawExtension: "arw")
    }

    func testManagedProgrammingPublishesMatchingClipCameraRawAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: true, rawExtension: "arw")
    }

    func testProgrammingPublishesCanonRawAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: false, rawExtension: "cr3")
    }

    func testProgrammingPublishesMatchingClipCanonRawAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: true, rawExtension: "cr3")
    }

    func testManagedProgrammingPublishesCanonRawAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: false, rawExtension: "cr3")
    }

    func testManagedProgrammingPublishesMatchingClipCanonRawAfterRecovery() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: true, rawExtension: "cr3")
    }

    func testProgrammingRecoveryExcludesOtherClipCameraRaw() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: true, rawExtension: "arw", mixedClipBatch: true)
    }

    func testManagedProgrammingRecoveryExcludesOtherClipCameraRaw() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: true, rawExtension: "arw", mixedClipBatch: true)
    }

    func testProgrammingRecoveryExcludesOtherClipCanonRaw() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: true, rawExtension: "cr3", mixedClipBatch: true)
    }

    func testManagedProgrammingRecoveryExcludesOtherClipCanonRaw() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: true, rawExtension: "cr3", mixedClipBatch: true)
    }

    func testProgrammingRecoveryPreservesEditedCameraRawUntilReviewed() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: true, rawExtension: "arw", mixedClipBatch: true, editedOutputConflict: true)
    }

    func testManagedProgrammingRecoveryPreservesEditedCameraRawUntilReviewed() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: true, rawExtension: "arw", mixedClipBatch: true, editedOutputConflict: true)
    }

    func testProgrammingRecoveryPreservesEditedCanonRawUntilReviewed() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: false, matchingClip: true, rawExtension: "cr3", mixedClipBatch: true, editedOutputConflict: true)
    }

    func testManagedProgrammingRecoveryPreservesEditedCanonRawUntilReviewed() throws {
        try verifyProgrammingPublishesRecoveredImage(managed: true, matchingClip: true, rawExtension: "cr3", mixedClipBatch: true, editedOutputConflict: true)
    }

    private func verifyProgrammingPublishesRecoveredImage(managed: Bool, matchingClip: Bool = false, rawExtension: String? = nil, mixedClipBatch: Bool = false, editedOutputConflict: Bool = false) throws {
        let raw = rawExtension != nil
        if raw && ProcessInfo.processInfo.environment["AAGEDAL_NATIVE_RAW_RECOVERY"] != "1" {
            throw XCTSkip("Stage the authorized camera RAW in the DEBUG test bundle and set AAGEDAL_NATIVE_RAW_RECOVERY=1")
        }
        launch(seedJob: true, seedMap: true, recoveryFixture: true,
               managedRecovery: managed, imageRecovery: true, matchingClipImage: matchingClip, mixedClipRecovery: mixedClipBatch,
               rawRecovery: raw, rawExtension: rawExtension ?? "arw", editedRawConflict: editedOutputConflict)
        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        let window = app.windows["Metadata Programming"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.buttons["Reprocess Existing Files…"].click()
        let blocked = window.sheets.firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 5))
        let failure = blocked.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            ".aagedal-sync-ui-fixture.transaction", ".aagedal-sync-ui-fixture.transaction"
        )).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        let message = failure.value as? String ?? failure.label
        let pathStart = try XCTUnwrap(message.range(of: "remains at "))
        let pathEnd = try XCTUnwrap(message.range(of: ". Recover the retained files"))
        let recovery = URL(fileURLWithPath: String(message[pathStart.upperBound..<pathEnd.lowerBound]))
        let destination = recovery.deletingLastPathComponent()
        let endpoint = managed ? destination.deletingLastPathComponent() : destination
        let root = endpoint.deletingLastPathComponent()
        let session = try XCTUnwrap(app.launchEnvironment["AAGEDAL_UI_TEST_SESSION"])
        guard root.lastPathComponent == session,
              root.deletingLastPathComponent().lastPathComponent == "AagedalFTPSyncUITests",
              endpoint.lastPathComponent == "Destination",
              destination.lastPathComponent == (managed ? "Synced Files" : "Destination"),
              recovery.lastPathComponent == ".aagedal-sync-ui-fixture.transaction" else {
            XCTFail("Refusing to inspect an image outside this isolated fixture")
            return
        }
        let basename = matchingClip ? "MAP_recovery" : "recovery"
        let filename = basename + (raw ? ".xmp" : ".jpg")
        let image = destination.appendingPathComponent("nested/\(filename)")
        let source = root.appendingPathComponent("Source/\(filename)")
        let rawOutput = destination.appendingPathComponent("nested/" + basename + "." + (rawExtension ?? "arw"))
        let rawSource = root.appendingPathComponent("Source/" + basename + "." + (rawExtension ?? "arw"))
        let rawBytes = raw ? try Data(contentsOf: rawSource) : nil
        let rawDate = raw ? try XCTUnwrap(rawOutput.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) : nil
        func assertRawUnchanged() throws {
            guard raw else { return }
            XCTAssertEqual(try Data(contentsOf: rawOutput), rawBytes)
            XCTAssertEqual(try Data(contentsOf: rawSource), rawBytes)
            XCTAssertEqual(try rawOutput.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, rawDate)
            XCTAssertEqual(try rawSource.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, rawDate)
        }
        let excludedFiles = mixedClipBatch ? [destination.appendingPathComponent("nested"), root.appendingPathComponent("Source")]
            .flatMap { folder in [rawExtension ?? "arw", "xmp"].map { folder.appendingPathComponent("MAP_other." + $0) } } : []
        let excludedSnapshots = try excludedFiles.map { file in
            (file, try Data(contentsOf: file), try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
        func assertOtherClipUnchanged() throws {
            for (file, bytes, date) in excludedSnapshots {
                XCTAssertEqual(try Data(contentsOf: file), bytes, "Other clip must remain untouched: \(file.lastPathComponent)")
                XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
            }
        }
        try assertRawUnchanged()
        try assertOtherClipUnchanged()
        let manifestBytes = try Data(contentsOf: recovery.appendingPathComponent("recovery.json"))
        let before = try Data(contentsOf: image)
        let modified = try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(try Data(contentsOf: source), before)
        let otherDate = Calendar.current.startOfDay(for: Date()).addingTimeInterval(11 * 60 * 60 + 30 * 60)
        for (file, bytes, date) in excludedSnapshots {
            // Both fixture pairs start with the same bytes. Check against that
            // known source as well as snapshots taken after blocked admission.
            XCTAssertEqual(bytes, file.pathExtension == "xmp" ? before : rawBytes)
            XCTAssertEqual(date, otherDate)
        }
        XCTAssertFalse(blocked.buttons["Reprocess Files"].exists)
        blocked.buttons["Cancel"].click()
        waitForSheetTransition()
        XCTAssertTrue(blocked.waitForNonExistence(timeout: 5))
        try assertRawUnchanged()
        try assertOtherClipUnchanged()
        XCTAssertEqual(try Data(contentsOf: image), before)

        // The same real image must remain protected when recovery admission is
        // reached through a clip's scoped action, not only the full-batch button.
        let clip = element("metadata-programming-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        clip.rightClick()
        let clipAction = app.menuItems["Reprocess This Clip’s Files…"]
        XCTAssertTrue(clipAction.waitForExistence(timeout: 3))
        clipAction.click()
        let scopedBlocked = window.sheets.firstMatch
        XCTAssertTrue(scopedBlocked.waitForExistence(timeout: 5))
        let scopedFailure = scopedBlocked.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            recovery.path, recovery.path
        )).firstMatch
        XCTAssertTrue(scopedFailure.waitForExistence(timeout: 8))
        XCTAssertFalse(scopedBlocked.buttons["Reprocess Clip’s Files"].exists)
        scopedBlocked.buttons["Cancel"].click()
        waitForSheetTransition()
        XCTAssertTrue(scopedBlocked.waitForNonExistence(timeout: 5))
        try assertRawUnchanged()
        try assertOtherClipUnchanged()
        XCTAssertEqual(try Data(contentsOf: image), before)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))

        app.terminate()
        app.launchEnvironment["AAGEDAL_UI_TEST_RECONCILE_RECOVERY"] = "1"
        app.launch()
        waitForJobsWindow(seedJob: true)
        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        if matchingClip {
            let clip = element("metadata-programming-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
            XCTAssertTrue(clip.waitForExistence(timeout: 5))
            clip.rightClick()
            let action = app.menuItems["Reprocess This Clip’s Files…"]
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            action.click()
        } else {
            window.buttons["Reprocess Existing Files…"].click()
        }
        let review = window.sheets.firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let ready = review.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Preflight checked 1 files: 1 ready to update",
            "Preflight checked 1 files: 1 ready to update"
        )).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 8))
        try assertRawUnchanged()
        try assertOtherClipUnchanged()
        XCTAssertEqual(try Data(contentsOf: image), before, "Review must not publish")
        let publish = review.buttons[matchingClip ? "Reprocess Clip’s Files" : "Reprocess Files"]
        XCTAssertTrue(publish.isEnabled)
        publish.click()
        XCTAssertTrue(review.waitForNonExistence(timeout: 5))
        let completion = window.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Reprocessed 1 of 1 files; 0 skipped, 0 failed",
            "Reprocessed 1 of 1 files; 0 skipped, 0 failed"
        )).firstMatch
        XCTAssertTrue(completion.waitForExistence(timeout: 15))
        if raw {
            // Existing XMP GPS wins under fill-empty, including a scheduled clip.
            try assertRecoveryCity(image, raw: true)
            let coordinates = try XMLDocument(contentsOf: image)
            for (field, expected) in [("GPSLatitude", "59,30N"), ("GPSLongitude", "10,15E")] {
                XCTAssertEqual(try coordinates.nodes(forXPath: "//*[local-name()='\(field)'] | //@*[local-name()='\(field)']").first?.stringValue, expected)
            }
            if matchingClip {
                let xml = try XMLDocument(contentsOf: image)
                XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='Headline'] | //@*[local-name()='Headline']").first?.stringValue,
                               "Scoped capture")
            }
        } else {
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(image as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
            let iptc = try XCTUnwrap(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
            XCTAssertEqual(iptc[kCGImagePropertyIPTCCity as String] as? String,
                           matchingClip ? "Oslo" : "Recovery Venue")
            if matchingClip {
                XCTAssertEqual(iptc[kCGImagePropertyIPTCHeadline as String] as? String, "Scoped capture")
            }
        }
        try assertRawUnchanged()
        try assertOtherClipUnchanged()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("reconciled-recovery/recovery.json")), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("rescued-original.txt")), Data("retained original fixture bytes".utf8))
        let published = try Data(contentsOf: image)
        XCTAssertNotEqual(published, before)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)

        app.terminate()
        app.launch()
        waitForJobsWindow(seedJob: true)
        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        if mixedClipBatch {
            let clip = element("metadata-programming-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
            XCTAssertTrue(clip.waitForExistence(timeout: 5))
            clip.rightClick()
            let action = app.menuItems["Reprocess This Clip’s Files…"]
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            action.click()
        } else {
            window.buttons["Reprocess Existing Files…"].click()
        }
        let repeatReview = window.sheets.firstMatch
        XCTAssertTrue(repeatReview.waitForExistence(timeout: 5))
        let noReady = repeatReview.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Preflight checked 1 files: 0 ready to update",
            "Preflight checked 1 files: 0 ready to update"
        )).firstMatch
        XCTAssertTrue(noReady.waitForExistence(timeout: 8))
        XCTAssertFalse(repeatReview.buttons[mixedClipBatch ? "Reprocess Clip’s Files" : "Reprocess Files"].isEnabled)
        try assertRawUnchanged()
        try assertOtherClipUnchanged()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("reconciled-recovery/recovery.json")), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: image), published)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        repeatReview.buttons["Cancel"].click()
        if mixedClipBatch {
            waitForSheetTransition()
            XCTAssertTrue(repeatReview.waitForNonExistence(timeout: 5))
            window.buttons["Reprocess Existing Files…"].click()
            let allReview = window.sheets.firstMatch
            XCTAssertTrue(allReview.waitForExistence(timeout: 5))
            let otherReady = allReview.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Preflight checked 2 files: 1 ready to update",
                "Preflight checked 2 files: 1 ready to update"
            )).firstMatch
            XCTAssertTrue(otherReady.waitForExistence(timeout: 8), "Full scope must still offer the other clip")
            XCTAssertTrue(allReview.buttons["Reprocess Files"].isEnabled)
            try assertOtherClipUnchanged()
            XCTAssertEqual(try Data(contentsOf: image), published)
            allReview.buttons["Cancel"].click()
            waitForSheetTransition()
            XCTAssertTrue(allReview.waitForNonExistence(timeout: 5))
            try assertOtherClipUnchanged()
        }
        if editedOutputConflict {
            // The DEBUG app performs the edits inside its own isolated sandbox.
            // The runner independently reads and validates the resulting bytes.
            func assertPreserved(_ bytes: Data) throws {
                XCTAssertEqual(try Data(contentsOf: image), bytes)
                XCTAssertEqual(try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
                XCTAssertEqual(try Data(contentsOf: source), before)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("rescued-original.txt")), Data("retained original fixture bytes".utf8))
                try assertRawUnchanged()
                try assertOtherClipUnchanged()
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("reconciled-recovery/recovery.json")), manifestBytes)
            }
            func openClipReview() -> XCUIElement {
                let clip = element("metadata-programming-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
                XCTAssertTrue(clip.waitForExistence(timeout: 5))
                clip.rightClick()
                let action = app.menuItems["Reprocess This Clip’s Files…"]
                XCTAssertTrue(action.waitForExistence(timeout: 3))
                action.click()
                let sheet = window.sheets.firstMatch
                XCTAssertTrue(sheet.waitForExistence(timeout: 5))
                return sheet
            }
            func openConflictReview() -> XCUIElement {
                let sheet = openClipReview()
                XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "Preflight checked 1 files: 0 ready to update",
                    "Preflight checked 1 files: 0 ready to update"
                )).firstMatch.waitForExistence(timeout: 8))
                XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "1 edited output was found", "1 edited output was found"
                )).firstMatch.exists)
                XCTAssertFalse(sheet.buttons["Reprocess Clip’s Files"].isEnabled)
                XCTAssertTrue(sheet.buttons["Reprocess 1 Edited Output"].isEnabled)
                return sheet
            }
            let editReview = openClipReview()
            XCTAssertTrue(editReview.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Preflight checked 1 files: 0 ready to update",
                "Preflight checked 1 files: 0 ready to update"
            )).firstMatch.waitForExistence(timeout: 8))
            editReview.buttons["Fixture Edit A"].click()
            let reviewedBytes = try Data(contentsOf: image)
            let editedXML = try XMLDocument(contentsOf: image)
            XCTAssertEqual(try editedXML.nodes(forXPath: "//*[local-name()='Headline'] | //@*[local-name()='Headline']").first?.stringValue, "")
            let reviewedText = try XCTUnwrap(String(data: reviewedBytes, encoding: .utf8))
            XCTAssertTrue(reviewedText.contains("<!-- local edit A -->"))
            let laterBytes = Data(reviewedText.replacingOccurrences(of: "<!-- local edit A -->", with: "<!-- local edit B -->").utf8)
            XCTAssertEqual(reviewedBytes.count, laterBytes.count)
            XCTAssertNotEqual(reviewedBytes, laterBytes)
            editReview.buttons["Cancel"].click()
            waitForSheetTransition()
            XCTAssertTrue(editReview.waitForNonExistence(timeout: 5))
            let cancelled = openConflictReview()
            try assertPreserved(reviewedBytes)
            cancelled.buttons["Cancel"].click()
            waitForSheetTransition()
            XCTAssertTrue(cancelled.waitForNonExistence(timeout: 5))
            try assertPreserved(reviewedBytes)

            let staleReview = openConflictReview()
            try assertPreserved(reviewedBytes)
            staleReview.buttons["Fixture Edit B"].click()
            try assertPreserved(laterBytes)
            staleReview.buttons["Reprocess 1 Edited Output"].click()
            XCTAssertTrue(staleReview.waitForNonExistence(timeout: 5))
            XCTAssertTrue(window.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Reprocessed 0 of 1 files; 1 skipped, 0 failed",
                "Reprocessed 0 of 1 files; 1 skipped, 0 failed"
            )).firstMatch.waitForExistence(timeout: 15))
            try assertPreserved(laterBytes)

            let freshReview = openConflictReview()
            try assertPreserved(laterBytes)
            freshReview.buttons["Reprocess 1 Edited Output"].click()
            XCTAssertTrue(freshReview.waitForNonExistence(timeout: 5))
            XCTAssertTrue(completion.waitForExistence(timeout: 15))
            try assertRecoveryCity(image, raw: true)
            let reapplied = try XMLDocument(contentsOf: image)
            XCTAssertEqual(try reapplied.nodes(forXPath: "//*[local-name()='Headline'] | //@*[local-name()='Headline']").first?.stringValue, "Scoped capture")
            for (field, expected) in [("GPSLatitude", "59,30N"), ("GPSLongitude", "10,15E")] {
                XCTAssertEqual(try reapplied.nodes(forXPath: "//*[local-name()='\(field)'] | //@*[local-name()='\(field)']").first?.stringValue, expected)
            }
            let approved = try Data(contentsOf: image)
            XCTAssertNotEqual(approved, laterBytes)
            try assertPreserved(approved)

            app.terminate()
            app.launch()
            waitForJobsWindow(seedJob: true)
            element("Metadata").firstMatch.click()
            element("open-metadata-programming").click()
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            let clip = element("metadata-programming-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
            XCTAssertTrue(clip.waitForExistence(timeout: 5))
            clip.rightClick()
            let action = app.menuItems["Reprocess This Clip’s Files…"]
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            action.click()
            let finalReview = window.sheets.firstMatch
            XCTAssertTrue(finalReview.waitForExistence(timeout: 5))
            XCTAssertTrue(finalReview.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Preflight checked 1 files: 0 ready to update",
                "Preflight checked 1 files: 0 ready to update"
            )).firstMatch.waitForExistence(timeout: 8))
            XCTAssertFalse(finalReview.buttons["Reprocess Clip’s Files"].isEnabled)
            XCTAssertFalse(finalReview.buttons["Reprocess 1 Edited Output"].exists)
            try assertPreserved(approved)
            finalReview.buttons["Cancel"].click()
            waitForSheetTransition()
            XCTAssertTrue(finalReview.waitForNonExistence(timeout: 5))
            try assertPreserved(approved)
        }
    }

    private func verifyProgrammingRecoveryReview(managed: Bool) {
        launch(seedJob: true, seedMap: true, recoveryFixture: true, managedRecovery: managed)
        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        let window = app.windows["Metadata Programming"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        for scoped in [false, true] {
            if scoped {
                let clip = element("metadata-programming-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
                XCTAssertTrue(clip.waitForExistence(timeout: 5))
                clip.rightClick()
                let action = app.menuItems["Reprocess This Clip’s Files…"]
                XCTAssertTrue(action.waitForExistence(timeout: 3))
                XCTAssertTrue(action.isEnabled)
                action.click()
            } else {
                window.buttons["Reprocess Existing Files…"].click()
            }
            let sheet = window.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            let failure = sheet.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Recover the retained files", "Recover the retained files"
            )).firstMatch
            XCTAssertTrue(failure.waitForExistence(timeout: 8))
            XCTAssertFalse(sheet.buttons["Checking Files…"].exists)
            XCTAssertFalse(sheet.buttons["Reprocess Files"].exists)
            XCTAssertFalse(sheet.buttons["Reprocess Clip’s Files"].exists)
            sheet.buttons["Cancel"].click()
            waitForSheetTransition()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        }
        app.terminate()
        app.launchEnvironment["AAGEDAL_UI_TEST_RECONCILE_RECOVERY"] = "1"
        app.launch()
        waitForJobsWindow(seedJob: true)
        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.buttons["Reprocess Existing Files…"].click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let success = sheet.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Preflight checked 0 files", "Preflight checked 0 files"
        )).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 8))
        XCTAssertFalse(sheet.buttons["Reprocess Files"].isEnabled)
        sheet.buttons["Cancel"].click()
        waitForSheetTransition()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    func testCreatesJobFromDraft() {
        launch()

        element("add-sync-job-empty-state").click()
        XCTAssertTrue(app.staticTexts["Unsaved draft"].waitForExistence(timeout: 3))

        replaceText(in: element("job-name"), with: "Created in UI smoke test")
        element("save-job").click()

        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Created in UI smoke test"].exists)
        XCTAssertFalse(app.staticTexts["Unsaved draft"].exists)
    }

    func testCancellingNewJobSelectionKeepsDraftAndAllowsSelectingSameRowAgain() {
        launch(seedJob: true)
        element("add-sync-job").click()
        replaceText(in: element("job-name"), with: "Keep this unsaved job")
        app.staticTexts["UI Smoke Fixture"].click()
        let review = app.windows["jobs"].sheets.firstMatch
        XCTAssertTrue(review.buttons["Cancel"].waitForExistence(timeout: 3))
        review.buttons["Cancel"].click()
        XCTAssertEqual(element("job-name").value as? String, "Keep this unsaved job")
        XCTAssertTrue(app.staticTexts["Unsaved draft"].exists)

        app.staticTexts["UI Smoke Fixture"].click()
        let discard = review.buttons["Discard Draft"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.click()
        XCTAssertEqual(element("job-name").value as? String, "UI Smoke Fixture")
        XCTAssertFalse(app.staticTexts["Unsaved draft"].exists)
        XCTAssertFalse(app.staticTexts["Keep this unsaved job"].exists)
    }

    func testCancellingSavedJobSelectionKeepsEditsAndAllowsSavingBeforeSwitch() {
        launch(seedJob: true)
        element("add-sync-job").click()
        replaceText(in: element("job-name"), with: "Second saved job")
        element("save-job").click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
        replaceText(in: element("job-name"), with: "Second job with edits")
        app.staticTexts["UI Smoke Fixture"].click()
        let review = app.windows["jobs"].sheets.firstMatch
        XCTAssertTrue(review.buttons["Cancel"].waitForExistence(timeout: 3))
        review.buttons["Cancel"].click()
        XCTAssertEqual(element("job-name").value as? String, "Second job with edits")

        app.staticTexts["UI Smoke Fixture"].click()
        let save = review.buttons["Save Changes"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.click()
        XCTAssertEqual(element("job-name").value as? String, "UI Smoke Fixture")
        app.staticTexts["Second job with edits"].click()
        XCTAssertEqual(element("job-name").value as? String, "Second job with edits")
    }

    func testEditsSavedJob() {
        launch(seedJob: true)

        let nameField = element("job-name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        replaceText(in: nameField, with: "Edited in UI smoke test")
        element("save-job").click()

        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Edited in UI smoke test"].exists)
    }

    func testLocationSetupHasDirectActionsAndReturnsToUnsavedDraft() {
        launch(seedJob: true)
        let nameField = element("job-name")
        replaceText(in: nameField, with: "Location setup draft")
        let editSource = app.buttons["Source: Edit Location"]
        XCTAssertTrue(editSource.waitForExistence(timeout: 3))
        XCTAssertTrue(editSource.isHittable)
        editSource.click()
        XCTAssertTrue(app.staticTexts["Source Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Choose…"].exists)
        let sheetScreenshot = XCTAttachment(screenshot: app.screenshot())
        sheetScreenshot.name = "Source location settings"
        sheetScreenshot.lifetime = .keepAlways
        add(sheetScreenshot)
        app.buttons["Done"].click()
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        XCTAssertEqual(nameField.value as? String, "Location setup draft")
        XCTAssertTrue(app.buttons["Destination: Edit Location"].isHittable)
        let mainScreenshot = XCTAttachment(screenshot: app.screenshot())
        mainScreenshot.name = "Job setup with direct location actions"
        mainScreenshot.lifetime = .keepAlways
        add(mainScreenshot)
    }

    func testMenuBarStopUpdatesOpenSettingsAndSaveKeepsJobPaused() {
        launch(seedJob: true)
        openStatusMenu()
        app.buttons["Start"].click()
        dismissStatusPanelIfNeeded()
        let automatic = element("automatic-sync-enabled")
        XCTAssertTrue(automatic.waitForExistence(timeout: 3))
        XCTAssertEqual(String(describing: automatic.value ?? ""), "1")
        replaceText(in: element("job-name"), with: "Keep stopped after save")
        openStatusMenu()
        app.buttons["Stop"].click()
        dismissStatusPanelIfNeeded()
        XCTAssertEqual(String(describing: automatic.value ?? ""), "0")
        XCTAssertEqual(element("job-name").value as? String, "Keep stopped after save")
        element("save-job").click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
        openStatusMenu()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Stop"].exists)
    }

    func testProgrammedFilenameFilterCanBeSavedForServerDownload() {
        launchVersion3(session: UUID().uuidString, fixture: "populated",
                       expectsStartupWindow: false, seedRemoteJob: true)
        XCTAssertFalse(app.windows["Startup and Recovery"].waitForExistence(timeout: 2))
        let jobsWindow = app.windows["jobs"]
        if !jobsWindow.waitForExistence(timeout: 5) {
            openStatusMenu()
            element("open-jobs-window").click()
        }
        XCTAssertTrue(element("job-name").waitForExistence(timeout: 8))
        let fileTab = app.radioButtons["File Filtering & Deletion"]
        XCTAssertTrue(fileTab.waitForExistence(timeout: 5))
        fileTab.click()
        let toggle = element("use-metadata-programming-filter")
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertFalse(element("metadata-programming-filter-explanation").exists)
        toggle.click()
        XCTAssertTrue(element("metadata-programming-filter-explanation").waitForExistence(timeout: 3))
        element("save-job").click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
    }

    func testRecoversAfterVisibleSaveFailure() {
        launch(failFirstJobSave: true)

        element("add-sync-job-empty-state").click()
        replaceText(in: element("job-name"), with: "Recovered job")
        element("save-job").click()

        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["The UI smoke test intentionally blocked this save. Try saving again."].exists)
        alert.buttons["OK"].click()

        XCTAssertTrue(app.staticTexts["Unsaved draft"].exists)
        element("save-job").click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Unsaved draft"].exists)
    }

    func testExportsAndImportsConfigurationPackage() {
        launch(seedJob: true)

        openConfigurationMenu()
        let exportJobs = app.menuItems["Export Sync Jobs…"]
        XCTAssertTrue(exportJobs.waitForExistence(timeout: 5))
        exportJobs.click()
        XCTAssertTrue(app.staticTexts["Export Sync Jobs"].waitForExistence(timeout: 3))
        element("encrypt-configuration").click()
        element("configuration-transfer-submit").click()

        openConfigurationMenu()
        let importPackage = app.menuItems["Import Configuration Package…"]
        XCTAssertTrue(importPackage.waitForExistence(timeout: 5))
        importPackage.click()
        XCTAssertTrue(app.staticTexts["Import Unencrypted Package"].waitForExistence(timeout: 3))
        element("configuration-transfer-submit").click()

        XCTAssertTrue(app.staticTexts["UI Smoke Fixture (Imported)"].waitForExistence(timeout: 5))
    }

    func testMetadataProgrammingMakesImportDiscoverable() {
        launch(seedJob: true)

        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(element("import-metadata-programming").waitForExistence(timeout: 3))

        let jobRow = metadataWindow.staticTexts["UI Smoke Fixture"].firstMatch
        XCTAssertTrue(jobRow.waitForExistence(timeout: 3))
        jobRow.rightClick()
        XCTAssertTrue(app.menuItems["Import Metadata Programming…"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testTimelineKeyboardNavigationOpensClipMetadata() {
        launch(seedJob: true, seedMap: true)

        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        let clip = element("metadata-programming-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
        XCTAssertTrue(clip.waitForExistence(timeout: 3))
        clip.click()

        // Selection provides the starting time; the arrow creates/moves the
        // playhead before Command-I is sent through the same focused timeline.
        let timeline = element("metadata-programming-timeline")
        timeline.typeKey(.rightArrow, modifierFlags: [])
        timeline.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(element("metadata-clip-editor").waitForExistence(timeout: 5))
    }

    func testVariableDraftRejectsInvalidActivationAndCancelKeepsLiteralHeadline() {
        openSeededClipEditor()
        let headline = app.textFields["Headline"].firstMatch
        let original = headline.value as? String
        app.buttons["Edit Headline variables"].click()
        let source = app.textViews["Headline source draft"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        replaceText(in: source, with: "{unknown}")
        app.checkBoxes["Resolve Variables"].click()
        XCTAssertFalse(app.buttons["Apply"].firstMatch.isEnabled)
        replaceText(in: source, with: "{photographer}")
        XCTAssertTrue(app.buttons["Apply"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        waitForSheetTransition()
        XCTAssertTrue(headline.waitForExistence(timeout: 3))
        XCTAssertEqual(headline.value as? String, original)
    }

    func testVariableApplyRetainsSourceAndKeywordsCancelKeepsList() {
        openSeededClipEditor()
        app.buttons["Edit Headline variables"].click()
        let source = app.textViews["Headline source draft"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        replaceText(in: source, with: "Photo: {photographer}")
        app.checkBoxes["Resolve Variables"].click()
        app.buttons["Apply"].firstMatch.click()
        waitForSheetTransition()
        let editHeadline = app.buttons["Edit Headline variables"].firstMatch
        XCTAssertTrue(editHeadline.waitForExistence(timeout: 3))
        XCTAssertTrue(editHeadline.isHittable)
        editHeadline.click()
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        XCTAssertEqual(source.value as? String, "Photo: {photographer}")
        XCTAssertEqual(String(describing: app.checkBoxes["Resolve Variables"].value ?? ""), "1")
        app.typeKey(.escape, modifierFlags: [])

        app.buttons["Edit Keywords…"].click()
        XCTAssertTrue(element("metadata-keywords-editor").waitForExistence(timeout: 3))
        let before = app.textFields.matching(identifier: "Keyword").count
        app.buttons["Add Keyword"].click()
        XCTAssertEqual(app.textFields.matching(identifier: "Keyword").count, before + 1)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["Edit Keywords…"].click()
        XCTAssertTrue(element("metadata-keywords-editor").waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields.matching(identifier: "Keyword").count, before)
    }

    func testPeopleLibrarySettingsShowsBundledModelAndLibraryAdmission() {
        launch(seedJob: true)

        element("Metadata").firstMatch.click()
        let openSettings = element("open-people-library-settings")
        XCTAssertTrue(openSettings.waitForExistence(timeout: 3))
        XCTAssertTrue(openSettings.isEnabled)
        openSettings.click()

        XCTAssertTrue(element("peopleLibrary.summary").waitForExistence(timeout: 5))
        let modelStatus = element("faceModel.status")
        XCTAssertTrue(modelStatus.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["AuraFace model included with the app"].exists)
        XCTAssertTrue(app.staticTexts["Recognition is not ready. Select a compatible People Library and relaunch to validate the model and library."].exists)
    }

    private func openSeededClipEditor() {
        launch(seedJob: true, seedMap: true)
        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        let window = app.windows["Metadata Programming"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let clip = element("metadata-programming-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
        XCTAssertTrue(clip.waitForExistence(timeout: 3))
        clip.click()
        let timeline = element("metadata-programming-timeline")
        timeline.typeKey(.rightArrow, modifierFlags: [])
        timeline.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(element("metadata-clip-editor").waitForExistence(timeout: 5))
    }

    func testPhotographerMapClipScrubbingAndEditing() {
        launch(seedJob: true, seedMap: true)

        openStatusMenu()
        let openMetadata = element("open-metadata-window")
        XCTAssertTrue(openMetadata.waitForExistence(timeout: 5))
        openMetadata.click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        dismissStatusPanelIfNeeded()
        element("open-photographer-map").click()

        let mapWindow = app.windows["Photographer Map"]
        XCTAssertTrue(mapWindow.waitForExistence(timeout: 5))
        let clip = element("photographer-map-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
        XCTAssertTrue(clip.waitForExistence(timeout: 5))

        let selectedTime = element("photographer-map-selected-time")
        clip.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        let earlierTime = selectedTime.value as? String
        clip.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        XCTAssertNotNil(earlierTime)
        XCTAssertNotEqual(selectedTime.value as? String, earlierTime)
        XCTAssertEqual(clip.value as? String, "location set")

        clip.doubleClick()
        XCTAssertTrue(element("metadata-clip-editor").waitForExistence(timeout: 5))
    }

    func testPhotographerMapTimelineSupportsKeyboardAdjustment() {
        launch(seedJob: true, seedMap: true)

        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        element("open-photographer-map").click()

        let mapWindow = app.windows["Photographer Map"]
        XCTAssertTrue(mapWindow.waitForExistence(timeout: 5))
        let timeline = element("photographer-map-timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let selectedTime = element("photographer-map-selected-time")
        XCTAssertTrue(selectedTime.waitForExistence(timeout: 3))

        timeline.click()
        let initialTime = selectedTime.value as? String
        timeline.typeKey(.rightArrow, modifierFlags: [])

        XCTAssertNotEqual(selectedTime.value as? String, initialTime)
    }

    func testPhotographerMapTimelineRepeatedScrubbingKeepsWindowResponsive() {
        launch(seedJob: true, seedMap: true)

        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        element("open-photographer-map").click()

        let mapWindow = app.windows["Photographer Map"]
        XCTAssertTrue(mapWindow.waitForExistence(timeout: 5))
        let timeline = element("photographer-map-timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        let morning = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.5))
        let afternoon = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.5))
        for _ in 0..<4 {
            morning.press(forDuration: 0.05, thenDragTo: afternoon)
            afternoon.press(forDuration: 0.05, thenDragTo: morning)
        }

        let today = mapWindow.buttons["Today"]
        XCTAssertTrue(today.waitForExistence(timeout: 2))
        XCTAssertTrue(today.isHittable)
        today.click()
        XCTAssertTrue(element("photographer-map-selected-time").isHittable)
    }

    func testAccessibilityTextSizeKeepsCoreControlsOperable() {
        launch(seedJob: true, seedMap: true, accessibilityText: true)

        XCTAssertTrue(element("job-name").isHittable)
        XCTAssertTrue(element("save-job").exists)

        element("Metadata").firstMatch.click()
        element("open-metadata-programming").click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        element("open-photographer-map").click()

        let mapWindow = app.windows["Photographer Map"]
        XCTAssertTrue(mapWindow.waitForExistence(timeout: 5))
        let timeline = element("photographer-map-timeline")
        let clip = element("photographer-map-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(timeline.frame.height, 44)
        XCTAssertLessThan(timeline.frame.height, mapWindow.frame.height * 0.15)
        XCTAssertTrue(mapWindow.frame.intersects(timeline.frame))
        XCTAssertTrue(mapWindow.frame.intersects(clip.frame))
    }

    func testVersion3StartupMigratesPopulatedStorePausedAndReopensIt() {
        let session = UUID().uuidString
        launchVersion3(session: session, fixture: "populated", expectsStartupWindow: false)

        XCTAssertFalse(app.windows["Startup and Recovery"].waitForExistence(timeout: 2))
        XCTAssertFalse(element("startup.source.jobs-v2.json").exists)
        openStatusMenu()
        XCTAssertTrue(app.staticTexts["Migrated 2.9 UI Fixture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start"].exists)
        XCTAssertFalse(element("startup.open").exists)

        app.terminate()
        launchVersion3(session: session, expectsStartupWindow: false)
        XCTAssertFalse(app.windows["Startup and Recovery"].waitForExistence(timeout: 2))
        openStatusMenu()
        XCTAssertTrue(app.staticTexts["Migrated 2.9 UI Fixture"].waitForExistence(timeout: 5))
    }

    func testVersion3FreshInstallSkipsStartupAndRecoveryWindow() {
        launchVersion3(session: UUID().uuidString, expectsStartupWindow: false)

        XCTAssertFalse(app.windows["Startup and Recovery"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.statusItems.firstMatch.exists)
        openStatusMenu()
        XCTAssertFalse(element("startup.open").exists)
    }

    func testVersion3CalendarConflictReviewRejectsServerChangeAndRefreshes() throws {
        let session = UUID().uuidString
        launchVersion3(session: session, fixture: "calendar-conflict", expectsStartupWindow: false)
        if app.windows["Startup and Recovery"].exists {
            app.disclosureTriangles["Recovery details"].click()
            XCTFail("Startup fixture failed: \(app.windows["Startup and Recovery"].debugDescription)")
            return
        }
        openStatusMenu()
        element("open-jobs-window").click()
        let jobs = app.windows["jobs"]
        XCTAssertTrue(jobs.waitForExistence(timeout: 5))
        XCTAssertTrue(element("job-name").waitForExistence(timeout: 5))
        element("Metadata Sync").firstMatch.click()
        let resolve = app.buttons["Resolve Conflicts…"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 5))
        resolve.click()

        let sheet = app.sheets.firstMatch
        if !sheet.waitForExistence(timeout: 5) {
            let nearby = jobs.staticTexts.allElementsBoundByIndex
                .map { ($0.value as? String) ?? $0.label }
            XCTFail("Review did not open: \(nearby)")
            return
        }
        XCTAssertTrue(sheet.staticTexts["Resolve conflicts in “Fixture calendar”"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "This Mac {photographer}", "This Mac {photographer}"
        )).firstMatch.exists)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Server {photographer}", "Server {photographer}"
        )).firstMatch.exists)
        XCTAssertFalse(sheet.buttons["Apply Resolutions"].isEnabled)
        sheet.buttons["This Mac"].click()
        XCTAssertTrue(sheet.buttons["Apply Resolutions"].isEnabled)
        sheet.buttons["Apply Resolutions"].click()

        let changed = sheet.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "server changed again", "server changed again"
        )).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 8))
        XCTAssertTrue(sheet.exists, "A stale choice must leave the review open")
        sheet.buttons["Refresh Review"].click()
        let newest = sheet.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Newest server {photographer}", "Newest server {photographer}"
        )).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "This Mac {photographer}", "This Mac {photographer}"
        )).firstMatch.exists)
        XCTAssertFalse(sheet.buttons["Apply Resolutions"].isEnabled,
            "A refreshed review must require an explicit new choice")
    }

    func testVersion3SyncServerCanBeAddedWithoutSelectingAJob() {
        launchVersion3(session: UUID().uuidString, expectsStartupWindow: false)
        openStatusMenu()
        XCTAssertFalse(element("startup.open").exists)
        app.buttons["Settings"].click()
        app.buttons["Shared Calendars"].click()
        XCTAssertTrue(element("metadata-sync-section").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["FTP Servers"].exists)
        XCTAssertFalse(element("Sync Job").exists)
        let sidebar = element("metadata-sync-server-list")
        XCTAssertTrue(sidebar.exists)
        XCTAssertLessThan(sidebar.frame.midX, element("metadata-sync-server-name").frame.midX)
        let remove = element("metadata-sync-server-remove")
        XCTAssertGreaterThanOrEqual(remove.frame.width, 36)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 36)
        XCTAssertFalse(remove.isEnabled)
        element("metadata-sync-server-name").click()
        element("metadata-sync-server-name").typeText("Newsroom")
        let invitation = element("metadata-sync-invitation")
        XCTAssertTrue(invitation.waitForExistence(timeout: 5))
        XCTAssertTrue(invitation.isEnabled)
        let connect = element("metadata-sync-server-connect")
        XCTAssertFalse(connect.isEnabled)
        XCTAssertFalse(app.buttons["Start Calendar Sync"].exists)
        invitation.click()
        let joinString = "Server: https://fixture.invalid/\nInvitation: " + String(repeating: "b", count: 64)
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        pasteboard.clearContents()
        pasteboard.setString(joinString, forType: .string)
        invitation.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(connect.isEnabled)
        connect.click()
        // Isolated sessions reject startup; connecting must preserve the input for retry.
        XCTAssertTrue(app.staticTexts["Calendar network activity stays disabled in isolated test sessions."].waitForExistence(timeout: 5))
        XCTAssertEqual(invitation.value as? String, joinString)
        element("Members & Invitations").firstMatch.click()
        XCTAssertTrue(app.staticTexts["Select a connected sync server from the list."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Show Members"].exists)
        XCTAssertFalse(app.buttons["Load Calendars"].exists)
        XCTAssertFalse(app.staticTexts["Server and calendar"].exists)
    }

    func testJobMetadataSyncSettingsManageAttachmentSeparatelyFromServers() {
        launch(seedJob: true)
        element("Metadata Sync").firstMatch.click()
        XCTAssertTrue(app.buttons["Manage Sync Servers…"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("metadata-sync-invitation").exists)
        XCTAssertFalse(element("Sync Job").exists)
    }

    func testServerSettingsDeleteControlHasLargeTargetAndDeletesSelectedFixture() {
        launch(seedServer: true)
        openStatusMenu()
        app.buttons["Settings"].click()
        app.buttons["FTP Servers"].click()

        let delete = element("server.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Disposable UI Server"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(delete.frame.width, 36)
        XCTAssertGreaterThanOrEqual(delete.frame.height, 36)

        app.buttons["Photographers"].click()
        app.buttons["FTP Servers"].click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Servers settings after switching from Photographers"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        delete.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).click()
        let confirm = app.sheets.firstMatch.buttons["Delete Disposable UI Server"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertFalse(app.staticTexts["Disposable UI Server"].waitForExistence(timeout: 2))
        XCTAssertFalse(delete.isEnabled)
    }

    func testServerDraftSurvivesTabSwitchAndCancelledAddThenCanBeDiscarded() {
        launch(seedServer: true)
        openStatusMenu()
        app.buttons["Settings"].click()
        app.buttons["FTP Servers"].click()
        let name = element("server.name")
        replaceText(in: name, with: "Unsaved server edit")
        app.buttons["Photographers"].click()
        app.buttons["FTP Servers"].click()
        XCTAssertEqual(name.value as? String, "Unsaved server edit")
        app.buttons["Add Server"].click()
        XCTAssertTrue(app.dialogs.buttons["Cancel"].waitForExistence(timeout: 3))
        app.dialogs.buttons["Cancel"].click()
        XCTAssertEqual(name.value as? String, "Unsaved server edit")
        app.buttons["Add Server"].click()
        app.dialogs.buttons["Discard Changes"].click()
        XCTAssertTrue(app.buttons["Discard Draft"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("server.save").isEnabled, "An incomplete server must stay an unsaved draft")
        app.buttons["Discard Draft"].click()
        XCTAssertEqual(name.value as? String, "Disposable UI Server")
        XCTAssertFalse(app.staticTexts["Unsaved changes"].exists)
    }

    func testClosingServerSettingsProtectsUnsavedDraftAndSavePersistsIt() {
        launch(seedServer: true)
        openStatusMenu()
        app.buttons["Settings"].click()
        app.buttons["FTP Servers"].click()
        let name = element("server.name")
        replaceText(in: name, with: "Saved after close review")
        let settings = app.windows.containing(.textField, identifier: "server.name").firstMatch
        let close = settings.buttons[XCUIIdentifierCloseWindow]
        app.buttons["Photographers"].click()
        app.windows.containing(.button, identifier: "FTP Servers").firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.dialogs.buttons["Cancel"].waitForExistence(timeout: 3))
        app.dialogs.buttons["Cancel"].click()
        app.buttons["FTP Servers"].click()
        XCTAssertEqual(name.value as? String, "Saved after close review")
        close.click()
        app.dialogs.buttons["Save Changes"].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        openStatusMenu()
        app.buttons["Settings"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Saved after close review")
        XCTAssertFalse(app.staticTexts["Unsaved changes"].exists)
    }

    func testSwitchingServersCanCancelOrSaveTheCurrentDraft() {
        launch(seedServer: true)
        openStatusMenu()
        app.buttons["Settings"].click()
        app.buttons["FTP Servers"].click()
        app.buttons["Duplicate Server"].click()
        let name = element("server.name")
        replaceText(in: name, with: "Edited second server")
        element("server.protocol").click()
        app.menuItems["FTPS (TLS)"].click()
        replaceText(in: element("server.port"), with: "2121")
        app.staticTexts["Disposable UI Server"].click()
        XCTAssertTrue(app.dialogs.buttons["Cancel"].waitForExistence(timeout: 3))
        app.dialogs.buttons["Cancel"].click()
        XCTAssertEqual(name.value as? String, "Edited second server")
        app.staticTexts["Disposable UI Server"].click()
        app.dialogs.buttons["Save Changes"].click()
        XCTAssertEqual(name.value as? String, "Disposable UI Server")
        app.staticTexts["Edited second server"].click()
        XCTAssertEqual(name.value as? String, "Edited second server")
        XCTAssertEqual(String(describing: element("server.port").value ?? "").filter { $0.isNumber }, "2121")
        XCTAssertFalse(app.staticTexts["Unsaved changes"].exists)
    }

    func testOpenJobConnectionRefreshesWhenSharedServerChangesInSettings() {
        launch(seedJob: true, seedServer: true)
        replaceText(in: element("job-name"), with: "Keep local job edits")
        app.buttons["Source: Edit Location"].click()
        element("endpoint.type").click()
        app.menuItems["FTPS (TLS)"].click()
        element("endpoint.server-profile").click()
        app.menuItems["Disposable UI Server"].click()
        replaceText(in: element("endpoint.remote-folder"), with: "/keep/job/folder")

        openStatusMenu()
        app.buttons["Settings"].click()
        app.buttons["FTP Servers"].click()
        replaceText(in: element("server.port"), with: "2121")
        element("server.save").click()

        let sheet = app.windows["jobs"].sheets.firstMatch
        let port = sheet.descendants(matching: .any)["endpoint.port"]
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: port.value ?? "").filter { $0.isNumber } == "2121"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 5), .completed)
        XCTAssertFalse(port.isEnabled)
        XCTAssertEqual(sheet.descendants(matching: .any)["endpoint.remote-folder"].value as? String, "/keep/job/folder")
        // Settings can overlap the sheet's Done button; close it before returning to the job.
        app.windows.containing(.button, identifier: "FTP Servers").firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        sheet.buttons["Done"].click()
        XCTAssertEqual(element("job-name").value as? String, "Keep local job edits")
        element("save-job").click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
    }

    func testJobConnectionKeepsCustomPortWhenSelectingDifferentProtocolProfile() {
        launch(seedJob: true, seedServer: true)
        openStatusMenu()
        app.buttons["Settings"].click()
        app.buttons["FTP Servers"].click()
        replaceText(in: element("server.port"), with: "2121")
        element("server.save").click()
        openStatusMenu()
        element("open-jobs-window").click()
        dismissStatusPanelIfNeeded()
        app.buttons["Source: Edit Location"].click()
        element("endpoint.type").click()
        app.menuItems["FTPS (TLS)"].click()
        element("endpoint.server-profile").click()
        app.menuItems["Disposable UI Server"].click()
        let port = element("endpoint.port")
        XCTAssertEqual(String(describing: port.value ?? "").filter { $0.isNumber }, "2121")
        XCTAssertFalse(port.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Saved profile custom port in job setup"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].click()
        element("save-job").click()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
    }

    func testVersion3BackupOnlySourceUsesDetailedRecoveryMigration() {
        launchVersion3(session: UUID().uuidString, fixture: "backup-only")

        XCTAssertTrue(app.staticTexts["Recovery Migration"].waitForExistence(timeout: 8))
        XCTAssertTrue(element("startup.source.jobs-v2.json").exists)
        XCTAssertTrue(element("startup.closedOtherCopies").exists)
        XCTAssertFalse(element("startup.upgrade").exists)
    }

    func testVersion3DamagedPrimaryNeverFallsBackToBackup() {
        launchVersion3(session: UUID().uuidString, fixture: "damaged-primary")

        XCTAssertTrue(app.windows["Startup and Recovery"].waitForExistence(timeout: 8))
        XCTAssertFalse(element("startup.source.jobs-v2.json").exists)

        let failure = element("startup.message")
        XCTAssertTrue(failure.waitForExistence(timeout: 12))
        let message = (failure.value as? String) ?? failure.label
        XCTAssertTrue(message.contains("The app could not open your saved data"), "Actual startup message: \(message)")
        XCTAssertFalse(app.staticTexts["Review before starting"].exists)
        XCTAssertFalse(app.staticTexts["Recovery Backup UI Fixture"].exists)
    }

    func testVersion3RecoversPreparedCopyWithoutReimportingLegacyChanges() {
        launchVersion3(session: UUID().uuidString, fixture: "prepared-recovery")

        let recover = element("startup.recover")
        XCTAssertTrue(recover.waitForExistence(timeout: 8))
        XCTAssertTrue(recover.isEnabled)
        recover.click()

        XCTAssertTrue(app.staticTexts["Review before starting"].waitForExistence(timeout: 12))
        app.windows["Startup and Recovery"].buttons[XCUIIdentifierCloseWindow].click()
        openStatusMenu()
        XCTAssertTrue(app.staticTexts["Prepared Recovery UI Fixture"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Legacy Changed After Preparation"].exists)
        XCTAssertTrue(app.buttons["Start"].exists)
    }

    private func launch(
        seedJob: Bool = false,
        seedMap: Bool = false,
        seedServer: Bool = false,
        failFirstJobSave: Bool = false,
        accessibilityText: Bool = false,
        recoveryFixture: Bool = false,
        managedRecovery: Bool = false,
        imageRecovery: Bool = false,
        matchingClipImage: Bool = false,
        mixedClipRecovery: Bool = false,
        interruptPublication: Bool = false,
        rawRecovery: Bool = false,
        rawExtension: String = "arw",
        interruptionPhase: String = "beforeCommit",
        editedRawConflict: Bool = false,
        ordinarySyncInterruption: Bool = false,
        processedHandoffInterruption: Bool = false
    ) {
        let cleanApp = XCUIApplication()
        cleanApp.terminate()
        app = cleanApp
        app.launchEnvironment["AAGEDAL_UI_TESTING"] = "1"
        app.launchEnvironment["AAGEDAL_UI_TEST_OPEN_JOBS"] = "1"
        app.launchEnvironment["AAGEDAL_UI_TEST_SESSION"] = UUID().uuidString
        if seedJob { app.launchEnvironment["AAGEDAL_UI_TEST_SEED_JOB"] = "1" }
        if seedMap { app.launchEnvironment["AAGEDAL_UI_TEST_SEED_MAP"] = "1" }
        if seedServer { app.launchEnvironment["AAGEDAL_UI_TEST_SEED_SERVER"] = "1" }
        if failFirstJobSave { app.launchEnvironment["AAGEDAL_UI_TEST_FAIL_FIRST_JOB_SAVE"] = "1" }
        if accessibilityText { app.launchEnvironment["AAGEDAL_UI_TEST_ACCESSIBILITY_TEXT"] = "1" }
        if recoveryFixture { app.launchEnvironment["AAGEDAL_UI_TEST_RECOVERY"] = "1" }
        if imageRecovery { app.launchEnvironment["AAGEDAL_UI_TEST_IMAGE_RECOVERY"] = "1" }
        if matchingClipImage { app.launchEnvironment["AAGEDAL_UI_TEST_MATCHING_CLIP_IMAGE"] = "1" }
        if mixedClipRecovery { app.launchEnvironment["AAGEDAL_UI_TEST_MIXED_CLIP_RECOVERY"] = "1" }
        if editedRawConflict { app.launchEnvironment["AAGEDAL_UI_TEST_EDIT_RAW_CONFLICT"] = "1" }
        if managedRecovery { app.launchEnvironment["AAGEDAL_UI_TEST_MANAGED_RECOVERY"] = "1" }
        if rawRecovery {
            app.launchEnvironment["AAGEDAL_UI_TEST_RAW_RECOVERY"] = "1"
            app.launchEnvironment["AAGEDAL_UI_TEST_RAW_EXTENSION"] = rawExtension
        }
        if ordinarySyncInterruption { app.launchEnvironment["AAGEDAL_UI_TEST_INTERRUPT_ORDINARY_SYNC"] = "1" }
        if processedHandoffInterruption { app.launchEnvironment["AAGEDAL_UI_TEST_INTERRUPT_PROCESSED_HANDOFF"] = "1" }
        if interruptPublication {
            app.launchEnvironment["AAGEDAL_UI_TEST_INTERRUPT_PUBLICATION"] = "1"
            app.launchEnvironment["AAGEDAL_UI_TEST_INTERRUPTION_PHASE"] = interruptionPhase
        }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        waitForJobsWindow(seedJob: seedJob)
    }

    private func waitForJobsWindow(seedJob: Bool) {
        let jobsWindow = app.windows["jobs"]
        XCTAssertTrue(jobsWindow.waitForExistence(timeout: 8))
        let expectedContent = seedJob ? element("job-name") : element("add-sync-job-empty-state")
        XCTAssertTrue(expectedContent.waitForExistence(timeout: 8))
    }

    private func launchVersion3(session: String, fixture: String? = nil, expectsStartupWindow: Bool = true,
                                seedRemoteJob: Bool = false) {
        let cleanApp = XCUIApplication()
        cleanApp.terminate()
        app = cleanApp
        app.launchEnvironment["AAGEDAL_UI_TESTING"] = "1"
        app.launchEnvironment["AAGEDAL_UI_TEST_SESSION"] = session
        app.launchEnvironment["AAGEDAL_UI_TEST_V3_STARTUP"] = "1"
        if let fixture { app.launchEnvironment["AAGEDAL_UI_TEST_V3_FIXTURE"] = fixture }
        if seedRemoteJob { app.launchEnvironment["AAGEDAL_UI_TEST_SEED_REMOTE_JOB"] = "1" }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if expectsStartupWindow {
            XCTAssertTrue(app.windows["Startup and Recovery"].waitForExistence(timeout: 8))
        } else {
            XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 8))
        }
    }

    private func openStatusMenu() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let jobsButton = element("open-jobs-window")
        if !jobsButton.waitForExistence(timeout: 8) {
            // Establish a known closed state before retrying. A second blind
            // click can close a panel that appeared just after the first wait.
            app.typeKey(.escape, modifierFlags: [])
            statusItem.click()
            XCTAssertTrue(jobsButton.waitForExistence(timeout: 5))
        }
    }

    private func openConfigurationMenu() {
        let menu = element("configuration-transfer-menu")
        if !menu.exists {
            openStatusMenu()
            app.buttons["Settings"].click()
            app.buttons["General"].click()
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.click()
    }

    private func dismissStatusPanelIfNeeded() {
        let panelContent = element("open-jobs-window")
        if panelContent.exists {
            app.statusItems.firstMatch.click()
            XCTAssertFalse(panelContent.waitForExistence(timeout: 2))
        }
    }

    /// Querying a SwiftUI hierarchy during an AppKit sheet dismissal can recurse
    /// inside accessibility on the macOS 27 beta. Let the transition settle before
    /// asking XCTest for another full snapshot.
    private func waitForSheetTransition() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }
}
