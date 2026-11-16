import Darwin
import Foundation
import QuotaCore

public enum CodexUsageError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound
    case invalidExecutable(String)
    case launchFailed
    case timedOut
    case serverExited
    case malformedResponse
    case responseTooLarge
    case authenticationRequired
    case rateLimited
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found. Install Codex, or select its executable in Settings."
        case .invalidExecutable(let path):
            "The selected Codex executable cannot be run: \(path)"
        case .launchFailed:
            "Codex could not start. Check the selected executable in Settings."
        case .timedOut:
            "Codex did not return usage in time. The tracker will retry automatically."
        case .serverExited:
            "Codex closed before returning usage. Open Codex to check your sign-in, then refresh."
        case .malformedResponse:
            "Codex returned an unreadable usage response. Update Codex, then refresh."
        case .responseTooLarge:
            "Codex returned an unexpectedly large response. Update Codex, then refresh."
        case .authenticationRequired:
            "Sign in to Codex with your ChatGPT account, then refresh. You can use ‘codex login’ in Terminal."
        case .rateLimited:
            "Usage requests are temporarily limited. The tracker will wait before retrying."
        case .serverError(let code):
            "Codex could not read account usage (server error \(code)). Check your Codex sign-in, then refresh."
        }
    }
}

public enum CodexExecutable {
    /// Uses existing installations and environment only; it never launches a shell or changes sign-in.
    public static func resolve(overridePath: String? = nil) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = overridePath ?? environment["CODEX_PACE_CLI"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            guard canExecute(path) else { throw CodexUsageError.invalidExecutable(path) }
            return URL(fileURLWithPath: path)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            home + "/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        for applications in ["/Applications", home + "/Applications"] {
            candidates += [
                applications + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                applications + "/Codex.app/Contents/Resources/codex",
                applications + "/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            ]
        }
        guard let path = candidates.first(where: canExecute) else {
            throw CodexUsageError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private static func canExecute(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

public struct CodexUsageClient: Sendable {
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 25) {
        self.executableURL = executableURL
        self.timeout = timeout.isFinite ? max(0.05, timeout) : 25
    }

    /// One short-lived helper per read. Blocking pipe work stays off the main actor.
    public func fetch() async throws -> UsageSnapshot {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let runner = AppServerRead(
                            executableURL: executableURL,
                            timeout: timeout,
                            cancellation: cancellation
                        )
                        continuation.resume(returning: try runner.run())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Cancellation is the only cross-thread mutable state. Process and pipes belong to one worker.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

private final class AppServerRead {
    private let executableURL: URL?
    private let timeout: TimeInterval
    private let cancellation: CancellationFlag
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var deadline: TimeInterval = 0
    private var launched = false
    private var ownedProcessGroup: pid_t?
    private let maximumLineBytes = 1_048_576

    init(executableURL: URL?, timeout: TimeInterval, cancellation: CancellationFlag) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.cancellation = cancellation
    }

    func run() throws -> UsageSnapshot {
        try cancellation.check()
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        process.executableURL = try executableURL ?? CodexExecutable.resolve()
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        // Raw stderr can contain account details. Do not retain or forward it to UI/logs.
        process.standardError = FileHandle.nullDevice
        defer { cleanUp() }
        do {
            try process.run()
            launched = true
            // Foundation starts a task in a separate process group on macOS.
            // Verify that ownership before ever using a negative kill target.
            let pid = process.processIdentifier
            let group = getpgid(pid)
            if pid > 1, group == pid, group != getpgrp() {
                ownedProcessGroup = group
            }
        } catch {
            throw CodexUsageError.launchFailed
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        setNonBlocking(input.fileHandleForWriting.fileDescriptor)
        setNonBlocking(output.fileHandleForReading.fileDescriptor)
        // Avoid a process-wide SIGPIPE disposition change if the server closes stdin early.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        try send([
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "codex_pace", "title": "Codex Pace", "version": "0.1.0"]],
        ])
        _ = try result(for: 1)
        try send(["method": "initialized", "params": [:]])
        try send(["id": 2, "method": "account/rateLimits/read"])
        let data = try result(for: 2)
        try cancellation.check()
        return try UsageParser.decodeRateLimitsResult(data, fetchedAt: Date())
    }

    private func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private func checkDeadline() throws {
        try cancellation.check()
        if ProcessInfo.processInfo.systemUptime >= deadline { throw CodexUsageError.timedOut }
    }

    private func waitFor(_ descriptor: Int32, events: Int16) throws {
        try checkDeadline()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        let milliseconds = Int32(max(1, min(100, remaining * 1_000)))
        var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
        let status = poll(&descriptor, 1, milliseconds)
        if status < 0 && errno != EINTR { throw CodexUsageError.serverExited }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        let descriptor = input.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try checkDeadline()
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0 && errno == EINTR { continue }
                else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    try waitFor(descriptor, events: Int16(POLLOUT))
                } else {
                    throw CodexUsageError.serverExited
                }
            }
        }
    }

    private func result(for requestID: Int) throws -> Data {
        let descriptor = output.fileHandleForReading.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            try checkDeadline()
            while let newline = buffer.firstIndex(of: 0x0A) {
                if buffer.distance(from: buffer.startIndex, to: newline) > maximumLineBytes {
                    throw CodexUsageError.responseTooLarge
                }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try? JSONSerialization.jsonObject(with: line),
                      let message = object as? [String: Any] else {
                    throw CodexUsageError.malformedResponse
                }
                // Ignore notifications and responses for unrelated IDs.
                guard let id = message["id"] as? NSNumber, id.intValue == requestID else { continue }
                if let error = message["error"] as? [String: Any] { throw rpcError(error) }
                guard let result = message["result"], JSONSerialization.isValidJSONObject(result) else {
                    throw CodexUsageError.malformedResponse
                }
                return try JSONSerialization.data(withJSONObject: result)
            }
            if buffer.count > maximumLineBytes { throw CodexUsageError.responseTooLarge }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
                throw CodexUsageError.serverExited
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                if !process.isRunning { throw CodexUsageError.serverExited }
                try waitFor(descriptor, events: Int16(POLLIN | POLLHUP))
            } else {
                throw CodexUsageError.serverExited
            }
        }
    }

    private func rpcError(_ error: [String: Any]) -> CodexUsageError {
        let code = (error["code"] as? NSNumber)?.intValue ?? -1
        let message = (error["message"] as? String ?? "").lowercased()
        if code == 401 || code == 403 || message.contains("unauthorized") || message.contains("not authenticated")
            || message.contains("not logged in") || message.contains("log in") || message.contains("login required")
            || message.contains("chatgpt authentication") || message.contains("chatgpt auth") {
            return .authenticationRequired
        }
        if code == 429 || code == -32001 || message.contains("too many requests") || message.contains("rate limit")
            || message.contains("overloaded") {
            return .rateLimited
        }
        return .serverError(code)
    }

    private func cleanUp() {
        try? input.fileHandleForWriting.close()
        if launched {
            waitForHelpersToExit(seconds: 0.25)
            if helpersAreRunning {
                signalHelpers(SIGTERM)
                waitForHelpersToExit(seconds: 0.25)
            }
            if helpersAreRunning {
                signalHelpers(SIGKILL)
                waitForHelpersToExit(seconds: 0.25)
            }
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    private var safeOwnedGroup: pid_t? {
        guard let group = ownedProcessGroup,
              group > 1,
              group == process.processIdentifier,
              group != getpgrp() else { return nil }
        return group
    }

    private var helpersAreRunning: Bool {
        // Keep checking the verified group even after its leader has exited:
        // descendants may still hold stdout open or ignore EOF/SIGTERM.
        if let group = safeOwnedGroup {
            if Darwin.kill(-group, 0) == 0 || errno == EPERM { return true }
        }
        return process.isRunning
    }

    private func signalHelpers(_ signal: Int32) {
        if let group = safeOwnedGroup {
            _ = Darwin.kill(-group, signal)
        } else if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, signal)
        }
    }

    private func waitForHelpersToExit(seconds: TimeInterval) {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while helpersAreRunning && ProcessInfo.processInfo.systemUptime < end {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
