import XCTest

/// Runs against the DEBUG-only synthetic sensor (-UITestSyntheticSensor). Verifies UI wiring, not physics.
final class CurrentSenseUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestSyntheticSensor"]
        app.launch()
    }

    private func header() -> String { app.staticTexts["readings.header"].label }

    func testModeSelectorUpdatesImmediately() {
        let ac = app.buttons["mode.ac"], dc = app.buttons["mode.dc"]
        XCTAssertTrue(dc.waitForExistence(timeout: 5))
        XCTAssertTrue(dc.isSelected)
        ac.tap()
        XCTAssertTrue(ac.isSelected)
        XCTAssertFalse(dc.isSelected)
        XCTAssertTrue(app.staticTexts["readings.disclaimer"].exists, "AC mode shows the not-a-voltage-tester note")
        XCTAssertFalse(app.staticTexts["reading.current.value"].exists, "AC mode never shows a current row")
    }

    func testTapStartsAndStopsMeasurement() {
        let button = app.buttons["measure.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertEqual(header(), "Taking baseline")
        let live = NSPredicate(format: "label == %@", "Live")
        expectation(for: live, evaluatedWith: app.staticTexts["readings.header"])
        waitForExpectations(timeout: 15)
        button.tap()
        XCTAssertNotEqual(header(), "Live", "stopped measurement must not be presented as live")
    }

    func testACShowsDetectionWithoutCurrent() {
        app.buttons["mode.ac"].tap()
        app.buttons["measure.button"].tap()
        let detected = NSPredicate(format: "label == %@", "Detected")
        expectation(for: detected, evaluatedWith: app.staticTexts["reading.field.value"])
        waitForExpectations(timeout: 20)
        XCTAssertFalse(app.staticTexts["reading.current.value"].exists)
    }

    func testModeSwitchWhileRunningClearsContent() {
        app.buttons["measure.button"].tap()
        app.buttons["mode.ac"].tap()
        XCTAssertEqual(header(), "Taking baseline")
        XCTAssertEqual(app.staticTexts["reading.field.value"].label, "\u{2014}")
    }

    func testRapidTapsLeaveConsistentState() {
        let button = app.buttons["measure.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<6 { button.tap() }          // even number: ends stopped
        XCTAssertNotEqual(header(), "Taking baseline")
        XCTAssertNotEqual(header(), "Live")
        button.tap()
        XCTAssertEqual(header(), "Taking baseline")
    }
}
