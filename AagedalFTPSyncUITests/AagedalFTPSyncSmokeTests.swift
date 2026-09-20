import AppKit
import XCTest

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

    private func verifyRetainedMetadataRecovery(managed: Bool) throws {
        launch(seedJob: true, recoveryFixture: true, managedRecovery: managed)
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
                format: "label CONTAINS %@ OR value CONTAINS %@", "Preflight checked 0 files", "Preflight checked 0 files"
            )).firstMatch
            XCTAssertTrue(success.waitForExistence(timeout: 8))
            // The text fixture is deliberately not an image: admission succeeds,
            // while no metadata publication is offered for an empty image batch.
            XCTAssertFalse(sheet.buttons["Reprocess Saved Files"].isEnabled)
            sheet.buttons["Cancel"].click()
            waitForSheetTransition()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
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

    func testEditsSavedJob() {
        launch(seedJob: true)

        let nameField = element("job-name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        replaceText(in: nameField, with: "Edited in UI smoke test")
        element("save-job").click()

        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Edited in UI smoke test"].exists)
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
        element("File Filtering & Deletion").firstMatch.click()
        let toggle = element("use-metadata-programming-filter")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
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

        let alert = app.dialogs.firstMatch
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

    func testPeopleLibrarySettingsShowsUnavailableModelConfiguration() {
        launch(seedJob: true)

        element("Metadata").firstMatch.click()
        let openSettings = element("open-people-library-settings")
        XCTAssertTrue(openSettings.waitForExistence(timeout: 3))
        XCTAssertTrue(openSettings.isEnabled)
        openSettings.click()

        XCTAssertTrue(element("peopleLibrary.summary").waitForExistence(timeout: 5))
        let modelStatus = element("faceModel.status")
        XCTAssertTrue(modelStatus.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Model downloads are not configured in this build."].exists)
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
        let openMetadata = app.buttons["Metadata Programming for UI Smoke Fixture"]
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

    func testVersion3SyncServerCanBeAddedWithoutSelectingAJob() {
        launchVersion3(session: UUID().uuidString, expectsStartupWindow: false)
        openStatusMenu()
        XCTAssertFalse(element("startup.open").exists)
        app.buttons["Settings"].click()
        app.buttons["Sync Servers"].click()
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

        let failClosed = "Startup could not complete safely. Saved data remains available for recovery. Quit and reopen the app before trying Open or Recover; no default configuration was loaded."
        let failure = app.staticTexts.matching(NSPredicate(format: "value == %@", failClosed)).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 12))
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
        managedRecovery: Bool = false
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
        if managedRecovery { app.launchEnvironment["AAGEDAL_UI_TEST_MANAGED_RECOVERY"] = "1" }
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
