import Foundation

/// Parsed tmux control mode protocol messages.
///
/// tmux control mode sends line-based messages on stdout, each prefixed with `%`.
/// See `tmux(1)` CONTROL MODE section for the full protocol specification.
enum TmuxMessage: Equatable, Sendable {
    /// `%output %<pane-id> <base64-encoded-data>`
    /// Terminal output from a pane, base64-encoded.
    case output(paneId: String, data: Data)

    /// `%begin <time> <command-number> <flags>`
    /// Start of a command response block.
    case begin(commandNumber: Int)

    /// `%end <time> <command-number> <flags>`
    /// Successful end of a command response block.
    case end(commandNumber: Int)

    /// `%error <time> <command-number> <flags>`
    /// Error end of a command response block. The response lines between %begin and %error
    /// contain the error message.
    case error(commandNumber: Int)

    /// `%window-add @<window-id>`
    case windowAdd(windowId: String)

    /// `%window-close @<window-id>`
    case windowClose(windowId: String)

    /// `%window-renamed @<window-id> <new-name>`
    case windowRenamed(windowId: String, name: String)

    /// `%session-changed $<session-id> <session-name>`
    case sessionChanged(sessionId: String, name: String)

    /// `%session-renamed <new-name>`
    case sessionRenamed(name: String)

    /// `%pane-mode-changed %<pane-id>`
    case paneModeChanged(paneId: String)

    /// `%exit [reason]`
    /// The tmux server or client is exiting.
    case exit(reason: String?)

    /// `%layout-change @<window-id> <layout> @<window-flags>`
    case layoutChange(windowId: String, layout: String)

    /// `%unlinked-window-add @<window-id>`
    case unlinkedWindowAdd(windowId: String)

    /// `%unlinked-window-close @<window-id>`
    case unlinkedWindowClose(windowId: String)

    /// A line that is part of a command response (between %begin and %end/%error).
    /// Not a `%`-prefixed message — just a plain response line.
    case responseLine(String)

    /// A line that could not be parsed as any known message type.
    case unknown(String)
}

/// Stateless parser for individual tmux control mode protocol lines.
///
/// Each line from tmux control mode stdout is parsed independently.
/// Command response accumulation (between %begin and %end) is handled
/// by the caller (TmuxGateway).
enum TmuxProtocolParser {

    /// Parse a single line from tmux control mode stdout.
    ///
    /// Lines starting with `%` are protocol messages. Other lines are
    /// command response data (emitted between `%begin` and `%end`/`%error`).
    static func parseLine(_ line: String) -> TmuxMessage {
        guard line.hasPrefix("%") else {
            return .responseLine(line)
        }

        // Split on first space to get the message type
        let scanner = LineScanner(line)
        guard let messageType = scanner.nextToken() else {
            return .unknown(line)
        }

        switch messageType {
        case "%output":
            return parseOutput(scanner, line: line)
        case "%begin":
            return parseCommandFrame(scanner, kind: .begin, line: line)
        case "%end":
            return parseCommandFrame(scanner, kind: .end, line: line)
        case "%error":
            return parseCommandFrame(scanner, kind: .error, line: line)
        case "%window-add":
            return parseWindowEvent(scanner, kind: .add, line: line)
        case "%window-close":
            return parseWindowEvent(scanner, kind: .close, line: line)
        case "%window-renamed":
            return parseWindowRenamed(scanner, line: line)
        case "%unlinked-window-add":
            return parseWindowEvent(scanner, kind: .unlinkedAdd, line: line)
        case "%unlinked-window-close":
            return parseWindowEvent(scanner, kind: .unlinkedClose, line: line)
        case "%session-changed":
            return parseSessionChanged(scanner, line: line)
        case "%session-renamed":
            if let name = scanner.rest()?.trimmingCharacters(in: .whitespaces) {
                return .sessionRenamed(name: name)
            }
            return .unknown(line)
        case "%pane-mode-changed":
            if let paneId = scanner.nextToken() {
                return .paneModeChanged(paneId: paneId)
            }
            return .unknown(line)
        case "%exit":
            let reason = scanner.rest()?.trimmingCharacters(in: .whitespaces)
            return .exit(reason: reason?.isEmpty == true ? nil : reason)
        case "%layout-change":
            return parseLayoutChange(scanner, line: line)
        default:
            return .unknown(line)
        }
    }

    // MARK: - Private Parsers

    private static func parseOutput(_ scanner: LineScanner, line: String) -> TmuxMessage {
        // %output %<pane-id> <base64-encoded-data>
        guard let paneId = scanner.nextToken() else {
            return .unknown(line)
        }
        guard let base64String = scanner.rest() else {
            return .unknown(line)
        }

        guard let data = Data(base64Encoded: base64String) else {
            return .unknown(line)
        }

        return .output(paneId: paneId, data: data)
    }

    private enum CommandFrameKind {
        case begin, end, error
    }

    private static func parseCommandFrame(
        _ scanner: LineScanner,
        kind: CommandFrameKind,
        line: String
    ) -> TmuxMessage {
        // %begin <time> <command-number> <flags>
        // %end <time> <command-number> <flags>
        // %error <time> <command-number> <flags>
        guard let _ = scanner.nextToken() else { // time
            return .unknown(line)
        }
        guard let cmdNumStr = scanner.nextToken(),
              let cmdNum = Int(cmdNumStr) else {
            return .unknown(line)
        }

        switch kind {
        case .begin: return .begin(commandNumber: cmdNum)
        case .end: return .end(commandNumber: cmdNum)
        case .error: return .error(commandNumber: cmdNum)
        }
    }

    private enum WindowEventKind {
        case add, close, unlinkedAdd, unlinkedClose
    }

    private static func parseWindowEvent(
        _ scanner: LineScanner,
        kind: WindowEventKind,
        line: String
    ) -> TmuxMessage {
        guard let windowId = scanner.nextToken() else {
            return .unknown(line)
        }
        switch kind {
        case .add: return .windowAdd(windowId: windowId)
        case .close: return .windowClose(windowId: windowId)
        case .unlinkedAdd: return .unlinkedWindowAdd(windowId: windowId)
        case .unlinkedClose: return .unlinkedWindowClose(windowId: windowId)
        }
    }

    private static func parseWindowRenamed(_ scanner: LineScanner, line: String) -> TmuxMessage {
        guard let windowId = scanner.nextToken() else {
            return .unknown(line)
        }
        let name = scanner.rest()?.trimmingCharacters(in: .whitespaces) ?? ""
        return .windowRenamed(windowId: windowId, name: name)
    }

    private static func parseSessionChanged(_ scanner: LineScanner, line: String) -> TmuxMessage {
        guard let sessionId = scanner.nextToken() else {
            return .unknown(line)
        }
        let name = scanner.rest()?.trimmingCharacters(in: .whitespaces) ?? ""
        return .sessionChanged(sessionId: sessionId, name: name)
    }

    private static func parseLayoutChange(_ scanner: LineScanner, line: String) -> TmuxMessage {
        guard let windowId = scanner.nextToken() else {
            return .unknown(line)
        }
        let layout = scanner.nextToken() ?? ""
        return .layoutChange(windowId: windowId, layout: layout)
    }
}

// MARK: - Line Scanner

/// Simple token scanner for splitting a line by whitespace.
private final class LineScanner {
    private let line: String
    private var currentIndex: String.Index

    init(_ line: String) {
        self.line = line
        self.currentIndex = line.startIndex
    }

    /// Consume and return the next whitespace-delimited token, or nil if exhausted.
    func nextToken() -> String? {
        // Skip leading whitespace
        while currentIndex < line.endIndex && line[currentIndex].isWhitespace {
            currentIndex = line.index(after: currentIndex)
        }
        guard currentIndex < line.endIndex else { return nil }

        let start = currentIndex
        while currentIndex < line.endIndex && !line[currentIndex].isWhitespace {
            currentIndex = line.index(after: currentIndex)
        }
        return String(line[start..<currentIndex])
    }

    /// Return the rest of the line from the current position (after skipping leading whitespace),
    /// or nil if exhausted.
    func rest() -> String? {
        // Skip leading whitespace
        while currentIndex < line.endIndex && line[currentIndex].isWhitespace {
            currentIndex = line.index(after: currentIndex)
        }
        guard currentIndex < line.endIndex else { return nil }

        let result = String(line[currentIndex...])
        currentIndex = line.endIndex
        return result
    }
}
