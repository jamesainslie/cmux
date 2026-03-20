import Foundation

/// Manages a single tmux control mode connection.
///
/// Each `TmuxController` corresponds to one `tmux -CC` session running
/// in a gateway terminal surface. It maintains mappings between tmux
/// entities (windows, panes) and cmux native UI elements (workspaces,
/// panels, virtual surfaces).
@MainActor
final class TmuxController: ObservableObject {
    let id: UUID = UUID()

    /// The panel ID of the gateway surface that initiated this connection.
    let gatewayPanelId: UUID

    /// Reference to the gateway surface for sending commands.
    weak var gatewaySurface: TerminalSurface?

    /// Reference to the tab manager for creating workspaces.
    weak var tabManager: TabManager?

    /// The gateway that bridges C API actions to this controller.
    let gateway: TmuxGateway

    // MARK: - Published State

    @Published private(set) var connectionState: TmuxConnectionState = .connecting
    @Published private(set) var sessionId: Int = 0
    @Published private(set) var sessionName: String = ""
    @Published private(set) var tmuxVersion: String = ""

    // MARK: - Entity Maps

    /// Maps tmux window ID → cmux workspace ID.
    private(set) var windowToWorkspace: [Int: UUID] = [:]

    /// Maps tmux pane ID → TmuxPaneClient managing the virtual surface.
    private(set) var paneToClient: [Int: AnyObject] = [:]  // TmuxPaneClient in Phase 2

    /// Maps tmux pane ID → cmux panel ID.
    private(set) var paneToPanelId: [Int: UUID] = [:]

    // MARK: - Feedback Loop Prevention (spec SS5)

    /// Incremented during notification handling to suppress echoed changes.
    private var suppressActivityChanges: Int = 0

    /// Incremented when sending select-window to ignore the resulting notification.
    private var ignoreWindowChangeNotificationCount: Int = 0

    // MARK: - Global Registry

    /// All active tmux controllers indexed by their ID.
    private static var activeControllers: [UUID: TmuxController] = [:]

    /// Find a controller by its gateway panel ID.
    static func controller(forGatewayPanel panelId: UUID) -> TmuxController? {
        activeControllers.values.first { $0.gatewayPanelId == panelId }
    }

    // MARK: - Init

    init(gatewayPanelId: UUID, gateway: TmuxGateway) {
        self.gatewayPanelId = gatewayPanelId
        self.gateway = gateway
        Self.activeControllers[id] = self
    }

    // MARK: - Event Handling

    /// Process an event from the Ghostty Viewer.
    func handleEvent(_ event: TmuxEvent) {
        switch event {
        case .enter:
            connectionState = .negotiating
            buryGatewayWorkspace()

        case .exit:
            teardown()

        case .windowsChanged(let payload):
            handleWindowsChanged(payload)

        case .paneOutput(let paneId, let data):
            routeOutput(paneId: Int(paneId), data: data)

        case .layoutChange(let windowId, let layoutJSON):
            handleLayoutChange(windowId: Int(windowId), layoutJSON: layoutJSON)

        case .windowAdd(let windowId):
            handleWindowAdd(windowId: Int(windowId))

        case .windowClose(let windowId):
            handleWindowClose(windowId: Int(windowId))

        case .windowRenamed(let windowId, let name):
            handleWindowRenamed(windowId: Int(windowId), name: name)

        case .sessionChanged(_, let name):
            sessionName = name

        case .sessionRenamed(let name):
            sessionName = name
        }
    }

    // MARK: - Windows

    private func handleWindowsChanged(_ payload: TmuxWindowsPayload) {
        // Update metadata
        sessionId = payload.sessionId
        tmuxVersion = payload.tmuxVersion

        if connectionState == .negotiating || connectionState == .connecting {
            connectionState = .synchronizing
        }

        // Actual window/layout creation is implemented in Phase 3.
        // For now, transition to connected after receiving windows.
        openWindows(payload.windows)

        if connectionState == .synchronizing {
            connectionState = .connected
            gateway.enableWrite()
        }
    }

    /// Create or update native workspaces for the given tmux windows.
    /// Stub — full implementation in Phase 3 (Layout Engine).
    func openWindows(_ windows: [TmuxWindow]) {
        // Phase 3 will implement: diff against current windowToWorkspace,
        // create new workspaces, remove closed ones, update layouts.
    }

    private func handleLayoutChange(windowId: Int, layoutJSON: Data) {
        // Phase 3: parse layout, diff against current, apply changes
    }

    private func handleWindowAdd(windowId: Int) {
        // Phase 3: create new workspace
    }

    private func handleWindowClose(windowId: Int) {
        // Phase 3: remove workspace
        windowToWorkspace.removeValue(forKey: windowId)
    }

    private func handleWindowRenamed(windowId: Int, name: String) {
        // Phase 7: update workspace title in sidebar
    }

    // MARK: - Output Routing

    /// Route pane output data to the correct virtual surface.
    /// Stub — full implementation in Phase 2 (Virtual Surface).
    func routeOutput(paneId: Int, data: Data) {
        // Phase 2 will implement: paneToClient[paneId]?.feedOutput(data)
    }

    // MARK: - Input Routing

    /// Send keystrokes to a tmux pane via the gateway.
    /// Stub — full implementation in Phase 4 (Input Routing).
    func sendKeys(_ data: Data, toPane paneId: Int) {
        // Phase 4 will implement: TmuxKeyEncoder.encode + gateway.sendCommand
    }

    // MARK: - Lifecycle

    /// Cleanly detach from the tmux session.
    func detach() {
        connectionState = .disconnecting
        gateway.sendCommand("detach\n")
    }

    /// Force disconnect without clean detach.
    func forceDisconnect() {
        teardown()
    }

    private func teardown() {
        connectionState = .disconnected

        unburyGatewayWorkspace()

        // Clean up entity maps
        paneToClient.removeAll()
        paneToPanelId.removeAll()
        windowToWorkspace.removeAll()

        gateway.reset()
        Self.activeControllers.removeValue(forKey: id)
    }

    // MARK: - Gateway Burial

    /// Hide the gateway workspace from the sidebar when tmux control mode enters.
    private func buryGatewayWorkspace() {
        guard let surface = gatewaySurface,
              let workspace = tabManager?.tabs.first(where: { $0.id == surface.tabId }) else {
            return
        }
        workspace.isBuriedGateway = true
    }

    /// Restore the gateway workspace to the sidebar when tmux disconnects.
    private func unburyGatewayWorkspace() {
        guard let surface = gatewaySurface,
              let workspace = tabManager?.tabs.first(where: { $0.id == surface.tabId }) else {
            return
        }
        workspace.isBuriedGateway = false
    }
}
