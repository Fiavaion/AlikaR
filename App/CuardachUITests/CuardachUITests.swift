import XCTest

final class CuardachUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Unpacked sample bundle in the repo, read directly by the simulator app.
    private var sampleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/courtyard-hunt.arhunt")
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
    }

    private func launch(seeded: Bool = false) {
        if seeded { app.launchEnvironment["UITEST_SEED_OPENED"] = sampleURL.path }
        app.launch()
        XCTAssertTrue(app.navigationBars["Cuardach"].waitForExistence(timeout: 15))
    }

    private func createExperience(titled title: String) {
        app.buttons["New experience"].tap()
        let alert = app.alerts["New experience"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields["Title"]
        field.tap()
        field.typeText(title)
        alert.buttons["Create"].tap()
    }

    func testLaunchShowsEmptyLibrary() {
        launch()
        XCTAssertTrue(app.buttons["Make your first experience"].exists)
        XCTAssertTrue(app.buttons["Studio briefs"].exists)
    }

    func testStudioBriefsListOpens() {
        launch()
        app.buttons["Studio briefs"].tap()
        XCTAssertTrue(app.navigationBars["Studio briefs"].waitForExistence(timeout: 5))
        // The discipline picker plus at least one brief.
        XCTAssertGreaterThan(app.cells.count, 1)
    }

    func testCreateAndDeleteExperience() {
        launch()
        createExperience(titled: "UITest Hunt")
        // Creating opens the author screen; come back to the library.
        let back = app.buttons["Done"]
        XCTAssertTrue(back.waitForExistence(timeout: 20), "author screen did not open")
        back.tap()
        let row = app.buttons["UITest Hunt"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Make your first experience"].exists)
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Make your first experience"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
    }

    func testSeededBundleAppearsAndCanBeRemixed() {
        launch(seeded: true)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Courtyard Hunt'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Remix a copy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete"].exists)
        app.buttons["Remix a copy"].tap()
        let back = app.buttons["Done"]
        XCTAssertTrue(back.waitForExistence(timeout: 20), "author screen did not open")
        back.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Courtyard Hunt (remix)'")).firstMatch
            .waitForExistence(timeout: 5))
    }
}
