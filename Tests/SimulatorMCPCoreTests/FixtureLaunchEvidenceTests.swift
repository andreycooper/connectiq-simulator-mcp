import Darwin
import Foundation
import MCP
import Testing

@testable import SimulatorMCPCore

@Suite("Task 13 fixture launch evidence")
struct FixtureLaunchEvidenceTests {
    @Test("kernel argv and socket parsers preserve exact evidence")
    func processEvidenceParsers() throws {
        #expect(try DarwinProcessIdentityReader.parseProcArguments(procArgumentsData([
            "/sdk/bin/shell", "--transport=tcp", "--transport_args=127.0.0.1:1234",
        ])) == ["/sdk/bin/shell", "--transport=tcp", "--transport_args=127.0.0.1:1234"])

        let connection = try #require(ProcessEvidenceCollector.parseEstablishedConnections(
            Data("p4201\nn127.0.0.1:50321->127.0.0.1:42877\n".utf8),
            expectedPid: 4201).first)
        #expect(connection.local == TCPEndpoint(address: "127.0.0.1", port: 50321, family: "ipv4"))
        #expect(connection.remote == TCPEndpoint(address: "127.0.0.1", port: 42877, family: "ipv4"))
    }

    @Test("connection owner must have a complete current chain to the launcher")
    func connectionOwnerChain() throws {
        let launcher = ProcessEvidenceSnapshot(
            pid: 4200, parentPid: 100, processGroupId: 300,
            processStartIdentity: "Mon Jul 14 12:34:55 2026",
            executablePath: "/bin/bash",
            arguments: ["/bin/bash", "/sdk/bin/monkeydo", "/project with spaces/app.prg", "fenix6xpro"])
        let owner = ProcessEvidenceSnapshot(
            pid: 4201, parentPid: 4200, processGroupId: 300,
            processStartIdentity: "Mon Jul 14 12:34:56 2026",
            executablePath: "/sdk/bin/shell",
            arguments: ["/sdk/bin/shell", "--transport=tcp", "--transport_args=127.0.0.1:1234"])

        #expect(try ProcessEvidenceCollector.parentChain(
            ownerPid: owner.pid, launcher: launcher,
            snapshots: [launcher.pid: launcher, owner.pid: owner]).map(\.pid) == [4201, 4200])

        let unrelated = ProcessEvidenceSnapshot(
            pid: 4301, parentPid: 999, processGroupId: 999,
            processStartIdentity: "Mon Jul 14 12:34:56 2026",
            executablePath: "/sdk/bin/shell",
            arguments: ["/sdk/bin/shell", "--transport=tcp", "--transport_args=127.0.0.1:1234"])
        #expect(throws: ProcessEvidenceError.self) {
            try ProcessEvidenceCollector.parentChain(
                ownerPid: unrelated.pid, launcher: launcher,
                snapshots: [launcher.pid: launcher, unrelated.pid: unrelated])
        }
    }

    @Test("only the anchored exact SDK shell is a connection-owner candidate")
    func sdkShellOwnerSelection() {
        let sdk = "/sdk root/connectiq-sdk-mac-8.4.1"
        let shell = ProcessEvidenceSnapshot(
            pid: 20954, parentPid: 20852, processGroupId: 20700,
            processStartIdentity: "Tue Jul 14 21:28:04 2026",
            executablePath: "\(sdk)/bin/shell",
            arguments: ["\(sdk)/bin/shell", "--transport=tcp", "--transport_args=127.0.0.1:1234"])
        #expect(ProcessEvidenceCollector.isExactSDKShellOwner(shell, sdkPath: sdk))

        let unrelated = ProcessEvidenceSnapshot(
            pid: 30954, parentPid: 999, processGroupId: 999,
            processStartIdentity: "Tue Jul 14 21:28:04 2026",
            executablePath: "/tmp/shell",
            arguments: ["\(sdk)/bin/shell", "--transport=tcp", "--transport_args=127.0.0.1:1234"])
        #expect(!ProcessEvidenceCollector.isExactSDKShellOwner(unrelated, sdkPath: sdk))
        let deceptive = ProcessEvidenceSnapshot(
            pid: 30955, parentPid: 20852, processGroupId: 20700,
            processStartIdentity: "Tue Jul 14 21:28:04 2026",
            executablePath: "\(sdk)/bin/shell",
            arguments: ["\(sdk)/bin/shell", "--transport=tcp",
                        "prefix--transport_args=127.0.0.1:1234"])
        #expect(!ProcessEvidenceCollector.isExactSDKShellOwner(deceptive, sdkPath: sdk))

        let remote = TCPEndpoint(address: "127.0.0.1", port: 1234, family: "ipv4")
        let wildcard = TCPEndpoint(address: "*", port: 1234, family: "ipv4")
        #expect(ProcessEvidenceCollector.matchedSimulatorListener(
            remote: remote, listeners: [wildcard]) == wildcard)
        #expect(ProcessEvidenceCollector.matchedSimulatorListener(
            remote: TCPEndpoint(address: "10.0.0.2", port: 1234, family: "ipv4"),
            listeners: [wildcard]) == nil)
    }

    @Test("a kernel-listed descendant that cannot be inspected fails closed")
    func vanishedDescendantExecutableInspection() throws {
        let launcher = ProcessEvidenceSnapshot(
            pid: 100, parentPid: 50, processGroupId: 40,
            processStartIdentity: "100.000001", executablePath: "/bin/bash",
            arguments: ["/bin/bash", "/sdk/bin/monkeydo", "/tmp/app.prg", "fenix6xpro"])
        let reader = FixtureProcessIdentityReader(
            snapshots: [launcher.pid: launcher], children: [launcher.pid: [24497]])
        let collector = ProcessEvidenceCollector(identityReader: reader)
        #expect(throws: ProcessEvidenceError.self) {
            try collector.descendants(of: launcher)
        }
        #expect(throws: ProcessEvidenceError.self) {
            try DarwinProcessIdentityReader.parseProcArguments(Data([0, 0, 0, 0]))
        }
    }

    @Test("kernel snapshot captures the current process argv")
    func currentProcessKernelSnapshot() throws {
        let captured = try DarwinProcessIdentityReader().snapshot(pid: getpid())
        let snapshot = try #require(captured)
        #expect(!snapshot.arguments.isEmpty)
        #expect(!snapshot.processStartIdentity.isEmpty)
        #expect(snapshot.pid == getpid())
    }

    @Test("acceptance records the fresh connection after an ephemeral local-port change")
    func freshAcceptanceConnection() throws {
        let listener = TCPEndpoint(address: "*", port: 1234, family: "ipv4")
        let stale = ProcessEvidenceConnection(
            local: TCPEndpoint(address: "127.0.0.1", port: 50_000, family: "ipv4"),
            remote: TCPEndpoint(address: "127.0.0.1", port: 1234, family: "ipv4"))
        let fresh = ProcessEvidenceConnection(
            local: TCPEndpoint(address: "127.0.0.1", port: 50_001, family: "ipv4"),
            remote: stale.remote)
        let selected = try ProcessEvidenceCollector.singleCurrentListenerConnection(
            [fresh], listeners: [listener])
        let accepted = try #require(selected)
        #expect(accepted.connection == fresh)
        #expect(accepted.connection != stale)
        #expect(accepted.listener == listener)
        #expect(try ProcessEvidenceCollector.singleCurrentListenerConnection(
            [], listeners: [listener]) == nil)
        #expect(throws: ProcessEvidenceError.self) {
            try ProcessEvidenceCollector.singleCurrentListenerConnection(
                [fresh, fresh], listeners: [listener])
        }
    }

    @Test("kernel snapshots reject unavailable and changed identities")
    func stableKernelSnapshotBoundary() throws {
        let before = KernelBSDIdentity(
            pid: 42, parentPid: 10, processGroupId: 7,
            startSeconds: 100, startMicroseconds: 1)
        let changed = KernelBSDIdentity(
            pid: 42, parentPid: 10, processGroupId: 7,
            startSeconds: 101, startMicroseconds: 2)

        #expect(try DarwinProcessIdentityReader(kernel: FixtureKernelReader(
            identities: [before, nil], path: "/sdk/bin/shell", arguments: ["shell"]
        )).snapshot(pid: 42) == nil)
        #expect(try DarwinProcessIdentityReader(kernel: FixtureKernelReader(
            identities: [before, before], path: "/sdk/bin/shell", arguments: nil
        )).snapshot(pid: 42) == nil)
        #expect(try DarwinProcessIdentityReader(kernel: FixtureKernelReader(
            identities: [before, changed], path: "/sdk/bin/shell", arguments: ["shell"]
        )).snapshot(pid: 42) == nil)
    }

    @Test("post-lsof acceptance rejects PID reuse and ancestry changes")
    func postLsofIdentityRevalidation() throws {
        let fixture = acceptanceFixture()
        #expect(throws: ProcessEvidenceError.self) {
            try ProcessEvidenceCollector.validateAcceptanceBoundary(
                expectedLauncher: fixture.launcher,
                expectedOwner: fixture.owner,
                currentLauncher: fixture.launcher,
                currentOwner: ProcessEvidenceSnapshot(
                    pid: fixture.owner.pid, parentPid: fixture.java.pid,
                    processGroupId: fixture.owner.processGroupId,
                    processStartIdentity: "reused", executablePath: fixture.owner.executablePath,
                    arguments: fixture.owner.arguments),
                currentDescendants: [fixture.java, fixture.owner],
                sdkPath: fixture.sdk, prgPath: fixture.prg, device: "fenix6xpro")
        }
        let reparented = ProcessEvidenceSnapshot(
            pid: fixture.owner.pid, parentPid: 999,
            processGroupId: fixture.owner.processGroupId,
            processStartIdentity: fixture.owner.processStartIdentity,
            executablePath: fixture.owner.executablePath, arguments: fixture.owner.arguments)
        #expect(throws: ProcessEvidenceError.self) {
            try ProcessEvidenceCollector.validateAcceptanceBoundary(
                expectedLauncher: fixture.launcher, expectedOwner: fixture.owner,
                currentLauncher: fixture.launcher, currentOwner: reparented,
                currentDescendants: [fixture.java, reparented],
                sdkPath: fixture.sdk, prgPath: fixture.prg, device: "fenix6xpro")
        }
    }

    @Test("cleanup records groups but always terminates deepest-first PIDs")
    func cleanupPlanning() throws {
        let fixture = acceptanceFixture()
        let testProcess = ProcessEvidenceSnapshot(
            pid: 10, parentPid: 1, processGroupId: 10,
            processStartIdentity: "10.1", executablePath: "/tests",
            arguments: ["/tests"])
        #expect(try ProcessEvidenceCollector.cleanupPlan(
            launcher: fixture.launcher, testProcess: testProcess,
            descendants: [fixture.java, fixture.owner],
            groupMembers: [fixture.launcher, fixture.java, fixture.owner])
            == .individual(pids: [fixture.owner.pid, fixture.java.pid, fixture.launcher.pid]))

        let orphan = ProcessEvidenceSnapshot(
            pid: 999, parentPid: 1, processGroupId: fixture.launcher.processGroupId,
            processStartIdentity: "999.1", executablePath: "/unrelated",
            arguments: ["/unrelated"])
        #expect(try ProcessEvidenceCollector.cleanupPlan(
            launcher: fixture.launcher, testProcess: testProcess,
            descendants: [fixture.java, fixture.owner],
            groupMembers: [fixture.launcher, fixture.java, fixture.owner, orphan])
            == .individual(pids: [fixture.owner.pid, fixture.java.pid, fixture.launcher.pid]))

        let inheritedTest = ProcessEvidenceSnapshot(
            pid: testProcess.pid, parentPid: 1,
            processGroupId: fixture.launcher.processGroupId,
            processStartIdentity: testProcess.processStartIdentity,
            executablePath: testProcess.executablePath, arguments: testProcess.arguments)
        #expect(try ProcessEvidenceCollector.cleanupPlan(
            launcher: fixture.launcher, testProcess: inheritedTest,
            descendants: [fixture.java, fixture.owner],
            groupMembers: [fixture.launcher, fixture.java, fixture.owner])
            == .individual(pids: [fixture.owner.pid, fixture.java.pid, fixture.launcher.pid]))
    }

    @Test("uninspectable listed group member fails closed")
    func uninspectableGroupMember() throws {
        let fixture = acceptanceFixture()
        let reader = FixtureProcessIdentityReader(
            snapshots: [fixture.launcher.pid: fixture.launcher],
            children: [:],
            groupPids: [fixture.launcher.processGroupId: [fixture.launcher.pid, 777]])
        let collector = ProcessEvidenceCollector(identityReader: reader)
        #expect(throws: ProcessEvidenceError.self) {
            try collector.processGroupMembers(processGroupId: fixture.launcher.processGroupId)
        }
    }

    @Test("evidence schema records the complete final launcher-group boundary")
    func launcherGroupEvidenceSchema() throws {
        let fixture = acceptanceFixture()
        let members = [fixture.launcher, fixture.java, fixture.owner]
        #expect(ProcessEvidenceCollector.launcherGroupFullyAnchored(
            members: members, launcher: fixture.launcher,
            descendants: [fixture.java, fixture.owner]))
        let unrelated = ProcessEvidenceSnapshot(
            pid: 99, parentPid: 1, processGroupId: fixture.launcher.processGroupId,
            processStartIdentity: "99.1", executablePath: "/tests", arguments: ["/tests"])
        #expect(!ProcessEvidenceCollector.launcherGroupFullyAnchored(
            members: members + [unrelated], launcher: fixture.launcher,
            descendants: [fixture.java, fixture.owner]))

        let evidence = fixtureEvidence(
            fixture: fixture, launcherProcessGroupMembers: members,
            launcherGroupFullyAnchored: true,
            postSocketRevalidationVerified: true)
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(evidence)) as? [String: Any])
        #expect((object["launcherProcessGroupMembers"] as? [[String: Any]])?.count == 3)
        #expect(object["launcherGroupFullyAnchored"] as? Bool == true)
        #expect(object["postSocketRevalidationVerified"] as? Bool == true)
    }

    @Test("cleanup execution is cancellation-resistant and deepest-first")
    func cancellationDuringDescendantCleanup() async throws {
        let fixture = acceptanceFixture()
        let runtime = FixtureCleanupRuntime(
            snapshots: [fixture.launcher, fixture.java, fixture.owner],
            survivesTermPids: [fixture.owner.pid], cancelDuringFirstWait: true)
        try await EvidenceCleanupExecutor(
            identityReader: runtime, signaler: runtime,
            waitForExit: { try await runtime.waitForExit($0) },
            terminateOwnedWrapper: { runtime.terminateWrapper() })
            .cleanup(
                launcher: fixture.launcher,
                launcherPid: fixture.launcher.pid,
                previouslyObserved: [fixture.java, fixture.owner])
        #expect(runtime.signalEvents == [
            CleanupSignal(pid: fixture.owner.pid, signal: SIGTERM),
            CleanupSignal(pid: fixture.owner.pid, signal: SIGKILL),
            CleanupSignal(pid: fixture.java.pid, signal: SIGTERM),
        ])
        #expect(runtime.wrapperTerminationCount == 1)
    }

    @Test("partial cleanup failure preserves every ancestor anchor")
    func partialCleanupFailure() async {
        let fixture = acceptanceFixture()
        let runtime = FixtureCleanupRuntime(
            snapshots: [fixture.launcher, fixture.java, fixture.owner],
            failingPid: fixture.owner.pid)
        await #expect(throws: ProcessEvidenceError.self) {
            try await EvidenceCleanupExecutor(
                identityReader: runtime, signaler: runtime,
                waitForExit: { try await runtime.waitForExit($0) },
                terminateOwnedWrapper: { runtime.terminateWrapper() })
                .cleanup(
                    launcher: fixture.launcher,
                    launcherPid: fixture.launcher.pid,
                    previouslyObserved: [fixture.java, fixture.owner])
        }
        #expect(runtime.signaledPids == [fixture.owner.pid])
        // Preserve the wrapper/ancestry anchor when a descendant could not be
        // terminated; killing it here would create the orphan under review.
        #expect(runtime.wrapperTerminationCount == 0)
    }

    @Test("a descendant spawned during cleanup is terminated before its ancestor")
    func descendantSpawnedDuringCleanup() async throws {
        let fixture = acceptanceFixture()
        let lateOwner = ProcessEvidenceSnapshot(
            pid: 103, parentPid: fixture.java.pid,
            processGroupId: fixture.launcher.processGroupId,
            processStartIdentity: "103.1", executablePath: "\(fixture.sdk)/bin/shell",
            arguments: ["\(fixture.sdk)/bin/shell", "--transport=tcp",
                        "--transport_args=127.0.0.1:1234"])
        let runtime = FixtureCleanupRuntime(
            snapshots: [fixture.launcher, fixture.java, fixture.owner],
            spawnAfterSignal: [fixture.owner.pid: lateOwner])
        try await EvidenceCleanupExecutor(
            identityReader: runtime, signaler: runtime,
            waitForExit: { try await runtime.waitForExit($0) },
            terminateOwnedWrapper: { runtime.terminateWrapper() })
            .cleanup(
                launcher: fixture.launcher,
                launcherPid: fixture.launcher.pid,
                previouslyObserved: [fixture.java, fixture.owner])
        #expect(runtime.signaledPids == [
            fixture.owner.pid, lateOwner.pid, fixture.java.pid,
        ])
        #expect(runtime.wrapperTerminationCount == 1)
    }

    @Test("natural launcher exit after descendant cleanup is safe")
    func naturalLauncherExitAfterDescendants() async throws {
        let fixture = acceptanceFixture()
        let runtime = FixtureCleanupRuntime(
            snapshots: [fixture.launcher, fixture.java, fixture.owner],
            launcherExitsWhenDescendantsExit: true)
        try await EvidenceCleanupExecutor(
            identityReader: runtime, signaler: runtime,
            waitForExit: { try await runtime.waitForExit($0) },
            terminateOwnedWrapper: { runtime.terminateWrapper() })
            .cleanup(
                launcher: fixture.launcher,
                launcherPid: fixture.launcher.pid,
                previouslyObserved: [fixture.java, fixture.owner])
        #expect(runtime.signaledPids == [fixture.owner.pid, fixture.java.pid])
        #expect(runtime.wrapperTerminationCount == 0)
    }

    @Test("launcher disappearance is safe only when no owned descendant remains")
    func launcherDisappearanceCleanup() async throws {
        let fixture = acceptanceFixture()
        let emptyRuntime = FixtureCleanupRuntime(snapshots: [])
        try await EvidenceCleanupExecutor(
            identityReader: emptyRuntime, signaler: emptyRuntime,
            waitForExit: { try await emptyRuntime.waitForExit($0) },
            terminateOwnedWrapper: { emptyRuntime.terminateWrapper() })
            .cleanup(
                launcher: fixture.launcher,
                launcherPid: fixture.launcher.pid,
                previouslyObserved: [fixture.java, fixture.owner])
        #expect(emptyRuntime.signaledPids.isEmpty)

        let orphanRuntime = FixtureCleanupRuntime(snapshots: [fixture.owner])
        await #expect(throws: ProcessEvidenceError.self) {
            try await EvidenceCleanupExecutor(
                identityReader: orphanRuntime, signaler: orphanRuntime,
                waitForExit: { try await orphanRuntime.waitForExit($0) },
                terminateOwnedWrapper: { orphanRuntime.terminateWrapper() })
                .cleanup(
                    launcher: fixture.launcher,
                    launcherPid: fixture.launcher.pid,
                    previouslyObserved: [fixture.owner])
        }
        #expect(orphanRuntime.signaledPids.isEmpty)
    }

    @Test("initial full launcher capture failure uses owned-wrapper cleanup")
    func initialLauncherCaptureFailureCleanup() async throws {
        let fixture = acceptanceFixture()
        let runtime = FixtureCleanupRuntime(snapshots: [fixture.java, fixture.owner])
        try await EvidenceCleanupExecutor(
            identityReader: runtime, signaler: runtime,
            waitForExit: { try await runtime.waitForExit($0) },
            terminateOwnedWrapper: { runtime.terminateWrapper() })
            .cleanup(
                launcher: nil, launcherPid: fixture.launcher.pid,
                previouslyObserved: [])
        #expect(runtime.signaledPids == [fixture.owner.pid, fixture.java.pid])
        #expect(runtime.wrapperTerminationCount == 1)
    }

    @Test("normal failure and cancellation paths all invoke required cleanup")
    func requiredCleanupOnEveryExit() async throws {
        let counter = CleanupCounter()
        _ = try await ProcessEvidenceCollector.withRequiredCleanup(
            operation: { 1 }, cleanup: { counter.increment() })
        await #expect(throws: ProcessEvidenceError.self) {
            _ = try await ProcessEvidenceCollector.withRequiredCleanup(
                operation: {
                    throw ProcessEvidenceError.inspectionFailed("fixture failure")
                },
                cleanup: { counter.increment() })
        }
        await #expect(throws: CancellationError.self) {
            _ = try await ProcessEvidenceCollector.withRequiredCleanup(
                operation: { throw CancellationError() },
                cleanup: { counter.increment() })
        }
        #expect(counter.value == 3)
    }

    @Test("launch elapsed time excludes compilation")
    func launchElapsedExcludesBuild() {
        let clock = FakeClock()
        clock.advance(by: .seconds(20))
        let timer = EvidenceLaunchTimer(clock: clock)
        let launchStarted = timer.markLaunchStart()
        clock.advance(by: .milliseconds(750))
        #expect(timer.elapsedMilliseconds(since: launchStarted) == 750)
    }

    @Test("final marker timing uses the production launch boundary")
    func finalMarkerTimingUsesLaunchBoundary() async throws {
        let clock = FakeClock()
        let lifecycle = Task13ObservedLifecycle(
            base: Task13FailingLifecycle(), clock: clock)
        let command = MonkeydoCommand(
            sdk: SdkInfo(
                version: SemVer(major: 9, minor: 1, patch: 0),
                root: URL(fileURLWithPath: "/sdk"),
                source: .explicit),
            prgPath: URL(fileURLWithPath: "/fixture.prg"),
            device: "fenix6xpro",
            testFilter: nil)

        await #expect(throws: Task13EvidenceError.self) {
            _ = try await lifecycle.launchApp(command, onStdout: nil, onStderr: nil)
        }
        clock.advance(by: .milliseconds(100))
        await lifecycle.accepted(task13VerifiedConnectionFixture(elapsed: 25))
        clock.advance(by: .milliseconds(50))

        #expect(try await lifecycle.fixtureMarkerElapsedMilliseconds() == 150)
    }

    @Test("final production launch evidence encodes the complete version 1 contract")
    func finalProductionLaunchEvidenceSchema() throws {
        let evidence = task13LaunchEvidenceFixture()
        let data = try JSONEncoder().encode(evidence)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["connectionVerified"] as? Bool == true)
        #expect(object["ancestryVerified"] as? Bool == true)
        #expect(object["postSocketRevalidationVerified"] as? Bool == true)
        #expect(object["launcherGroupFullyAnchored"] as? Bool == true)
        #expect(object["launcherGroupDedicated"] as? Bool == true)
        #expect(object["fixtureMarker"] as? String == "FIXTURE_STARTED")
        #expect(object["fixtureMarkerObserved"] as? Bool == true)
        #expect(object["connectionElapsedMonotonicMilliseconds"] as? Int == 125)
        #expect(object["fixtureMarkerElapsedMonotonicMilliseconds"] as? Int == 175)
        #expect((object["launcherGroupMembers"] as? [[String: Any]])?.count == 3)
    }

    @Test("opt-in production RunCoordinator closes the final fixture launch gate")
    func liveProductionRunCoordinatorEvidence() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sdkPath = environment["SIM_TASK13_SDK_PATH"],
            let developerKey = environment["SIM_TASK13_DEVELOPER_KEY"],
            let outputPath = environment["SIM_TASK13_EVIDENCE_OUTPUT"]
        else { return }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try validateTask13Prerequisite(
            root.appending(path: "docs/verification/simulator-contracts/monkeydo-process-8.4.1.json"),
            sdkVersion: "8.4.1")
        try validateTask13Prerequisite(
            root.appending(path: "docs/verification/simulator-contracts/monkeydo-process-9.1.0.json"),
            sdkVersion: "9.1.0")

        let projectRoot = root.appending(path: "Tests/fixtures/testapp", directoryHint: .isDirectory)
        let project = try ProjectDescriptor.resolve(projectPath: projectRoot.path, jungleOverride: nil)
        let buildContext = try BuildContext.resolve(
            project: project, developerKeyOverride: developerKey)
        let sdk = try SdkLocator().resolve(explicitPath: sdkPath)
        guard sdk.version == SemVer(major: 9, minor: 1, patch: 0) else {
            throw Task13EvidenceError("the final production launch gate requires SDK 9.1.0")
        }

        let processRunner = Subprocess()
        let lifecycle = Task13ObservedLifecycle(
            base: MonkeydoProcessLifecycle(processRunner: processRunner),
            clock: ContinuousClock())
        let sessions = AppSessionManager(lifecycle: lifecycle)
        let controller = SimulatorController(
            // live-readback: this gate runs only when SIM_TASK13_* are all
            // set, against the real simulator — see
            // DeviceVerificationTests.unitTestsNeverReachTheWindowServer.
            queue: AsyncFIFO(), lease: .standard, runtimeStore: .standard,
            processRunner: processRunner, sessionStopper: sessions,
            monkeydoLifecycle: lifecycle)
        let coordinator = RunCoordinator(
            // live-readback: this gate runs only when SIM_TASK13_* are all
            // set, against the real simulator, and is meant to read the real
            // window title. Every other construction must inject a double —
            // see DeviceVerificationTests.unitTestsNeverReachTheWindowServer.
            controller: controller,
            compiler: Compiler(runner: processRunner),
            sessionManager: sessions,
            processRunner: processRunner,
            lifecycle: lifecycle,
            evidenceObserver: lifecycle)
        let services = task13ToolServices(controller: controller, sessions: sessions)
        let identityReader = SimulatorMCPCore.DarwinProcessIdentityReader()
        let fixtureBin = projectRoot.appending(path: "bin", directoryHint: .isDirectory)

        do {
            try await withMCPHarness(handlers: ToolHandlers.configured(services)) { harness in
                let initialStop = try await harness.call("sim_stop", as: SimStopResult.self)
                _ = try requireTask13PublicResult(initialStop.envelope, tool: "sim_stop")
                _ = try await controller.withOperation(
                    .simStart, requirement: .start(requested: sdk)) { $0 }

                let result = try await coordinator.runApp(RunAppRequest(
                    project: project,
                    buildContext: buildContext,
                    sdk: sdk,
                    device: "fenix6xpro",
                    rebuild: true))
                let connection = try await lifecycle.onlyConnection()
                let runtime = try requireTask13Runtime()
                let ownership = try requireTask13Ownership(runtime)
                let simulatorSnapshot = try #require(
                    try identityReader.snapshot(pid: runtime.simulatorPid))

                #expect(result.device == "fenix6xpro")
                #expect(result.sdkVersion == "9.1.0")
                #expect(result.sdkPath == sdk.root.path)
                #expect(runtime.sdkPath == sdk.root.path)
                #expect(runtime.currentDevice == "fenix6xpro")
                #expect(ownership.launcher == connection.launcher.stableIdentity)
                #expect(connection.connectionOwner.executablePath
                    == sdk.root.appending(path: "bin/shell").path)
                #expect(connection.parentChain.first == connection.connectionOwner)
                #expect(connection.parentChain.last == connection.launcher)
                #expect(connection.launcherGroupFullyAnchored)
                #expect(connection.postSocketRevalidationVerified)
                #expect(connection.launcher.processGroupId != connection.serverProcess.processGroupId)
                #expect(connection.elapsedMonotonicMilliseconds > 0)

                let markerElapsed = try await waitForFixtureMarker(
                    harness: harness, sessionID: result.sessionId, observer: lifecycle)
                #expect(markerElapsed >= connection.elapsedMonotonicMilliseconds)

                let evidence = Task13LaunchEvidence(
                    schemaVersion: 1,
                    recordedOn: ISO8601DateFormatter().string(from: Date()),
                    sdkVersion: sdk.version.description,
                    sdkPath: sdk.root.path,
                    device: result.device,
                    simulator: Task13SimulatorEvidence(
                        pid: runtime.simulatorPid,
                        executablePath: runtime.executablePath,
                        matchedListener: connection.matchedSimulatorListener),
                    launcher: connection.launcher,
                    connectionOwner: Task13ConnectionOwnerEvidence(
                        process: connection.connectionOwner,
                        localEndpoint: connection.localEndpoint,
                        remoteEndpoint: connection.remoteEndpoint),
                    parentChain: connection.parentChain,
                    launcherGroupMembers: connection.launcherGroupMembers.sorted { $0.pid < $1.pid },
                    serverProcess: connection.serverProcess,
                    ancestryVerified: true,
                    postSocketRevalidationVerified: connection.postSocketRevalidationVerified,
                    connectionVerified: true,
                    launcherGroupDedicated:
                        connection.launcher.processGroupId != connection.serverProcess.processGroupId,
                    launcherGroupFullyAnchored: connection.launcherGroupFullyAnchored,
                    sessionId: result.sessionId,
                    currentDevice: try #require(runtime.currentDevice),
                    fixtureMarker: "FIXTURE_STARTED",
                    fixtureMarkerObserved: true,
                    connectionElapsedMonotonicMilliseconds:
                        connection.elapsedMonotonicMilliseconds,
                    fixtureMarkerElapsedMonotonicMilliseconds: markerElapsed)

                let stopped = try await harness.call("sim_stop", as: SimStopResult.self)
                let stoppedResult = try requireTask13PublicResult(
                    stopped.envelope, tool: "sim_stop")
                #expect(stoppedResult.status.state == .notRunning)
                try auditTask13Cleanup(
                    connection: connection,
                    simulator: simulatorSnapshot,
                    identityReader: identityReader)
                #expect(RuntimeStore.standard.read() == nil)

                try writeTask13Evidence(evidence, to: URL(fileURLWithPath: outputPath))
            }
            try? FileManager.default.removeItem(at: fixtureBin)
        } catch {
            _ = try? await controller.withOperation(.simStop, requirement: .stop) { _ in () }
            try? FileManager.default.removeItem(at: fixtureBin)
            throw error
        }
    }

    @Test("opt-in live harness records wrapper and connection-owner evidence")
    func liveProcessEvidenceHarness() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sdkPath = environment["SIM_LAUNCH_EVIDENCE_SDK_PATH"],
            let developerKey = environment["SIM_LAUNCH_EVIDENCE_DEVELOPER_KEY"],
            let outputPath = environment["SIM_LAUNCH_EVIDENCE_OUTPUT"]
        else { return }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectRoot = root.appending(path: "Tests/fixtures/testapp", directoryHint: .isDirectory)
        let project = try ProjectDescriptor.resolve(projectPath: projectRoot.path, jungleOverride: nil)
        let buildContext = try BuildContext.resolve(
            project: project, developerKeyOverride: developerKey)
        let sdk = try SdkLocator().resolve(explicitPath: sdkPath)
        let processRunner = Subprocess()
        let sessions = AppSessionManager(
            lifecycle: MonkeydoProcessLifecycle(processRunner: processRunner))
        let controller = SimulatorController(
            // live-readback: this gate runs only when SIM_LAUNCH_EVIDENCE_*
            // are all set, against the real simulator — see
            // DeviceVerificationTests.unitTestsNeverReachTheWindowServer.
            queue: AsyncFIFO(), lease: .standard, runtimeStore: .standard,
            processRunner: processRunner, sessionStopper: sessions)
        let fixtureBin = projectRoot.appending(path: "bin", directoryHint: .isDirectory)

        do {
            _ = try await controller.withOperation(.simStop, requirement: .stop) { _ in () }
            let context = try await controller.withOperation(
                .simStart, requirement: .start(requested: sdk)) { $0 }

            let clock = ContinuousClock()
            let timer = EvidenceLaunchTimer(clock: clock)
            let build = try await Compiler(runner: processRunner).build(BuildRequest(
                context: buildContext, sdk: sdk, device: "fenix6xpro",
                mode: .debugApp, force: true))
            let prg = try #require(build.prgPath)
            let transcript = OrderedTranscriptCollector()
            let launchStarted = timer.markLaunchStart()
            let launcherProcess = try await processRunner.start(
                executable: sdk.monkeydo,
                arguments: [prg.path, "fenix6xpro"],
                environment: nil,
                workingDirectory: project.root,
                timeout: nil,
                onStdout: { transcript.append($0, stream: .stdout) },
                onStderr: { transcript.append($0, stream: .stderr) })

            let collector = ProcessEvidenceCollector(runner: processRunner)
            let observedProcesses = ObservedProcessBuffer()
            let identityDeadline = clock.now.advanced(by: .seconds(1))
            guard let ownedLauncher = try captureSnapshotWithoutSuspension(
                pid: launcherProcess.pid, collector: collector,
                clock: clock, deadline: identityDeadline)
            else {
                try await cleanupInitialCaptureFailure(
                    process: launcherProcess,
                    launcherPid: launcherProcess.pid,
                    collector: collector)
                throw ProcessEvidenceError.inspectionFailed(
                    "could not capture full launcher identity before the first post-launch suspension")
            }
            guard let testProcess = try captureSnapshotWithoutSuspension(
                    pid: getpid(), collector: collector,
                    clock: clock, deadline: identityDeadline)
            else {
                try await cleanupOwnedLaunch(
                    process: launcherProcess,
                    launcher: ownedLauncher,
                    previouslyObserved: observedProcesses.snapshots,
                    collector: collector)
                throw ProcessEvidenceError.inspectionFailed(
                    "could not capture test-process identity before the first post-launch suspension")
            }

            let accepted = try await ProcessEvidenceCollector.withRequiredCleanup(
                operation: {
                    try await collectEvidence(
                    collector: collector,
                    launcher: ownedLauncher,
                    testProcess: testProcess,
                    simulator: context,
                    sdk: sdk,
                    prg: prg,
                    transcript: transcript,
                    observedProcesses: observedProcesses,
                    clock: clock,
                    launchStarted: launchStarted)
                },
                cleanup: {
                    try await Task.detached {
                        try await cleanupOwnedLaunch(
                            process: launcherProcess,
                            launcher: ownedLauncher,
                            previouslyObserved: observedProcesses.snapshots,
                            collector: collector)
                    }.value
                })
            try writeEvidence(accepted.evidence, to: outputPath)

            _ = try await controller.withOperation(.simStop, requirement: .stop) { _ in () }
            try? FileManager.default.removeItem(at: fixtureBin)
        } catch {
            _ = try? await controller.withOperation(.simStop, requirement: .stop) { _ in () }
            try? FileManager.default.removeItem(at: fixtureBin)
            throw error
        }
    }

    private func collectEvidence(
        collector: ProcessEvidenceCollector,
        launcher: ProcessEvidenceSnapshot,
        testProcess: ProcessEvidenceSnapshot,
        simulator: OperationContext,
        sdk: SdkInfo,
        prg: URL,
        transcript: OrderedTranscriptCollector,
        observedProcesses: ObservedProcessBuffer,
        clock: ContinuousClock,
        launchStarted: ContinuousClock.Instant
    ) async throws -> AcceptedProcessEvidence {
        let deadline = clock.now.advanced(by: .seconds(30))
        guard ProcessEvidenceCollector.isExactLauncher(
            launcher, sdkPath: sdk.root.path, prgPath: prg.path, device: "fenix6xpro")
        else {
            throw ProcessEvidenceError.inspectionFailed(
                "spawned launcher identity or arguments do not match the exact monkeydo launch")
        }
        var observed: [Int32: ProcessEvidenceSnapshot] = [:]
        var lastDescendantCommands: [String] = []
        var lastPredicateMatches: [Int32] = []
        var lastConnections: [String] = []

        while clock.now < deadline {
            try Task.checkCancellation()
            guard let currentLauncher = try collector.snapshot(pid: launcher.pid) else {
                try await clock.sleep(for: .milliseconds(25))
                continue
            }
            guard currentLauncher == launcher else {
                throw ProcessEvidenceError.inspectionFailed(
                    "launcher changed identity before connection acceptance")
            }
            let currentDescendants = try collector.descendants(of: launcher)
            lastDescendantCommands = currentDescendants.map {
                "pid=\($0.pid) ppid=\($0.parentPid) command=\($0.displayCommand)"
            }
            lastPredicateMatches = []
            lastConnections = []
            for descendant in currentDescendants {
                if let previous = observed[descendant.pid], previous != descendant {
                    throw ProcessEvidenceError.inspectionFailed(
                        "descendant PID \(descendant.pid) changed identity during collection")
                }
                observed[descendant.pid] = descendant
                observedProcesses.record(descendant)
            }

            var matches: [(
                ProcessEvidenceSnapshot, ProcessEvidenceConnection, TCPEndpoint
            )] = []
            for descendant in currentDescendants {
                guard ProcessEvidenceCollector.isExactSDKShellOwner(
                    descendant, sdkPath: sdk.root.path)
                else { continue }
                lastPredicateMatches.append(descendant.pid)
                let connections = try await collector.establishedConnections(pid: descendant.pid)
                lastConnections.append(contentsOf: connections.map {
                    "pid=\(descendant.pid) local=\($0.local.family):\($0.local.address):\($0.local.port) remote=\($0.remote.family):\($0.remote.address):\($0.remote.port)"
                })
                for connection in connections {
                    guard let listener = ProcessEvidenceCollector.matchedSimulatorListener(
                        remote: connection.remote,
                        listeners: simulator.listeningEndpoints)
                    else { continue }
                    matches.append((descendant, connection, listener))
                }
            }
            if matches.count > 1 {
                throw ProcessEvidenceError.inspectionFailed(
                    "multiple anchored MonkeyDoDeux connections matched the simulator listener")
            }
            if let match = matches.first {
                guard let currentConnection = try ProcessEvidenceCollector
                    .singleCurrentListenerConnection(
                        try await collector.establishedConnections(pid: match.0.pid),
                        listeners: simulator.listeningEndpoints)
                else {
                    try await clock.sleep(for: .milliseconds(25))
                    continue
                }
                // Acceptance boundary: after the final suspending socket query,
                // synchronously re-read every identity and the complete chain.
                // No `await` is permitted between these reads and returning the
                // evidence value derived from them.
                guard let acceptedLauncher = try collector.snapshot(pid: launcher.pid),
                    let acceptedOwner = try collector.snapshot(pid: match.0.pid)
                else { continue }
                let acceptedDescendants = try collector.descendants(of: acceptedLauncher)
                let chain = try ProcessEvidenceCollector.validateAcceptanceBoundary(
                    expectedLauncher: launcher,
                    expectedOwner: match.0,
                    currentLauncher: acceptedLauncher,
                    currentOwner: acceptedOwner,
                    currentDescendants: acceptedDescendants,
                    sdkPath: sdk.root.path,
                    prgPath: prg.path,
                    device: "fenix6xpro")
                let launcherProcessGroupMembers = try collector.processGroupMembers(
                    processGroupId: acceptedLauncher.processGroupId)
                let launcherGroupFullyAnchored = ProcessEvidenceCollector
                    .launcherGroupFullyAnchored(
                        members: launcherProcessGroupMembers,
                        launcher: acceptedLauncher,
                        descendants: acceptedDescendants)
                let runtime = try #require(RuntimeStore.standard.read())
                let fixtureMarker = transcript.events.contains {
                    $0.line.contains("FIXTURE_STARTED")
                }
                let elapsed = EvidenceLaunchTimer(clock: clock)
                    .elapsedMilliseconds(since: launchStarted)
                let evidence = MonkeydoProcessEvidence(
                    collectionSchemaVersion: 1,
                    collectionCommands: ProcessEvidenceCommands(
                        snapshot: ProcessEvidenceCollector.snapshotCommand,
                        processList: ProcessEvidenceCollector.processListCommand,
                        executable: ProcessEvidenceCollector.executableCommand,
                        connections: ProcessEvidenceCollector.connectionCommand),
                    recordedOn: ISO8601DateFormatter().string(from: Date()),
                    sdkVersion: sdk.version.description,
                    sdkPath: sdk.root.path,
                    device: "fenix6xpro",
                    simulator: SimulatorProcessEvidence(
                        pid: simulator.simulatorPid,
                        executablePath: runtime.executablePath,
                        listeningEndpoints: simulator.listeningEndpoints.sorted(by: endpointOrder)),
                    testProcess: testProcess,
                    launcher: launcher,
                    launcherProcessGroupMembers: launcherProcessGroupMembers,
                    descendants: observed.values.sorted { $0.pid < $1.pid },
                    connectionOwner: ConnectionOwnerEvidence(
                        process: acceptedOwner,
                        localEndpoint: currentConnection.connection.local,
                        remoteEndpoint: currentConnection.connection.remote,
                        matchedSimulatorListener: currentConnection.listener),
                    parentChain: chain,
                    ancestryVerified: true,
                    endpointVerified: true,
                    launcherGroupInherited: launcher.processGroupId == testProcess.processGroupId,
                    launcherGroupDedicated: launcher.processGroupId != testProcess.processGroupId,
                    launcherGroupFullyAnchored: launcherGroupFullyAnchored,
                    postSocketRevalidationVerified: true,
                    fixtureMarkerObserved: fixtureMarker,
                    elapsedMonotonicMilliseconds: elapsed)
                return AcceptedProcessEvidence(
                    evidence: evidence,
                    launcher: launcher,
                    descendants: observed.values.sorted { $0.pid < $1.pid })
            }
            try await clock.sleep(for: .milliseconds(50))
        }
        throw ProcessEvidenceError.inspectionFailed(
            "no anchored MonkeyDoDeux owner connected to a validated simulator listener in 30 seconds; "
                + "descendants=\(lastDescendantCommands); predicateMatches=\(lastPredicateMatches); "
                + "connections=\(lastConnections); listeners="
                + "\(simulator.listeningEndpoints.sorted(by: endpointOrder))")
    }

    private func captureSnapshotWithoutSuspension(
        pid: Int32,
        collector: ProcessEvidenceCollector,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) throws -> ProcessEvidenceSnapshot? {
        while clock.now < deadline {
            if let snapshot = try collector.snapshot(pid: pid) { return snapshot }
        }
        return nil
    }

    private func cleanupOwnedLaunch(
        process: any RunningProcess,
        launcher: ProcessEvidenceSnapshot,
        previouslyObserved: [ProcessEvidenceSnapshot],
        collector: ProcessEvidenceCollector
    ) async throws {
        let sender = DarwinProcessSignalSender()
        try await EvidenceCleanupExecutor(
            identityReader: collector.identityReader,
            signaler: sender,
            waitForExit: { snapshot in
                try await waitForProcessExit(snapshot, collector: collector)
            },
            terminateOwnedWrapper: {
                await process.terminate(grace: .seconds(5))
            })
            .cleanup(
                launcher: launcher,
                launcherPid: launcher.pid,
                previouslyObserved: previouslyObserved)
        let survivors = try previouslyObserved.filter {
            try collector.snapshot(pid: $0.pid) == $0
        }
        guard survivors.isEmpty else {
            throw ProcessEvidenceError.inspectionFailed(
                "owned descendants remain after structured wrapper cleanup: \(survivors.map(\.pid))")
        }
    }

    private func cleanupInitialCaptureFailure(
        process: any RunningProcess,
        launcherPid: Int32,
        collector: ProcessEvidenceCollector
    ) async throws {
        try await EvidenceCleanupExecutor(
            identityReader: collector.identityReader,
            signaler: DarwinProcessSignalSender(),
            waitForExit: { snapshot in
                try await waitForProcessExit(snapshot, collector: collector)
            },
            terminateOwnedWrapper: {
                await process.terminate(grace: .seconds(5))
            })
            .cleanup(launcher: nil, launcherPid: launcherPid, previouslyObserved: [])
    }

    private func waitForProcessExit(
        _ snapshot: ProcessEvidenceSnapshot,
        collector: ProcessEvidenceCollector
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            guard try collector.snapshot(pid: snapshot.pid) == snapshot else { return true }
            try await clock.sleep(for: .milliseconds(25))
        }
        return try collector.snapshot(pid: snapshot.pid) != snapshot
    }

    private func writeEvidence(_ evidence: MonkeydoProcessEvidence, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(evidence).write(
            to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func fixtureEvidence(
        fixture: AcceptanceFixture,
        launcherProcessGroupMembers: [ProcessEvidenceSnapshot],
        launcherGroupFullyAnchored: Bool,
        postSocketRevalidationVerified: Bool
    ) -> MonkeydoProcessEvidence {
        MonkeydoProcessEvidence(
            collectionSchemaVersion: 1,
            collectionCommands: ProcessEvidenceCommands(
                snapshot: "snapshot", processList: "process-list",
                executable: "executable", connections: "connections"),
            recordedOn: "2026-07-14T00:00:00Z", sdkVersion: "9.1.0",
            sdkPath: fixture.sdk, device: "fenix6xpro",
            simulator: SimulatorProcessEvidence(
                pid: 7, executablePath: "/simulator", listeningEndpoints: []),
            testProcess: fixture.launcher, launcher: fixture.launcher,
            launcherProcessGroupMembers: launcherProcessGroupMembers,
            descendants: [fixture.java, fixture.owner],
            connectionOwner: ConnectionOwnerEvidence(
                process: fixture.owner,
                localEndpoint: TCPEndpoint(address: "127.0.0.1", port: 1, family: "ipv4"),
                remoteEndpoint: TCPEndpoint(address: "127.0.0.1", port: 2, family: "ipv4"),
                matchedSimulatorListener: TCPEndpoint(
                    address: "127.0.0.1", port: 2, family: "ipv4")),
            parentChain: [fixture.owner, fixture.java, fixture.launcher],
            ancestryVerified: true, endpointVerified: true,
            launcherGroupInherited: true, launcherGroupDedicated: false,
            launcherGroupFullyAnchored: launcherGroupFullyAnchored,
            postSocketRevalidationVerified: postSocketRevalidationVerified,
            fixtureMarkerObserved: true, elapsedMonotonicMilliseconds: 1)
    }
}

private struct AcceptedProcessEvidence: Sendable {
    let evidence: MonkeydoProcessEvidence
    let launcher: ProcessEvidenceSnapshot
    let descendants: [ProcessEvidenceSnapshot]
}

private struct ProcessEvidenceCommands: Codable, Sendable {
    let snapshot: String
    let processList: String
    let executable: String
    let connections: String
}

private struct SimulatorProcessEvidence: Codable, Sendable {
    let pid: Int32
    let executablePath: String
    let listeningEndpoints: [TCPEndpoint]
}

private struct ConnectionOwnerEvidence: Codable, Sendable {
    let process: ProcessEvidenceSnapshot
    let localEndpoint: TCPEndpoint
    let remoteEndpoint: TCPEndpoint
    let matchedSimulatorListener: TCPEndpoint
}

private struct MonkeydoProcessEvidence: Codable, Sendable {
    let collectionSchemaVersion: Int
    let collectionCommands: ProcessEvidenceCommands
    let recordedOn: String
    let sdkVersion: String
    let sdkPath: String
    let device: String
    let simulator: SimulatorProcessEvidence
    let testProcess: ProcessEvidenceSnapshot
    let launcher: ProcessEvidenceSnapshot
    let launcherProcessGroupMembers: [ProcessEvidenceSnapshot]
    let descendants: [ProcessEvidenceSnapshot]
    let connectionOwner: ConnectionOwnerEvidence
    let parentChain: [ProcessEvidenceSnapshot]
    let ancestryVerified: Bool
    let endpointVerified: Bool
    let launcherGroupInherited: Bool
    let launcherGroupDedicated: Bool
    let launcherGroupFullyAnchored: Bool
    let postSocketRevalidationVerified: Bool
    let fixtureMarkerObserved: Bool
    let elapsedMonotonicMilliseconds: Int
}

private struct Task13SimulatorEvidence: Codable, Sendable {
    let pid: Int32
    let executablePath: String
    let matchedListener: TCPEndpoint
}

private struct Task13ConnectionOwnerEvidence: Codable, Sendable {
    let process: ProcessIdentitySnapshot
    let localEndpoint: TCPEndpoint
    let remoteEndpoint: TCPEndpoint
}

private struct Task13LaunchEvidence: Codable, Sendable {
    let schemaVersion: Int
    let recordedOn: String
    let sdkVersion: String
    let sdkPath: String
    let device: String
    let simulator: Task13SimulatorEvidence
    let launcher: ProcessIdentitySnapshot
    let connectionOwner: Task13ConnectionOwnerEvidence
    let parentChain: [ProcessIdentitySnapshot]
    let launcherGroupMembers: [ProcessIdentitySnapshot]
    let serverProcess: ProcessIdentitySnapshot
    let ancestryVerified: Bool
    let postSocketRevalidationVerified: Bool
    let connectionVerified: Bool
    let launcherGroupDedicated: Bool
    let launcherGroupFullyAnchored: Bool
    let sessionId: Int
    let currentDevice: String
    let fixtureMarker: String
    let fixtureMarkerObserved: Bool
    let connectionElapsedMonotonicMilliseconds: UInt64
    let fixtureMarkerElapsedMonotonicMilliseconds: UInt64
}

private struct Task13EvidenceError: Error, CustomStringConvertible, Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct Task13FailingLifecycle: MonkeydoProcessLifecycling {
    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        throw Task13EvidenceError("intentional launch failure")
    }

    func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        throw Task13EvidenceError("intentional test launch failure")
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {}

    func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership,
        grace: Duration
    ) async throws {}
}

private actor Task13ObservedLifecycle<C: Clock>: MonkeydoProcessLifecycling,
    RunEvidenceObserving where C.Duration == Duration
{
    private let base: any MonkeydoProcessLifecycling
    private let clock: C
    private var launchStarted: C.Instant?
    private var connections: [VerifiedMonkeydoConnection] = []

    init(base: any MonkeydoProcessLifecycling, clock: C) {
        self.base = base
        self.clock = clock
    }

    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        launchStarted = clock.now
        return try await base.launchApp(
            command, onStdout: onStdout, onStderr: onStderr)
    }

    func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await base.launchTests(
            command,
            workingDirectory: workingDirectory,
            timeout: timeout,
            onStdout: onStdout,
            onStderr: onStderr)
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {
        try await base.terminate(owned, grace: grace)
    }

    func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership,
        grace: Duration
    ) async throws {
        try await base.terminatePersisted(ownership, grace: grace)
    }

    func accepted(_ connection: VerifiedMonkeydoConnection) {
        connections.append(connection)
    }

    func onlyConnection() throws -> VerifiedMonkeydoConnection {
        guard connections.count == 1, let connection = connections.first else {
            throw Task13EvidenceError(
                "expected exactly one production connection acceptance, observed \(connections.count)")
        }
        return connection
    }

    func fixtureMarkerElapsedMilliseconds() throws -> UInt64 {
        guard connections.count == 1 else {
            throw Task13EvidenceError(
                "cannot time the fixture marker without one accepted production connection")
        }
        guard let launchStarted else {
            throw Task13EvidenceError(
                "cannot time the fixture marker without the production launch boundary")
        }
        return try task13DurationMilliseconds(launchStarted.duration(to: clock.now))
    }
}

private func task13DurationMilliseconds(_ duration: Duration) throws -> UInt64 {
    let components = duration.components
    guard components.seconds >= 0, components.attoseconds >= 0 else {
        throw Task13EvidenceError("a monotonic duration unexpectedly became negative")
    }
    let seconds = UInt64(components.seconds)
    let attoseconds = UInt64(components.attoseconds)
    let (wholeMilliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
    guard !overflow else {
        throw Task13EvidenceError("a monotonic duration overflowed milliseconds")
    }
    return wholeMilliseconds + attoseconds / 1_000_000_000_000_000
}

private func task13ToolServices(
    controller: SimulatorController,
    sessions: AppSessionManager
) -> ToolHandlerServices {
    ToolHandlerServices(
        listSdks: { try task13UnavailableService() },
        listDevices: { _ in try task13UnavailableService() },
        build: { _ in try task13UnavailableService() },
        simStart: { _ in try task13UnavailableService() },
        simStop: {
            _ = try await controller.withOperation(.simStop, requirement: .stop) { _ in () }
            return SimStopResult(status: try await controller.status())
        },
        simStatus: { try await controller.status() },
        runApp: { _ in try task13UnavailableService() },
        runTests: { _ in try task13UnavailableService() },
        getLogs: { request in
            try await sessions.logs(
                sessionId: request.sessionId,
                sinceToken: request.sinceToken,
                limit: request.limit)
        },
        doctor: { _ in try task13UnavailableService() })
}

private func task13UnavailableService<Value>() throws -> Value {
    throw Task13EvidenceError("the final Task 13 harness called an unrelated public service")
}

private func waitForFixtureMarker(
    harness: MCPHarness,
    sessionID: Int,
    observer: Task13ObservedLifecycle<ContinuousClock>
) async throws -> UInt64 {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    var cursor: String?

    while clock.now < deadline {
        var arguments: [String: Value] = ["sessionId": .int(sessionID), "limit": .int(500)]
        if let cursor { arguments["sinceToken"] = .string(cursor) }
        let response = try await harness.call(
            "get_logs", arguments: arguments, as: GetLogsResult.self)
        guard response.envelope.ok, let logs = response.envelope.result else {
            throw Task13EvidenceError(
                "public get_logs failed while waiting for FIXTURE_STARTED: "
                    + (response.envelope.error?.message ?? "missing result"))
        }
        if logs.lines.contains(where: { $0.text == "FIXTURE_STARTED" }) {
            return try await observer.fixtureMarkerElapsedMilliseconds()
        }
        cursor = logs.nextToken
        try await clock.sleep(for: .milliseconds(25))
    }
    throw Task13EvidenceError(
        "public get_logs did not return the exact FIXTURE_STARTED line within 30 seconds")
}

private func requireTask13Runtime() throws -> RuntimeRecord {
    guard let runtime = RuntimeStore.standard.read() else {
        throw Task13EvidenceError("runtime schema 2 was absent while the fixture app was running")
    }
    return runtime
}

private func requireTask13Ownership(
    _ runtime: RuntimeRecord
) throws -> PersistedMonkeydoOwnership {
    guard let ownership = runtime.monkeydoOwnership else {
        throw Task13EvidenceError("runtime schema 2 omitted monkeydo ownership while the app ran")
    }
    return ownership
}

private func requireTask13PublicResult<Result: Codable & Sendable>(
    _ envelope: ToolEnvelope<Result>,
    tool: String
) throws -> Result {
    guard envelope.ok, let result = envelope.result else {
        let failure = envelope.error
        throw Task13EvidenceError(
            "public \(tool) failed with \(failure?.code ?? "missing_error"): "
                + "\(failure?.message ?? "missing message"); "
                + "fix: \(failure?.fix ?? "missing fix")")
    }
    return result
}

private func auditTask13Cleanup(
    connection: VerifiedMonkeydoConnection,
    simulator: ProcessIdentitySnapshot,
    identityReader: SimulatorMCPCore.DarwinProcessIdentityReader
) throws {
    let ownedSnapshots = [connection.launcher] + connection.parentChain
        + connection.launcherGroupMembers
    for expected in ownedSnapshots {
        guard try identityReader.snapshot(pid: expected.pid)?.stableIdentity
            != expected.stableIdentity
        else {
            throw Task13EvidenceError(
                "owned monkeydo process \(expected.pid) survived public sim_stop")
        }
    }
    guard try identityReader.snapshot(pid: simulator.pid)?.stableIdentity
        != simulator.stableIdentity
    else {
        throw Task13EvidenceError(
            "simulator process \(simulator.pid) survived public sim_stop")
    }
    let launcherGroup = try identityReader.processGroupPIDs(
        processGroupId: connection.launcher.processGroupId)
    guard launcherGroup.isEmpty else {
        throw Task13EvidenceError(
            "launcher process group \(connection.launcher.processGroupId) still contains \(launcherGroup)")
    }
    guard try identityReader.snapshot(pid: connection.serverProcess.pid)
        == connection.serverProcess
    else {
        throw Task13EvidenceError("the current Task 13 harness identity changed during cleanup")
    }
    let serverGroup = try identityReader.processGroupPIDs(
        processGroupId: connection.serverProcess.processGroupId)
    let staleHelpers: [Int32] = try serverGroup.compactMap { pid -> Int32? in
        guard pid != connection.serverProcess.pid,
            let snapshot = try identityReader.snapshot(pid: pid)
        else { return nil }
        let command = ([snapshot.executablePath] + snapshot.arguments).joined(separator: " ")
        return command.contains("swiftpm-testing-helper") ? pid : nil
    }
    guard staleHelpers.isEmpty else {
        throw Task13EvidenceError(
            "additional SwiftPM test helpers survived cleanup: \(staleHelpers)")
    }
}

private func validateTask13Prerequisite(_ url: URL, sdkVersion: String) throws {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["sdkVersion"] as? String == sdkVersion,
        object["device"] as? String == "fenix6xpro",
        object["ancestryVerified"] as? Bool == true,
        object["endpointVerified"] as? Bool == true,
        object["postSocketRevalidationVerified"] as? Bool == true,
        object["launcherGroupDedicated"] as? Bool == true,
        object["launcherGroupFullyAnchored"] as? Bool == true,
        let sdkPath = object["sdkPath"] as? String,
        let launcher = object["launcher"] as? [String: Any],
        launcher["executablePath"] as? String == "/bin/bash",
        let launcherGroup = launcher["processGroupId"] as? NSNumber,
        let testProcess = object["testProcess"] as? [String: Any],
        let testGroup = testProcess["processGroupId"] as? NSNumber,
        launcherGroup.int32Value != testGroup.int32Value,
        let owner = object["connectionOwner"] as? [String: Any],
        let ownerProcess = owner["process"] as? [String: Any],
        ownerProcess["executablePath"] as? String == sdkPath + "/bin/shell",
        let parentChain = object["parentChain"] as? [[String: Any]],
        parentChain.count == 3,
        let javaArguments = parentChain[1]["arguments"] as? [String],
        javaArguments.contains("com.garmin.monkeybrains.monkeydodeux.MonkeyDoDeux"),
        let groupMembers = object["launcherProcessGroupMembers"] as? [[String: Any]],
        task13PIDs(groupMembers) == task13PIDs(parentChain)
    else {
        throw Task13EvidenceError(
            "prerequisite \(url.lastPathComponent) does not satisfy the approved lifecycle contract")
    }
}

private func task13PIDs(_ snapshots: [[String: Any]]) -> [Int32] {
    snapshots.compactMap { ($0["pid"] as? NSNumber)?.int32Value }.sorted()
}

private func writeTask13Evidence(_ evidence: Task13LaunchEvidence, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(evidence).write(to: url, options: .atomic)
}

private func task13LaunchEvidenceFixture() -> Task13LaunchEvidence {
    let launcher = ProcessIdentitySnapshot(
        pid: 100, parentPid: 10, processGroupId: 100,
        start: ProcessStartIdentity(seconds: 1, microseconds: 1),
        executablePath: "/bin/bash",
        arguments: ["/bin/bash", "/sdk/bin/monkeydo", "/tmp/fixture.prg", "fenix6xpro"])
    let java = ProcessIdentitySnapshot(
        pid: 101, parentPid: 100, processGroupId: 100,
        start: ProcessStartIdentity(seconds: 1, microseconds: 2),
        executablePath: "/usr/bin/java",
        arguments: ["/usr/bin/java", "com.garmin.monkeybrains.monkeydodeux.MonkeyDoDeux"])
    let owner = ProcessIdentitySnapshot(
        pid: 102, parentPid: 101, processGroupId: 100,
        start: ProcessStartIdentity(seconds: 1, microseconds: 3),
        executablePath: "/sdk/bin/shell",
        arguments: ["/sdk/bin/shell", "--transport=tcp", "--transport_args=127.0.0.1:1234"])
    let server = ProcessIdentitySnapshot(
        pid: 10, parentPid: 1, processGroupId: 10,
        start: ProcessStartIdentity(seconds: 1, microseconds: 0),
        executablePath: "/tests",
        arguments: ["/tests"])
    return Task13LaunchEvidence(
        schemaVersion: 1,
        recordedOn: "2026-07-15T00:00:00Z",
        sdkVersion: "9.1.0",
        sdkPath: "/sdk",
        device: "fenix6xpro",
        simulator: Task13SimulatorEvidence(
            pid: 7,
            executablePath: "/sdk/bin/simulator",
            matchedListener: TCPEndpoint(address: "*", port: 1234, family: "ipv4")),
        launcher: launcher,
        connectionOwner: Task13ConnectionOwnerEvidence(
            process: owner,
            localEndpoint: TCPEndpoint(address: "127.0.0.1", port: 50_000, family: "ipv4"),
            remoteEndpoint: TCPEndpoint(address: "127.0.0.1", port: 1234, family: "ipv4")),
        parentChain: [owner, java, launcher],
        launcherGroupMembers: [launcher, java, owner],
        serverProcess: server,
        ancestryVerified: true,
        postSocketRevalidationVerified: true,
        connectionVerified: true,
        launcherGroupDedicated: true,
        launcherGroupFullyAnchored: true,
        sessionId: 1,
        currentDevice: "fenix6xpro",
        fixtureMarker: "FIXTURE_STARTED",
        fixtureMarkerObserved: true,
        connectionElapsedMonotonicMilliseconds: 125,
        fixtureMarkerElapsedMonotonicMilliseconds: 175)
}

private func task13VerifiedConnectionFixture(
    elapsed: UInt64
) -> VerifiedMonkeydoConnection {
    let evidence = task13LaunchEvidenceFixture()
    return VerifiedMonkeydoConnection(
        launcher: evidence.launcher,
        connectionOwner: evidence.connectionOwner.process,
        parentChain: evidence.parentChain,
        launcherGroupMembers: evidence.launcherGroupMembers,
        serverProcess: evidence.serverProcess,
        launcherGroupFullyAnchored: evidence.launcherGroupFullyAnchored,
        postSocketRevalidationVerified: evidence.postSocketRevalidationVerified,
        localEndpoint: evidence.connectionOwner.localEndpoint,
        remoteEndpoint: evidence.connectionOwner.remoteEndpoint,
        matchedSimulatorListener: evidence.simulator.matchedListener,
        elapsedMonotonicMilliseconds: elapsed)
}

private struct FixtureProcessIdentityReader: ProcessIdentityReading, Sendable {
    let snapshots: [Int32: ProcessEvidenceSnapshot]
    let children: [Int32: [Int32]]
    let groupPids: [Int32: [Int32]]

    init(
        snapshots: [Int32: ProcessEvidenceSnapshot],
        children: [Int32: [Int32]],
        groupPids: [Int32: [Int32]] = [:]
    ) {
        self.snapshots = snapshots
        self.children = children
        self.groupPids = groupPids
    }

    func snapshot(pid: Int32) throws -> ProcessEvidenceSnapshot? { snapshots[pid] }
    func childPIDs(parentPid: Int32) throws -> [Int32] { children[parentPid] ?? [] }
    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        groupPids[processGroupId]
            ?? snapshots.values.filter { $0.processGroupId == processGroupId }.map(\.pid).sorted()
    }
}

private final class FixtureCleanupRuntime: ProcessIdentityReading,
    ProcessSignalSending, @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshots: [Int32: ProcessEvidenceSnapshot]
    private var signals: [CleanupSignal] = []
    private var wrapperTerminations = 0
    private var waitCount = 0
    private let failingPid: Int32?
    private let survivesTermPids: Set<Int32>
    private let cancelDuringFirstWait: Bool
    private let launcherExitsWhenDescendantsExit: Bool
    private let spawnAfterSignal: [Int32: ProcessEvidenceSnapshot]

    init(
        snapshots: [ProcessEvidenceSnapshot],
        failingPid: Int32? = nil,
        survivesTermPids: Set<Int32> = [],
        cancelDuringFirstWait: Bool = false,
        launcherExitsWhenDescendantsExit: Bool = false,
        spawnAfterSignal: [Int32: ProcessEvidenceSnapshot] = [:]
    ) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        self.failingPid = failingPid
        self.survivesTermPids = survivesTermPids
        self.cancelDuringFirstWait = cancelDuringFirstWait
        self.launcherExitsWhenDescendantsExit = launcherExitsWhenDescendantsExit
        self.spawnAfterSignal = spawnAfterSignal
    }

    var signalEvents: [CleanupSignal] { lock.withLock { signals } }
    var signaledPids: [Int32] { lock.withLock { signals.map(\.pid) } }
    var wrapperTerminationCount: Int { lock.withLock { wrapperTerminations } }

    func snapshot(pid: Int32) throws -> ProcessEvidenceSnapshot? {
        lock.withLock { snapshots[pid] }
    }

    func childPIDs(parentPid: Int32) throws -> [Int32] {
        lock.withLock {
            snapshots.values.filter { $0.parentPid == parentPid }.map(\.pid).sorted()
        }
    }

    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        lock.withLock {
            snapshots.values.filter { $0.processGroupId == processGroupId }.map(\.pid).sorted()
        }
    }

    func signal(pid: Int32, signal: Int32) throws {
        lock.withLock { signals.append(CleanupSignal(pid: pid, signal: signal)) }
        if failingPid == pid {
            throw ProcessEvidenceError.inspectionFailed("injected signal failure for PID \(pid)")
        }
        if signal == SIGKILL || !survivesTermPids.contains(pid) {
            lock.withLock {
                snapshots[pid] = nil
                if let spawned = spawnAfterSignal[pid] {
                    snapshots[spawned.pid] = spawned
                }
                if launcherExitsWhenDescendantsExit,
                    snapshots.values.allSatisfy({ $0.executablePath == "/bin/bash" })
                {
                    for launcherPid in snapshots.keys {
                        snapshots[launcherPid] = nil
                    }
                }
            }
        }
    }

    func waitForExit(_ snapshot: ProcessEvidenceSnapshot) async throws -> Bool {
        let shouldCancel = lock.withLock { () -> Bool in
            waitCount += 1
            return cancelDuringFirstWait && waitCount == 1
        }
        if shouldCancel {
            throw CancellationError()
        }
        return try self.snapshot(pid: snapshot.pid) != snapshot
    }

    func terminateWrapper() {
        lock.withLock {
            wrapperTerminations += 1
            for pid in snapshots.values.filter({ $0.executablePath == "/bin/bash" }).map(\.pid) {
                snapshots[pid] = nil
            }
        }
    }
}

private struct CleanupSignal: Equatable, Sendable {
    let pid: Int32
    let signal: Int32
}

private final class FixtureKernelReader: KernelProcessReading, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [KernelBSDIdentity?]
    private let path: String?
    private let capturedArguments: [String]?

    init(
        identities: [KernelBSDIdentity?],
        path: String?,
        arguments: [String]?
    ) {
        self.identities = identities
        self.path = path
        self.capturedArguments = arguments
    }

    func bsdIdentity(pid _: Int32) throws -> KernelBSDIdentity? {
        lock.withLock {
            guard !identities.isEmpty else { return nil }
            return identities.removeFirst()
        }
    }

    func executablePath(pid _: Int32) throws -> String? { path }
    func arguments(pid _: Int32) throws -> [String]? { capturedArguments }
    func childPIDs(parentPid _: Int32) throws -> [Int32] { [] }
    func processGroupPIDs(processGroupId _: Int32) throws -> [Int32] { [] }
}

private final class CleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ObservedProcessBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var byPid: [Int32: ProcessEvidenceSnapshot] = [:]

    var snapshots: [ProcessEvidenceSnapshot] {
        lock.withLock { byPid.values.sorted { $0.pid < $1.pid } }
    }

    func record(_ snapshot: ProcessEvidenceSnapshot) {
        lock.withLock { byPid[snapshot.pid] = snapshot }
    }
}

private func procArgumentsData(_ arguments: [String]) -> Data {
    var argc = Int32(arguments.count)
    var data = withUnsafeBytes(of: &argc) { Data($0) }
    data.append(contentsOf: arguments[0].utf8)
    data.append(0)
    data.append(0)
    for argument in arguments {
        data.append(contentsOf: argument.utf8)
        data.append(0)
    }
    return data
}

private struct AcceptanceFixture {
    let sdk: String
    let prg: String
    let launcher: ProcessEvidenceSnapshot
    let java: ProcessEvidenceSnapshot
    let owner: ProcessEvidenceSnapshot
}

private func acceptanceFixture() -> AcceptanceFixture {
    let sdk = "/sdk root/connectiq-sdk-mac-8.4.1"
    let prg = "/project with spaces/app.prg"
    let launcher = ProcessEvidenceSnapshot(
        pid: 100, parentPid: 10, processGroupId: 100,
        processStartIdentity: "100.1", executablePath: "/bin/bash",
        arguments: ["/bin/bash", "\(sdk)/bin/monkeydo", prg, "fenix6xpro"])
    let java = ProcessEvidenceSnapshot(
        pid: 101, parentPid: 100, processGroupId: 100,
        processStartIdentity: "101.1", executablePath: "/jdk/bin/java",
        arguments: ["/usr/bin/java", "-classpath", "\(sdk)/bin/monkeybrains.jar",
                    "com.garmin.monkeybrains.monkeydodeux.MonkeyDoDeux",
                    "-f", prg, "-d", "fenix6xpro", "-s", "\(sdk)/bin/shell"])
    let owner = ProcessEvidenceSnapshot(
        pid: 102, parentPid: 101, processGroupId: 100,
        processStartIdentity: "102.1", executablePath: "\(sdk)/bin/shell",
        arguments: ["\(sdk)/bin/shell", "--transport=tcp",
                    "--transport_args=127.0.0.1:1234"])
    return AcceptanceFixture(sdk: sdk, prg: prg, launcher: launcher, java: java, owner: owner)
}

private func endpointOrder(_ lhs: TCPEndpoint, _ rhs: TCPEndpoint) -> Bool {
    (lhs.family, lhs.address, lhs.port) < (rhs.family, rhs.address, rhs.port)
}

private func durationMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    let seconds = Double(components.seconds)
    let fractional = Double(components.attoseconds) / 1e18
    return Int((seconds + fractional) * 1_000)
}
