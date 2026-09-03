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

    private func launch(seedJob: Bool = false, failFirstJobSave: Bool = false) {
        let cleanApp = XCUIApplication()
        cleanApp.terminate()
        app = cleanApp
        app.launchEnvironment["AAGEDAL_UI_TESTING"] = "1"
        app.launchEnvironment["AAGEDAL_UI_TEST_SESSION"] = UUID().uuidString
        if seedJob { app.launchEnvironment["AAGEDAL_UI_TEST_SEED_JOB"] = "1" }
        if failFirstJobSave { app.launchEnvironment["AAGEDAL_UI_TEST_FAIL_FIRST_JOB_SAVE"] = "1" }
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
