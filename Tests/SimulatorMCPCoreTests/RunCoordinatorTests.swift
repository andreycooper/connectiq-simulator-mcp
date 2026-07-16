import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("RunCoordinator")
struct RunCoordinatorTests {
    @Test("one run_app lease spans build through verified publication in exact order")
    func appLeaseTraceIsExact() async throws {
        let fixture = CoordinatorFixture()
        let trace = CoordinatorTrace()
        let runner = CoordinatorRunner(
            processes: [CoordinatorProcess(pid: 7000, output: nil)], trace: trace)
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext, trace: trace),
            compiler: CoordinatorCompiler(
                outcomes: [fixture.successfulBuild(mode: .debugApp)], trace: trace),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 7000, trace: trace))

        _ = try await coordinator.runApp(fixture.appRequest)

        #expect(trace.values == [
            "run_app.lease.begin", "build.debugApp", "terminate_shared",
            "process.start", "connection.probe", "active.pid+device", "run_app.lease.end",
        ])
    }

    @Test("run_app forwards the exact accepted connection to the evidence observer")
    func appForwardsExactAcceptedEvidence() async throws {
        let fixture = CoordinatorFixture()
        let runner = CoordinatorRunner(
            processes: [CoordinatorProcess(pid: 7005, output: nil)])
        let probeCapture = CoordinatorEvidenceRecorder()
        let observer = CoordinatorEvidenceRecorder()
        let probe = CoordinatorProbe { owned in
            let accepted = coordinatorConnection(owned)
            await probeCapture.accepted(accepted)
            return accepted
        }
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(
                outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: probe,
            evidenceObserver: observer)

        _ = try await coordinator.runApp(fixture.appRequest)

        #expect(await observer.values == probeCapture.values)
        #expect(await observer.values.first?.launcher.pid == 7005)
    }

    @Test("one run_tests lease spans build through transcript cleanup in exact order")
    func testsLeaseTraceIsExact() async throws {
        let fixture = CoordinatorFixture()
        let trace = CoordinatorTrace()
        let runner = CoordinatorRunner(
            processes: [CoordinatorProcess(
                pid: 8000,
                output: ProcessOutput(
                    exitCode: 1,
                    stdout: Data(CoordinatorFixture.passingTranscript.utf8), stderr: Data()))],
            trace: trace)
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext, trace: trace),
            compiler: CoordinatorCompiler(
                outcomes: [fixture.successfulBuild(mode: .unitTests)], trace: trace),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 8000, trace: trace))

        _ = try await coordinator.runTests(fixture.testsRequest(filter: nil))

        #expect(trace.values == [
            "run_tests.lease.begin", "terminate_shared", "build.unitTests",
            "process.start", "active.pid", "connection.probe", "active.device",
            "run_tests.lease.end",
        ])
    }

    @Test("trailing partial transcript lines preserve callback arrival order")
    func partialTranscriptOrder() {
        let collector = OrderedTranscriptCollector()
        collector.append(Data("stderr-tail".utf8), stream: .stderr)
        collector.append(Data("stdout-tail".utf8), stream: .stdout)

        collector.finish()

        #expect(collector.events.map(\.stream) == [.stderr, .stdout])
        #expect(collector.events.map(\.line) == ["stderr-tail", "stdout-tail"])
    }

    @Test("a complete transcript is observable before monkeydo exits")
    func completeTranscriptDoesNotRequireProcessExit() async throws {
        let collector = OrderedTranscriptCollector()

        collector.append(
            Data((CoordinatorFixture.passingTranscript + "\n").utf8), stream: .stdout)

        let summary = try await collector.waitForSummary()
        #expect(summary.overallPassed)
        #expect(summary.passed == 1)
    }

    @Test("run_app holds one operation across build, replacement, connection, and publication")
    func runAppOrdering() async throws {
        let fixture = CoordinatorFixture()
        let process = CoordinatorProcess(pid: 7001, output: nil)
        let monkeydo = CoordinatorRunner(processes: [process])
        let sessions = AppSessionManager(processRunner: monkeydo)
        let compiler = CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)])
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: compiler,
            sessionManager: sessions,
            processRunner: monkeydo,
            connectionProbe: fixture.connectedProbe(pid: 7001))

        let result = try await coordinator.runApp(fixture.appRequest)

        #expect(result.sessionId == 1)
        #expect(result.device == "fenix6xpro")
        #expect(result.rebuilt)
        #expect(monkeydo.invocations.first?.arguments == [
            fixture.prg.path, "fenix6xpro",
        ])
        #expect(await controller.events == [
            "run_app.begin", "terminate_shared", "active:7001:fenix6xpro", "run_app.end",
        ])
        #expect(await compiler.requests.map(\.mode) == [.debugApp])
    }

    @Test("a build failure starts no monkeydo child")
    func buildFailureStartsNothing() async throws {
        let fixture = CoordinatorFixture()
        let monkeydo = CoordinatorRunner(processes: [])
        let compiler = CoordinatorCompiler(outcomes: [fixture.failedBuild(mode: .debugApp)])
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: compiler,
            sessionManager: AppSessionManager(processRunner: monkeydo),
            processRunner: monkeydo,
            connectionProbe: fixture.connectedProbe(pid: 7001))

        do {
            _ = try await coordinator.runApp(fixture.appRequest)
            Issue.record("a failed build must fail run_app")
        } catch let error as ToolError {
            #expect(error.code == "build_failed")
            #expect(!error.fix.isEmpty)
            #expect(error.details?["diagnostics"] == .array([
                .object([
                    "file": .string("source/App.mc"),
                    "line": .int(1),
                    "column": .int(1),
                    "severity": .string("error"),
                    "message": .string("captured compile failure"),
                ])
            ]))
        }
        #expect(monkeydo.invocations.isEmpty)
        #expect(await controller.events == ["run_app.begin", "run_app.end"])
    }

    @Test("run_tests trusts a complete passing transcript despite monkeydo exit 1")
    func passingTranscriptOverridesExitCode() async throws {
        let fixture = CoordinatorFixture()
        let process = CoordinatorProcess(
            pid: 8001,
            output: ProcessOutput(
                exitCode: 1, stdout: Data(CoordinatorFixture.passingTranscript.utf8), stderr: Data()))
        let monkeydo = CoordinatorRunner(processes: [process])
        let controller = CoordinatorController(context: fixture.operationContext)
        let compiler = CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)])
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: compiler,
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: monkeydo,
            connectionProbe: fixture.connectedProbe(pid: 8001))

        let result = try await coordinator.runTests(fixture.testsRequest(filter: "probe_pass"))

        #expect(result.overallPassed)
        #expect(result.passed == 1)
        #expect(result.failed == 0)
        #expect(monkeydo.invocations.first?.arguments == [
            fixture.prg.path, "fenix6xpro", "-t", "probe_pass",
        ])
        #expect(monkeydo.invocations.first?.timeout == .seconds(300))
        #expect(await compiler.requests.first?.force == true)
        #expect(await controller.events == [
            "run_tests.begin", "terminate_shared", "active:8001:nil",
            "active:nil:fenix6xpro", "run_tests.end",
        ])
    }

    @Test("run_tests terminates monkeydo after an authoritative transcript before process exit")
    func passingTranscriptTerminatesLiveMonkeydo() async throws {
        let fixture = CoordinatorFixture()
        let process = CoordinatorProcess(
            pid: 8006,
            output: nil,
            initialStdout: Data((CoordinatorFixture.passingTranscript + "\n").utf8))
        let runner = CoordinatorRunner(processes: [process])
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 8006))

        let result = try await coordinator.runTests(fixture.testsRequest(filter: nil))

        #expect(result.overallPassed)
        #expect(await process.terminationCount == 1)
    }

    @Test("run_tests cleans its owned child when runtime publication fails")
    func testPublicationFailureCleansOwnedChild() async throws {
        let fixture = CoordinatorFixture()
        let process = CoordinatorProcess(
            pid: 8005,
            output: ProcessOutput(exitCode: 1, stdout: Data(), stderr: Data()))
        let runner = CoordinatorRunner(processes: [process])
        let publicationFailure = ToolError(
            code: "internal_error",
            message: "Runtime ownership could not be published.",
            fix: "Check runtime state permissions, then retry.")
        let controller = CoordinatorController(
            context: fixture.operationContext,
            publishErrorOnActive: publicationFailure)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 8005))

        await expectCoordinatorError("internal_error") {
            try await coordinator.runTests(fixture.testsRequest(filter: nil))
        }

        #expect(await process.terminationCount == 1)
        #expect(await controller.events == [
            "run_tests.begin", "terminate_shared", "active:nil:nil", "run_tests.end",
        ])
    }

    @Test("a complete short-lived test transcript proves connection when lsof misses it")
    func shortLivedTranscriptProvesConnection() async throws {
        let fixture = CoordinatorFixture()
        let process = CoordinatorProcess(
            pid: 8003,
            output: ProcessOutput(
                exitCode: 1, stdout: Data(CoordinatorFixture.passingTranscript.utf8), stderr: Data()))
        let runner = CoordinatorRunner(processes: [process])
        let probe = CoordinatorProbe { owned in
            throw coordinatorEarlyExit(pid: owned.launcher.pid)
        }
        let controller = CoordinatorController(context: fixture.operationContext)
        let observer = CoordinatorEvidenceRecorder()
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: runner,
            connectionProbe: probe,
            evidenceObserver: observer)

        let result = try await coordinator.runTests(fixture.testsRequest(filter: "probe_pass"))

        #expect(result.overallPassed)
        #expect(await controller.events.contains("active:nil:fenix6xpro"))
        #expect(await observer.values.isEmpty)
    }

    @Test("an early-exit output failure still attempts owned-process cleanup")
    func earlyExitOutputFailureStillCleans() async throws {
        let fixture = CoordinatorFixture()
        let outputFailure = ToolError(
            code: "process_wait_failed",
            message: "The monkeydo output drain failed.",
            fix: "Retry the test run and inspect the simulator logs if it repeats.")
        let process = CoordinatorProcess(pid: 8004, output: nil, waitError: outputFailure)
        let runner = CoordinatorRunner(processes: [process])
        let probe = CoordinatorProbe { owned in
            throw coordinatorEarlyExit(pid: owned.launcher.pid)
        }
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: runner,
            connectionProbe: probe)

        await expectCoordinatorError("process_wait_failed") {
            try await coordinator.runTests(fixture.testsRequest(filter: nil))
        }

        #expect(await process.terminationCount == 1)
        #expect(await controller.events == [
            "run_tests.begin", "terminate_shared", "active:8004:nil", "run_tests.end",
        ])
    }

    @Test("run_tests retries an incomplete early exit inside one operation")
    func testsRetryIncompleteEarlyExit() async throws {
        let fixture = CoordinatorFixture()
        let first = CoordinatorProcess(
            pid: 8051,
            output: ProcessOutput(
                exitCode: 1, stdout: Data("Executing test probe_pass...\n".utf8), stderr: Data()))
        let second = CoordinatorProcess(
            pid: 8052,
            output: ProcessOutput(
                exitCode: 1, stdout: Data(CoordinatorFixture.passingTranscript.utf8), stderr: Data()))
        let runner = CoordinatorRunner(processes: [first, second])
        let probe = CoordinatorProbe { owned in
            guard owned.launcher.pid == 8052 else {
                throw coordinatorEarlyExit(pid: owned.launcher.pid)
            }
            return coordinatorConnection(owned)
        }
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: runner,
            connectionProbe: probe)

        let result = try await coordinator.runTests(fixture.testsRequest(filter: nil))

        #expect(result.overallPassed)
        #expect(runner.invocations.count == 2)
        #expect(await controller.events.filter { $0 == "revalidate:run_tests" }.count == 1)
    }

    @Test("a complete failing transcript is returned as overallPassed false")
    func failingTranscriptIsAResult() async throws {
        let fixture = CoordinatorFixture()
        let process = CoordinatorProcess(
            pid: 8002,
            output: ProcessOutput(
                exitCode: 0, stdout: Data(CoordinatorFixture.failingTranscript.utf8), stderr: Data()))
        let monkeydo = CoordinatorRunner(processes: [process])
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: monkeydo,
            connectionProbe: fixture.connectedProbe(pid: 8002))

        let result = try await coordinator.runTests(fixture.testsRequest(filter: nil))

        #expect(!result.overallPassed)
        #expect(result.failed == 1)
        #expect(result.errors == 0)
    }

    @Test("the 300-second test timeout cleans the child and releases the operation")
    func testTimeoutCleansAndReleases() async throws {
        let fixture = CoordinatorFixture()
        let timeout = ToolError(
            code: "operation_timeout",
            message: "monkeydo exceeded its 300-second deadline.",
            fix: "Inspect the test for a hang, then retry.")
        let process = CoordinatorProcess(pid: 8060, output: nil, waitError: timeout)
        let runner = CoordinatorRunner(processes: [process])
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 8060))

        await expectCoordinatorError("operation_timeout") {
            try await coordinator.runTests(fixture.testsRequest(filter: nil))
        }

        #expect(runner.invocations.first?.timeout == .seconds(300))
        #expect(await process.terminationCount == 1)
        #expect(await controller.events.last == "run_tests.end")
    }

    @Test("SDK mismatch rejects the operation before build")
    func sdkMismatchBuildsNothing() async throws {
        let fixture = CoordinatorFixture()
        let compiler = CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)])
        let controller = CoordinatorController(
            context: fixture.operationContext,
            startError: ToolError(
                code: "sdk_mismatch", message: "wrong SDK",
                fix: "Restart with the requested SDK."))
        let runner = CoordinatorRunner(processes: [])
        let coordinator = RunCoordinator(
            controller: controller, compiler: compiler,
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 1))

        await expectCoordinatorError("sdk_mismatch") {
            try await coordinator.runApp(fixture.appRequest)
        }
        #expect(await compiler.requests.isEmpty)
        #expect(runner.invocations.isEmpty)
    }

    @Test("an early child exit retries inside the same simulator operation")
    func earlyExitRetries() async throws {
        let fixture = CoordinatorFixture()
        let first = CoordinatorProcess(
            pid: 7101,
            output: ProcessOutput(exitCode: 1, stdout: Data(), stderr: Data("first failed\n".utf8)))
        let second = CoordinatorProcess(pid: 7102, output: nil)
        let runner = CoordinatorRunner(processes: [first, second])
        let probe = CoordinatorProbe { owned in
            guard owned.launcher.pid == 7102 else {
                throw coordinatorEarlyExit(pid: owned.launcher.pid)
            }
            return coordinatorConnection(owned)
        }
        let controller = CoordinatorController(context: fixture.operationContext)
        let sessions = AppSessionManager(processRunner: runner)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: sessions,
            processRunner: runner,
            connectionProbe: probe)

        let result = try await coordinator.runApp(fixture.appRequest)

        #expect(result.sessionId == 2)
        #expect(runner.invocations.count == 2)
        #expect(await controller.events.filter { $0 == "revalidate:run_app" }.count == 1)
    }

    @Test("three failed app attempts publish no session")
    func exhaustedAttemptsPublishNothing() async throws {
        let fixture = CoordinatorFixture()
        let processes = (0..<3).map { offset in
            CoordinatorProcess(
                pid: Int32(7200 + offset),
                output: ProcessOutput(
                    exitCode: 1, stdout: Data(), stderr: Data("attempt-\(offset)\n".utf8)))
        }
        let runner = CoordinatorRunner(processes: processes)
        let probe = CoordinatorProbe { owned in
            throw coordinatorEarlyExit(pid: owned.launcher.pid)
        }
        let sessions = AppSessionManager(processRunner: runner)
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: sessions,
            processRunner: runner,
            connectionProbe: probe)

        do {
            _ = try await coordinator.runApp(fixture.appRequest)
            Issue.record("three early exits must fail")
        } catch let error as ToolError {
            #expect(error.code == "monkeydo_exited")
            #expect(error.details?["lastOutput"] == .array([.string("attempt-2")]))
        }
        await expectCoordinatorError("no_current_session") {
            try await sessions.logs(limit: 10)
        }
        #expect(runner.invocations.count == 3)
    }

    @Test("a failed replacement leaves the killed old session current and readable")
    func failedReplacementPreservesOldSession() async throws {
        let fixture = CoordinatorFixture()
        let old = CoordinatorProcess(pid: 7250, output: nil)
        let failed = (0..<3).map { offset in
            CoordinatorProcess(
                pid: Int32(7251 + offset),
                output: ProcessOutput(exitCode: 1, stdout: Data(), stderr: Data()))
        }
        let runner = CoordinatorRunner(processes: [old] + failed)
        let sessions = AppSessionManager(processRunner: runner)
        let oldPending = try await sessions.beginPending(
            executable: fixture.sdk.monkeydo,
            arguments: [fixture.prg.path, "fenix6xpro"])
        let oldID = try await sessions.commit(
            oldPending, device: "fenix6xpro", prgPath: fixture.prg, sdk: fixture.sdk)
        let probe = CoordinatorProbe { owned in
            throw coordinatorEarlyExit(pid: owned.launcher.pid)
        }
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: sessions,
            processRunner: runner,
            connectionProbe: probe)

        await expectCoordinatorError("monkeydo_exited") {
            try await coordinator.runApp(fixture.appRequest)
        }

        let logs = try await sessions.logs(limit: 10)
        #expect(logs.sessionId == Int(oldID))
        #expect(logs.state == "exited")
        #expect(logs.terminationReason == "killed")
    }

    @Test("runtime publication failure leaves the old session current")
    func publicationFailurePreservesOldSession() async throws {
        let fixture = CoordinatorFixture()
        let old = CoordinatorProcess(pid: 7260, output: nil)
        let candidate = CoordinatorProcess(pid: 7261, output: nil)
        let runner = CoordinatorRunner(processes: [old, candidate])
        let sessions = AppSessionManager(processRunner: runner)
        let oldPending = try await sessions.beginPending(
            executable: fixture.sdk.monkeydo,
            arguments: [fixture.prg.path, "fenix6xpro"])
        let oldID = try await sessions.commit(
            oldPending, device: "fenix6xpro", prgPath: fixture.prg, sdk: fixture.sdk)
        let controller = CoordinatorController(
            context: fixture.operationContext,
            publishErrorOnActive: ToolError(
                code: "internal_error", message: "runtime publication failed",
                fix: "Check runtime state permissions, then retry."))
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: sessions,
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 7261))

        await expectCoordinatorError("internal_error") {
            try await coordinator.runApp(fixture.appRequest)
        }

        let logs = try await sessions.logs(limit: 10)
        #expect(logs.sessionId == Int(oldID))
        #expect(logs.state == "exited")
        #expect(logs.terminationReason == "killed")
    }

    @Test("successful run_app replaces an existing session only after proof")
    func successfulReplacementPublishesNewSession() async throws {
        let fixture = CoordinatorFixture()
        let old = CoordinatorProcess(pid: 7270, output: nil)
        let candidate = CoordinatorProcess(pid: 7271, output: nil)
        let runner = CoordinatorRunner(processes: [old, candidate])
        let sessions = AppSessionManager(processRunner: runner)
        let oldPending = try await sessions.beginPending(
            executable: fixture.sdk.monkeydo,
            arguments: [fixture.prg.path, "fenix6xpro"])
        let oldID = try await sessions.commit(
            oldPending, device: "fenix6xpro", prgPath: fixture.prg, sdk: fixture.sdk)
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: sessions,
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 7271))

        let result = try await coordinator.runApp(fixture.appRequest)

        #expect(result.sessionId == Int(oldID + 1))
        #expect(await old.terminationCount == 1)
        #expect(try await sessions.logs(limit: 10).sessionId == result.sessionId)
        await expectCoordinatorError("stale_session") {
            try await sessions.logs(sessionId: oldID, limit: 10)
        }
    }

    @Test("run_tests terminates a conflicting local app session")
    func testsTerminateCurrentSession() async throws {
        let fixture = CoordinatorFixture()
        let old = CoordinatorProcess(pid: 7301, output: nil)
        let sessionRunner = CoordinatorRunner(processes: [old])
        let sessions = AppSessionManager(processRunner: sessionRunner)
        let pending = try await sessions.beginPending(
            executable: fixture.sdk.monkeydo,
            arguments: [fixture.prg.path, "fenix6xpro"])
        _ = try await sessions.commit(
            pending, device: "fenix6xpro", prgPath: fixture.prg, sdk: fixture.sdk)

        let test = CoordinatorProcess(
            pid: 8301,
            output: ProcessOutput(
                exitCode: 1, stdout: Data(CoordinatorFixture.passingTranscript.utf8), stderr: Data()))
        let testRunner = CoordinatorRunner(processes: [test])
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: sessions,
            processRunner: testRunner,
            connectionProbe: fixture.connectedProbe(pid: 8301))

        _ = try await coordinator.runTests(fixture.testsRequest(filter: nil))

        #expect(await old.terminationCount == 1)
    }

    @Test("cancelling run_app aborts its pending child and clears runtime state")
    func cancellationCleansPendingChild() async throws {
        let fixture = CoordinatorFixture()
        let child = CoordinatorProcess(pid: 7401, output: nil)
        let runner = CoordinatorRunner(processes: [child])
        let observationGate = CoordinatorObservationGate()
        let probe = CoordinatorProbe { _ in
            await observationGate.enterAndWait()
            try Task.checkCancellation()
            throw coordinatorEarlyExit(pid: 7401)
        }
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: probe)
        let task = Task { try await coordinator.runApp(fixture.appRequest) }
        await observationGate.waitUntilEntered()

        task.cancel()
        await observationGate.release()
        do {
            _ = try await task.value
            Issue.record("cancellation must escape run_app")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await child.terminationCount == 1)
        #expect(await controller.events.contains("active:nil:nil"))
        #expect(await controller.events.last == "run_app.end")
    }

    @Test("cancelling run_tests terminates its child and clears runtime state")
    func cancellationCleansTestChild() async throws {
        let fixture = CoordinatorFixture()
        let child = CoordinatorProcess(pid: 8401, output: nil)
        let runner = CoordinatorRunner(processes: [child])
        let observationGate = CoordinatorObservationGate()
        let probe = CoordinatorProbe { _ in
            await observationGate.enterAndWait()
            try Task.checkCancellation()
            throw coordinatorEarlyExit(pid: 8401)
        }
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .unitTests)]),
            sessionManager: AppSessionManager(processRunner: CoordinatorRunner(processes: [])),
            processRunner: runner,
            connectionProbe: probe)
        let task = Task { try await coordinator.runTests(fixture.testsRequest(filter: nil)) }
        await observationGate.waitUntilEntered()

        task.cancel()
        await observationGate.release()
        do {
            _ = try await task.value
            Issue.record("cancellation must escape run_tests")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await child.terminationCount == 1)
        #expect(await controller.events.contains("active:nil:nil"))
        #expect(await controller.events.last == "run_tests.end")
    }
}

private struct CoordinatorFixture {
    let sdk = SdkInfo(
        version: SemVer(major: 9, minor: 1, patch: 0),
        root: URL(fileURLWithPath: "/sdk/9.1.0", isDirectory: true),
        source: .installed)
    let prg = URL(fileURLWithPath: "/project/bin/app.prg")

    var project: ProjectDescriptor {
        ProjectDescriptor(
            root: URL(fileURLWithPath: "/project", isDirectory: true),
            jungle: URL(fileURLWithPath: "/project/monkey.jungle"),
            manifest: URL(fileURLWithPath: "/project/manifest.xml"),
            appName: "app",
            applicationId: "0123456789abcdef0123456789abcdef",
            manifestDevices: ["fenix6xpro"])
    }

    var buildContext: BuildContext {
        BuildContext(
            project: project,
            developerKey: URL(fileURLWithPath: "/keys/developer.der"))
    }

    var operationContext: OperationContext {
        OperationContext(
            simulatorPid: 42,
            sdk: sdk,
            currentDevice: nil,
            listeningEndpoints: [
                TCPEndpoint(address: "127.0.0.1", port: 1234, family: "ipv4")
            ])
    }

    var appRequest: RunAppRequest {
        RunAppRequest(
            project: project, buildContext: buildContext, sdk: sdk,
            device: "fenix6xpro", rebuild: true)
    }

    func testsRequest(filter: String?) -> RunTestsRequest {
        RunTestsRequest(
            project: project, buildContext: buildContext, sdk: sdk,
            device: "fenix6xpro", testFilter: filter)
    }

    func successfulBuild(mode: BuildMode) -> BuildOutcome {
        BuildOutcome(
            succeeded: true, prgPath: prg, rebuilt: true, artifactKey: "artifact",
            device: "fenix6xpro", mode: mode, diagnostics: [])
    }

    func failedBuild(mode: BuildMode) -> BuildOutcome {
        BuildOutcome(
            succeeded: false, prgPath: nil, rebuilt: false, artifactKey: "artifact",
            device: "fenix6xpro", mode: mode,
            diagnostics: [
                BuildDiagnostic(
                    file: "source/App.mc", line: 1, column: 1, severity: .error,
                    message: "captured compile failure")
            ])
    }

    func connectedProbe(pid: Int32, trace: CoordinatorTrace? = nil) -> CoordinatorProbe {
        CoordinatorProbe { owned in
            trace?.append("connection.probe")
            #expect(owned.launcher.pid == pid)
            return coordinatorConnection(owned)
        }
    }

    static let passingTranscript = """
        ------------------------------------------------------------------------------
        Executing test probe_pass...
        DEBUG (19:07): probe_pass ran
        PASS

        ===============================================================================
        RESULTS
        Test:                               Status:
        probe_pass                          PASS
        Ran 1 test

        PASSED (passed=1, failed=0, errors=0)
        """

    static let failingTranscript = """
        ------------------------------------------------------------------------------
        Executing test probe_fail...
        DEBUG (19:07): probe_fail ran
        FAIL

        ===============================================================================
        RESULTS
        Test:                               Status:
        probe_fail                          FAIL
        Ran 1 test

        FAILED (passed=0, failed=1, errors=0)
        """
}

private struct CoordinatorProbe: MonkeydoConnectionProbing, Sendable {
    let operation: @Sendable (OwnedMonkeydoProcess) async throws
        -> VerifiedMonkeydoConnection

    func waitUntilConnected(
        owned: OwnedMonkeydoProcess,
        listeningEndpoints: Set<TCPEndpoint>,
        isTestCommand: Bool,
        timeout: Duration,
        elapsedBeforeProbe: Duration
    ) async throws -> VerifiedMonkeydoConnection {
        try await operation(owned)
    }
}

private actor CoordinatorEvidenceRecorder: RunEvidenceObserving {
    private(set) var values: [VerifiedMonkeydoConnection] = []
    func accepted(_ connection: VerifiedMonkeydoConnection) {
        values.append(connection)
    }
}

private func coordinatorEarlyExit(pid: Int32) -> ToolError {
    ToolError(
        code: "monkeydo_exited",
        message: "Owned monkeydo launcher \(pid) exited before connecting.",
        fix: "Retry the launch after validating simulator readiness.",
        details: ["pid": .int(Int(pid))])
}

private func coordinatorConnection(
    _ owned: OwnedMonkeydoProcess
) -> VerifiedMonkeydoConnection {
    let java = ProcessIdentitySnapshot(
        pid: owned.launcher.pid + 1,
        parentPid: owned.launcher.pid,
        processGroupId: owned.launcher.processGroupId,
        start: ProcessStartIdentity(seconds: 2, microseconds: 1),
        executablePath: "/usr/bin/java",
        arguments: ["/usr/bin/java"])
    let shell = ProcessIdentitySnapshot(
        pid: owned.launcher.pid + 2,
        parentPid: java.pid,
        processGroupId: owned.launcher.processGroupId,
        start: ProcessStartIdentity(seconds: 2, microseconds: 2),
        executablePath: owned.command.sdk.root.appending(path: "bin/shell").path,
        arguments: ["shell"])
    let server = ProcessIdentitySnapshot(
        pid: 99_999, parentPid: 1, processGroupId: 99_999,
        start: ProcessStartIdentity(seconds: 1, microseconds: 0),
        executablePath: "/usr/local/bin/simulator-mcp", arguments: ["simulator-mcp"])
    let local = TCPEndpoint(address: "127.0.0.1", port: 52_000, family: "ipv4")
    let remote = TCPEndpoint(address: "127.0.0.1", port: 1_234, family: "ipv4")
    return VerifiedMonkeydoConnection(
        launcher: owned.launcher,
        connectionOwner: shell,
        parentChain: [shell, java, owned.launcher],
        launcherGroupMembers: [owned.launcher, java, shell],
        serverProcess: server,
        launcherGroupFullyAnchored: true,
        postSocketRevalidationVerified: true,
        localEndpoint: local,
        remoteEndpoint: remote,
        matchedSimulatorListener: remote,
        elapsedMonotonicMilliseconds: 1)
}

private actor CoordinatorCompiler: BuildCompiling {
    private var outcomes: [BuildOutcome]
    private let trace: CoordinatorTrace?
    private(set) var requests: [BuildRequest] = []

    init(outcomes: [BuildOutcome], trace: CoordinatorTrace? = nil) {
        self.outcomes = outcomes
        self.trace = trace
    }

    func build(_ request: BuildRequest) async throws -> BuildOutcome {
        trace?.append("build.\(request.mode)")
        requests.append(request)
        return outcomes.removeFirst()
    }
}

private actor CoordinatorController: RunOperationControlling {
    let context: OperationContext
    let startError: ToolError?
    let publishErrorOnActive: ToolError?
    let trace: CoordinatorTrace?
    private(set) var events: [String] = []

    init(
        context: OperationContext,
        startError: ToolError? = nil,
        publishErrorOnActive: ToolError? = nil,
        trace: CoordinatorTrace? = nil
    ) {
        self.context = context
        self.startError = startError
        self.publishErrorOnActive = publishErrorOnActive
        self.trace = trace
    }

    func withRunAppOperation(
        requested: SdkInfo,
        body: @escaping @Sendable (OperationContext) async throws -> RunAppResult
    ) async throws -> RunAppResult {
        if let startError { throw startError }
        trace?.append("run_app.lease.begin")
        events.append("run_app.begin")
        defer {
            events.append("run_app.end")
            trace?.append("run_app.lease.end")
        }
        let result = try await body(context)
        return result
    }

    func withRunTestsOperation(
        requested: SdkInfo,
        body: @escaping @Sendable (OperationContext) async throws -> RunTestsResult
    ) async throws -> RunTestsResult {
        if let startError { throw startError }
        trace?.append("run_tests.lease.begin")
        events.append("run_tests.begin")
        defer {
            events.append("run_tests.end")
            trace?.append("run_tests.lease.end")
        }
        let result = try await body(context)
        return result
    }

    func terminateActiveMonkeydo(inside operation: SimOperation) async throws {
        trace?.append("terminate_shared")
        events.append("terminate_shared")
    }

    func publishActiveMonkeydo(
        _ owned: OwnedMonkeydoProcess, device: String?, inside operation: SimOperation
    ) async throws {
        if let publishErrorOnActive { throw publishErrorOnActive }
        trace?.append(device == nil ? "active.pid" : "active.pid+device")
        events.append("active:\(owned.launcher.pid):\(device ?? "nil")")
    }

    func clearActiveMonkeydo(
        expectedLauncher: StableProcessIdentity,
        device: String?,
        inside operation: SimOperation
    ) async throws {
        trace?.append(device == nil ? "active.clear" : "active.device")
        events.append("active:nil:\(device ?? "nil")")
    }

    func revalidateReady(_ context: OperationContext, inside operation: SimOperation) async throws {
        events.append("revalidate:\(operation.rawValue)")
    }
}

private final class CoordinatorRunner: ProcessRunning, MonkeydoProcessLifecycling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var processes: [CoordinatorProcess]
    private var recorded: [FakeInvocation] = []
    private let trace: CoordinatorTrace?

    init(processes: [CoordinatorProcess], trace: CoordinatorTrace? = nil) {
        self.processes = processes
        self.trace = trace
    }

    var invocations: [FakeInvocation] { lock.withLock { recorded } }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess {
        trace?.append("process.start")
        let process = lock.withLock { () -> CoordinatorProcess in
            recorded.append(FakeInvocation(
                executable: executable, arguments: arguments, environment: environment,
                workingDirectory: workingDirectory, timeout: timeout))
            return processes.removeFirst()
        }
        await process.install(stdout: onStdout, stderr: onStderr)
        return process
    }

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
        let process = try await start(
            executable: command.sdk.monkeydo,
            arguments: [command.prgPath.path, command.device] + suffix,
            environment: nil, workingDirectory: workingDirectory, timeout: timeout,
            onStdout: onStdout, onStderr: onStderr)
        return OwnedMonkeydoProcess(
            process: process,
            launcher: ProcessIdentitySnapshot(
                pid: process.pid, parentPid: 1, processGroupId: process.pid,
                start: ProcessStartIdentity(seconds: 1, microseconds: UInt64(process.pid)),
                executablePath: "/bin/bash",
                arguments: ["/bin/bash", command.sdk.monkeydo.path,
                    command.prgPath.path, command.device] + suffix),
            command: command)
    }
}

private extension AppSessionManager {
    init(processRunner: CoordinatorRunner) {
        self.init(lifecycle: processRunner)
    }

    func beginPending(executable _: URL, arguments: [String]) async throws -> PendingSession {
        let fixture = CoordinatorFixture()
        return try await beginPending(MonkeydoCommand(
            sdk: fixture.sdk,
            prgPath: URL(fileURLWithPath: arguments.first ?? fixture.prg.path),
            device: arguments.dropFirst().first ?? "fenix6xpro",
            testFilter: nil))
    }
}

private final class CoordinatorTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private actor CoordinatorProcess: RunningProcess {
    nonisolated let pid: Int32
    private let output: ProcessOutput?
    private let waitError: ToolError?
    private let initialStdout: Data
    private var stdout: (@Sendable (Data) -> Void)?
    private var stderr: (@Sendable (Data) -> Void)?
    private var continuation: CheckedContinuation<ProcessOutput, Error>?
    private var completedOutput: ProcessOutput?
    private var outputEmitted = false
    private(set) var terminationCount = 0

    init(
        pid: Int32,
        output: ProcessOutput?,
        waitError: ToolError? = nil,
        initialStdout: Data = Data()
    ) {
        self.pid = pid
        self.output = output
        self.waitError = waitError
        self.initialStdout = initialStdout
    }

    func install(
        stdout: (@Sendable (Data) -> Void)?, stderr: (@Sendable (Data) -> Void)?
    ) {
        self.stdout = stdout
        self.stderr = stderr
        if !initialStdout.isEmpty { stdout?(initialStdout) }
    }

    func wait() async throws -> ProcessOutput {
        if let waitError { throw waitError }
        if let completedOutput { return completedOutput }
        if let output {
            emitIfNeeded(output)
            return output
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func terminate(grace: Duration) async {
        terminationCount += 1
        let result: ProcessOutput
        if let output {
            emitIfNeeded(output)
            result = output
        } else {
            result = ProcessOutput(exitCode: 15, stdout: Data(), stderr: Data())
        }
        completedOutput = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func emitIfNeeded(_ output: ProcessOutput) {
        guard !outputEmitted else { return }
        outputEmitted = true
        if !output.stdout.isEmpty { stdout?(output.stdout) }
        if !output.stderr.isEmpty { stderr?(output.stderr) }
    }
}

private func expectCoordinatorError<T: Sendable>(
    _ code: String,
    operation: @escaping @Sendable () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("expected ToolError \(code)")
    } catch let error as ToolError {
        #expect(error.code == code)
        #expect(!error.fix.isEmpty)
    } catch {
        Issue.record("expected ToolError \(code), got \(error)")
    }
}

private actor CoordinatorObservationGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
