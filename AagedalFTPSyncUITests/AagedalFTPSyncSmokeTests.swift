import XCTest

@MainActor
final class AagedalFTPSyncSmokeTests: XCTestCase {
    private var app: XCUIApplication!

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
        app.menuItems["Export Sync Jobs…"].click()
        XCTAssertTrue(app.staticTexts["Export Sync Jobs"].waitForExistence(timeout: 3))
        element("encrypt-configuration").click()
        element("configuration-transfer-submit").click()

        openConfigurationMenu()
        app.menuItems["Import Configuration Package…"].click()
        XCTAssertTrue(app.staticTexts["Import Unencrypted Package"].waitForExistence(timeout: 3))
        element("configuration-transfer-submit").click()

        XCTAssertTrue(app.staticTexts["UI Smoke Fixture (Imported)"].waitForExistence(timeout: 5))
    }

    func testMetadataProgrammingMakesImportDiscoverable() {
        launch(seedJob: true)

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

    func testPhotographerMapClipSelectionAndEditing() {
        launch(seedJob: true, seedMap: true)

        element("open-metadata-programming").click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        element("open-photographer-map").click()

        let mapWindow = app.windows["Photographer Map"]
        XCTAssertTrue(mapWindow.waitForExistence(timeout: 5))
        let clip = element("photographer-map-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
        XCTAssertTrue(clip.waitForExistence(timeout: 5))

        clip.click()
        XCTAssertEqual(clip.value as? String, "Selected, location set")

        clip.doubleClick()
        XCTAssertTrue(element("metadata-clip-editor").waitForExistence(timeout: 5))
    }

    func testPhotographerMapTimelineSupportsKeyboardAdjustment() {
        launch(seedJob: true, seedMap: true)

        element("open-metadata-programming").click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        element("open-photographer-map").click()

        let mapWindow = app.windows["Photographer Map"]
        XCTAssertTrue(mapWindow.waitForExistence(timeout: 5))
        let row = element("photographer-map-timeline-row-C542A26A-2872-42E5-B021-7AA3E599D3A8")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let selectedTime = element("photographer-map-selected-time")
        XCTAssertTrue(selectedTime.waitForExistence(timeout: 3))

        row.click()
        let initialTime = selectedTime.value as? String
        row.typeKey(.rightArrow, modifierFlags: [])

        XCTAssertNotEqual(selectedTime.value as? String, initialTime)
    }

    func testAccessibilityTextSizeKeepsCoreControlsOperable() {
        launch(seedJob: true, seedMap: true, accessibilityText: true)

        XCTAssertTrue(element("job-name").isHittable)
        XCTAssertTrue(element("save-job").exists)

        element("open-metadata-programming").click()
        let metadataWindow = app.windows["Metadata Programming"]
        XCTAssertTrue(metadataWindow.waitForExistence(timeout: 5))
        element("open-photographer-map").click()

        let mapWindow = app.windows["Photographer Map"]
        XCTAssertTrue(mapWindow.waitForExistence(timeout: 5))
        let row = element("photographer-map-timeline-row-C542A26A-2872-42E5-B021-7AA3E599D3A8")
        let clip = element("photographer-map-clip-D7523669-D8BE-46C4-9FE7-3E18CF25F8B6")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(row.frame.height, 24)
        XCTAssertGreaterThanOrEqual(clip.frame.height, 20)
        XCTAssertTrue(mapWindow.frame.intersects(row.frame))
        XCTAssertTrue(mapWindow.frame.intersects(clip.frame))
    }

    private func launch(
        seedJob: Bool = false,
        seedMap: Bool = false,
        failFirstJobSave: Bool = false,
        accessibilityText: Bool = false
    ) {
        let cleanApp = XCUIApplication()
        cleanApp.terminate()
        app = cleanApp
        app.launchEnvironment["AAGEDAL_UI_TESTING"] = "1"
        app.launchEnvironment["AAGEDAL_UI_TEST_SESSION"] = UUID().uuidString
        if seedJob { app.launchEnvironment["AAGEDAL_UI_TEST_SEED_JOB"] = "1" }
        if seedMap { app.launchEnvironment["AAGEDAL_UI_TEST_SEED_MAP"] = "1" }
        if failFirstJobSave { app.launchEnvironment["AAGEDAL_UI_TEST_FAIL_FIRST_JOB_SAVE"] = "1" }
        if accessibilityText { app.launchEnvironment["AAGEDAL_UI_TEST_ACCESSIBILITY_TEXT"] = "1" }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        if !app.windows["Aagedal FTP Sync"].waitForExistence(timeout: 1) {
            app.statusItems["Aagedal FTP Sync"].click()
            let openJobs = element("open-jobs-window")
            XCTAssertTrue(openJobs.waitForExistence(timeout: 3))
            openJobs.click()
            if openJobs.exists {
                app.statusItems["Aagedal FTP Sync"].click()
            }
        }
        let expectedContent = seedJob ? element("job-name") : element("add-sync-job-empty-state")
        XCTAssertTrue(expectedContent.waitForExistence(timeout: 8))
    }

    private func openConfigurationMenu() {
        let menu = element("configuration-transfer-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.click()
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
