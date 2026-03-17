import XCTest

final class TerminalHostEditorUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSetupFixtureOpensHostEditorAndStartsWorkspaceAfterSave() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_SETUP_FIXTURE"] = "1"
        app.launch()

        let serverButton = app.buttons["terminal.server.cmux-setup"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 6), "Expected setup fixture server pin")
        serverButton.tap()

        let hostnameField = app.textFields["terminal.hostEditor.hostname"]
        XCTAssertTrue(hostnameField.waitForExistence(timeout: 4), "Expected hostname field")
        hostnameField.tap()
        hostnameField.typeText("cmux-macmini")

        let usernameField = app.textFields["terminal.hostEditor.username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 2), "Expected username field")
        usernameField.tap()
        usernameField.typeText("cmux")

        let passwordField = app.secureTextFields["terminal.hostEditor.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 2), "Expected password field")
        passwordField.tap()
        passwordField.typeText("fixture")

        let saveButton = app.buttons["terminal.hostEditor.save"]
        XCTAssertTrue(saveButton.isEnabled, "Expected host editor save button")
        saveButton.tap()

        XCTAssertTrue(app.navigationBars["Mac mini"].waitForExistence(timeout: 4), "Expected workspace title")
        XCTAssertTrue(
            app.otherElements["terminal.workspace.detail"].waitForExistence(timeout: 4),
            "Expected workspace detail after saving the configured host"
        )
    }
}
