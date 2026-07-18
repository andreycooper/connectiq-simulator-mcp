import Foundation
import Darwin
import Testing

@testable import SimulatorMCPCore

@Suite("Subprocess")
struct SubprocessTests {

    @Test("bounded stdin reaches the child and closes at EOF")
    func boundedStdin() async throws {
        let runner: any ProcessRunning = Subprocess()
        let process = try await runner.start(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: nil,
            workingDirectory: nil, timeout: nil, stdinData: Data("probe".utf8),
            onStdout: nil, onStderr: nil)
        let output = try await process.wait()
        #expect(output.exitCode == 0)
        #expect(output.stdout == Data("probe".utf8))
    }

    @Test("nil stdin preserves the null-device EOF behavior")
    func nilStdinIsEOF() async throws {
        let runner: any ProcessRunning = Subprocess()
        let process = try await runner.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read value; test $? -eq 1"], environment: nil,
            workingDirectory: nil, timeout: nil, stdinData: nil, onStdout: nil, onStderr: nil)
        let output = try await process.wait()
        #expect(output.exitCode == 0)
    }

    @Test("bounded stdin processes retain timeout cleanup")
    func boundedStdinTimeoutCleansChild() async throws {
        let descriptors = DescriptorBox()
        defer { closeSentinels(descriptors.value) }
        let runner: any ProcessRunning = Subprocess(testHooks: .init(
            pipeDescriptors: { descriptors.set(try! descriptorSentinels($0)) }
        ))
        let process = try await runner.start(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            environment: nil, workingDirectory: nil, timeout: .milliseconds(100),
            stdinData: Data("ignored".utf8), onStdout: nil, onStderr: nil)
        do {
            _ = try await process.wait()
            Issue.record("bounded stdin process should time out")
        } catch let error as ToolError {
            #expect(error.code == "operation_timeout")
            #expect(!error.fix.isEmpty)
            for identity in descriptors.value {
                #expect(!originalMatchesSentinel(identity))
            }
        }
    }

    @Test("bounded stdin launch failure closes every parent endpoint")
    func boundedStdinLaunchFailureClosesParentEndpoints() async throws {
        let descriptors = DescriptorBox()
        defer { closeSentinels(descriptors.value) }
        let missing = URL(fileURLWithPath: "/definitely/missing/\(UUID().uuidString)")
        do {
            _ = try await Subprocess(testHooks: .init(
                pipeDescriptors: { descriptors.set(try! descriptorSentinels($0)) }
            )).start(
                executable: missing, arguments: [], timeout: .seconds(1),
                stdinData: Data("probe".utf8), onStdout: nil, onStderr: nil)
            Issue.record("missing bounded-stdin executable should fail")
        } catch let error as ToolError {
            #expect(error.code == "executable_not_found")
            for sentinel in descriptors.value {
                #expect(!originalMatchesSentinel(sentinel))
            }
        }
    }

    @Test("a second reader setup failure cancels the first and returns a stable error")
    func secondReaderSetupFailureIsTranslated() async throws {
        let firstReader = DescriptorBox()
        defer { closeSentinels(firstReader.value) }
        do {
            _ = try await Subprocess(testHooks: .init(
                failReaderConstructionAt: 2,
                firstReaderDescriptors: { firstReader.set(try! descriptorSentinels($0)) }
            )).start(
                executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["unused"],
                timeout: .seconds(1), onStdout: nil, onStderr: nil)
            Issue.record("reader setup should fail")
        } catch let error as ToolError {
            #expect(error.code == "internal_error")
            #expect(!error.fix.isEmpty)
            #expect(firstReader.value.allSatisfy { !originalMatchesSentinel($0) })
        }
    }

    @Test("a non-consuming child cannot block bounded stdin past its deadline")
    func boundedStdinLargePayloadTimesOutAndCleansChild() async throws {
        let runner: any ProcessRunning = Subprocess()
        let payload = Data(repeating: 0x5A, count: 2 * 1024 * 1024)
        do {
            _ = try await runner.start(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                environment: nil, workingDirectory: nil, timeout: .milliseconds(100),
                stdinData: payload, onStdout: nil, onStderr: nil)
            Issue.record("bounded stdin write should time out before returning a process")
        } catch let error as ToolError {
            #expect(error.code == "stdin_write_timeout")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("an early child exit translates closed stdin without SIGPIPE")
    func earlyChildExitIsTranslated() async throws {
        let runner: any ProcessRunning = Subprocess()
        do {
            _ = try await runner.start(
                executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
                environment: nil, workingDirectory: nil, timeout: .seconds(2),
                stdinData: Data(repeating: 1, count: 2 * 1024 * 1024),
                onStdout: nil, onStderr: nil)
            Issue.record("closed stdin should fail the bounded write")
        } catch let error as ToolError {
            #expect(error.code == "stdin_write_failed")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("cancelling a bounded stdin write terminates the child and closes descriptors")
    func cancellingBoundedStdinCleansChild() async throws {
        let blocked = Started()
        let pidBox = PIDBox()
        let descriptors = DescriptorBox()
        defer { closeSentinels(descriptors.value) }
        let cleanupGate = CleanupGate()
        let task = Task {
            try await Subprocess(testHooks: .init(
                stdinWriteBlocked: { blocked.mark() },
                cleanupHook: {
                    cleanupGate.markStarted()
                    await cleanupGate.waitUntilReleased()
                },
                processStarted: { pidBox.set($0) },
                pipeDescriptors: { descriptors.set(try! descriptorSentinels($0)) }
            )).start(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                environment: nil, workingDirectory: nil, timeout: .seconds(30),
                stdinData: Data(repeating: 0x44, count: 8 * 1024 * 1024),
                onStdout: nil, onStderr: nil)
        }
        await blocked.wait()
        task.cancel()
        await cleanupGate.waitUntilStarted()
        cleanupGate.release()
        do {
            _ = try await task.value
            Issue.record("cancelled bounded stdin must throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("cancellation must remain CancellationError after cleanup: \(error)")
        }
        #expect(pidBox.value > 0)
        #expect(processIsGone(pid: pidBox.value))
        let boundedOpenDescriptors = descriptors.value.filter(originalMatchesSentinel)
        #expect(boundedOpenDescriptors.isEmpty, "open descriptors: \(boundedOpenDescriptors)")
    }

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

    @Test("stderr callback preserves stream order")
    func stderrCallbackPreservesOrder() async throws {
        let collector = ChunkCollector()
        let expected = Data(repeating: 0, count: 512 * 1024)
        let process = try await Subprocess().start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 524288 /dev/zero 1>&2"],
            timeout: nil, onStdout: nil, onStderr: { collector.append($0) })
        let output = try await process.wait()
        #expect(collector.chunks.count > 1)
        #expect(collector.chunks.reduce(Data(), +) == output.stderr)
        #expect(output.stderr == expected)
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
        let iterations = 15

        for _ in 0..<iterations {
            let descriptors = DescriptorBox()
            defer { closeSentinels(descriptors.value) }
            let process = try await Subprocess(testHooks: .init(
                pipeDescriptors: { descriptors.set(try! descriptorSentinels($0)) }
            )).start(
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

            #expect(processIsGone(pid: pid))
            for identity in descriptors.value {
                #expect(!originalMatchesSentinel(identity))
            }
        }

    }

    @Test("cancellation gives a TERM-cooperative child its grace path")
    func cooperativeCancellationUsesTermWithoutKill() async throws {
        let clock = FakeClock()
        let entered = Started()
        let cleanupStarted = Started()
        let descriptors = DescriptorBox()
        let killed = Started()
        let readySignal = Started()
        defer { closeSentinels(descriptors.value) }
        let startedPID = PIDBox()
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let process = try await Subprocess(testHooks: .init(
            cleanupHook: { cleanupStarted.mark() },
            processStarted: { startedPID.set($0); startedPID.mark() },
            waitEntered: { entered.mark() },
            pipeDescriptors: { descriptors.set(try! descriptorSentinels($0)) },
            graceClock: clock,
            graceDuration: .seconds(5)
            , killSent: { killed.mark() }
        )).start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap 'printf TERM > \"\(marker.path)\"; exit 0' TERM; printf READY; while :; do :; done"],
            timeout: nil, onStdout: { _ in readySignal.mark() }
        )
        await readySignal.wait()
        #expect(startedPID.value == process.pid)
        let waiter = Task<ProcessOutput, Error> { try await process.wait() }
        await entered.wait()
        waiter.cancel()
        await cleanupStarted.wait()
        do { _ = try await waiter.value; Issue.record("expected cancellation") }
        catch is CancellationError { }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!killed.value)
        try? FileManager.default.removeItem(at: marker)
        #expect(processIsGone(pid: process.pid))
        for identity in descriptors.value { #expect(!originalMatchesSentinel(identity)) }
    }

    @Test("cancellation kills a TERM-resistant child only after grace")
    func resistantCancellationEscalatesAfterGrace() async throws {
        let clock = FakeClock()
        let entered = Started()
        let cleanupStarted = Started()
        let descriptors = DescriptorBox()
        let readySignal = Started()
        defer { closeSentinels(descriptors.value) }
        let startedPID = PIDBox()
        let process = try await Subprocess(testHooks: .init(
            cleanupHook: { cleanupStarted.mark() },
            processStarted: { startedPID.set($0); startedPID.mark() },
            waitEntered: { entered.mark() },
            pipeDescriptors: { descriptors.set(try! descriptorSentinels($0)) },
            graceClock: clock,
            graceDuration: .seconds(5)
        )).start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf READY; while :; do :; done"],
            timeout: nil, onStdout: { _ in readySignal.mark() }
        )
        await readySignal.wait()
        #expect(startedPID.value == process.pid)
        let waiter = Task<ProcessOutput, Error> { try await process.wait() }
        await entered.wait()
        waiter.cancel()
        await cleanupStarted.wait()
        await clock.waitUntilPendingSleepCount(1)
        #expect(!processIsGone(pid: process.pid))
        clock.advance(by: .seconds(4))
        #expect(!processIsGone(pid: process.pid))
        clock.advance(by: .seconds(1))
        do {
            _ = try await waiter.value
            Issue.record("resistant cancellation should throw")
        } catch is CancellationError {
            // expected
        }
        #expect(processIsGone(pid: process.pid))
        for identity in descriptors.value { #expect(!originalMatchesSentinel(identity)) }
    }

    @Test("cancelling the waiting task terminates the child and closes descriptors")
    func testCancellationTerminatesChildAndClosesDescriptors() async throws {
        let gate = CleanupGate()
        let entered = Started()
        let descriptors = DescriptorBox()
        defer { closeSentinels(descriptors.value) }
        let process = try await Subprocess(testHooks: .init(cleanupHook: {
            gate.markStarted()
            await gate.waitUntilReleased()
        }, waitEntered: { entered.mark() }, pipeDescriptors: { descriptors.set(try! descriptorSentinels($0)) })).start(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: nil,
                workingDirectory: nil,
                timeout: nil,
                onStdout: nil,
                onStderr: nil
            )
        let pid = process.pid
        let waiter = Task<ProcessOutput, Error> { try await process.wait() }
        await entered.wait()
        waiter.cancel()
        await gate.waitUntilStarted()
        gate.release()
        do { _ = try await waiter.value; Issue.record("expected cancellation") }
        catch is CancellationError { }
        #expect(processIsGone(pid: pid))
        let normalOpenDescriptors = descriptors.value.filter(originalMatchesSentinel)
        #expect(normalOpenDescriptors.isEmpty, "open descriptors: \(normalOpenDescriptors)")

    }

    @Test("an already-cancelled waiter still awaits cleanup")
    func alreadyCancelledWaiterAwaitsCleanup() async throws {
        let gate = CleanupGate()
        let process = try await Subprocess(testHooks: .init(cleanupHook: {
            gate.markStarted()
            await gate.waitUntilReleased()
        })).start(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: nil)
        let invoked = Started()
        let proceed = Started()
        let waiter = Task<ProcessOutput, Error> {
            invoked.mark()
            await proceed.wait()
            return try await process.wait()
        }
        await invoked.wait()
        waiter.cancel()
        proceed.mark()
        await gate.waitUntilStarted()
        gate.release()
        do { _ = try await waiter.value; Issue.record("expected cancellation") }
        catch is CancellationError { }
        #expect(processIsGone(pid: process.pid))
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

@Suite("DispatchPipeReader")
struct DispatchPipeReaderTests {
    @Test("natural EOF preserves bytes and completes the stream")
    func naturalEOF() async throws {
        let pipe = Pipe()
        let reader = try DispatchPipeReader(readHandle: pipe.fileHandleForReading)
        let collected = Task { () -> Data in
            var result = Data()
            for await chunk in reader.stream { result.append(chunk) }
            return result
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("reader-proof".utf8))
        try pipe.fileHandleForWriting.close()
        let output = await collected.value
        #expect(output == Data("reader-proof".utf8))
        await reader.cancelAndWait()
    }

    @Test("repeated cancellation is idempotent")
    func repeatedCancellation() async throws {
        let pipe = Pipe()
        let reader = try DispatchPipeReader(readHandle: pipe.fileHandleForReading)
        async let first: Void = reader.cancelAndWait()
        async let second: Void = reader.cancelAndWait()
        _ = await (first, second)
        await reader.cancelAndWait()
        try pipe.fileHandleForWriting.close()
    }

    @Test("concurrent cancellation waits for the cancel handler")
    func cancellationWaitsForHandler() async throws {
        let pipe = Pipe()
        let started = ReaderAsyncSignal()
        let registered = ReaderRegistrationGate()
        let release = DispatchSemaphore(value: 0)
        let reader = try DispatchPipeReader(
            readHandle: pipe.fileHandleForReading,
            onCancellationStarted: { started.signal() },
            waitForCancellationRelease: { release.wait() },
            onCancellationWaiterRegistered: { registered.mark() })
        let firstCompleted = ReaderAsyncSignal()
        let secondCompleted = ReaderAsyncSignal()
        let firstCancellation = Task {
            await reader.cancelAndWait()
            firstCompleted.signal()
        }
        let secondCancellation = Task {
            await reader.cancelAndWait()
            secondCompleted.signal()
        }
        await started.wait()
        await registered.waitForTwo()
        #expect(!firstCompleted.value)
        #expect(!secondCompleted.value)
        release.signal()
        await firstCancellation.value
        await secondCancellation.value
        #expect(firstCompleted.value)
        #expect(secondCompleted.value)
        try pipe.fileHandleForWriting.close()
    }

    @Test("repeated cancellation does not close a recycled descriptor")
    func repeatedCancellationDoesNotCloseRecycledDescriptor() async throws {
        let pipe = Pipe()
        let reader = try DispatchPipeReader(readHandle: pipe.fileHandleForReading)
        await reader.cancelAndWait()
        let replacement = open("/dev/null", O_RDONLY)
        #expect(replacement >= 0)
        #expect(dup2(replacement, reader.fd) == reader.fd)
        if replacement != reader.fd { _ = Darwin.close(replacement) }
        await reader.cancelAndWait()
        #expect(fcntl(reader.fd, F_GETFD) >= 0)
        _ = Darwin.close(reader.fd)
        try pipe.fileHandleForWriting.close()
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

        await started.wait()
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        lock.lock()
        flag = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if flag {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

final class ReaderAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

final class ReaderRegistrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        lock.lock(); count += 1
        let pending = count >= 2 ? waiters : []
        if count >= 2 { waiters.removeAll() }
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func waitForTwo() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count >= 2 { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32 = 0
    private var flag = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func set(_ value: Int32) { lock.lock(); pid = value; lock.unlock() }
    var value: Int32 { lock.lock(); defer { lock.unlock() }; return pid }
    func mark() {
        lock.lock(); flag = true
        let pending = waiters; waiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if flag { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

final class DescriptorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [FDSentinel] = []
    func set(_ value: [FDSentinel]) { lock.lock(); descriptors = value; lock.unlock() }
    var value: [FDSentinel] { lock.lock(); defer { lock.unlock() }; return descriptors }
}

final class CleanupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didRelease = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func markStarted() {
        lock.lock(); didStart = true
        let pending = startWaiters; startWaiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    func release() {
        lock.lock(); didRelease = true
        let pending = releaseWaiters; releaseWaiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didStart { lock.unlock(); continuation.resume() }
            else { startWaiters.append(continuation); lock.unlock() }
        }
    }
    private var released: Bool { lock.lock(); defer { lock.unlock() }; return didRelease }
    func waitUntilReleased() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didRelease { lock.unlock(); continuation.resume() }
            else { releaseWaiters.append(continuation); lock.unlock() }
        }
    }
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
}

private func processIsGone(pid: Int32) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

private func descriptorSet() -> Set<Int> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.compactMap(Int.init) ?? [])
}

private func pipeDescriptorSet() -> Set<Int> {
    descriptorSet().filter { fd in
        var info = stat()
        guard fstat(Int32(fd), &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFIFO
    }
}

struct FDSentinel: Sendable {
    let originalFD: Int32
    let sentinelFD: Int32
    let device: UInt64
    let inode: UInt64
}

private enum DescriptorSentinelError: Error {
    case duplicateFailed(Int32)
    case statFailed(Int32)
}

private func descriptorSentinels(_ fds: [Int32]) throws -> [FDSentinel] {
    var sentinels: [FDSentinel] = []
    for fd in fds {
        let sentinelFD = fcntl(fd, F_DUPFD_CLOEXEC, 100)
        guard sentinelFD >= 0 else {
            closeSentinels(sentinels)
            throw DescriptorSentinelError.duplicateFailed(fd)
        }
        var info = stat()
        guard fstat(sentinelFD, &info) == 0 else {
            _ = Darwin.close(sentinelFD)
            closeSentinels(sentinels)
            throw DescriptorSentinelError.statFailed(sentinelFD)
        }
        sentinels.append(FDSentinel(
            originalFD: fd, sentinelFD: sentinelFD,
            device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
    }
    return sentinels
}

private func originalMatchesSentinel(_ sentinel: FDSentinel) -> Bool {
    var info = stat()
    guard fstat(sentinel.originalFD, &info) == 0 else { return false }
    return UInt64(info.st_dev) == sentinel.device && UInt64(info.st_ino) == sentinel.inode
}

private func closeSentinels(_ sentinels: [FDSentinel]) {
    for sentinel in sentinels {
        _ = Darwin.close(sentinel.sentinelFD)
    }
}
