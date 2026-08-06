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
            connectionProbe: fixture.connectedProbe(pid: 7000, trace: trace),
            deviceReadback: fixture.deviceReadback)

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
            evidenceObserver: observer,
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 8000, trace: trace),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 7001),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 7001),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 8001),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 8006),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 8005),
            deviceReadback: fixture.deviceReadback)

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
            evidenceObserver: observer,
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: probe,
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: probe,
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 8002),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 8060),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: fixture.connectedProbe(pid: 1),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: probe,
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: probe,
            deviceReadback: fixture.deviceReadback)

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
        let oldPending = try await sessions.beginPending(MonkeydoCommand(
            sdk: fixture.sdk, prgPath: fixture.prg, device: "fenix6xpro", testFilter: nil))
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
            connectionProbe: probe,
            deviceReadback: fixture.deviceReadback)

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
        let oldPending = try await sessions.beginPending(MonkeydoCommand(
            sdk: fixture.sdk, prgPath: fixture.prg, device: "fenix6xpro", testFilter: nil))
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
            connectionProbe: fixture.connectedProbe(pid: 7261),
            deviceReadback: fixture.deviceReadback)

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
        let oldPending = try await sessions.beginPending(MonkeydoCommand(
            sdk: fixture.sdk, prgPath: fixture.prg, device: "fenix6xpro", testFilter: nil))
        let oldID = try await sessions.commit(
            oldPending, device: "fenix6xpro", prgPath: fixture.prg, sdk: fixture.sdk)
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: sessions,
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 7271),
            deviceReadback: fixture.deviceReadback)

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
        let pending = try await sessions.beginPending(MonkeydoCommand(
            sdk: fixture.sdk, prgPath: fixture.prg, device: "fenix6xpro", testFilter: nil))
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
            connectionProbe: fixture.connectedProbe(pid: 8301),
            deviceReadback: fixture.deviceReadback)

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
            connectionProbe: probe,
            deviceReadback: fixture.deviceReadback)
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
            connectionProbe: probe,
            deviceReadback: fixture.deviceReadback)
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

/// Not `private`: `CoordinatorFixture.connectedProbe`, moved to
/// `Support/CoordinatorFixtures.swift`, calls this across the file boundary.
func coordinatorConnection(
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
