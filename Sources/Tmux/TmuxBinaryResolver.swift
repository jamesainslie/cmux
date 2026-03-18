import Foundation

/// Resolves a suitable tmux binary for control mode integration.
///
/// Search order:
/// 1. System tmux from `$PATH` (version >= 3.2 required for stable control mode)
/// 2. Bundled tmux binary from app bundle `Resources/tmux`
/// 3. `nil` if no suitable binary found (feature unavailable)
enum TmuxBinaryResolver {

    /// Minimum tmux version required for reliable control mode support.
    static let minimumVersion = TmuxVersion(major: 3, minor: 2, suffix: nil)

    /// Result of resolving a tmux binary.
    struct Resolution: Sendable {
        let path: String
        let version: TmuxVersion
        let source: Source

        enum Source: String, Sendable {
            case system
            case bundled
        }
    }

    /// Attempt to find a usable tmux binary.
    /// Returns nil if no suitable binary is available.
    static func resolve() -> Resolution? {
        // 1. Check system PATH
        if let systemPath = findSystemTmux(),
           let version = queryVersion(at: systemPath),
           version >= minimumVersion {
            return Resolution(path: systemPath, version: version, source: .system)
        }

        // 2. Check bundled binary
        if let bundledPath = findBundledTmux(),
           let version = queryVersion(at: bundledPath),
           version >= minimumVersion {
            return Resolution(path: bundledPath, version: version, source: .bundled)
        }

        return nil
    }

    // MARK: - Private

    /// Well-known tmux install locations to check when `which` fails.
    /// macOS GUI apps get a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
    /// so Homebrew/MacPorts/Nix paths won't be found by `which`.
    private static let wellKnownPaths = [
        "/opt/homebrew/bin/tmux",     // Homebrew (Apple Silicon)
        "/usr/local/bin/tmux",        // Homebrew (Intel) / manual installs
        "/opt/local/bin/tmux",        // MacPorts
        "/run/current-system/sw/bin/tmux",  // NixOS
        "/nix/var/nix/profiles/default/bin/tmux",  // Nix single-user
    ]

    private static func findSystemTmux() -> String? {
        // 1. Try `which` first (works when PATH includes the binary)
        if let path = findViaWhich() {
            return path
        }

        // 2. Fall back to well-known paths (needed for GUI apps with minimal PATH)
        for path in wellKnownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func findViaWhich() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["tmux"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let path, !path.isEmpty else { return nil }

        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func findBundledTmux() -> String? {
        guard let bundlePath = Bundle.main.path(forResource: "tmux", ofType: nil) else {
            return nil
        }
        return FileManager.default.isExecutableFile(atPath: bundlePath) ? bundlePath : nil
    }

    /// Query `tmux -V` and parse the version string.
    static func queryVersion(at path: String) -> TmuxVersion? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-V"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        return TmuxVersion.parse(output)
    }
}

// MARK: - TmuxVersion

/// Semantic version for tmux (major.minor, with optional suffix like "a", "next-3.5").
struct TmuxVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let suffix: String?

    var description: String {
        var s = "\(major).\(minor)"
        if let suffix { s += suffix }
        return s
    }

    static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }

    /// Parse a version from `tmux -V` output.
    /// Handles formats like "tmux 3.4", "tmux 3.3a", "tmux next-3.5".
    static func parse(_ versionString: String) -> TmuxVersion? {
        let trimmed = versionString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to find a version number pattern like "3.4", "3.3a"
        // tmux -V outputs "tmux <version>" or "tmux next-<version>"
        let pattern = #"(\d+)\.(\d+)([a-z]*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ) else {
            return nil
        }

        guard let majorRange = Range(match.range(at: 1), in: trimmed),
              let minorRange = Range(match.range(at: 2), in: trimmed),
              let major = Int(trimmed[majorRange]),
              let minor = Int(trimmed[minorRange]) else {
            return nil
        }

        let suffixRange = Range(match.range(at: 3), in: trimmed)
        let suffix = suffixRange.flatMap { range in
            let s = String(trimmed[range])
            return s.isEmpty ? nil : s
        }

        return TmuxVersion(major: major, minor: minor, suffix: suffix)
    }
}
