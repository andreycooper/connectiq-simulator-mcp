import Foundation
import Testing

@testable import SimulatorMCPCore

/// Gates 2, 3 and 6 of the v3 design, run against a **real** `AppSessionManager`.
///
/// A fake that serves scripted pages cannot prove any of these: it would have
/// to reimplement `logs`' cursor filtering, and a bug in that reimplementation
/// would look like a pass. These drive the shipped ring buffer, the shipped
/// cursor encoding and the shipped exit classification, and the app emits its
/// lines from inside a press step — which is when a real app emits them.
@Suite("SequenceWaitForLog")
struct SequenceWaitForLogTests {

    // MARK: - Gate 2

    @Test("a marker emitted before the sequence never satisfies a wait")
    func staleMarkerCannotSatisfyAWait() async throws {
        let session = try await WaitHarness.start()
        // Already in the buffer before the sequence begins. The lines *before*
        // the marker matter: a baseline taken from nextToken with a limit-1
        // page would land on "boot-1", leaving the stale marker ahead of the
        // cursor and satisfying the wait. Only latestToken sits past it.
        session.emit("boot-1\nboot-2\nMENU_OPENED\n")

        let run = try await session.service().run(RunSequenceToolRequest(
            steps: [.waitForLog(contains: "MENU_OPENED", timeoutMs: 200)],
            allowFocus: false))

        let failure = try #require(run.failure)
        #expect(failure.code == "sequence_marker_timeout")
        #expect(failure.details?["failedStepIndex"] == .int(0))
        #expect(run.result.steps.map(\.status) == ["failed"])
        // The baseline is latestToken, so the stale line was never even scanned.
        #expect(failure.details?["linesScanned"] == .int(0))
    }

    // MARK: - Gate 3

    @Test("a marker beyond one page is found once the cursor advances")
    func markerBeyondOnePageIsFound() async throws {
        let session = try await WaitHarness.start()
        // 600 lines of chatter past the 500-line poll page, then the marker.
        let noise = (1...600).map { "noise-\($0)" }.joined(separator: "\n")
        let run = try await session.service(onPress: { session.emit(noise + "\nMENU_OPENED\n") })
            .run(RunSequenceToolRequest(
                steps: [
                    .press(button: "enter", holdMs: nil),
                    .waitForLog(contains: "MENU_OPENED", timeoutMs: 5_000),
                ],
                allowFocus: true))

        #expect(run.failure == nil)
        let wait = try #require(run.result.steps.last)
        #expect(wait.status == "completed")
        // 500 on the first page, 101 on the second: the cursor moved.
        #expect(wait.linesScanned == 601)
    }

    @Test("a marker consumed by one wait does not satisfy a later wait")
    func consumedMarkerIsNotReusable() async throws {
        let session = try await WaitHarness.start()
        let run = try await session.service(onPress: { session.emit("MARK\n") })
            .run(RunSequenceToolRequest(
                steps: [
                    .press(button: "enter", holdMs: nil),
                    .waitForLog(contains: "MARK", timeoutMs: 5_000),
                    .waitForLog(contains: "MARK", timeoutMs: 200),
                ],
                allowFocus: true))

        let failure = try #require(run.failure)
        #expect(failure.code == "sequence_marker_timeout")
        #expect(failure.details?["failedStepIndex"] == .int(2))
        #expect(run.result.steps.map(\.status) == ["completed", "completed", "failed"])
    }

    /// The gate the retained-page-suffix mechanism exists for. Both markers
    /// land in one flush, so they arrive in the same poll page; adopting that
    /// page's `nextToken` alone would put the cursor past the second one and
    /// the later wait would hang for its whole timeout.
    @Test("a second marker in the same page still satisfies a later wait")
    func secondMarkerInTheSamePageIsReachable() async throws {
        let session = try await WaitHarness.start()
        let run = try await session.service(onPress: { session.emit("MARK\nMARK\n") })
            .run(RunSequenceToolRequest(
                steps: [
                    .press(button: "enter", holdMs: nil),
                    .waitForLog(contains: "MARK", timeoutMs: 5_000),
                    .waitForLog(contains: "MARK", timeoutMs: 5_000),
                ],
                allowFocus: true))

        #expect(run.failure == nil)
        #expect(run.result.steps.map(\.status) == ["completed", "completed", "completed"])
        // The second wait was satisfied from the carried suffix: one line
        // scanned, and no poll was needed to find it.
        #expect(run.result.steps.last?.linesScanned == 1)
    }

    // MARK: - Gate 6

    @Test("an app that exits mid-wait fails as a crash, well before the timeout")
    func exitShortCircuitsTheWait() async throws {
        let session = try await WaitHarness.start()
        let run = try await session.service(onPress: {
            session.emit("Stack Trace:\n  at App.onStart\n")
            await session.finish(exitCode: 1)
        }).run(RunSequenceToolRequest(
            steps: [
                .press(button: "enter", holdMs: nil),
                .waitForLog(contains: "NEVER_PRINTED", timeoutMs: 10_000),
            ],
            allowFocus: true))

        let failure = try #require(run.failure)
        #expect(failure.code == "sequence_app_exited")
        #expect(failure.details?["crashDetected"] == .bool(true))
        #expect(failure.details?["exitCode"] == .int(1))
        #expect(!failure.fix.isEmpty)

        // The whole point: the poll response already said the app died, so the
        // declared 10 s was never spent. Counted in polls, not wall clock —
        // burning the timeout at a 50 ms interval is ~200 polls, and an
        // elapsed-time assertion measures the machine's load under a parallel
        // suite rather than the property under test.
        #expect(await session.logCallCount() <= 5)
    }

    /// Scanning the page before checking `state` is what makes this pass. An
    /// unterminated line is not a log line until `finishLines()` runs, which
    /// happens on exit — so the marker and the exit arrive on the same page.
    @Test("a marker flushed by the app's own exit still satisfies the wait")
    func markerFlushedAtExitStillCounts() async throws {
        let session = try await WaitHarness.start()
        let run = try await session.service(onPress: {
            session.emit("PARTIAL_MARKER_NO_NEWLINE")   // no trailing newline
            await session.finish(exitCode: 0)
        }).run(RunSequenceToolRequest(
            steps: [
                .press(button: "enter", holdMs: nil),
                .waitForLog(contains: "PARTIAL_MARKER", timeoutMs: 5_000),
            ],
            allowFocus: true))

        #expect(run.failure == nil)
        #expect(run.result.steps.map(\.status) == ["completed", "completed"])
    }

    // MARK: - Pre-lease refusal (Gate 5, session half)

    @Test("a wait against a server that owns no session is refused before the lease")
    func noSessionIsRefusedBeforeTheLease() async throws {
        let manager = AppSessionManager(
            lifecycle: WaitSessionLifecycle(runner: WaitSessionRunner(processes: [])))
        let leases = LeaseCounter()
        let service = SequenceService(
            operationRunner: SequenceOperationRunner { _, _, body in
                await leases.record()
                return try await body(waitTestContext())
            },
            capture: { _ in Issue.record("no step may run"); throw ToolError(
                code: "internal_error", message: "unreachable", fix: "unreachable") },
            press: { _, _ in Issue.record("no step may run"); throw ToolError(
                code: "internal_error", message: "unreachable", fix: "unreachable") },
            readLogs: { token, limit in
                try await manager.logs(sinceToken: token, limit: limit)
            },
            revalidate: { _ in })

        await #expect(throws: ToolError.self) {
            _ = try await service.run(RunSequenceToolRequest(
                steps: [.waitForLog(contains: "X", timeoutMs: 1_000)], allowFocus: false))
        }
        do {
            _ = try await service.run(RunSequenceToolRequest(
                steps: [.waitForLog(contains: "X", timeoutMs: 1_000)], allowFocus: false))
        } catch let error as ToolError {
            #expect(error.code == "sequence_session_unavailable")
            // Never the shipped get_logs advice, which would restart the app.
            #expect(!error.fix.contains("Call run_app successfully"))
            #expect(error.fix.contains("run_app"))
        }
        #expect(await leases.count == 0, "a doomed sequence must not take the lease")
    }
}

// MARK: - Harness

private actor LeaseCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

/// A published session backed by the real `AppSessionManager`.
private struct WaitHarness: Sendable {
    let manager: AppSessionManager
    private let process: WaitSessionProcess
    private let logCalls = LeaseCounter()

    func logCallCount() async -> Int { await logCalls.count }

    static func start() async throws -> WaitHarness {
        let process = WaitSessionProcess()
        let manager = AppSessionManager(
            lifecycle: WaitSessionLifecycle(runner: WaitSessionRunner(processes: [process])))
        let sdk = waitTestSdk()
        let pending = try await manager.beginPending(MonkeydoCommand(
            sdk: sdk, prgPath: URL(fileURLWithPath: "/tmp/app.prg"), device: "fenix6xpro",
            testFilter: nil))
        _ = try await manager.commit(
            pending, device: "fenix6xpro", prgPath: URL(fileURLWithPath: "/tmp/app.prg"),
            sdk: sdk)
        return WaitHarness(manager: manager, process: process)
    }

    func emit(_ text: String) {
        process.emit(text, stream: .stdout)
    }

    func finish(exitCode: Int32) async {
        process.finish(exitCode: exitCode)
        await manager.waitForCurrentExitForTesting()
    }

    /// `onPress` is where the app's output comes from — a real app logs
    /// because a button was pressed, not before the sequence started.
    func service(onPress: @escaping @Sendable () async -> Void = {}) -> SequenceService {
        let manager = self.manager
        let logCalls = self.logCalls
        return SequenceService(
            operationRunner: .immediate(context: waitTestContext()),
            capture: { _ in
                ScreenshotOutput(
                    result: ScreenshotResult(
                        path: "/tmp/simulator-mcp/frame.png", mimeType: "image/png",
                        width: 454, height: 454, capturedPid: 4_242, appDisplayRect: nil),
                    png: Data([0x89, 0x50, 0x4E, 0x47]))
            },
            press: { request, _ in
                await onPress()
                return PressButtonResult(
                    button: request.button, pressType: "press",
                    transport: "focused-keys", simulatorPid: 4_242)
            },
            readLogs: { token, limit in
                await logCalls.record()
                return try await manager.logs(sinceToken: token, limit: limit)
            },
            revalidate: { _ in })
    }
}

private func waitTestSdk() -> SdkInfo {
    SdkInfo(
        version: SemVer("9.1.0")!, root: URL(fileURLWithPath: "/sdk/9.1.0"), source: .explicit)
}

private func waitTestContext() -> OperationContext {
    OperationContext(
        simulatorPid: 4_242, sdk: waitTestSdk(), currentDevice: "fenix6xpro",
        listeningEndpoints: [])
}

private struct WaitSessionLifecycle: MonkeydoProcessLifecycling, Sendable {
    let runner: any ProcessRunning

    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        let process = try await runner.start(
            executable: command.sdk.monkeydo,
            arguments: [command.prgPath.path, command.device],
            environment: nil, workingDirectory: nil, timeout: nil,
            onStdout: onStdout, onStderr: onStderr)
        return OwnedMonkeydoProcess(
            process: process,
            launcher: ProcessIdentitySnapshot(
                pid: process.pid, parentPid: 1, processGroupId: process.pid,
                start: ProcessStartIdentity(seconds: 1, microseconds: UInt64(process.pid)),
                executablePath: "/bin/bash",
                arguments: ["/bin/bash", command.sdk.monkeydo.path]),
            command: command)
    }

    func launchTests(
        _ command: MonkeydoCommand, workingDirectory: URL?, timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?, onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await launchApp(command, onStdout: onStdout, onStderr: onStderr)
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {
        let cleanup = Task.detached {
            await owned.process.terminate(grace: grace)
            _ = try await owned.output()
        }
        try await cleanup.value
    }

    func terminatePersisted(_ ownership: PersistedMonkeydoOwnership, grace: Duration) async throws {}
}

private final class WaitSessionRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [WaitSessionProcess]

    init(processes: [WaitSessionProcess]) { self.processes = processes }

    func start(
        executable: URL, arguments: [String], environment: [String: String]?,
        workingDirectory: URL?, timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?, onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess {
        let process: WaitSessionProcess = try lock.withLock {
            guard !processes.isEmpty else {
                throw ToolError(
                    code: "app_launch_failed", message: "No process queued.",
                    fix: "Queue a process before launching.")
            }
            return processes.removeFirst()
        }
        process.attach(onStdout: onStdout, onStderr: onStderr)
        return process
    }
}

private final class WaitSessionProcess: RunningProcess, @unchecked Sendable {
    nonisolated let pid: Int32 = 4_242

    private let lock = NSLock()
    private var stdout: (@Sendable (Data) -> Void)?
    private var stderr: (@Sendable (Data) -> Void)?
    private var output: ProcessOutput?
    private var waiters: [CheckedContinuation<ProcessOutput, Never>] = []

    func attach(
        onStdout: (@Sendable (Data) -> Void)?, onStderr: (@Sendable (Data) -> Void)?
    ) {
        lock.withLock {
            self.stdout = onStdout
            self.stderr = onStderr
        }
    }

    func emit(_ text: String, stream: LogStream) {
        let callback = lock.withLock { stream == .stdout ? stdout : stderr }
        callback?(Data(text.utf8))
    }

    func finish(exitCode: Int32) {
        let result = ProcessOutput(exitCode: exitCode, stdout: Data(), stderr: Data())
        let continuations: [CheckedContinuation<ProcessOutput, Never>] = lock.withLock {
            guard output == nil else { return [] }
            output = result
            defer { waiters.removeAll() }
            return waiters
        }
        continuations.forEach { $0.resume(returning: result) }
    }

    func wait() async throws -> ProcessOutput {
        await withCheckedContinuation { continuation in
            let result = lock.withLock { () -> ProcessOutput? in
                if let output { return output }
                waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    func terminate(grace: Duration) async {
        finish(exitCode: 0)
    }
}
