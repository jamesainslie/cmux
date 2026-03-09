import Foundation
import Darwin

final class LifecycleUITestSocketClient {
    private let path: String

    private static let readinessAttempts = 12
    private static let readinessDelay: TimeInterval = 0.1
    private static let mutatingAttempts = 4
    private static let mutatingRetryDelay: TimeInterval = 0.1
    private static let responseTimeout: TimeInterval = 4.0

    init(path: String) {
        self.path = path
    }

    func call(method: String, params: [String: Any] = [:]) -> [String: Any]? {
        if method != "system.ping" {
            _ = warmSocket()
        }

        let attempts = method == "system.ping" ? 1 : Self.mutatingAttempts
        var lastResponse: [String: Any]?
        for attempt in 0..<attempts {
            let response = callOnce(method: method, params: params)
            lastResponse = response
            if !shouldRetry(response: response, method: method) {
                return response
            }
            if attempt + 1 < attempts {
                Thread.sleep(forTimeInterval: Self.mutatingRetryDelay)
            }
        }
        return lastResponse
    }

    private func warmSocket() -> Bool {
        for _ in 0..<Self.readinessAttempts {
            let response = callOnce(method: "system.ping", params: [:])
            if let result = response["result"] as? [String: Any],
               result["pong"] as? Bool == true {
                return true
            }
            Thread.sleep(forTimeInterval: Self.readinessDelay)
        }
        return false
    }

    private func shouldRetry(response: [String: Any]?, method: String) -> Bool {
        guard method != "system.ping" else { return false }
        guard let response else { return true }
        return response["_transportFailure"] as? Bool == true
    }

    private func callOnce(method: String, params: [String: Any]) -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return transportFailure(method: method, stage: "socket", detail: errnoDescription("socket"))
        }
        defer { close(fd) }

#if os(macOS)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
#endif

        setTimeout(fd: fd, option: SO_RCVTIMEO, timeout: Self.responseTimeout)
        setTimeout(fd: fd, option: SO_SNDTIMEO, timeout: 1.0)

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= maxLen else {
            return transportFailure(method: method, stage: "path", detail: "socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for (index, byte) in bytes.enumerated() {
                raw[index] = byte
            }
        }

        let sunPathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        let addrLen = socklen_t(sunPathOffset + bytes.count)
#if os(macOS)
        addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addrLen)
            }
        }
        guard connected == 0 else {
            let directFailure = errnoDescription("connect")
            if let cliFallback = callOnceViaBundledCLI(method: method, params: params) {
                return cliFallback
            }
            if let fallback = callOnceViaNetcat(method: method, params: params) {
                return fallback
            }
            return transportFailure(
                method: method,
                stage: "connect",
                detail: "\(directFailure); bundled CLI and netcat fallbacks unavailable"
            )
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return transportFailure(method: method, stage: "encode", detail: "invalid JSON payload")
        }

        var packet = Data()
        packet.append(data)
        packet.append(0x0A)
        guard sendAll(fd: fd, data: packet) else {
            return transportFailure(method: method, stage: "send", detail: errnoDescription("send"))
        }

        return readResponse(fd: fd, method: method)
    }

    private func setTimeout(fd: Int32, option: Int32, timeout: TimeInterval) {
        let wholeSeconds = Int(timeout)
        let microseconds = Int32((timeout - TimeInterval(wholeSeconds)) * 1_000_000)
        var value = timeval(tv_sec: wholeSeconds, tv_usec: microseconds)
        _ = withUnsafePointer(to: &value) { ptr in
            setsockopt(fd, SOL_SOCKET, option, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private func sendAll(fd: Int32, data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            while sent < rawBuffer.count {
                let wrote = send(fd, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
                if wrote <= 0 { return false }
                sent += wrote
            }
            return true
        }
    }

    private func readResponse(fd: Int32, method: String) -> [String: Any] {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(Self.responseTimeout)

        while Date() < deadline {
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollTimeoutMs = Int32(max(1, min(250, Int((deadline.timeIntervalSinceNow) * 1000.0))))
            let pollResult = poll(&pollDescriptor, 1, pollTimeoutMs)
            if pollResult == 0 {
                continue
            }
            if pollResult < 0 {
                return transportFailure(method: method, stage: "read", detail: errnoDescription("poll"))
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let readCount = recv(fd, &chunk, chunk.count, 0)
            if readCount > 0 {
                buffer.append(chunk, count: Int(readCount))
                if buffer.contains(0x0A) {
                    break
                }
                continue
            }

            if readCount == 0 {
                if buffer.isEmpty {
                    return transportFailure(method: method, stage: "read", detail: "EOF before response")
                }
                break
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            return transportFailure(method: method, stage: "read", detail: errnoDescription("recv"))
        }

        guard !buffer.isEmpty else {
            return transportFailure(method: method, stage: "read", detail: "timeout waiting for response")
        }

        guard let text = String(data: buffer, encoding: .utf8),
              let line = text.split(separator: "\n", maxSplits: 1).first else {
            return transportFailure(
                method: method,
                stage: "decode",
                detail: "non-UTF8 or empty response: \(preview(buffer))"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return transportFailure(
                method: method,
                stage: "decode",
                detail: "invalid JSON line: \(String(line.prefix(200)))"
            )
        }

        return json
    }

    private func callOnceViaNetcat(method: String, params: [String: Any]) -> [String: Any]? {
        let netcatPath = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: netcatPath) else {
            return nil
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: netcatPath)
        process.arguments = ["-U", path, "-w", "2"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        if let payloadData = (text + "\n").data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(payloadData)
        }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !outputData.isEmpty,
              let output = String(data: outputData, encoding: .utf8),
              let line = output.split(separator: "\n", maxSplits: 1).first,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func callOnceViaBundledCLI(method: String, params: [String: Any]) -> [String: Any]? {
        guard let cliPath = resolveBundledCLIPath(),
              let paramsData = try? JSONSerialization.data(withJSONObject: params),
              let paramsJSON = String(data: paramsData, encoding: .utf8) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "--socket", path,
            "v2-call", method,
            "--params-json", paramsJSON,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = String(Self.responseTimeout)
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !outputData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func resolveBundledCLIPath() -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CMUX_UI_TEST_CLI_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(override)
        }

        if let builtProductsDir = environment["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            candidates.append(contentsOf: bundledCLICandidates(under: URL(fileURLWithPath: builtProductsDir)))
        }

        if let testHost = environment["TEST_HOST"], !testHost.isEmpty {
            let hostURL = URL(fileURLWithPath: testHost)
            let productsDir = hostURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            candidates.append(contentsOf: bundledCLICandidates(under: URL(fileURLWithPath: productsDir)))
        }

        let bundleCandidates = [
            Bundle.main.bundleURL,
            Bundle(for: Self.self).bundleURL,
        ]
        for bundleURL in bundleCandidates {
            if let productsDir = productsDirectory(from: bundleURL) {
                candidates.append(contentsOf: bundledCLICandidates(under: productsDir))
            }
        }

        for candidate in Array(Set(candidates)) {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            }
        }
        return nil
    }

    private func productsDirectory(from bundleURL: URL) -> URL? {
        var url = bundleURL.resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url.deletingLastPathComponent()
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func bundledCLICandidates(under productsDir: URL) -> [String] {
        let fileManager = FileManager.default
        var candidates = [
            productsDir.appendingPathComponent("cmux DEV.app/Contents/Resources/bin/cmux").path,
            productsDir.appendingPathComponent("cmux.app/Contents/Resources/bin/cmux").path,
        ]

        if let children = try? fileManager.contentsOfDirectory(
            at: productsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for child in children where child.pathExtension == "app" {
                let name = child.lastPathComponent
                if name.contains("UITests-Runner") || name.contains("XCTRunner") {
                    continue
                }
                candidates.append(child.appendingPathComponent("Contents/Resources/bin/cmux").path)
            }
        }

        return candidates
    }

    private func preview(_ data: Data) -> String {
        if let string = String(data: data.prefix(200), encoding: .utf8) {
            return string
        }
        return data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func errnoDescription(_ operation: String) -> String {
        let message = String(cString: strerror(errno))
        return "\(operation) errno=\(errno) \(message)"
    }

    private func transportFailure(method: String, stage: String, detail: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": 1,
            "error": [
                "code": -32098,
                "message": "Lifecycle UI test socket transport failure",
                "data": [
                    "method": method,
                    "path": path,
                    "stage": stage,
                    "detail": detail,
                ],
            ],
            "_transportFailure": true,
        ]
    }
}
