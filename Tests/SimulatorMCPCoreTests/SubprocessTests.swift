import Foundation
import Testing

import SimulatorMCPCore

@Suite("Subprocess")
struct SubprocessTests {

    @Test("captures stdout and stderr independently")
    func testCapturesStdoutAndStderrIndependently() async throws {
        let process = try await Subprocess().start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out-line; echo err-line 1>&2"],
            environment: nil,
            workingDirectory: nil,
            timeout: nil,
            onStdout: nil,
            onStderr: nil
        )
        let output = try await process.wait()

        #expect(output.exitCode == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "out-line\n")
        #expect(String(decoding: output.stderr, as: UTF8.self) == "err-line\n")
    }

    @Test("handles output larger than a pipe buffer without deadlock", .timeLimit(.minutes(1)))
    func testLargeOutputDoesNotDeadlock() async throws {
        // The kernel pipe buffer is 64KiB on Darwin; 512KiB forces many
        // read/write cycles and would deadlock a naive
        // "run() then read()" implementation.
        let byteCount = 512 * 1024
        let process = try await Subprocess().start(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1024", "count=\(byteCount / 1024)"],
            environment: nil,
            workingDirectory: nil,
            timeout: nil,
            onStdout: nil,
            onStderr: nil
        )
        let output = try await process.wait()

        #expect(output.exitCode == 0)
        #expect(output.stdout.count == byteCount)
    }

    @Test("streams chunks via onStdout while retaining the complete result", .timeLimit(.minutes(1)))
    func testStreamsChunksWhileRetainingCompleteResult() async throws {
        let collector = ChunkCollector()
        let byteCount = 256 * 1024
        let process = try await Subprocess().start(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1024", "count=\(byteCount / 1024)"],
            environment: nil,
            workingDirectory: nil,
            timeout: nil,
            onStdout: { data in collector.append(data) },
            onStderr: nil
        )
        let output = try await process.wait()

        let chunks = collector.chunks
        #expect(chunks.count > 1, "expected more than one chunk to prove this is actually streamed")
        #expect(chunks.reduce(Data(), +) == output.stdout)
        #expect(output.stdout.count == byteCount)
    }

    @Test("preserves a nonzero exit code")
    func testPreservesNonzeroExitCode() async throws {
        let process = try await Subprocess().start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            environment: nil,
            workingDirectory: nil,
            timeout: nil,
            onStdout: nil,
            onStderr: nil
        )
        let output = try await process.wait()

        #expect(output.exitCode == 7)
    }

    @Test("a run-level timeout terminates the child, closes descriptors, and throws operation_timeout")
    func testTimeoutTerminatesChild() async throws {
        // `/dev/fd` reports the whole test process's open descriptors, so a
        // single before/after snapshot is noisy under Swift Testing's
        // concurrent execution even with `.serialized` on this suite
        // (other suites in the same process can still interleave). Running
        // several iterations and asserting on the *net* growth catches a
        // real per-call leak (which scales with the iteration count) while
        // tolerating small one-off noise from unrelated concurrent activity.
        let iterations = 15
        let fdCountBefore = openFileDescriptorCount()

        for _ in 0..<iterations {
            let process = try await Subprocess().start(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: nil,
                workingDirectory: nil,
                timeout: .milliseconds(200),
                onStdout: nil,
                onStderr: nil
            )
            let pid = process.pid

            let start = ContinuousClock.now
            do {
                _ = try await process.wait()
                Issue.record("expected wait() to throw operation_timeout")
            } catch let error as ToolError {
                #expect(error.code == "operation_timeout")
                #expect(!error.fix.isEmpty)
                #expect(error.details?["executable"] != nil)
            }
            let elapsed = ContinuousClock.now - start
            #expect(
                elapsed < .seconds(5), "timeout + grace should resolve well under the 30s sleep duration")

            await waitUntilProcessGone(pid: pid)
            #expect(processIsGone(pid: pid))
        }

        let fdCountAfter = openFileDescriptorCount()
        #expect(
            fdCountAfter <= fdCountBefore + 4,
            "expected pipe read ends to be closed after every forced timeout across \(iterations) iterations (before=\(fdCountBefore), after=\(fdCountAfter))"
        )
    }

    @Test("cancelling the waiting task terminates the child and closes descriptors")
    func testCancellationTerminatesChildAndClosesDescriptors() async throws {
        // See the comment on `testTimeoutTerminatesChild`: iterate and check
        // net growth rather than a single noisy before/after snapshot.
        let iterations = 15
        let fdCountBefore = openFileDescriptorCount()

        for _ in 0..<iterations {
            let process = try await Subprocess().start(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: nil,
                workingDirectory: nil,
                timeout: nil,
                onStdout: nil,
                onStderr: nil
            )
            let pid = process.pid

            let waiter = Task<ProcessOutput, Error> {
                try await process.wait()
            }
            try await Task.sleep(for: .milliseconds(50))
            waiter.cancel()

            do {
                _ = try await waiter.value
                Issue.record("expected wait() to throw CancellationError once cancelled")
            } catch is CancellationError {
                // expected
            }

            await waitUntilProcessGone(pid: pid)
            #expect(processIsGone(pid: pid))
        }

        let fdCountAfter = openFileDescriptorCount()
        #expect(
            fdCountAfter <= fdCountBefore + 4,
            "expected pipe read ends to be closed after every cancellation across \(iterations) iterations (before=\(fdCountBefore), after=\(fdCountAfter))"
        )
    }

    @Test("a missing executable becomes executable_not_found with a non-empty fix")
    func testExecutableNotFoundBecomesToolError() async throws {
        let missing = URL(fileURLWithPath: "/definitely/does/not/exist/\(UUID().uuidString)")
        do {
            _ = try await Subprocess().start(
                executable: missing,
                arguments: [],
                environment: nil,
                workingDirectory: nil,
                timeout: nil,
                onStdout: nil,
                onStderr: nil
            )
            Issue.record("expected start() to throw")
        } catch let error as ToolError {
            #expect(error.code == "executable_not_found")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a non-executable path becomes permission_denied with a non-empty fix")
    func testPermissionDeniedBecomesToolError() async throws {
        // A directory is never executable; Foundation's `Process.run()`
        // surfaces this as a genuine POSIX EACCES (verified empirically),
        // distinct from the "no such file" case above.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        do {
            _ = try await Subprocess().start(
                executable: directory,
                arguments: [],
                environment: nil,
                workingDirectory: nil,
                timeout: nil,
                onStdout: nil,
                onStderr: nil
            )
            Issue.record("expected start() to throw")
        } catch let error as ToolError {
            #expect(error.code == "permission_denied")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a child writing to stdout cannot reach the server's real stdout")
    func testChildStdoutNeverLeaksToRealStdout() async throws {
        var output: ProcessOutput?
        let captured = try await captureStdout {
            let process = try await Subprocess().start(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello-from-child"],
                environment: nil,
                workingDirectory: nil,
                timeout: nil,
                onStdout: nil,
                onStderr: nil
            )
            output = try await process.wait()
        }

        #expect(captured.isEmpty, "the child's stdout must never land on the test process's real fd 1")
        #expect(String(decoding: output?.stdout ?? Data(), as: UTF8.self) == "hello-from-child\n")
    }
}

@Suite("ClockSupport")
struct ClockSupportTests {
    @Test("returns the operation's result when it finishes before the deadline")
    func testOperationWins() async throws {
        let clock = FakeClock()
        let result = try await ClockSupport.withDeadline(.seconds(10), clock: clock) {
            "done"
        }
        #expect(result == "done")
    }

    @Test("throws DeadlineExceeded once the fake clock is advanced past the deadline")
    func testDeadlineWins() async throws {
        let clock = FakeClock()
        let started = Started()

        async let raced: Void = {
            do {
                _ = try await ClockSupport.withDeadline(.seconds(1), clock: clock) {
                    started.mark()
                    try await Task.sleep(for: .seconds(3600))
                    return "never"
                }
                Issue.record("expected DeadlineExceeded")
            } catch is ClockSupport.DeadlineExceeded {
                // expected
            }
        }()

        while !started.value {
            try await Task.sleep(for: .milliseconds(5))
        }
        clock.advance(by: .seconds(2))
        try await raced
    }
}

/// `@Sendable` chunk collector for `onStdout`/`onStderr` callbacks, which
/// arrive on a background context. A plain `var` closed over by a
/// `@Sendable` closure is rejected by Swift 6 strict concurrency, so this
/// wraps the mutation behind a lock (mirrors the pattern already used for
/// `Log.err` sink tests in MCPBootstrapTests).
final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }

    var chunks: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Single-flag `@unchecked Sendable` box used to synchronize test-only
/// polling with a task running inside `async let`.
final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func mark() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

private func openFileDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
}

private func processIsGone(pid: Int32) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

private func waitUntilProcessGone(pid: Int32, timeout: Duration = .seconds(2)) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if processIsGone(pid: pid) { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
