import Foundation

/// Parsed tmux control mode protocol messages.
///
/// tmux control mode sends line-based messages on stdout, each prefixed with `%`.
/// See `tmux(1)` CONTROL MODE section for the full protocol specification.
enum TmuxMessage: Equatable, Sendable {
    /// `%output %<pane-id> <octal-escaped-data>`
    /// Terminal output from a pane, with octal-escaped bytes (e.g. `\033` for ESC).
    case output(paneId: String, data: Data)

    /// `%begin <time> <command-number> <flags>`
    /// Start of a command response block.
    /// flags & 1 == 0 → server-originated (e.g. initial handshake)
    /// flags & 1 != 0 → client-originated (response to a command we sent)
    case begin(commandNumber: Int, flags: Int)

    /// `%end <time> <command-number> <flags>`
    /// Successful end of a command response block.
    case end(commandNumber: Int, flags: Int)

    /// `%error <time> <command-number> <flags>`
    /// Error end of a command response block. The response lines between %begin and %error
    /// contain the error message.
    case error(commandNumber: Int, flags: Int)

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
        // %output %<pane-id> <octal-escaped-data>
        // tmux 3.x sends octal-escaped bytes: \033 for ESC, \015 for CR, \\ for literal backslash
        guard let paneId = scanner.nextToken() else {
            return .unknown(line)
        }
        guard let escapedString = scanner.rest() else {
            // Empty output is valid (e.g., cursor movement with no visible chars)
            return .output(paneId: paneId, data: Data())
        }

        let data = unescapeOctal(escapedString)
        return .output(paneId: paneId, data: data)
    }

    /// Unescape tmux octal-encoded output data.
    ///
    /// tmux control mode encodes non-printable bytes as `\NNN` (3-digit octal)
    /// and literal backslashes as `\\`. All other bytes pass through unchanged.
    static func unescapeOctal(_ input: String) -> Data {
        var result = Data()
        result.reserveCapacity(input.utf8.count)

        // Use an array + index for lookahead without consuming from iterator
        let bytes = Array(input.utf8)
        var i = 0

        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "\\") && i + 1 < bytes.count {
                let next = bytes[i + 1]

                if next == UInt8(ascii: "\\") {
                    // Escaped backslash: \\ → single backslash
                    result.append(UInt8(ascii: "\\"))
                    i += 2
                } else if next >= UInt8(ascii: "0") && next <= UInt8(ascii: "7") {
                    // Octal sequence: expect exactly 3 digits (\NNN) from tmux
                    var octalValue = UInt8(next - UInt8(ascii: "0"))
                    var consumed = 2 // backslash + first digit

                    if i + 2 < bytes.count {
                        let d2 = bytes[i + 2]
                        if d2 >= UInt8(ascii: "0") && d2 <= UInt8(ascii: "7") {
                            octalValue = octalValue &* 8 &+ (d2 - UInt8(ascii: "0"))
                            consumed = 3

                            if i + 3 < bytes.count {
                                let d3 = bytes[i + 3]
                                if d3 >= UInt8(ascii: "0") && d3 <= UInt8(ascii: "7") {
                                    octalValue = octalValue &* 8 &+ (d3 - UInt8(ascii: "0"))
                                    consumed = 4
                                }
                            }
                        }
                    }

                    result.append(octalValue)
                    i += consumed
                } else {
                    // Unknown escape — emit both chars as-is
                    result.append(byte)
                    result.append(next)
                    i += 2
                }
            } else {
                result.append(byte)
                i += 1
            }
        }

        return result
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

        // Parse optional flags field (default to 1 = client-originated for backwards compat)
        let flagsStr = scanner.nextToken()
        let flags = flagsStr.flatMap { Int($0) } ?? 1

        switch kind {
        case .begin: return .begin(commandNumber: cmdNum, flags: flags)
        case .end: return .end(commandNumber: cmdNum, flags: flags)
        case .error: return .error(commandNumber: cmdNum, flags: flags)
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
