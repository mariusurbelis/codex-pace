import Darwin
import Foundation
import XCTest
@testable import CodexUsage

@MainActor
final class CodexUsageClientTests: XCTestCase {
    func testReadsAfterHandshakeAndIgnoresNotificationsAndUnrelatedResponses() async throws {
        let fixture = try Fixture(script: """
        IFS= read -r request || exit 1
        printf '%s\\n' "$request" >> "$0.requests"
        printf '%s\\n' '{"method":"account/updated","params":{"authMode":"chatgpt"}}'
        printf '%s\\n' '{"id":999,"result":{}}'
        printf '%s' '{"id":1,"res'
        /bin/sleep 0.02
        printf '%s\\n' 'ult":{"userAgent":"fixture"}}'
        IFS= read -r notification || exit 1
        printf '%s\\n' "$notification" >> "$0.requests"
        IFS= read -r request || exit 1
        printf '%s\\n' "$request" >> "$0.requests"
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":37.5,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null}}}'
        IFS= read -r eof
        """)
        defer { fixture.remove() }

        let snapshot = try await CodexUsageClient(executableURL: fixture.executable, timeout: 2).fetch()
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 37.5)
        XCTAssertEqual(snapshot.windows.first?.windowDurationMins, 10080)
        XCTAssertEqual(snapshot.windows.first?.resetsAt?.timeIntervalSince1970, 2_000_000_000)

        let requests = try String(contentsOf: fixture.executable.appendingPathExtension("requests"), encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/rateLimits/read"])
        XCTAssertFalse(requests.contains { ($0["method"] as? String)?.hasPrefix("turn/") == true })
        try await assertStopped(fixture)
    }

    func testAuthErrorIsActionableAndDoesNotExposeRawServerMessage() async throws {
        let fixture = try Fixture(script: """
        IFS= read -r request || exit 1
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r notification || exit 1
        IFS= read -r request || exit 1
        printf '%s\\n' '{"id":2,"error":{"code":401,"message":"Unauthorized bearer secret-do-not-display"}}'
        IFS= read -r eof
        """)
        defer { fixture.remove() }

        do {
            _ = try await CodexUsageClient(executableURL: fixture.executable, timeout: 2).fetch()
            XCTFail("Expected authentication error")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .authenticationRequired)
            XCTAssertFalse(error.localizedDescription.contains("secret-do-not-display"))
            XCTAssertTrue(error.localizedDescription.contains("codex login"))
        }
        try await assertStopped(fixture)
    }

    func testBackpressureIsReportedAsRateLimited() async throws {
        let fixture = try Fixture(script: """
        IFS= read -r request || exit 1
        printf '%s\\n' '{"id":1,"error":{"code":-32001,"message":"Server overloaded; retry later."}}'
        IFS= read -r eof
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executableURL: fixture.executable, timeout: 2).fetch()
            XCTFail("Expected rate limit error")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .rateLimited)
        }
        try await assertStopped(fixture)
    }

    func testServerExitDoesNotHang() async throws {
        let fixture = try Fixture(script: "exit 4")
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executableURL: fixture.executable, timeout: 2).fetch()
            XCTFail("Expected early exit error")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .serverExited)
        }
        try await assertStopped(fixture)
    }

    func testStalledServerTimesOutAndHelperIsTerminated() async throws {
        let fixture = try Fixture(script: "exec /bin/sleep 30")
        defer { fixture.remove() }
        let start = ContinuousClock.now
        do {
            _ = try await CodexUsageClient(executableURL: fixture.executable, timeout: 0.15).fetch()
            XCTFail("Expected timeout")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        try await assertStopped(fixture)
    }

    func testCancellationStopsStalledHelper() async throws {
        let fixture = try Fixture(script: "exec /bin/sleep 30")
        defer { fixture.remove() }
        let client = CodexUsageClient(executableURL: fixture.executable, timeout: 20)
        let task = Task { try await client.fetch() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected; no result or authentication state change.
        }
        try await assertStopped(fixture)
    }

    func testTimeoutKillsStubbornDescendantsAsWellAsGroupLeader() async throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }
        let fixture = try Fixture(script: """
        trap '' TERM
        /bin/sleep 30 &
        printf '%s\\n' "$!" > "$0.descendant"
        wait
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executableURL: fixture.executable, timeout: 0.2).fetch()
            XCTFail("Expected timeout")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertTrue(unrelated.isRunning, "Cleanup must not signal a sibling process group")
        try await assertStopped(fixture)
        try await assertStopped(pidFile: fixture.executable.appendingPathExtension("descendant"))
    }

    func testCleanupKillsDescendantEvenAfterItsGroupLeaderHasExited() async throws {
        let fixture = try Fixture(script: """
        trap '' TERM
        /bin/sleep 30 &
        printf '%s\\n' "$!" > "$0.descendant"
        /bin/sleep 0.1
        exit 4
        """)
        defer { fixture.remove() }
        do {
            _ = try await CodexUsageClient(executableURL: fixture.executable, timeout: 2).fetch()
            XCTFail("Expected early exit")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .serverExited)
        }
        try await assertStopped(fixture)
        try await assertStopped(pidFile: fixture.executable.appendingPathExtension("descendant"))
    }

    func testExplicitMissingExecutableDoesNotSilentlyUseAnotherInstallation() throws {
        XCTAssertThrowsError(try CodexExecutable.resolve(overridePath: "/does-not-exist/codex")) {
            XCTAssertEqual($0 as? CodexUsageError, .invalidExecutable("/does-not-exist/codex"))
        }
    }

    private func assertStopped(_ fixture: Fixture) async throws {
        try await assertStopped(pidFile: fixture.pidFile)
    }

    private func assertStopped(pidFile: URL) async throws {
        let raw = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(raw))
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Helper process \(pid) remained running")
    }
}

private struct Fixture {
    let directory: URL
    let executable: URL
    var pidFile: URL { executable.appendingPathExtension("pid") }

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-pace-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("codex-fixture")
        let contents = "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$0.pid\"\n" + script + "\n"
        try contents.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
