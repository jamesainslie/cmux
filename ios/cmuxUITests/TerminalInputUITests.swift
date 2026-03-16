import XCTest

final class TerminalInputUITests: XCTestCase {
    private enum Fixture {
        static let workspaceID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testInputFixtureTypingUpdatesWorkspacePreview() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INPUT_FIXTURE"] = "1"
        app.launch()

        let serverButton = app.buttons["terminal.server.cmux-input"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 6), "Expected input fixture server pin")
        serverButton.tap()

        let detail = app.otherElements["terminal.workspace.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 4), "Expected terminal workspace detail")
        detail.tap()
        app.typeText("ls")

        app.navigationBars["Input Fixture"].buttons.firstMatch.tap()

        let preview = app.staticTexts["terminal.workspace.preview.\(Fixture.workspaceID)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 4), "Expected workspace preview")
        XCTAssertEqual(preview.label, "ls")
    }

    func testInputFixtureAccessoryTabUpdatesWorkspacePreview() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INPUT_FIXTURE"] = "1"
        app.launch()

        let serverButton = app.buttons["terminal.server.cmux-input"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 6), "Expected input fixture server pin")
        serverButton.tap()

        let detail = app.otherElements["terminal.workspace.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 4), "Expected terminal workspace detail")
        detail.tap()

        let tabButton = app.buttons["terminal.inputAccessory.tab"]
        XCTAssertTrue(tabButton.waitForExistence(timeout: 4), "Expected tab accessory button")
        tabButton.tap()

        app.navigationBars["Input Fixture"].buttons.firstMatch.tap()

        let preview = app.staticTexts["terminal.workspace.preview.\(Fixture.workspaceID)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 4), "Expected workspace preview")
        XCTAssertEqual(preview.label, "[TAB]")
    }
}
