import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("AppSessionManager")
struct AppSessionManagerTests {
    @Test("failed and aborted pending launches never publish a session")
    func pendingFailureAndAbortStayInvisible() async throws {
        let launchError = ToolError(
            code: "app_launch_failed", message: "monkeydo could not start.",
            fix: "Check the SDK and retry.")
        let failing = AppSessionManager(
            processRunner: SessionTestRunner(processes: [], launchError: launchError))

        do {
            _ = try await failing.beginPending(
                executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["app.prg"])
            Issue.record("the launch error must propagate")
        } catch let error as ToolError {
            #expect(error == launchError)
        }
        await expectToolError("no_current_session") { try await failing.logs(limit: 10) }

        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        let pending = try await manager.beginPending(
            executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["app.prg"])
        process.emit("pending-only\n", stream: .stdout)
        await expectToolError("no_current_session") { try await manager.logs(limit: 10) }

        try await manager.abort(pending)

        #expect(process.terminationGraces == [.seconds(5)])
        #expect(process.waitCount == 1)
        await expectToolError("no_current_session") { try await manager.logs(limit: 10) }
    }

    @Test("abort removes pending before awaiting child cleanup")
    func abortCannotRaceCommit() async throws {
        let process = ControlledSessionProcess(blockTermination: true)
        let replacement = ControlledSessionProcess()
        let runner = SessionTestRunner(processes: [process, replacement])
        let manager = AppSessionManager(processRunner: runner)
        let pending = try await manager.beginPending(
            executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["app.prg"])
        let abort = Task { try await manager.abort(pending) }
        await process.waitUntilTerminationEntered()

        await expectToolError("invalid_arguments") {
            try await manager.commit(
                pending, device: "fenix6xpro", prgPath: URL(fileURLWithPath: "/tmp/app.prg"),
                sdk: sampleSessionSDK())
        }
        await expectToolError("invalid_arguments") {
            try await manager.beginPending(
                executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["replacement.prg"])
        }
        #expect(runner.startCount == 1)
        process.releaseTermination()
        try await abort.value
        await expectToolError("no_current_session") { try await manager.logs(limit: 10) }
    }

    @Test("cleanup failure propagates and retains the pending ownership for retry")
    func cleanupFailureRetainsPendingOwnership() async throws {
        let process = ControlledSessionProcess()
        let base = SessionTestLifecycle(
            processRunner: SessionTestRunner(processes: [process]))
        let manager = AppSessionManager(lifecycle: FailingTerminationLifecycle(base: base))
        let pending = try await manager.beginPending(MonkeydoCommand(
            sdk: sampleSessionSDK(),
            prgPath: URL(fileURLWithPath: "/tmp/app.prg"),
            device: "fenix6xpro",
            testFilter: nil))

        do {
            try await manager.abort(pending)
            Issue.record("uncertain cleanup must fail the operation")
        } catch let error as ToolError {
            #expect(error.code == "monkeydo_cleanup_failed")
        }
        await expectToolError("invalid_arguments") {
            try await manager.beginPending(MonkeydoCommand(
                sdk: sampleSessionSDK(),
                prgPath: URL(fileURLWithPath: "/tmp/new.prg"),
                device: "fenix6xpro",
                testFilter: nil))
        }
        await expectToolError("no_current_session") { try await manager.logs(limit: 10) }
    }

    @Test("aborting an exited wrapper still invokes owned-tree absence cleanup")
    func exitedPendingWrapperStillUsesLifecycleCleanup() async throws {
        let process = ControlledSessionProcess()
        let lifecycle = CountingSessionLifecycle(base: SessionTestLifecycle(
            processRunner: SessionTestRunner(processes: [process])))
        let manager = AppSessionManager(lifecycle: lifecycle)
        let pending = try await manager.beginPending(MonkeydoCommand(
            sdk: sampleSessionSDK(),
            prgPath: URL(fileURLWithPath: "/tmp/app.prg"),
            device: "fenix6xpro",
            testFilter: nil))
        process.finish(exitCode: 0)
        await manager.waitForPendingExitForTesting()

        try await manager.abort(pending)

        #expect(lifecycle.terminationCount == 1)
        #expect(process.waitCount == 1)
    }

    @Test("cancellation during launch cleans up a runner that returns late")
    func cancelledLaunchCleansUpLateChild() async throws {
        let process = ControlledSessionProcess()
        let runner = StartGateSessionRunner(process: process)
        let manager = AppSessionManager(processRunner: runner)
        let launch = Task {
            try await manager.beginPending(
                executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["app.prg"])
        }
        await runner.waitUntilStartEntered()

        launch.cancel()
        runner.releaseStart()

        do {
            _ = try await launch.value
            Issue.record("a cancelled launch must not return a pending session")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(process.terminationGraces == [.seconds(5)])
        #expect(process.terminationCancellationStates == [false])
        await expectToolError("no_current_session") { try await manager.logs(limit: 10) }
    }

    @Test("current ended session remains readable and repeated exit cannot rewrite it")
    func endedSessionAndExactlyOnceExit() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        let id = try await publish(process: process, manager: manager)
        process.emit("hello\n", stream: .stdout)
        process.finish(exitCode: 0)
        await manager.waitForCurrentExitForTesting()

        var result = try await manager.logs(limit: 10)
        #expect(result.sessionId == Int(id))
        #expect(result.state == "exited")
        #expect(result.terminationReason == "normal")
        #expect(result.exitCode == 0)
        #expect(result.lines.map(\.text) == ["hello"])

        await manager.childExitedForTesting(
            sessionId: id, output: ProcessOutput(exitCode: 99, stdout: Data(), stderr: Data()))
        result = try await manager.logs(limit: 10)
        #expect(result.exitCode == 0)
        #expect(result.terminationReason == "normal")
    }

    @Test("commit transfers pending stdout and stderr including chunk boundaries")
    func pendingEventsTransferAndPartialLinesFlush() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        let pending = try await manager.beginPending(
            executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["app.prg"])
        process.emit("out-part", stream: .stdout)
        process.emit("ial\n", stream: .stdout)
        process.emit("unterminated", stream: .stderr)

        _ = try await manager.commit(
            pending, device: "fenix6xpro", prgPath: URL(fileURLWithPath: "/tmp/app.prg"),
            sdk: sampleSessionSDK())
        var running = try await manager.logs(limit: 10)
        #expect(running.lines.map(\.text) == ["out-partial"])
        #expect(running.lines.map(\.stream) == [.stdout])

        process.finish(exitCode: 0)
        await manager.waitForCurrentExitForTesting()
        running = try await manager.logs(limit: 10)
        #expect(running.lines.map(\.text) == ["out-partial", "unterminated"])
        #expect(running.lines.map(\.stream) == [.stdout, .stderr])
    }

    @Test("replacement preparation terminates but failed candidate leaves old session readable")
    func failedReplacementLeavesEndedCurrent() async throws {
        let old = ControlledSessionProcess()
        let candidate = ControlledSessionProcess()
        let manager = AppSessionManager(
            processRunner: SessionTestRunner(processes: [old, candidate]))
        let oldID = try await publish(process: old, manager: manager)
        old.emit("old\n", stream: .stdout)

        try await manager.prepareCurrentForReplacement()

        #expect(old.terminationGraces == [.seconds(5)])
        var result = try await manager.logs(limit: 10)
        #expect(result.sessionId == Int(oldID))
        #expect(result.state == "exited")
        #expect(result.terminationReason == "killed")

        let pending = try await manager.beginPending(
            executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["candidate.prg"])
        candidate.emit("candidate\n", stream: .stderr)
        try await manager.abort(pending)

        result = try await manager.logs(limit: 10)
        #expect(result.sessionId == Int(oldID))
        #expect(result.lines.map(\.text) == ["old"])
    }

    @Test("begin rejects a running current session without mutating it")
    func beginRequiresPriorReplacementPreparation() async throws {
        let old = ControlledSessionProcess()
        let candidate = ControlledSessionProcess()
        let runner = SessionTestRunner(processes: [old, candidate])
        let manager = AppSessionManager(processRunner: runner)
        let oldID = try await publish(process: old, manager: manager)
        old.emit("preserve-old\n", stream: .stdout)

        await expectToolError("invalid_arguments") {
            try await manager.beginPending(
                executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["new.prg"])
        }

        let oldLogs = try await manager.logs(limit: 10)
        #expect(oldLogs.sessionId == Int(oldID))
        #expect(oldLogs.state == "running")
        #expect(oldLogs.lines.map(\.text) == ["preserve-old"])
        #expect(old.terminationGraces.isEmpty)
        #expect(runner.startCount == 1)
    }

    @Test("a real candidate start failure after preparation leaves old ended session readable")
    func candidateStartFailurePreservesPreparedOld() async throws {
        let old = ControlledSessionProcess()
        let launchError = ToolError(
            code: "app_launch_failed", message: "candidate failed to start.",
            fix: "Check the candidate and retry.")
        let runner = SessionTestRunner(
            processes: [old], launchErrorsByStart: [2: launchError])
        let manager = AppSessionManager(processRunner: runner)
        let oldID = try await publish(process: old, manager: manager)
        old.emit("still-readable\n", stream: .stdout)
        try await manager.prepareCurrentForReplacement()

        do {
            _ = try await manager.beginPending(
                executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["bad.prg"])
            Issue.record("the candidate launch must fail")
        } catch let error as ToolError {
            #expect(error == launchError)
        }

        let logs = try await manager.logs(limit: 10)
        #expect(logs.sessionId == Int(oldID))
        #expect(logs.state == "exited")
        #expect(logs.terminationReason == "killed")
        #expect(logs.lines.map(\.text) == ["still-readable"])
    }

    @Test("successful replacement invalidates old cursor and names the newer session")
    func replacementCreatesTombstone() async throws {
        let old = ControlledSessionProcess()
        let newer = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [old, newer]))
        let oldID = try await publish(process: old, manager: manager)
        old.emit("old\n", stream: .stdout)
        let oldToken = try await manager.logs(limit: 10).nextToken
        try await manager.prepareCurrentForReplacement()
        let newID = try await publish(process: newer, manager: manager)

        do {
            _ = try await manager.logs(sessionId: oldID, sinceToken: oldToken, limit: 10)
            Issue.record("a replaced cursor must be stale")
        } catch let error as ToolError {
            #expect(error.code == "stale_session")
            #expect(error.details?["sessionId"] == JSONValue.int(Int(oldID)))
            #expect(error.details?["newerSessionId"] == JSONValue.int(Int(newID)))
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("ring overflow and cursor pagination never duplicate lines")
    func boundedRingAndPagination() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        _ = try await publish(process: process, manager: manager)
        let text = (1...10_005).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        process.emit(text, stream: .stdout)

        let first = try await manager.logs(limit: 2_000)
        #expect(first.droppedLines == 5)
        #expect(first.lines.count == 2_000)
        #expect(first.lines.first?.seq == 6)
        #expect(first.lines.last?.seq == 2_005)

        let second = try await manager.logs(sinceToken: first.nextToken, limit: 2_000)
        #expect(second.lines.first?.seq == 2_006)
        #expect(Set(first.lines.map(\.seq)).isDisjoint(with: second.lines.map(\.seq)))

        var token = second.nextToken
        while true {
            let page = try await manager.logs(sinceToken: token, limit: 2_000)
            if page.lines.isEmpty {
                #expect(page.nextToken == token)
                break
            }
            token = page.nextToken
        }
        let emptyAgain = try await manager.logs(sinceToken: token, limit: 2_000)
        #expect(emptyAgain.lines.isEmpty)
        #expect(emptyAgain.nextToken == token)

        await expectToolError("invalid_arguments") { try await manager.logs(limit: 0) }
        await expectToolError("invalid_arguments") { try await manager.logs(limit: 2_001) }
    }

    @Test("circular ring preserves chronology through multiple capacity wraps")
    func circularRingMultipleWraps() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        _ = try await publish(process: process, manager: manager)
        let text = (1...25_005).map { "wrap-\($0)" }.joined(separator: "\n") + "\n"
        process.emit(text, stream: .stdout)

        var lines: [LogLine] = []
        var token: String?
        repeat {
            let page = try await manager.logs(sinceToken: token, limit: 2_000)
            lines.append(contentsOf: page.lines)
            token = page.nextToken
            if page.lines.isEmpty { break }
        } while true

        #expect(lines.count == 10_000)
        #expect(lines.first?.seq == 15_006)
        #expect(lines.last?.seq == 25_005)
        #expect(lines.first?.text == "wrap-15006")
        #expect(lines.last?.text == "wrap-25005")
        #expect(try await manager.logs(limit: 1).droppedLines == 15_005)
    }

    @Test("log sequence exhaustion never duplicates UInt64.max")
    func checkedLogSequenceAllocation() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(
            processRunner: SessionTestRunner(processes: [process]),
            initialLogSequence: UInt64.max - 1)
        _ = try await publish(process: process, manager: manager)
        process.emit("penultimate\nmaximum\ndropped-after-exhaustion\n", stream: .stdout)

        #expect(await manager.logSequencesForTesting == [UInt64.max - 1, UInt64.max])
        await expectToolError("log_sequence_exhausted") { try await manager.logs(limit: 10) }
    }

    @Test("timestamps are clamped monotonic across backward clock input")
    func timestampsNeverDecrease() async throws {
        let process = ControlledSessionProcess()
        let nanos = ScriptedNanos([100, 50, 200])
        let manager = AppSessionManager(
            processRunner: SessionTestRunner(processes: [process]),
            timestampNanos: { nanos.next() })
        _ = try await publish(process: process, manager: manager)
        process.emit("one\ntwo\nthree\n", stream: .stdout)

        let lines = try await manager.logs(limit: 10).lines
        #expect(lines.map(\.monotonicNanos) == [100, 100, 200])
    }

    @Test("stream tags and crash patterns are retained after the crash line is evicted")
    func streamsAndStickyCrashSummary() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        _ = try await publish(process: process, manager: manager)
        process.emit("ordinary\n", stream: .stdout)
        process.emit("Fatal Error: exploded\n", stream: .stderr)
        process.emit("ERROR: fenix6xpro: CompilerProbe.mc:1: compile summary\n", stream: .stderr)
        let filler = (1...10_000).map { "filler-\($0)" }.joined(separator: "\n") + "\n"
        process.emit(filler, stream: .stdout)

        let result = try await manager.logs(limit: 2_000)
        #expect(result.crashDetected)
        #expect(!result.lines.contains(where: { $0.text.contains("Fatal Error") }))
        #expect(result.lines.allSatisfy { $0.stream == .stdout })
    }

    @Test("all crash markers are flagged while compiler and test summaries are excluded")
    func crashPatternCoverageAndExclusions() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        _ = try await publish(process: process, manager: manager)
        process.emit("Stack Trace:\n", stream: .stdout)
        process.emit("Error: Array Out Of Bounds Error\n", stream: .stdout)
        process.emit("Unhandled Exception: boom\n", stream: .stderr)
        process.emit("Fatal Error: boom\n", stream: .stderr)
        process.emit("ERROR: fenix6xpro: X.mc:1: compiler summary\n", stream: .stderr)
        process.emit("probe_error                         ERROR\n", stream: .stdout)

        let lines = try await manager.logs(limit: 20).lines
        #expect(lines.prefix(4).allSatisfy { $0.crash })
        #expect(lines.suffix(2).allSatisfy { !$0.crash })
    }

    @Test("nonzero exit without crash marker is killed with its exit code")
    func nonzeroExitIsKilled() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        _ = try await publish(process: process, manager: manager)
        process.finish(exitCode: 17)
        await manager.waitForCurrentExitForTesting()

        let result = try await manager.logs(limit: 10)
        #expect(result.terminationReason == "killed")
        #expect(result.exitCode == 17)
        #expect(!result.crashDetected)
    }

    @Test("pre-exit cursors remain valid after normal and crash exits")
    func preExitTokensRemainValid() async throws {
        let normalProcess = ControlledSessionProcess()
        let normal = AppSessionManager(
            processRunner: SessionTestRunner(processes: [normalProcess]))
        _ = try await publish(process: normalProcess, manager: normal)
        normalProcess.emit("before-normal\n", stream: .stdout)
        let normalToken = try await normal.logs(limit: 10).nextToken
        normalProcess.finish(exitCode: 0)
        await normal.waitForCurrentExitForTesting()
        let normalAfter = try await normal.logs(sinceToken: normalToken, limit: 10)
        #expect(normalAfter.lines.isEmpty)
        #expect(normalAfter.terminationReason == "normal")

        let crashProcess = ControlledSessionProcess()
        let crash = AppSessionManager(
            processRunner: SessionTestRunner(processes: [crashProcess]))
        _ = try await publish(process: crashProcess, manager: crash)
        crashProcess.emit("before-crash\n", stream: .stdout)
        let crashToken = try await crash.logs(limit: 10).nextToken
        crashProcess.emit("Error: exploded\n", stream: .stderr)
        crashProcess.finish(exitCode: 1)
        await crash.waitForCurrentExitForTesting()
        let crashAfter = try await crash.logs(sinceToken: crashToken, limit: 10)
        #expect(crashAfter.lines.map(\.text) == ["Error: exploded"])
        #expect(crashAfter.terminationReason == "crashDetected")
    }

    @Test("malformed foreign and explicitly mismatched tokens are rejected")
    func strictCursorValidation() async throws {
        let process = ControlledSessionProcess()
        let instanceID = UUID()
        let manager = AppSessionManager(
            processRunner: SessionTestRunner(processes: [process]), instanceID: instanceID)
        let id = try await publish(process: process, manager: manager)
        process.emit("line\n", stream: .stdout)
        let token = try await manager.logs(limit: 10).nextToken

        await expectToolError("invalid_log_token") {
            try await manager.logs(sinceToken: "not base64!", limit: 10)
        }
        await expectToolError("invalid_log_token") {
            try await manager.logs(sessionId: id + 1, sinceToken: token, limit: 10)
        }

        let foreignProcess = ControlledSessionProcess()
        let foreign = AppSessionManager(
            processRunner: SessionTestRunner(processes: [foreignProcess]))
        _ = try await publish(process: foreignProcess, manager: foreign)
        foreignProcess.emit("foreign\n", stream: .stdout)
        let foreignToken = try await foreign.logs(limit: 10).nextToken
        await expectToolError("invalid_log_token") {
            try await manager.logs(sinceToken: foreignToken, limit: 10)
        }
        await expectToolError("invalid_log_token") {
            try await manager.logs(
                sinceToken: encodedCursor(
                    version: 2, instanceID: instanceID, sessionID: id, seq: 0), limit: 10)
        }
        await expectToolError("invalid_log_token") {
            try await manager.logs(
                sinceToken: encodedCursor(
                    version: 1, instanceID: instanceID, sessionID: id + 100, seq: 0), limit: 10)
        }
    }

    @Test("crash classification wins over manager termination")
    func crashWinsClassification() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        _ = try await publish(process: process, manager: manager)
        process.emit("Unhandled Exception: boom\n", stream: .stderr)

        try await manager.terminateCurrent(reason: .killed)

        let result = try await manager.logs(limit: 10)
        #expect(result.terminationReason == "crashDetected")
        #expect(result.crashDetected)
        #expect(result.exitCode == -15)
        #expect(result.lines.first?.stream == .stderr)
        #expect(result.lines.first?.crash == true)
    }

    @Test("public termination reasons cannot fabricate normal or crash classifications")
    func publicTerminationAlwaysMeansKilled() async throws {
        for suppliedReason in [TerminationReason.normal, .crashDetected] {
            let process = ControlledSessionProcess()
            let manager = AppSessionManager(
                processRunner: SessionTestRunner(processes: [process]))
            _ = try await publish(process: process, manager: manager)

            try await manager.terminateCurrent(reason: suppliedReason)

            let result = try await manager.logs(limit: 10)
            #expect(result.terminationReason == "killed")
            #expect(!result.crashDetected)
        }
    }

    @Test("trailing partial lines preserve cross-stream callback arrival order")
    func trailingPartialsPreserveArrivalOrder() async throws {
        let process = ControlledSessionProcess()
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: [process]))
        _ = try await publish(process: process, manager: manager)
        process.emit("stderr-first", stream: .stderr)
        process.emit("stdout-second", stream: .stdout)
        process.finish(exitCode: 0)
        await manager.waitForCurrentExitForTesting()

        let lines = try await manager.logs(limit: 10).lines
        #expect(lines.map(\.stream) == [.stderr, .stdout])
        #expect(lines.map(\.text) == ["stderr-first", "stdout-second"])
    }

    @Test("tombstones stay bounded and evicted old tokens are still stale")
    func tombstonesStayBounded() async throws {
        let processes = (0..<35).map { _ in ControlledSessionProcess() }
        let manager = AppSessionManager(processRunner: SessionTestRunner(processes: processes))
        _ = try await publish(process: processes[0], manager: manager)
        processes[0].emit("first\n", stream: .stdout)
        let firstToken = try await manager.logs(limit: 10).nextToken

        for process in processes.dropFirst() {
            try await manager.prepareCurrentForReplacement()
            _ = try await publish(process: process, manager: manager)
        }

        #expect(await manager.tombstoneCountForTesting == 32)
        do {
            _ = try await manager.logs(sinceToken: firstToken, limit: 10)
            Issue.record("an old same-instance token cannot reset to the current buffer")
        } catch let error as ToolError {
            #expect(error.code == "stale_session")
            #expect(error.details?["newerSessionId"] == .int(35))
        }
    }

    @Test("session ID exhaustion is actionable and does not launch a child")
    func checkedSessionIDs() async throws {
        let process = ControlledSessionProcess()
        let runner = SessionTestRunner(processes: [process])
        let manager = AppSessionManager(processRunner: runner, initialSessionID: UInt64.max)

        await expectToolError("session_id_exhausted") {
            try await manager.beginPending(
                executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: [])
        }
        #expect(runner.startCount == 0)
    }

    private func publish(
        process: ControlledSessionProcess,
        manager: AppSessionManager
    ) async throws -> UInt64 {
        let pending = try await manager.beginPending(
            executable: URL(fileURLWithPath: "/sdk/monkeydo"), arguments: ["app.prg"])
        return try await manager.commit(
            pending, device: "fenix6xpro", prgPath: URL(fileURLWithPath: "/tmp/app.prg"),
            sdk: sampleSessionSDK())
    }

    private func expectToolError<T: Sendable>(
        _ code: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async {
        do {
            _ = try await operation()
            Issue.record("expected ToolError \(code)")
        } catch let error as ToolError {
            #expect(error.code == code)
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        } catch {
            Issue.record("expected ToolError \(code), got \(error)")
        }
    }
}

private func sampleSessionSDK() -> SdkInfo {
    SdkInfo(
        version: SemVer("9.1.0")!, root: URL(fileURLWithPath: "/sdk/9.1.0"),
        source: .explicit)
}

// Test-only migration adapter: production AppSessionManager accepts only an
// owned monkeydo lifecycle. Keeping the old fake runners behind this adapter
// lets the Task 9 log/cursor matrix exercise the new ownership boundary
// without weakening the production API.
private extension AppSessionManager {
    init(
        processRunner: any ProcessRunning,
        instanceID: UUID = UUID(),
        timestampNanos: (@Sendable () -> Int64)? = nil,
        initialSessionID: UInt64 = 1,
        initialLogSequence: UInt64 = 1,
        diagnosticSink: @escaping Log.Sink = Log.standardError
    ) {
        self.init(
            lifecycle: SessionTestLifecycle(processRunner: processRunner),
            instanceID: instanceID,
            timestampNanos: timestampNanos,
            initialSessionID: initialSessionID,
            initialLogSequence: initialLogSequence,
            diagnosticSink: diagnosticSink)
    }

    func beginPending(executable: URL, arguments: [String]) async throws -> PendingSession {
        let sdk = sampleSessionSDK()
        return try await beginPending(MonkeydoCommand(
            sdk: sdk,
            prgPath: URL(fileURLWithPath: arguments.first ?? "/tmp/app.prg"),
            device: arguments.dropFirst().first ?? "fenix6xpro",
            testFilter: nil))
    }
}

private struct SessionTestLifecycle: MonkeydoProcessLifecycling, Sendable {
    let processRunner: any ProcessRunning

    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await launch(
            command, suffix: [], workingDirectory: nil, timeout: nil,
            onStdout: onStdout, onStderr: onStderr)
    }

    func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await launch(
            command, suffix: TestTranscriptParser.testArguments(filter: command.testFilter),
            workingDirectory: workingDirectory, timeout: timeout,
            onStdout: onStdout, onStderr: onStderr)
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {
        let cleanup = Task.detached {
            await owned.process.terminate(grace: grace)
            _ = try await owned.output()
        }
        try await cleanup.value
    }

    func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership, grace: Duration
    ) async throws {}

    private func launch(
        _ command: MonkeydoCommand,
        suffix: [String],
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        let process = try await processRunner.start(
            executable: command.sdk.monkeydo,
            arguments: [command.prgPath.path, command.device] + suffix,
            environment: nil,
            workingDirectory: workingDirectory,
            timeout: timeout,
            onStdout: onStdout,
            onStderr: onStderr)
        return OwnedMonkeydoProcess(
            process: process,
            launcher: ProcessIdentitySnapshot(
                pid: process.pid,
                parentPid: 1,
                processGroupId: process.pid,
                start: ProcessStartIdentity(seconds: 1, microseconds: UInt64(process.pid)),
                executablePath: "/bin/bash",
                arguments: ["/bin/bash", command.sdk.monkeydo.path,
                    command.prgPath.path, command.device] + suffix),
            command: command)
    }
}

private struct FailingTerminationLifecycle: MonkeydoProcessLifecycling, Sendable {
    let base: SessionTestLifecycle

    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await base.launchApp(command, onStdout: onStdout, onStderr: onStderr)
    }

    func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await base.launchTests(
            command, workingDirectory: workingDirectory, timeout: timeout,
            onStdout: onStdout, onStderr: onStderr)
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {
        throw ToolError(
            code: "monkeydo_cleanup_failed",
            message: "The owned tree could not be proven safe to signal.",
            fix: "Inspect the retained ownership before retrying cleanup.")
    }

    func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership, grace: Duration
    ) async throws {
        throw ToolError(
            code: "monkeydo_cleanup_failed",
            message: "The persisted tree could not be proven safe to signal.",
            fix: "Inspect the retained ownership before retrying cleanup.")
    }
}

private final class CountingSessionLifecycle: MonkeydoProcessLifecycling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let base: SessionTestLifecycle
    private var terminations = 0

    init(base: SessionTestLifecycle) { self.base = base }
    var terminationCount: Int { lock.withLock { terminations } }

    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await base.launchApp(command, onStdout: onStdout, onStderr: onStderr)
    }

    func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await base.launchTests(
            command, workingDirectory: workingDirectory, timeout: timeout,
            onStdout: onStdout, onStderr: onStderr)
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {
        lock.withLock { terminations += 1 }
        try await base.terminate(owned, grace: grace)
    }

    func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership, grace: Duration
    ) async throws {
        lock.withLock { terminations += 1 }
        try await base.terminatePersisted(ownership, grace: grace)
    }
}

private func encodedCursor(
    version: Int, instanceID: UUID, sessionID: UInt64, seq: UInt64
) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "version": version,
            "instanceId": instanceID.uuidString.lowercased(),
            "sessionId": sessionID,
            "seq": seq,
        ], options: [.sortedKeys])
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private final class ScriptedNanos: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]

    init(_ values: [Int64]) { self.values = values }

    func next() -> Int64 {
        lock.withLock { values.isEmpty ? 0 : values.removeFirst() }
    }
}

private final class SessionTestRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ControlledSessionProcess]
    private let launchError: ToolError?
    private let launchErrorsByStart: [Int: ToolError]
    private var starts = 0

    init(
        processes: [ControlledSessionProcess],
        launchError: ToolError? = nil,
        launchErrorsByStart: [Int: ToolError] = [:]
    ) {
        self.processes = processes
        self.launchError = launchError
        self.launchErrorsByStart = launchErrorsByStart
    }

    var startCount: Int { lock.withLock { starts } }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess {
        let process: ControlledSessionProcess = try lock.withLock {
            starts += 1
            if let launchError { throw launchError }
            if let launchError = launchErrorsByStart[starts] { throw launchError }
            guard !processes.isEmpty else {
                throw ToolError(
                    code: "app_launch_failed", message: "No fake process was queued.",
                    fix: "Queue a fake process before launching.")
            }
            return processes.removeFirst()
        }
        process.attach(onStdout: onStdout, onStderr: onStderr)
        return process
    }
}

private final class ControlledSessionProcess: RunningProcess, @unchecked Sendable {
    nonisolated let pid: Int32

    private let lock = NSLock()
    private var stdout: (@Sendable (Data) -> Void)?
    private var stderr: (@Sendable (Data) -> Void)?
    private var output: ProcessOutput?
    private var waiters: [CheckedContinuation<ProcessOutput, Never>] = []
    private var waits = 0
    private var graces: [Duration] = []
    private var terminationWasCancelled: [Bool] = []
    private let blockTermination: Bool
    private var terminationEntered = false
    private var terminationEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationRelease: CheckedContinuation<Void, Never>?
    private var terminationReleased = false

    init(pid: Int32 = 4242, blockTermination: Bool = false) {
        self.pid = pid
        self.blockTermination = blockTermination
    }

    var terminationGraces: [Duration] { lock.withLock { graces } }
    var terminationCancellationStates: [Bool] { lock.withLock { terminationWasCancelled } }
    var waitCount: Int { lock.withLock { waits } }

    func attach(
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
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
                waits += 1
                if let output { return output }
                waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    func terminate(grace: Duration) async {
        let enteredWaiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            graces.append(grace)
            terminationWasCancelled.append(Task.isCancelled)
            terminationEntered = true
            defer { terminationEnteredWaiters.removeAll() }
            return terminationEnteredWaiters
        }
        enteredWaiters.forEach { $0.resume() }
        if blockTermination {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if terminationReleased { return true }
                    terminationRelease = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        finish(exitCode: -15)
    }

    func waitUntilTerminationEntered() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if terminationEntered { return true }
                terminationEnteredWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseTermination() {
        let continuation = lock.withLock {
            terminationReleased = true
            defer { terminationRelease = nil }
            return terminationRelease
        }
        continuation?.resume()
    }
}

private final class StartGateSessionRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let process: ControlledSessionProcess
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(process: ControlledSessionProcess) { self.process = process }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            entered = true
            defer { enteredWaiters.removeAll() }
            return enteredWaiters
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if released { return true }
                releaseContinuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        process.attach(onStdout: onStdout, onStderr: onStderr)
        return process
    }

    func waitUntilStartEntered() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if entered { return true }
                enteredWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseStart() {
        let continuation = lock.withLock {
            released = true
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume()
    }
}
