import XCTest
import Foundation
import Darwin

final class BrowserLifecycleCrossWindowUITests: XCTestCase {
    private var socketPath = ""
    private var dataPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        launchTag = "ui-tests-browser-cross-window-\(UUID().uuidString.prefix(8))"
        socketPath = "/tmp/cmux-debug-\(launchTag).sock"
        dataPath = "/tmp/cmux-ui-socket-sanity-\(launchTag).json"
        LifecycleUITestSocketClient.setBundledCLIPathOverride(nil)
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: dataPath)
        super.tearDown()
    }

    func testBrowserWorkspaceMoveAcrossWindowsPreservesVisibleResidency() {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for browser cross-window lifecycle test. state=\(app.state.rawValue)"
        )

        guard let socketState = waitForSocketSanity(timeout: 20.0) else {
            XCTFail("Expected control socket sanity data")
            return
        }
        if let expectedSocketPath = socketState["socketExpectedPath"], !expectedSocketPath.isEmpty {
            socketPath = expectedSocketPath
        }
        LifecycleUITestSocketClient.setBundledCLIPathOverride(socketState["bundledCLIPath"])
        XCTAssertEqual(socketState["socketReady"], "1", "Expected ready socket. state=\(socketState)")
        XCTAssertEqual(socketState["windowReady"], "1", "Expected ready current window. state=\(socketState)")
        XCTAssertEqual(socketState["surfaceReady"], "1", "Expected ready current surface. state=\(socketState)")
        XCTAssertEqual(socketState["mutationReady"], "1", "Expected lifecycle mutation routing to be ready. state=\(socketState)")
        XCTAssertEqual(socketState["socketPingResponse"], "PONG", "Expected healthy socket ping. state=\(socketState)")

        guard let workspaceId = waitForCurrentWorkspaceId(timeout: 20.0) else {
            XCTFail("Missing current workspace result")
            return
        }
        guard let currentSurfaceId = socketState["currentSurfaceId"],
              !currentSurfaceId.isEmpty else {
            XCTFail("Socket sanity did not publish currentSurfaceId. state=\(socketState)")
            return
        }

        let opened = v2Call(
            "browser.open_split",
            params: [
                "url": "https://example.com/browser-cross-window",
                "workspace_id": workspaceId,
                "surface_id": currentSurfaceId,
            ]
        )
        let openedResult = opened?["result"] as? [String: Any]
        guard let browserPanelId = openedResult?["surface_id"] as? String,
              !browserPanelId.isEmpty else {
            XCTFail("browser.open_split did not return surface_id. payload=\(String(describing: opened))")
            return
        }

        guard let sourceWindowId = socketState["currentWindowId"],
              !sourceWindowId.isEmpty else {
            XCTFail("Socket sanity did not publish currentWindowId. state=\(socketState)")
            return
        }

        guard let createdWindow = v2Call("window.create"),
              let createdWindowResult = createdWindow["result"] as? [String: Any],
              let destinationWindowId = createdWindowResult["window_id"] as? String,
              !destinationWindowId.isEmpty else {
            XCTFail("window.create did not return window_id")
            return
        }

        XCTAssertNotEqual(sourceWindowId, destinationWindowId)

        guard v2Call(
            "workspace.move_to_window",
            params: [
                "workspace_id": workspaceId,
                "window_id": destinationWindowId,
                "focus": true,
            ]
        ) != nil else {
            XCTFail("workspace.move_to_window failed")
            return
        }

        XCTAssertTrue(
            waitForLifecycleSnapshot(timeout: 8.0) { snapshot in
                guard let browser = snapshot.records.first(where: { $0.panelId == browserPanelId }) else {
                    return false
                }
                return browser.selectedWorkspace &&
                    browser.activeWindowMembership &&
                    browser.anchorWindowNumber != 0 &&
                    browser.targetResidency == "visibleInActiveWindow"
            },
            "Expected browser to remain visible after cross-window workspace move"
        )

        guard let snapshot = latestLifecycleSnapshot(),
              let browser = snapshot.records.first(where: { $0.panelId == browserPanelId }) else {
            XCTFail("Missing browser lifecycle snapshot after cross-window move")
            return
        }

        XCTAssertTrue(browser.selectedWorkspace)
        XCTAssertTrue(browser.activeWindowMembership)
        XCTAssertEqual(browser.targetResidency, "visibleInActiveWindow")
        XCTAssertNotEqual(browser.anchorWindowNumber, 0)
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForSocketSanity(timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadSocketSanityData(),
               data["socketReady"] == "1",
               data["workspaceReady"] == "1",
               data["windowReady"] == "1",
               data["surfaceReady"] == "1",
               data["mutationReady"] == "1",
               data["socketPingResponse"] == "PONG" {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadSocketSanityData()
    }

    private func loadSocketSanityData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func waitForLifecycleSnapshot(
        timeout: TimeInterval,
        predicate: (BrowserCrossWindowSnapshot) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = latestLifecycleSnapshot(), predicate(snapshot) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let snapshot = latestLifecycleSnapshot(), predicate(snapshot) {
            return true
        }
        return false
    }

    private func latestLifecycleSnapshot() -> BrowserCrossWindowSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return BrowserCrossWindowSnapshot(result: result)
    }

    private func waitForCurrentWorkspaceId(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let workspaceId = loadSocketSanityData()?["currentWorkspaceId"], !workspaceId.isEmpty {
                return workspaceId
            }
            if let response = v2Call("workspace.current"),
               let result = response["result"] as? [String: Any],
               let workspaceId = result["workspace_id"] as? String,
               !workspaceId.isEmpty {
                return workspaceId
            }
            if let response = v2Call("workspace.list"),
               let result = response["result"] as? [String: Any],
               let workspaces = result["workspaces"] as? [[String: Any]],
               let selected = workspaces.first(where: { $0["selected"] as? Bool == true })?["workspace_id"] as? String,
               !selected.isEmpty {
                return selected
            }
            if let response = v2Call("workspace.list"),
               let result = response["result"] as? [String: Any],
               let workspaces = result["workspaces"] as? [[String: Any]],
               let first = workspaces.first?["workspace_id"] as? String,
               !first.isEmpty {
                return first
            }
            if let snapshot = latestLifecycleSnapshot(),
               let selected = snapshot.records.first(where: { $0.selectedWorkspace })?.workspaceId,
               !selected.isEmpty {
                return selected
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let workspaceId = loadSocketSanityData()?["currentWorkspaceId"], !workspaceId.isEmpty {
            return workspaceId
        }
        return nil
    }

    private func v2Call(_ method: String, params: [String: Any] = [:]) -> [String: Any]? {
        BrowserCrossWindowV2SocketClient(path: socketPath).call(method: method, params: params)
    }
}

private struct BrowserCrossWindowRecord {
    let panelId: String
    let workspaceId: String
    let selectedWorkspace: Bool
    let activeWindowMembership: Bool
    let targetResidency: String
    let anchorWindowNumber: Int
}

private struct BrowserCrossWindowSnapshot {
    let records: [BrowserCrossWindowRecord]

    init?(result: [String: Any]) {
        let rawRecords = result["records"] as? [[String: Any]] ?? []
        let desiredContainer = result["desired"] as? [String: Any] ?? [:]
        let rawDesired = desiredContainer["records"] as? [[String: Any]] ?? []
        let desiredPairs: [(String, String)] = rawDesired.compactMap { row -> (String, String)? in
            guard let panelId = row["panelId"] as? String else { return nil }
            return (panelId, row["targetResidency"] as? String ?? "")
        }
        let desiredByPanel = Dictionary(uniqueKeysWithValues: desiredPairs)

        records = rawRecords.compactMap { row -> BrowserCrossWindowRecord? in
            guard let panelId = row["panelId"] as? String else { return nil }
            let anchor = row["anchor"] as? [String: Any] ?? [:]
            return BrowserCrossWindowRecord(
                panelId: panelId,
                workspaceId: row["workspaceId"] as? String ?? "",
                selectedWorkspace: row["selectedWorkspace"] as? Bool ?? false,
                activeWindowMembership: row["activeWindowMembership"] as? Bool ?? false,
                targetResidency: desiredByPanel[panelId] ?? "",
                anchorWindowNumber: anchor["windowNumber"] as? Int ?? 0
            )
        }
    }
}

private typealias BrowserCrossWindowV2SocketClient = LifecycleUITestSocketClient
