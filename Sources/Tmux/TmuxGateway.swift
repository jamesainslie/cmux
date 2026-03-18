import Foundation
#if DEBUG
import Bonsplit
#endif

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
        /// Task that will fire the timeout. Cancelled when the command completes normally.
        var timeoutTask: Task<Void, Never>?
    }

    enum TmuxError: Error, LocalizedError, Sendable {
        case notConnected
        case serverExited(reason: String?)
        case commandFailed(message: String)
        case binaryNotFound
        case serverStartFailed
        case timeout

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to tmux server"
            case .serverExited(let reason): return "tmux server exited: \(reason ?? "unknown")"
            case .serverStartFailed: return "Failed to start tmux server"
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
        /// Initial content for a pane captured during setup (before live notifications begin).
        /// Called once per existing pane during `runInitialSetup()`.
        @MainActor func tmuxGateway(_ gateway: TmuxGateway, initialContent data: Data, forPaneId paneId: String)
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
    /// Primary (master) end of the PTY used for tmux control mode stdin.
    private var ptyPrimaryHandle: FileHandle?

    /// Reader thread for stdout parsing.
    private var readerThread: Thread?

    /// Commands awaiting response, in FIFO order.
    /// tmux assigns its own command numbers (not starting from 0 per-client),
    /// so we cannot use a keyed dictionary. Instead, we use a queue: the first
    /// `%begin` matches the first pending command, etc.
    private var pendingCommandQueue: [PendingCommand] = []

    /// Accumulated response lines for the currently open client-originated %begin block.
    private var currentResponseCommandNumber: Int?
    private var currentResponseLines: [String] = []

    /// Whether the current open %begin block is server-originated (flags & 1 == 0).
    /// Server-originated blocks are accumulated but NOT matched against pendingCommandQueue.
    private var currentBlockIsServerOriginated = false

    /// Monotonically increasing command ID for timeout correlation.
    private var nextCommandId = 1

    /// Controls whether notification-type messages (%output, %window-add, %window-close,
    /// %pane-mode-changed, %layout-change) are delivered to the delegate.
    ///
    /// Set to `false` during startup to prevent output from being delivered before surfaces
    /// exist. Set to `true` after the initial setup sequence (capture-pane) completes.
    /// This eliminates the need for the output buffer hack in AppDelegate.
    private var acceptNotifications = false

    /// Panes that existed at startup but haven't been claimed by any bindTmuxWindow call.
    /// The first bind can claim one instead of creating a new window.
    /// Thread-safe: only accessed on @MainActor.
    private(set) var unclaimedInitialPanes: [(windowId: String, paneId: String, ttyPath: String)] = []

    /// Claim the first unclaimed initial pane (if any) for reuse by bindTmuxWindow.
    func claimInitialPane() -> (windowId: String, paneId: String, ttyPath: String)? {
        guard !unclaimedInitialPanes.isEmpty else { return nil }
        return unclaimedInitialPanes.removeFirst()
    }

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
        #if DEBUG
        NSLog("tmux.gateway.start state=\(state)")
        #endif
        guard state == .idle || state == .disconnected(reason: nil) || {
            if case .disconnected = state { return true }
            return false
        }() else {
            #if DEBUG
            NSLog("tmux.gateway.start skipped, state=\(state)")
            #endif
            return
        }

        state = .starting

        guard let resolution = TmuxBinaryResolver.resolve() else {
            #if DEBUG
            NSLog("tmux.gateway.start no binary found")
            #endif
            state = .unavailable(reason: "No suitable tmux binary found (requires >= \(TmuxBinaryResolver.minimumVersion))")
            throw TmuxError.binaryNotFound
        }

        tmuxBinaryPath = resolution.path
        #if DEBUG
        NSLog("tmux.gateway.start resolved binary: \(resolution.path) v\(resolution.version) (\(resolution.source))")
        #endif
        NSLog("[TmuxGateway] Using tmux \(resolution.version) from \(resolution.source): \(resolution.path)")

        let hasExistingServer = await checkServerRunning(at: resolution.path)
        #if DEBUG
        NSLog("tmux.gateway.start existingServer=\(hasExistingServer)")
        #endif

        // If no existing server, bootstrap one on a background thread.
        // The three Process.run() + waitUntilExit() calls block, so they must
        // not run on the main thread.
        if !hasExistingServer {
            do {
                try await bootstrapServer(binaryPath: resolution.path)
            } catch {
                state = .unavailable(reason: "Failed to bootstrap tmux server: \(error.localizedDescription)")
                throw error
            }
        }

        // Allocate a PTY pair for the control mode client.
        // tmux -CC requires a real terminal (calls tcgetattr on stdin),
        // so we can't use bare pipes — we need a pseudo-terminal.
        var primary: Int32 = -1
        var secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
            state = .unavailable(reason: "Failed to allocate PTY for tmux control mode")
            throw TmuxError.serverStartFailed
        }

        // Configure PTY for raw I/O: disable echo (prevents our commands from being
        // echoed back to the reader) and disable output processing (prevents \r\n
        // conversion that adds spurious \r to tmux responses).
        var tio = termios()
        tcgetattr(secondary, &tio)
        cfmakeraw(&tio)
        tcsetattr(secondary, TCSANOW, &tio)

        let primaryHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        // Do NOT use closeOnDealloc for secondary — we close it explicitly in the
        // parent after process.run() so the slave has only one holder (the child).
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolution.path)
        process.arguments = ["-L", Self.socketName, "-CC", "attach"]

        // Override TERM so tmux doesn't fail with "missing or unsuitable terminal".
        // cmux runs inside ghostty which sets TERM=xterm-ghostty, but tmux requires
        // a terminfo entry it recognizes (xterm-256color is universally available).
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Strip Claude Code env vars so shells inside tmux panes don't trigger
        // the "nested session" error when the user runs `claude` inside a pane.
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = env

        #if DEBUG
        NSLog("tmux.gateway.start launching: \(resolution.path) \(process.arguments?.joined(separator: " ") ?? "")")
        #endif

        // Use the secondary (slave) end as both stdin AND stdout so tmux sees a
        // real TTY on all standard file descriptors. tmux -CC writes control mode
        // output to stdout, which goes through the PTY. We read responses from the
        // PTY master (primary) side.
        // stderr also uses the secondary PTY so tmux error messages flow through
        // the master and can be captured in debug logs if needed.
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        let stdoutPipe: Pipe? = nil  // We read from PTY master, not a pipe

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                let reason = proc.terminationStatus == 0 ? nil : "exit code \(proc.terminationStatus)"
                NSLog("[TmuxGateway] terminationStatus=\(proc.terminationStatus) reason=\(reason ?? "clean")")
                self.handleProcessTermination(reason: reason)
            }
        }

        do {
            try process.run()
        } catch {
            // Close both fds on launch failure. The secondary uses closeOnDealloc: false
            // so we must close it manually here; primaryHandle has closeOnDealloc: true.
            close(secondary)
            state = .unavailable(reason: "Failed to launch tmux: \(error.localizedDescription)")
            throw error
        }

        // CRITICAL: Close the parent's copy of the slave PTY after posix_spawn.
        // posix_spawn dup'd the fd into the child. If the parent keeps the slave
        // fd open, availableData on the master blocks forever even after tmux exits
        // (the slave has no writer, but the parent's open fd prevents POLLHUP/EOF).
        close(secondary)

        self.process = process
        self.stdinPipe = nil // We write commands via the primary PTY handle instead
        self.stdoutPipe = nil // Output comes through the PTY
        self.ptyPrimaryHandle = primaryHandle

        // Start reading from the PTY master side on a dedicated thread.
        // tmux -CC writes control mode output to its stdout, which flows through
        // the PTY slave → master path. We read it from the master handle.
        startReaderThread(fileHandle: primaryHandle)

        state = .connected
        NSLog("[TmuxGateway] Connected to tmux server (existing=\(hasExistingServer))")
    }

    /// Gracefully disconnect from the tmux server without killing it.
    /// The tmux server continues running, preserving all sessions.
    func detach() {
        guard state == .connected else { return }

        // Send detach command — enqueues in FIFO to prevent queue corruption
        sendFireAndForget("detach-client")

        cleanupProcess()
        state = .disconnected(reason: "detached")
    }

    /// Kill the tmux server and clean up.
    func stop() {
        if state == .connected {
            sendFireAndForget("kill-server")
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
        var args = ["new-window", "-d", "-P", "-F", "'#{window_id} #{pane_id} #{pane_tty}'"]
        if let dir = workingDirectory {
            args.append(contentsOf: ["-c", dir])
        }

        #if DEBUG
        dlog("tmux.gateway.createWindow sending: \(args.joined(separator: " "))")
        #endif
        let response = try await sendCommand(args.joined(separator: " "))
        #if DEBUG
        dlog("tmux.gateway.createWindow response: \(response)")
        #endif
        guard let firstLine = response.first else {
            throw TmuxError.commandFailed(message: "No response from new-window")
        }

        // Strip carriage returns (PTY may add \r) and single quotes (from -F format)
        let cleaned = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\r"))
        let parts = cleaned.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            throw TmuxError.commandFailed(message: "Unexpected new-window response: \(cleaned)")
        }

        let windowId = String(parts[0])
        let paneId = String(parts[1])
        let ttyPath = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) : nil

        #if DEBUG
        dlog("tmux.gateway.createWindow result: windowId=\(windowId) paneId=\(paneId) ttyPath=\(ttyPath ?? "nil")")
        #endif
        return (windowId: windowId, paneId: paneId, ttyPath: ttyPath)
    }

    /// Kill a tmux window (and its pane).
    func killWindow(_ windowId: String) async throws {
        _ = try await sendCommand("kill-window -t \(windowId)")
    }

    /// Resize a tmux pane to the given terminal dimensions.
    ///
    /// Uses fire-and-forget — the response is discarded but the FIFO queue stays
    /// in sync, preventing queue corruption from untracked %begin/%end pairs.
    func resizePane(_ paneId: String, columns: UInt16, rows: UInt16) {
        // Skip resize for placeholder pane IDs (before tmux binding resolves)
        guard paneId != "pending", paneId.hasPrefix("%") else { return }
        sendFireAndForget("resize-pane -t \(paneId) -x \(columns) -y \(rows)")
    }

    /// List all panes across all windows.
    func listPanes() async throws -> [(windowId: String, paneId: String, ttyPath: String)] {
        let response = try await sendCommand("list-panes -a -F '#{window_id} #{pane_id} #{pane_tty}'")

        return response.compactMap { line in
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "'\r"))
            let parts = trimmed.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { return nil }
            return (
                windowId: String(parts[0]),
                paneId: String(parts[1]),
                ttyPath: String(parts[2])
            )
        }
    }

    /// Run the initial setup sequence after connecting to tmux.
    ///
    /// 1. Discover existing panes via `list-panes`
    /// 2. Capture current screen content for each pane via `capture-pane -p -e`
    /// 3. Deliver captured content to the delegate
    /// 4. Enable live notification delivery (`acceptNotifications = true`)
    ///
    /// This must be called after surfaces are wired up (post-reconciliation) so that
    /// `initialContent` delegate calls find their target surfaces.
    func runInitialSetup() async {
        guard state == .connected else { return }

        #if DEBUG
        dlog("tmux.setup.start")
        #endif

        do {
            let panes = try await listPanes()
            #if DEBUG
            dlog("tmux.setup.panes count=\(panes.count)")
            #endif

            // All panes at startup are initially unclaimed. bindTmuxWindow calls
            // claimInitialPane() to reuse these instead of creating new windows.
            // This avoids creating extra panes during startup when session restore
            // timing causes the reconciliation to bind to dying panels.
            unclaimedInitialPanes = panes
            #if DEBUG
            dlog("tmux.setup.unclaimed count=\(unclaimedInitialPanes.count) panes=\(unclaimedInitialPanes.map(\.paneId))")
            #endif

            for pane in panes {
                do {
                    // capture-pane -t <paneId> -p -e: print pane contents with escape sequences
                    let lines = try await sendCommand("capture-pane -t \(pane.paneId) -p -e")
                    let content = lines.joined(separator: "\n")
                    if let data = content.data(using: .utf8), !data.isEmpty {
                        delegate?.tmuxGateway(self, initialContent: data, forPaneId: pane.paneId)
                        #if DEBUG
                        dlog("tmux.setup.capture paneId=\(pane.paneId) bytes=\(data.count)")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    dlog("tmux.setup.capture.error paneId=\(pane.paneId) error=\(error)")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            dlog("tmux.setup.listPanes.error error=\(error)")
            #endif
        }

        // NOW start delivering live notifications
        acceptNotifications = true
        #if DEBUG
        dlog("tmux.setup.complete acceptNotifications=true")
        #endif
    }

    /// Send keystrokes to a pane via `send-keys -H` (hex-encoded bytes).
    ///
    /// This bypasses all quoting and escaping issues by hex-encoding the raw
    /// bytes. tmux decodes them and writes directly to the pane's PTY master.
    /// Focus events (CSI I/O) from Ghostty are stripped — tmux handles its own
    /// focus reporting.
    ///
    /// Uses fire-and-forget to avoid per-keystroke Task creation and continuation
    /// overhead. The response is discarded but the FIFO queue stays in sync.
    func sendKeys(_ data: Data, toPaneId paneId: String) {
        guard !data.isEmpty, paneId != "pending", paneId.hasPrefix("%") else { return }

        // Strip Ghostty focus events (ESC [ I = focus in, ESC [ O = focus out)
        let bytes = Array(data)
        var filtered = [UInt8]()
        filtered.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B && i + 2 < bytes.count && bytes[i + 1] == 0x5B
                && (bytes[i + 2] == 0x49 || bytes[i + 2] == 0x4F) {
                i += 3; continue
            }
            filtered.append(bytes[i])
            i += 1
        }
        guard !filtered.isEmpty else { return }

        let hex = filtered.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendFireAndForget("send-keys -t \(paneId) -H \(hex)")
    }

    // MARK: - Command Infrastructure

    /// Write a command string to the tmux control mode input (PTY or pipe).
    private func writeCommand(_ commandLine: String) {
        guard let data = commandLine.data(using: .utf8) else { return }
        if let ptyHandle = ptyPrimaryHandle {
            ptyHandle.write(data)
        } else if let stdinPipe {
            stdinPipe.fileHandleForWriting.write(data)
        }
    }

    /// Send a command and await its response (between %begin and %end).
    private func sendCommand(_ command: String) async throws -> [String] {
        guard state == .connected, (ptyPrimaryHandle != nil || stdinPipe != nil) else {
            #if DEBUG
            dlog("tmux.gateway.sendCommand rejected: not connected state=\(state)")
            #endif
            throw TmuxError.notConnected
        }

        #if DEBUG
        dlog("tmux.gateway.sendCommand: \(command)")
        #endif

        let cmdId = nextCommandId
        nextCommandId += 1

        return try await withCheckedThrowingContinuation { continuation in
            var pending = PendingCommand(
                id: cmdId,
                command: command,
                responseLines: [],
                completion: { result in
                    #if DEBUG
                    switch result {
                    case .success(let lines):
                        dlog("tmux.gateway.command.ok cmd=\(command.prefix(40)) lines=\(lines.count)")
                    case .failure(let error):
                        dlog("tmux.gateway.command.fail cmd=\(command.prefix(40)) error=\(error)")
                    }
                    #endif
                    continuation.resume(with: result)
                }
            )

            // Schedule a 5-second timeout. If the command hasn't completed by then,
            // remove it from the queue and fail with .timeout.
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let idx = self.pendingCommandQueue.firstIndex(where: { $0.id == cmdId }) {
                    let cmd = self.pendingCommandQueue.remove(at: idx)
                    #if DEBUG
                    dlog("tmux.gateway.command.timeout cmdId=\(cmdId) cmd=\(command.prefix(40))")
                    #endif
                    cmd.completion(.failure(.timeout))
                }
            }
            pending.timeoutTask = timeoutTask

            pendingCommandQueue.append(pending)
            writeCommand("\(command)\n")
        }
    }

    /// Send a command without waiting for response (fire-and-forget).
    ///
    /// Unlike the old `sendRawCommand`, this still enqueues a PendingCommand with a
    /// no-op completion, keeping the FIFO queue in sync with tmux's %begin/%end pairs.
    /// This prevents untracked responses from corrupting the command queue.
    private func sendFireAndForget(_ command: String) {
        guard state == .connected else { return }
        let pending = PendingCommand(
            id: 0,
            command: command,
            responseLines: [],
            completion: { _ in } // no-op
        )
        pendingCommandQueue.append(pending)
        writeCommand("\(command)\n")
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
        #if DEBUG
        dlog("tmux.reader started")
        #endif

        while !Thread.current.isCancelled {
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty else {
                // EOF — pipe closed
                #if DEBUG
                dlog("tmux.reader EOF")
                #endif
                break
            }

            buffer.append(chunk)
            #if DEBUG
            dlog("tmux.reader chunk=\(chunk.count) bufferTotal=\(buffer.count)")
            #endif

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard var line = String(data: lineData, encoding: .utf8) else { continue }

                // Strip \r that may be added by PTY line discipline (ONLCR: \n → \r\n)
                if line.hasSuffix("\r") {
                    line = String(line.dropLast())
                }

                // Strip DCS prefix from the initial tmux control mode handshake.
                // tmux sends \x1bP1000p (ESC P <params> p) before the first %begin.
                // Without stripping, the parser won't recognize %begin.
                if line.first == "\u{1B}" || line.hasPrefix("P"),
                   let pctIdx = line.firstIndex(of: "%") {
                    line = String(line[pctIdx...])
                }

                #if DEBUG
                dlog("tmux.reader line: \(line.prefix(120))")
                #endif
                let message = TmuxProtocolParser.parseLine(line)

                DispatchQueue.main.async { [weak self] in
                    self?.handleMessage(message)
                }
            }
        }
        #if DEBUG
        dlog("tmux.reader exited")
        #endif
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: TmuxMessage) {
        #if DEBUG
        switch message {
        case .output(let paneId, let data):
            dlog("tmux.msg output paneId=\(paneId) bytes=\(data.count)")
        case .begin(let n, let f):
            dlog("tmux.msg begin #\(n) flags=\(f) pendingQueue=\(pendingCommandQueue.count)")
        case .end(let n, let f):
            dlog("tmux.msg end #\(n) flags=\(f) pendingQueue=\(pendingCommandQueue.count)")
        case .error(let n, let f):
            dlog("tmux.msg error #\(n) flags=\(f) pendingQueue=\(pendingCommandQueue.count)")
        default:
            dlog("tmux.msg \(message)")
        }
        #endif
        switch message {
        case .output(let paneId, let data):
            guard acceptNotifications else {
                #if DEBUG
                dlog("tmux.msg output GATED paneId=\(paneId) bytes=\(data.count)")
                #endif
                break
            }
            delegate?.tmuxGateway(self, didReceiveOutput: data, forPaneId: paneId)

        case .begin(let commandNumber, let flags):
            let isServerOriginated = (flags & 1) == 0
            currentResponseCommandNumber = commandNumber
            currentResponseLines = []
            currentBlockIsServerOriginated = isServerOriginated
            #if DEBUG
            if isServerOriginated {
                dlog("tmux.msg server-originated begin #\(commandNumber), will not drain queue")
            }
            #endif

        case .end:
            guard currentResponseCommandNumber != nil else {
                #if DEBUG
                dlog("tmux.msg end without active begin block, ignoring")
                #endif
                break
            }
            // Only drain the pending command queue for client-originated responses
            if !currentBlockIsServerOriginated {
                if !pendingCommandQueue.isEmpty {
                    let pending = pendingCommandQueue.removeFirst()
                    pending.timeoutTask?.cancel()
                    pending.completion(.success(currentResponseLines))
                }
            } else {
                #if DEBUG
                dlog("tmux.msg server-originated end, response discarded (\(currentResponseLines.count) lines)")
                #endif
            }
            currentResponseCommandNumber = nil
            currentResponseLines = []
            currentBlockIsServerOriginated = false

        case .error:
            guard currentResponseCommandNumber != nil else {
                #if DEBUG
                dlog("tmux.msg error without active begin block, ignoring")
                #endif
                break
            }
            if !currentBlockIsServerOriginated {
                if !pendingCommandQueue.isEmpty {
                    let pending = pendingCommandQueue.removeFirst()
                    pending.timeoutTask?.cancel()
                    let errorMessage = currentResponseLines.joined(separator: "\n")
                    pending.completion(.failure(.commandFailed(message: errorMessage)))
                }
            } else {
                #if DEBUG
                dlog("tmux.msg server-originated error, discarded (\(currentResponseLines.count) lines)")
                #endif
            }
            currentResponseCommandNumber = nil
            currentResponseLines = []
            currentBlockIsServerOriginated = false

        case .responseLine(let line):
            if currentResponseCommandNumber != nil {
                currentResponseLines.append(line)
            }

        case .windowAdd(let windowId):
            guard acceptNotifications else {
                #if DEBUG
                dlog("tmux.msg windowAdd GATED windowId=\(windowId)")
                #endif
                break
            }
            delegate?.tmuxGateway(self, windowAdded: windowId)

        case .windowClose(let windowId):
            guard acceptNotifications else {
                #if DEBUG
                dlog("tmux.msg windowClose GATED windowId=\(windowId)")
                #endif
                break
            }
            delegate?.tmuxGateway(self, windowClosed: windowId)

        case .paneModeChanged(let paneId):
            guard acceptNotifications else {
                #if DEBUG
                dlog("tmux.msg paneModeChanged GATED paneId=\(paneId)")
                #endif
                break
            }
            delegate?.tmuxGateway(self, paneModeChanged: paneId)

        case .exit(let reason):
            #if DEBUG
            NSLog("[TmuxGateway] Server exit: \(reason ?? "clean")")
            #endif
            cleanupProcess()
            state = .disconnected(reason: reason)
            delegate?.tmuxGatewayDidDisconnect(self, reason: reason)

        case .windowRenamed, .sessionChanged, .sessionRenamed, .layoutChange,
             .unlinkedWindowAdd, .unlinkedWindowClose, .unknown:
            #if DEBUG
            NSLog("[TmuxGateway] Unhandled message: \(message)")
            #endif
        }
    }

    // MARK: - Server Bootstrap

    /// Start a new tmux server and create a session, off the main thread.
    ///
    /// Runs three blocking Process calls (start-server, set-option, new-session)
    /// on a background dispatch queue to avoid blocking the main thread.
    nonisolated private func bootstrapServer(binaryPath: String) async throws {
        let socketName = Self.socketName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Remove stale socket if it exists
                    let uid = getuid()
                    let socketPath = "/tmp/tmux-\(uid)/\(socketName)"
                    if FileManager.default.fileExists(atPath: socketPath) {
                        #if DEBUG
                        NSLog("[TmuxGateway] removing stale socket: \(socketPath)")
                        #endif
                        try? FileManager.default.removeItem(atPath: socketPath)
                    }

                    // Clean env: strip Claude Code markers
                    var cleanEnv = ProcessInfo.processInfo.environment
                    cleanEnv.removeValue(forKey: "CLAUDECODE")
                    cleanEnv.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")

                    // 1. start-server
                    let startProcess = Process()
                    startProcess.executableURL = URL(fileURLWithPath: binaryPath)
                    startProcess.arguments = ["-L", socketName, "start-server"]
                    startProcess.standardOutput = FileHandle.nullDevice
                    startProcess.standardError = FileHandle.nullDevice
                    startProcess.environment = cleanEnv
                    try startProcess.run()
                    startProcess.waitUntilExit()
                    #if DEBUG
                    NSLog("[TmuxGateway] start-server exit=\(startProcess.terminationStatus)")
                    #endif

                    // 2. set default-shell
                    let userShell = cleanEnv["SHELL"] ?? "/bin/zsh"
                    let setShellProcess = Process()
                    setShellProcess.executableURL = URL(fileURLWithPath: binaryPath)
                    setShellProcess.arguments = ["-L", socketName, "set-option", "-g", "default-shell", userShell]
                    setShellProcess.standardOutput = FileHandle.nullDevice
                    setShellProcess.standardError = FileHandle.nullDevice
                    setShellProcess.environment = cleanEnv
                    try setShellProcess.run()
                    setShellProcess.waitUntilExit()
                    #if DEBUG
                    NSLog("[TmuxGateway] set default-shell=\(userShell) exit=\(setShellProcess.terminationStatus)")
                    #endif

                    // 3. new-session
                    let newSessionProcess = Process()
                    newSessionProcess.executableURL = URL(fileURLWithPath: binaryPath)
                    newSessionProcess.arguments = ["-L", socketName, "new-session", "-d", "-s", "cmux"]
                    newSessionProcess.environment = cleanEnv
                    let sessionStderrPipe = Pipe()
                    newSessionProcess.standardOutput = FileHandle.nullDevice
                    newSessionProcess.standardError = sessionStderrPipe
                    try newSessionProcess.run()
                    newSessionProcess.waitUntilExit()

                    let stderrData = sessionStderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                    #if DEBUG
                    NSLog("[TmuxGateway] new-session exit=\(newSessionProcess.terminationStatus) stderr=\(stderrStr)")
                    #endif

                    guard newSessionProcess.terminationStatus == 0 else {
                        let reason = "Failed to create tmux session (exit \(newSessionProcess.terminationStatus)): \(stderrStr)"
                        continuation.resume(throwing: TmuxError.serverStartFailed)
                        return
                    }
                    #if DEBUG
                    NSLog("[TmuxGateway] created server and session")
                    #endif
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
        ptyPrimaryHandle?.closeFile()
        ptyPrimaryHandle = nil

        // Fail all pending commands and cancel their timeouts
        let pending = pendingCommandQueue
        pendingCommandQueue.removeAll()
        for cmd in pending {
            cmd.timeoutTask?.cancel()
            cmd.completion(.failure(TmuxError.notConnected))
        }
        currentResponseCommandNumber = nil
        currentResponseLines = []
        currentBlockIsServerOriginated = false
        acceptNotifications = false
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
