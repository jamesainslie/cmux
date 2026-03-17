import Foundation

/// Manages the tmux control mode (`-CC`) subprocess and routes I/O between
/// tmux panes and Ghostty terminal surfaces.
///
/// TmuxGateway is the central coordinator for session persistence via tmux.
/// It launches (or attaches to) a `tmux -L cmux` server in control mode,
/// parses protocol messages on stdout, and dispatches terminal output to
/// the appropriate Ghostty surfaces.
@MainActor
final class TmuxGateway: ObservableObject {

    // MARK: - Types

    enum State: Equatable, Sendable {
        case idle
        case starting
        case connected
        case disconnected(reason: String?)
        case unavailable(reason: String)
    }

    /// Pending command awaiting a %begin/%end/%error response sequence.
    private struct PendingCommand {
        let id: Int
        let command: String
        let responseLines: [String]
        let completion: @Sendable (Result<[String], TmuxError>) -> Void
    }

    enum TmuxError: Error, LocalizedError, Sendable {
        case notConnected
        case serverExited(reason: String?)
        case commandFailed(message: String)
        case binaryNotFound
        case timeout

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to tmux server"
            case .serverExited(let reason): return "tmux server exited: \(reason ?? "unknown")"
            case .commandFailed(let msg): return "tmux command failed: \(msg)"
            case .binaryNotFound: return "No suitable tmux binary found"
            case .timeout: return "tmux command timed out"
            }
        }
    }

    /// Delegate protocol for receiving tmux events.
    protocol Delegate: AnyObject, Sendable {
        /// Output data received from a tmux pane, ready to feed into a Ghostty surface.
        @MainActor func tmuxGateway(_ gateway: TmuxGateway, didReceiveOutput data: Data, forPaneId paneId: String)
        /// A new tmux window was created.
        @MainActor func tmuxGateway(_ gateway: TmuxGateway, windowAdded windowId: String)
        /// A tmux window was closed.
        @MainActor func tmuxGateway(_ gateway: TmuxGateway, windowClosed windowId: String)
        /// The tmux server exited.
        @MainActor func tmuxGatewayDidDisconnect(_ gateway: TmuxGateway, reason: String?)
        /// Pane entered or exited copy mode.
        @MainActor func tmuxGateway(_ gateway: TmuxGateway, paneModeChanged paneId: String)
    }

    // MARK: - Properties

    @Published private(set) var state: State = .idle

    weak var delegate: Delegate?

    let paneRegistry: TmuxPaneRegistry

    /// The resolved tmux binary path, or nil if unavailable.
    private(set) var tmuxBinaryPath: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

    /// Reader thread for stdout parsing.
    private var readerThread: Thread?

    /// Next command number for control mode command/response correlation.
    private var nextCommandNumber: Int = 0

    /// Commands awaiting response, keyed by command number.
    private var pendingCommands: [Int: PendingCommand] = [:]

    /// Accumulated response lines for the currently open %begin block.
    private var currentResponseCommandNumber: Int?
    private var currentResponseLines: [String] = []

    /// Socket name for the isolated tmux server.
    nonisolated static let socketName = "cmux"

    // MARK: - Init

    init(paneRegistry: TmuxPaneRegistry? = nil) {
        self.paneRegistry = paneRegistry ?? TmuxPaneRegistry()
    }

    // MARK: - Lifecycle

    /// Start or attach to the tmux server.
    ///
    /// If a tmux server is already running on the `cmux` socket, attaches as a new
    /// control mode client. Otherwise, starts a new server.
    func start() async throws {
        guard state == .idle || state == .disconnected(reason: nil) || {
            if case .disconnected = state { return true }
            return false
        }() else {
            return
        }

        state = .starting

        guard let resolution = TmuxBinaryResolver.resolve() else {
            state = .unavailable(reason: "No suitable tmux binary found (requires >= \(TmuxBinaryResolver.minimumVersion))")
            throw TmuxError.binaryNotFound
        }

        tmuxBinaryPath = resolution.path
        NSLog("[TmuxGateway] Using tmux \(resolution.version) from \(resolution.source): \(resolution.path)")

        let hasExistingServer = await checkServerRunning(at: resolution.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolution.path)

        if hasExistingServer {
            // Attach to existing server in control mode
            process.arguments = ["-L", Self.socketName, "-CC", "attach"]
        } else {
            // Start new server + session in control mode
            process.arguments = ["-L", Self.socketName, "-CC", "new-session", "-d", "-s", "cmux"]
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                let reason = proc.terminationStatus == 0 ? nil : "exit code \(proc.terminationStatus)"
                self.handleProcessTermination(reason: reason)
            }
        }

        do {
            try process.run()
        } catch {
            state = .unavailable(reason: "Failed to launch tmux: \(error.localizedDescription)")
            throw error
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe

        // Start reading stdout on a dedicated thread
        startReaderThread(fileHandle: stdoutPipe.fileHandleForReading)

        state = .connected
        NSLog("[TmuxGateway] Connected to tmux server (existing=\(hasExistingServer))")
    }

    /// Gracefully disconnect from the tmux server without killing it.
    /// The tmux server continues running, preserving all sessions.
    func detach() {
        guard state == .connected else { return }

        // Send detach command — don't wait for response
        sendRawCommand("detach-client")

        cleanupProcess()
        state = .disconnected(reason: "detached")
    }

    /// Kill the tmux server and clean up.
    func stop() {
        if state == .connected {
            sendRawCommand("kill-server")
        }
        cleanupProcess()
        paneRegistry.clear()
        state = .idle
    }

    // MARK: - Commands

    /// Create a new tmux window (single pane) and return its window/pane IDs.
    ///
    /// Each cmux terminal panel maps to a single tmux window with one pane.
    /// cmux handles all split layout — tmux just holds the PTYs.
    func createWindow(
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) async throws -> (windowId: String, paneId: String, ttyPath: String?) {
        var args = ["new-window", "-d", "-P", "-F", "#{window_id} #{pane_id} #{pane_tty}"]
        if let dir = workingDirectory {
            args.append(contentsOf: ["-c", dir])
        }

        let response = try await sendCommand(args.joined(separator: " "))
        guard let firstLine = response.first else {
            throw TmuxError.commandFailed(message: "No response from new-window")
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            throw TmuxError.commandFailed(message: "Unexpected new-window response: \(firstLine)")
        }

        let windowId = String(parts[0])
        let paneId = String(parts[1])
        let ttyPath = parts.count > 2 ? String(parts[2]) : nil

        return (windowId: windowId, paneId: paneId, ttyPath: ttyPath)
    }

    /// Kill a tmux window (and its pane).
    func killWindow(_ windowId: String) async throws {
        _ = try await sendCommand("kill-window -t \(windowId)")
    }

    /// Resize a tmux pane to the given terminal dimensions.
    func resizePane(_ paneId: String, columns: UInt16, rows: UInt16) {
        // Fire-and-forget: resize is async and non-critical
        sendRawCommand("resize-pane -t \(paneId) -x \(columns) -y \(rows)")
    }

    /// List all panes across all windows.
    func listPanes() async throws -> [(windowId: String, paneId: String, ttyPath: String)] {
        let response = try await sendCommand("list-panes -a -F '#{window_id} #{pane_id} #{pane_tty}'")

        return response.compactMap { line in
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            let parts = trimmed.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { return nil }
            return (
                windowId: String(parts[0]),
                paneId: String(parts[1]),
                ttyPath: String(parts[2])
            )
        }
    }

    /// Send keystrokes directly to a pane's TTY for minimal latency.
    ///
    /// This bypasses tmux's command parser entirely, writing directly to the
    /// PTY slave device. The pane's shell reads keystrokes as if they were
    /// typed on a physical terminal.
    func writeToTTY(_ data: Data, ttyPath: String) {
        guard !ttyPath.isEmpty else { return }

        // Direct TTY write on background queue to avoid blocking
        DispatchQueue.global(qos: .userInteractive).async {
            let fd = open(ttyPath, O_WRONLY | O_NONBLOCK)
            guard fd >= 0 else { return }
            defer { close(fd) }

            data.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress else { return }
                var written = 0
                let total = buffer.count
                while written < total {
                    let n = write(fd, ptr.advanced(by: written), total - written)
                    if n <= 0 { break }
                    written += n
                }
            }
        }
    }

    /// Send keystrokes to a pane via tmux send-keys (fallback when TTY path unavailable).
    func sendKeys(_ text: String, toPaneId paneId: String) {
        // Escape the text for tmux
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        sendRawCommand("send-keys -t \(paneId) -l \"\(escaped)\"")
    }

    // MARK: - Command Infrastructure

    /// Send a command and await its response (between %begin and %end).
    private func sendCommand(_ command: String) async throws -> [String] {
        guard state == .connected, let stdinPipe else {
            throw TmuxError.notConnected
        }

        let commandNumber = nextCommandNumber
        nextCommandNumber += 1

        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingCommand(
                id: commandNumber,
                command: command,
                responseLines: [],
                completion: { result in continuation.resume(with: result) }
            )
            pendingCommands[commandNumber] = pending

            let commandLine = "\(command)\n"
            stdinPipe.fileHandleForWriting.write(commandLine.data(using: .utf8)!)
        }
    }

    /// Send a command without waiting for response (fire-and-forget).
    private func sendRawCommand(_ command: String) {
        guard let stdinPipe, state == .connected else { return }
        let commandLine = "\(command)\n"
        stdinPipe.fileHandleForWriting.write(commandLine.data(using: .utf8)!)
    }

    // MARK: - Stdout Reader

    private func startReaderThread(fileHandle: FileHandle) {
        let thread = Thread { [weak self] in
            self?.readerLoop(fileHandle: fileHandle)
        }
        thread.name = "com.cmux.tmux-reader"
        thread.qualityOfService = .userInteractive
        readerThread = thread
        thread.start()
    }

    /// Read stdout line-by-line and dispatch parsed messages.
    ///
    /// Runs on a dedicated thread to avoid blocking the main actor.
    /// Dispatches to main queue for state mutations and delegate calls.
    nonisolated private func readerLoop(fileHandle: FileHandle) {
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while !Thread.current.isCancelled {
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty else {
                // EOF — pipe closed
                break
            }

            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                let message = TmuxProtocolParser.parseLine(line)

                DispatchQueue.main.async { [weak self] in
                    self?.handleMessage(message)
                }
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: TmuxMessage) {
        switch message {
        case .output(let paneId, let data):
            delegate?.tmuxGateway(self, didReceiveOutput: data, forPaneId: paneId)

        case .begin(let commandNumber):
            currentResponseCommandNumber = commandNumber
            currentResponseLines = []

        case .end(let commandNumber):
            if let pending = pendingCommands.removeValue(forKey: commandNumber) {
                pending.completion(.success(currentResponseLines))
            }
            currentResponseCommandNumber = nil
            currentResponseLines = []

        case .error(let commandNumber):
            if let pending = pendingCommands.removeValue(forKey: commandNumber) {
                let errorMessage = currentResponseLines.joined(separator: "\n")
                pending.completion(.failure(.commandFailed(message: errorMessage)))
            }
            currentResponseCommandNumber = nil
            currentResponseLines = []

        case .responseLine(let line):
            if currentResponseCommandNumber != nil {
                currentResponseLines.append(line)
            }

        case .windowAdd(let windowId):
            delegate?.tmuxGateway(self, windowAdded: windowId)

        case .windowClose(let windowId):
            delegate?.tmuxGateway(self, windowClosed: windowId)

        case .paneModeChanged(let paneId):
            delegate?.tmuxGateway(self, paneModeChanged: paneId)

        case .exit(let reason):
            NSLog("[TmuxGateway] Server exit: \(reason ?? "clean")")
            cleanupProcess()
            state = .disconnected(reason: reason)
            delegate?.tmuxGatewayDidDisconnect(self, reason: reason)

        case .windowRenamed, .sessionChanged, .sessionRenamed, .layoutChange,
             .unlinkedWindowAdd, .unlinkedWindowClose, .unknown:
            // Informational messages — log in debug but no action needed
            #if DEBUG
            NSLog("[TmuxGateway] Unhandled message: \(message)")
            #endif
        }
    }

    // MARK: - Server Detection

    /// Check if a tmux server is already running on the cmux socket.
    nonisolated private func checkServerRunning(at binaryPath: String) async -> Bool {
        let socketName = Self.socketName
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = ["-L", socketName, "list-sessions"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Cleanup

    private func handleProcessTermination(reason: String?) {
        guard state == .connected || state == .starting else { return }
        NSLog("[TmuxGateway] Process terminated: \(reason ?? "clean")")
        cleanupProcess()
        state = .disconnected(reason: reason)
        delegate?.tmuxGatewayDidDisconnect(self, reason: reason)
    }

    private func cleanupProcess() {
        readerThread?.cancel()
        readerThread = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil

        stdinPipe?.fileHandleForWriting.closeFile()
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.closeFile()
        stdoutPipe = nil

        // Fail all pending commands
        let pending = pendingCommands
        pendingCommands.removeAll()
        for (_, cmd) in pending {
            cmd.completion(.failure(.notConnected))
        }
        currentResponseCommandNumber = nil
        currentResponseLines = []
    }
}

// MARK: - Session Persistence Mode

/// The session persistence mode selected by the user.
enum SessionPersistenceMode: String, Sendable, CaseIterable {
    case none = "none"
    case tmux = "tmux"

    /// UserDefaults key for the persistence mode setting.
    static let defaultsKey = "sessionPersistenceMode"

    /// Read the current mode from UserDefaults.
    static var current: SessionPersistenceMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = SessionPersistenceMode(rawValue: raw) else {
            return .none
        }
        return mode
    }

    /// Whether tmux-backed session persistence is enabled.
    static var isTmuxEnabled: Bool {
        current == .tmux
    }

    var displayName: String {
        switch self {
        case .none:
            return String(localized: "settings.persistence.mode.none", defaultValue: "None (default)")
        case .tmux:
            return String(localized: "settings.persistence.mode.tmux", defaultValue: "tmux (persistent sessions)")
        }
    }
}
