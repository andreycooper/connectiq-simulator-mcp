import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("SimulatorController")
struct SimulatorControllerTests {
    @Test("process lookup uses exact ps arguments only when proc_pidpath has no result")
    func processPathFallbackUsesPS() async throws {
        let sdkLayout = try SDKLayoutSandbox(version: "9.1.0")
        defer { sdkLayout.tearDown() }
        let executable = sdkLayout.simulatorExecutable.path
        let runner = FakeProcessRunner { invocation in
            #expect(invocation.executable.path == "/bin/ps")
            #expect(invocation.arguments == ["-p", "321", "-o", "comm="])
            return (0, Data((executable + "\n").utf8), Data())
        }
        let system = SimulatorProcessSystem.configured(
            processRunner: runner,
            isAlive: { $0 == 321 },
            procPath: { _ in nil },
            launch: { _ in 0 })

        let identity = try #require(try await system.lookup(321))

        #expect(identity.pid == 321)
        #expect(identity.executablePath == executable)
        #expect(identity.sdk?.root.path == sdkLayout.root.path)
        #expect(identity.sdk?.version == SemVer("9.1.0"))
        #expect(runner.invocations.count == 1)
        #expect(try await system.lookup(999) == nil)
        #expect(runner.invocations.count == 1, "dead PIDs must not invoke ps")
    }

    @Test("externally launched simulator SDK is inferred from a raw process path")
    func externalLaunchInferenceUsesRawProcessPath() async throws {
        let sdkLayout = try SDKLayoutSandbox(version: "8.4.1")
        defer { sdkLayout.tearDown() }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "simulator-external-inference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = FakeProcessRunner { invocation in
            switch invocation.executable.path {
            case "/usr/bin/pgrep":
                return (0, Data("322\n".utf8), Data())
            case "/usr/sbin/lsof":
                return (0, Data("p322\nf11\nn127.0.0.1:1234\n".utf8), Data())
            default:
                Issue.record("unexpected subprocess \(invocation.executable.path)")
                return (1, Data(), Data())
            }
        }
        let system = SimulatorProcessSystem.configured(
            processRunner: runner,
            isAlive: { $0 == 322 },
            procPath: { _ in sdkLayout.simulatorExecutable.path },
            launch: { _ in 0 })
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            identityLookup: system.lookup)
        let controller = SimulatorController(
            queue: AsyncFIFO(),
            lease: SimLease(lockFile: directory.appending(path: "sim.lock")),
            runtimeStore: RuntimeStore(runtimeFile: directory.appending(path: "runtime.json")),
            processRunner: runner,
            sessionStopper: NoSimulatorSessionStopper(),
            system: system,
            readinessProbe: probe,
            deviceReadback: ScriptedReadback([]))

        let context = try await controller.withOperation(
            .screenshot, requirement: .currentReady) { $0 }

        #expect(context.simulatorPid == 322)
        #expect(context.sdk.root.path == sdkLayout.root.path)
        #expect(context.sdk.version == SemVer("8.4.1"))
    }

    @Test("opt-in live harness records exact SDK runtime evidence")
    func runtimeEvidenceHarness() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sdkPath = environment["SIM_RUNTIME_EVIDENCE_SDK_PATH"],
            let versionText = environment["SIM_RUNTIME_EVIDENCE_SDK_VERSION"],
            let version = SemVer(versionText),
            let outputPath = environment["SIM_RUNTIME_EVIDENCE_OUTPUT"]
        else { return }
        let sdk = SdkInfo(
            version: version,
            root: URL(fileURLWithPath: sdkPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL,
            source: .explicit)
        let controller = SimulatorController(
            // live-readback: this gate runs only when SIM_RUNTIME_EVIDENCE_*
            // are all set, against the real simulator, and calls status()
            // below — see DeviceVerificationTests.unitTestsNeverReachTheWindowServer.
            queue: AsyncFIFO(),
            lease: .standard,
            runtimeStore: .standard,
            processRunner: Subprocess(),
            sessionStopper: NoSimulatorSessionStopper())

        // Evidence is collected sequentially for two SDKs. Stop whichever
        // verified simulator is already running before launching the exact
        // requested SDK; this follows sdk_mismatch's prescribed recovery.
        _ = try await controller.withOperation(
            .simStop, requirement: .stop) { _ in () }
        let context = try await controller.withOperation(
            .simStart, requirement: .start(requested: sdk)
        ) { $0 }
        let identity = try #require(try await controller.status().executablePath)
        let evidence = RuntimeEvidence(
            sdkVersion: version.description,
            sdkPath: sdk.root.path,
            simulatorPid: context.simulatorPid,
            executablePath: identity,
            listeningEndpoints: context.listeningEndpoints.filter {
                ["127.0.0.1", "::1", "localhost"].contains($0.address)
            }.sorted {
                ($0.family, $0.address, $0.port) < ($1.family, $1.address, $1.port)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var writeError: Error?
        do {
            try encoder.encode(evidence).write(
                to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            writeError = error
        }
        _ = try await controller.withOperation(
            .simStop, requirement: .stop) { _ in () }
        if let writeError { throw writeError }
    }

    @Test("start launches the exact SDK app and publishes a ready runtime")
    func startsRequestedSDK() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([])
        await fixture.system.setLaunchIdentity(sdk: sdk, pid: 4100)

        let context = try await fixture.controller.withOperation(
            .simStart, requirement: .start(requested: sdk)
        ) { $0 }

        #expect(context.simulatorPid == 4100)
        #expect(context.sdk.root == sdk.root)
        #expect(await fixture.system.launchedApps == [sdk.simulatorApp])
        #expect(fixture.store.read()?.simulatorPid == 4100)
        #expect(try await fixture.controller.status().state == .ready)
    }

    @Test("same SDK start is idempotent and different SDK is rejected")
    func startIdentityRules() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let running = sampleSDK(version: "8.4.1")
        let requested = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 42, sdk: running)])

        let context = try await fixture.controller.withOperation(
            .simStart, requirement: .start(requested: running)
        ) { $0 }
        #expect(context.simulatorPid == 42)
        #expect(await fixture.system.launchedApps.isEmpty)

        do {
            _ = try await fixture.controller.withOperation(
                .simStart, requirement: .start(requested: requested)
            ) { $0 }
            Issue.record("different SDK must fail")
        } catch let error as ToolError {
            #expect(error.code == "sdk_mismatch")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("multiple and unknown simulator processes fail with stable errors")
    func rejectsAmbiguousAndUnknownProcesses() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([
            fixture.system.identity(pid: 1, sdk: sdk), fixture.system.identity(pid: 2, sdk: sdk),
        ])
        do {
            _ = try await fixture.controller.withOperation(
                .screenshot, requirement: .currentReady) { $0 }
            Issue.record("multiple processes must fail")
        } catch let error as ToolError {
            #expect(error.code == "simulator_busy")
            #expect(error.fix == "Quit all Connect IQ simulator instances, then call sim_start.")
            #expect(error.details?["pids"] == .array([.int(1), .int(2)]))
        }

        await fixture.system.setProcesses([
            SimulatorProcessIdentity(
                pid: 3,
                executablePath: "/Applications/ConnectIQ.app/Contents/MacOS/simulator",
                sdk: nil),
        ])
        do {
            _ = try await fixture.controller.withOperation(
                .screenshot, requirement: .currentReady) { $0 }
            Issue.record("unknown SDK must fail")
        } catch let error as ToolError {
            #expect(error.code == "unknown_running_sdk")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("body throw and cancellation restore ready state")
    func failuresRestoreReady() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 50, sdk: sdk)])

        do {
            _ = try await fixture.controller.withOperation(
                .runApp, requirement: .ready(requested: sdk)
            ) { _ -> Int in throw ControllerTestError.expected }
            Issue.record("body error must propagate")
        } catch is ControllerTestError {}
        #expect(try await fixture.controller.status().state == .ready)

        let entered = AsyncSignal()
        let task = Task {
            try await fixture.controller.withOperation(
                .screenshot, requirement: .currentReady
            ) { _ in
                await entered.signal()
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        await entered.wait()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled body must fail")
        } catch is CancellationError {}
        #expect(try await fixture.controller.status().state == .ready)
    }

    @Test("current device persists only for the current PID and requires active operation")
    func currentDeviceLifecycle() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 60, sdk: sdk)])

        _ = try await fixture.controller.withOperation(
            .runApp, requirement: .ready(requested: sdk)
        ) { context in
            try await fixture.controller.setCurrentDevice("fenix6xpro", inside: .runApp)
            return context
        }
        #expect(fixture.store.read()?.currentDevice == "fenix6xpro")

        await fixture.system.setProcesses([fixture.system.identity(pid: 61, sdk: sdk)])
        #expect(try await fixture.controller.status().requestedDevice == nil)
        let refreshed = try await fixture.controller.withOperation(
            .screenshot, requirement: .currentReady) { $0 }
        #expect(refreshed.currentDevice == nil)
        #expect(fixture.store.read()?.currentDevice == nil)

        do {
            try await fixture.controller.setCurrentDevice("bad", inside: .runApp)
            Issue.record("device update outside operation must fail")
        } catch let error as ToolError {
            #expect(error.code == "invalid_simulator_state")
        }
    }

    @Test("a lease-owning operation refreshes currentDevice changed by another server")
    func operationSynchronizesExternalRuntimeDevice() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let identity = fixture.system.identity(pid: 62, sdk: sdk)
        await fixture.system.setProcesses([identity])

        _ = try await fixture.controller.withOperation(
            .runApp, requirement: .ready(requested: sdk)
        ) { context in
            try await fixture.controller.setCurrentDevice("cached-X", inside: .runApp)
            return context
        }
        #expect(fixture.store.read()?.currentDevice == "cached-X")

        try fixture.store.write(RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: "external-Y",
            monkeydoOwnership: nil))

        let context = try await fixture.controller.withOperation(
            .screenshot, requirement: .currentReady) { $0 }

        #expect(context.currentDevice == "external-Y")
        #expect(fixture.store.read()?.currentDevice == "external-Y")
    }

    @Test("stop ends the local session, TERM-waits, and clears runtime")
    func stopsAndWaitsForExit() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 70, sdk: sdk)])
        _ = try await fixture.controller.withOperation(
            .simStart, requirement: .start(requested: sdk)) { $0 }

        _ = try await fixture.controller.withOperation(
            .simStop, requirement: .stop) { $0.simulatorPid }

        #expect(await fixture.stopper.calls == 1)
        #expect(await fixture.system.signals == [.init(pid: 70, signal: 15)])
        #expect(fixture.store.read() == nil)
        #expect(try await fixture.controller.status().state == .notRunning)
    }

    @Test("sim_stop consumes another server's persisted monkeydo ownership first")
    func stopConsumesCrossServerMonkeydoOwnership() async throws {
        let path = MutableProcessPath("/bin/bash")
        let fixture = try ControllerFixture(monkeydoPath: path)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let identity = fixture.system.identity(pid: 701, sdk: sdk)
        let owned = controllerOwned(pid: 9_006, sdk: sdk)
        try fixture.store.write(RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: "fenix6xpro",
            monkeydoOwnership: persistedControllerOwnership(
                owned, ownerServerInstance: UUID())))
        await fixture.system.setProcesses([identity])

        _ = try await fixture.controller.withOperation(
            .simStop, requirement: .stop) { $0.simulatorPid }

        #expect(fixture.monkeydoSignals.values == [.init(pid: 9_006, signal: 15)])
        #expect(await fixture.system.signals.first == .init(pid: 701, signal: 15))
        #expect(fixture.store.read() == nil)
    }

    @Test("sim_stop preserves cross-server ownership when monkeydo cleanup fails")
    func stopPreservesOwnershipOnCrossServerCleanupFailure() async throws {
        let path = MutableProcessPath("/reused/process")
        let fixture = try ControllerFixture(monkeydoPath: path)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let identity = fixture.system.identity(pid: 702, sdk: sdk)
        let owned = controllerOwned(pid: 9_007, sdk: sdk)
        try fixture.store.write(RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: "fenix6xpro",
            monkeydoOwnership: persistedControllerOwnership(
                owned, ownerServerInstance: UUID())))
        await fixture.system.setProcesses([identity])

        do {
            _ = try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
            Issue.record("uncertain cross-server cleanup must abort sim_stop")
        } catch let error as ToolError {
            #expect(error.code == "monkeydo_cleanup_failed")
        }

        #expect(fixture.monkeydoSignals.values.isEmpty)
        #expect(await fixture.system.signals.isEmpty)
        #expect(fixture.store.read()?.monkeydoOwnership?.launcher == owned.launcher.stableIdentity)
    }

    @Test("sim_stop consumes persisted monkeydo ownership when simulator is already absent")
    func absentStopConsumesPersistedMonkeydoOwnership() async throws {
        let path = MutableProcessPath("/bin/bash")
        let fixture = try ControllerFixture(monkeydoPath: path)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let owned = controllerOwned(pid: 9_008, sdk: sdk)
        try fixture.store.write(RuntimeRecord(
            simulatorPid: 703,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: "fenix6xpro",
            monkeydoOwnership: persistedControllerOwnership(
                owned, ownerServerInstance: UUID())))
        await fixture.system.setProcesses([])

        _ = try await fixture.controller.withOperation(
            .simStop, requirement: .stop) { $0.simulatorPid }

        #expect(fixture.monkeydoSignals.values == [.init(pid: 9_008, signal: 15)])
        #expect(await fixture.system.signals.isEmpty)
        #expect(fixture.store.read() == nil)
    }

    @Test("absent sim_stop preserves ownership when monkeydo cleanup fails")
    func absentStopPreservesOwnershipOnCleanupFailure() async throws {
        let path = MutableProcessPath("/reused/process")
        let fixture = try ControllerFixture(monkeydoPath: path)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let owned = controllerOwned(pid: 9_009, sdk: sdk)
        try fixture.store.write(RuntimeRecord(
            simulatorPid: 704,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: nil,
            monkeydoOwnership: persistedControllerOwnership(
                owned, ownerServerInstance: UUID())))
        await fixture.system.setProcesses([])

        do {
            _ = try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
            Issue.record("absent simulator must not hide failed monkeydo cleanup")
        } catch let error as ToolError {
            #expect(error.code == "monkeydo_cleanup_failed")
        }

        #expect(fixture.store.read()?.monkeydoOwnership?.launcher == owned.launcher.stableIdentity)
    }

    @Test("sim_stop compare-clear preserves ownership changed during cleanup")
    func stopCompareClearPreservesChangedOwnership() async throws {
        let mutation = RuntimeOwnershipMutation()
        let path = MutableProcessPath("/bin/bash")
        let fixture = try ControllerFixture(
            monkeydoPath: path,
            monkeydoDidSignal: { _ in mutation.apply() })
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let identity = fixture.system.identity(pid: 705, sdk: sdk)
        let old = controllerOwned(pid: 9_010, sdk: sdk)
        let newer = controllerOwned(pid: 9_011, sdk: sdk)
        let oldRecord = RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: nil,
            monkeydoOwnership: persistedControllerOwnership(
                old, ownerServerInstance: UUID()))
        let newerRecord = RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: nil,
            monkeydoOwnership: persistedControllerOwnership(
                newer, ownerServerInstance: UUID()))
        try fixture.store.write(oldRecord)
        mutation.install(store: fixture.store, replacement: newerRecord)
        await fixture.system.setProcesses([identity])

        do {
            _ = try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
            Issue.record("changed ownership must fail compare-clear")
        } catch let error as ToolError {
            #expect(error.code == "runtime_ownership_changed")
        }

        #expect(fixture.store.read()?.monkeydoOwnership?.launcher == newer.launcher.stableIdentity)
        #expect(await fixture.system.signals.isEmpty)
    }

    @Test("active monkeydo state is published only inside the matching operation")
    func activeMonkeydoPublicationRequiresOperation() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 75, sdk: sdk)])

        _ = try await fixture.controller.withOperation(
            .runApp, requirement: .ready(requested: sdk)
        ) { _ in
            try await fixture.controller.publishActiveMonkeydo(
                controllerOwned(pid: 9001, sdk: sdk),
                device: "fenix6xpro", inside: .runApp)
        }

        #expect(fixture.store.read()?.monkeydoOwnership?.launcher.pid == 9001)
        #expect(fixture.store.read()?.currentDevice == "fenix6xpro")
        do {
            try await fixture.controller.clearActiveMonkeydo(
                expectedLauncher: controllerOwned(pid: 9001, sdk: sdk).launcher.stableIdentity,
                device: nil, inside: .runApp)
            Issue.record("runtime mutation outside the operation must fail")
        } catch let error as ToolError {
            #expect(error.code == "invalid_simulator_state")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a stale or reused launcher is left recorded without a signal")
    func staleMonkeydoPIDIsNotSignalled() async throws {
        let path = MutableProcessPath("/other/process")
        let fixture = try ControllerFixture(monkeydoPath: path)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 76, sdk: sdk)])
        _ = try await fixture.controller.withOperation(
            .runApp, requirement: .ready(requested: sdk)
        ) { _ in
            try await fixture.controller.publishActiveMonkeydo(
                controllerOwned(pid: 9002, sdk: sdk), device: nil, inside: .runApp)
        }

        _ = try await fixture.controller.withOperation(
            .runTests, requirement: .ready(requested: sdk)
        ) { _ in
            do {
                try await fixture.controller.terminateActiveMonkeydo(inside: .runTests)
                Issue.record("stale ownership must fail closed")
            } catch let error as ToolError {
                #expect(error.code == "monkeydo_cleanup_failed")
            }
        }

        #expect(fixture.store.read()?.monkeydoOwnership?.launcher.pid == 9002)
        #expect(fixture.monkeydoSignals.values.isEmpty)
    }

    @Test("a stale callback cannot clear a newer launcher ownership record")
    func staleCompareAndClearPreservesNewerOwnership() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 761, sdk: sdk)])
        let old = controllerOwned(pid: 9_101, sdk: sdk)
        let newer = controllerOwned(pid: 9_102, sdk: sdk)

        _ = try await fixture.controller.withOperation(
            .runApp, requirement: .ready(requested: sdk)
        ) { _ in
            try await fixture.controller.publishActiveMonkeydo(
                old, device: nil, inside: .runApp)
            try await fixture.controller.publishActiveMonkeydo(
                newer, device: nil, inside: .runApp)
            do {
                try await fixture.controller.clearActiveMonkeydo(
                    expectedLauncher: old.launcher.stableIdentity,
                    device: nil,
                    inside: .runApp)
                Issue.record("a stale callback must not clear newer ownership")
            } catch let error as ToolError {
                #expect(error.code == "runtime_ownership_changed")
            }
        }

        #expect(fixture.store.read()?.monkeydoOwnership?.launcher == newer.launcher.stableIdentity)
    }

    @Test("a validated monkeydo PID is terminated and cleared")
    func validatedMonkeydoPIDIsTerminated() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let path = MutableProcessPath("/bin/bash")
        let fixture = try ControllerFixture(monkeydoPath: path)
        defer { fixture.tearDown() }
        await fixture.system.setProcesses([fixture.system.identity(pid: 77, sdk: sdk)])
        _ = try await fixture.controller.withOperation(
            .runApp, requirement: .ready(requested: sdk)
        ) { _ in
            try await fixture.controller.publishActiveMonkeydo(
                controllerOwned(pid: 9003, sdk: sdk), device: nil, inside: .runApp)
        }

        _ = try await fixture.controller.withOperation(
            .runTests, requirement: .ready(requested: sdk)
        ) { _ in
            try await fixture.controller.terminateActiveMonkeydo(inside: .runTests)
        }

        #expect(fixture.monkeydoSignals.values == [.init(pid: 9003, signal: 15)])
        #expect(fixture.store.read()?.monkeydoOwnership == nil)
    }

    @Test("monkeydo identity changing before TERM receives no signal")
    func monkeydoIdentityChangeBeforeTermIsNotSignalled() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let paths = ProcessPathSequence(["/bin/bash", "/other/executable"])
        let fixture = try ControllerFixture(monkeydoPathLookup: { _ in paths.next() })
        defer { fixture.tearDown() }
        await fixture.system.setProcesses([fixture.system.identity(pid: 78, sdk: sdk)])
        _ = try await fixture.controller.withOperation(
            .runApp, requirement: .ready(requested: sdk)
        ) { _ in
            try await fixture.controller.publishActiveMonkeydo(
                controllerOwned(pid: 9004, sdk: sdk), device: nil, inside: .runApp)
        }

        _ = try await fixture.controller.withOperation(
            .runTests, requirement: .ready(requested: sdk)
        ) { _ in
            do {
                try await fixture.controller.terminateActiveMonkeydo(inside: .runTests)
                Issue.record("changed ownership must fail closed")
            } catch let error as ToolError {
                #expect(error.code == "monkeydo_cleanup_failed")
            }
        }

        #expect(fixture.monkeydoSignals.values.isEmpty)
        #expect(fixture.store.read()?.monkeydoOwnership?.launcher.pid == 9004)
    }

    @Test("stopping an absent simulator is idempotent and never signals")
    func absentStopIsIdempotent() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        await fixture.system.setProcesses([])

        let pid = try await fixture.controller.withOperation(
            .simStop, requirement: .stop) { $0.simulatorPid }

        #expect(pid == 0)
        #expect(await fixture.system.signals.isEmpty)
        #expect(await fixture.stopper.calls == 1)
        #expect(try await fixture.controller.status().state == .notRunning)
    }

    @Test("a body error after confirmed stop restores not-running state")
    func stoppedBodyErrorRestoresNotRunning() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 71, sdk: sdk)])

        do {
            _ = try await fixture.controller.withOperation(
                .simStop, requirement: .stop
            ) { _ -> Int in throw ControllerTestError.expected }
            Issue.record("stop body error must propagate")
        } catch is ControllerTestError {}

        #expect(try await fixture.controller.status().state == .notRunning)
        #expect(fixture.store.read() == nil)
    }

    @Test("status exposes an external lease holder without queueing")
    func statusReportsLeaseHolder() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let token = try await fixture.externalLease.acquire(operation: "run_tests")
        defer { try? token.release() }

        let status = try await fixture.controller.status()

        #expect(status.state == .busy)
        #expect(status.operation == "run_tests")
        #expect(status.leaseHolder?.contains("run_tests") == true)
    }

    /// `operationRequestsInFlight == 0` only rules out THIS server's own
    /// in-flight operation — the early-return path `currentStatus` covers.
    /// A foreign holder (another process, via a direct `SimLease.acquire`
    /// here, mirroring `statusReportsLeaseHolder`) reaches the readiness
    /// probe's `.busy` branch instead and, without this guard, would still
    /// consult the readback afterward — racing whatever that other process
    /// is mid-doing to the simulator's window, such as
    /// `restartForDeviceChange`. `status()` must treat a foreign holder
    /// identically to its own in-flight operation: unobserved.
    @Test("status skips the readback while a foreign lease holder is mid-operation")
    func statusSkipsReadbackForForeignHolder() async throws {
        let readback = ScriptedReadback([
            .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro")
        ])
        let fixture = try ControllerFixture(readback: readback)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 5400, sdk: sdk)])
        let token = try await fixture.externalLease.acquire(operation: "run_app")
        defer { try? token.release() }

        let status = try await fixture.controller.status()

        #expect(status.state == .busy)
        #expect(status.currentDevice == nil)
        #expect(status.deviceSource == "unobserved")
        #expect(await readback.calls == 0)
    }

    @Test("concurrent operations enter their bodies in FIFO arrival order")
    func operationsAreFIFO() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 80, sdk: sdk)])
        let firstEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()
        let order = StringRecorder()

        let first = Task {
            try await fixture.controller.withOperation(
                .screenshot, requirement: .currentReady
            ) { _ in
                order.append("first")
                await firstEntered.signal()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()
        let second = Task {
            try await fixture.controller.withOperation(
                .pressButton, requirement: .currentReady
            ) { _ in order.append("second") }
        }
        #expect(await waitUntil { await fixture.queue.queueDepth == 2 })
        let third = Task {
            try await fixture.controller.withOperation(
                .setGpsPosition, requirement: .currentReady
            ) { _ in order.append("third") }
        }
        #expect(await waitUntil { await fixture.queue.queueDepth == 3 })

        await releaseFirst.signal()
        try await first.value
        try await second.value
        try await third.value

        #expect(order.values == ["first", "second", "third"])
    }

    @Test("busy state names its operation and invalid lifecycle policies are rejected")
    func stateAndRequirementValidation() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        #expect(try await fixture.controller.status().state == .notRunning)
        await fixture.system.setProcesses([fixture.system.identity(pid: 81, sdk: sdk)])
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let operation = Task {
            try await fixture.controller.withOperation(
                .runTests, requirement: .ready(requested: sdk)
            ) { _ in
                await entered.signal()
                await release.wait()
            }
        }
        await entered.wait()
        let busy = try await fixture.controller.status()
        #expect(busy.state == .busy)
        #expect(busy.operation == "run_tests")
        await release.signal()
        try await operation.value
        #expect(try await fixture.controller.status().state == .ready)

        do {
            _ = try await fixture.controller.withOperation(
                .screenshot, requirement: .start(requested: sdk)) { _ in 1 }
            Issue.record("start policy on non-start operation must fail")
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
        }
    }

    @Test("status restores only a persisted device belonging to the validated process")
    func statusRestoresValidatedRuntimeDevice() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let identity = fixture.system.identity(pid: 91, sdk: sdk)
        try fixture.store.write(RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: "fenix6xpro",
            monkeydoOwnership: nil))
        await fixture.system.setProcesses([identity])

        // The fixture's default readback always reports unavailable, so this
        // is testing the persisted/requested field's restoration, not an
        // observation — `requestedDevice`, not `currentDevice`.
        #expect(try await fixture.controller.status().requestedDevice == "fenix6xpro")

        await fixture.system.setProcesses([fixture.system.identity(pid: 92, sdk: sdk)])
        #expect(try await fixture.controller.status().requestedDevice == nil)
    }

    @Test("currentDevice is null when the readback cannot see a device")
    func statusCurrentDeviceIsObserved() async throws {
        let fixture = try ControllerFixture(readback: ScriptedReadback([.idle]))
        defer { fixture.tearDown() }
        _ = try await fixture.startReady(pid: 5100)
        let status = try await fixture.controller.status()
        #expect(status.currentDevice == nil)
        #expect(status.deviceSource == "unobserved")
    }

    @Test("requestedDevice keeps the last requested id even when unobserved")
    func statusKeepsRequestedDevice() async throws {
        let fixture = try ControllerFixture(readback: ScriptedReadback([.idle, .idle]))
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5101)
        _ = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            try await controller.setCurrentDevice("fenix6spro", inside: .runApp)
            return fixture.runAppResult(sessionId: 1)
        }
        let status = try await controller.status()
        #expect(status.requestedDevice == "fenix6spro")
        #expect(status.currentDevice == nil)
    }

    @Test("an observed device populates currentDevice and marks the source")
    func statusReportsObservedDevice() async throws {
        let readback = ScriptedReadback([
            .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro")
        ])
        let fixture = try ControllerFixture(readback: readback)
        defer { fixture.tearDown() }
        _ = try await fixture.startReady(pid: 5102)
        let status = try await fixture.controller.status()
        #expect(status.currentDevice == "fenix6xpro")
        #expect(status.deviceSource == "observed")
        // The observation hinges entirely on the pid the readback is called
        // with — `DeviceReadback.observe` filters windows by it. Pin the
        // exact value rather than trusting the call happened at all.
        #expect(await readback.observedPids == [5102])
    }

    /// Every other `currentStatus` test leaves `requestedDevice` `nil`, which
    /// left `currentDevice: nil` and `currentDevice: requestedDevice`
    /// indistinguishable there by mutation — confirmed directly: swapping one
    /// for the other left the full suite green. This test sets a
    /// non-nil requested device and calls `status()` from inside the
    /// operation that set it, so `operationRequestsInFlight > 0` forces the
    /// `currentStatus(holder:)` fast path even though the readback (armed to
    /// return a device) would happily answer if consulted.
    @Test("currentStatus never reports the requested device as observed")
    func currentStatusNeverObservesDuringOperation() async throws {
        let fixture = try ControllerFixture(
            readback: ScriptedReadback([
                .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro")
            ]))
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5103)
        _ = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            try await controller.setCurrentDevice("fenix7s", inside: .runApp)
            let status = try await controller.status()
            #expect(status.currentDevice == nil)
            #expect(status.requestedDevice == "fenix7s")
            #expect(status.deviceSource == "unobserved")
            return fixture.runAppResult(sessionId: 1)
        }
    }

    @Test("status rejects a running simulator whose SDK cannot be inferred")
    func statusRejectsUnknownSDK() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        await fixture.system.setProcesses([
            SimulatorProcessIdentity(
                pid: 93,
                executablePath: "/Applications/ConnectIQ.app/Contents/MacOS/simulator",
                sdk: nil)
        ])

        do {
            _ = try await fixture.controller.status()
            Issue.record("unknown running SDK must not look not-running")
        } catch let error as ToolError {
            #expect(error.code == "unknown_running_sdk")
        }
    }

    @Test("status remains starting while the readiness probe is suspended")
    func statusDuringStartIsStarting() async throws {
        let probeEntered = AsyncSignal()
        let releaseProbe = AsyncSignal()
        let fixture = try ControllerFixture(runnerHandler: { _ in
            await probeEntered.signal()
            await releaseProbe.wait()
            return (0, Data("p94\nf11\nn127.0.0.1:1234\n".utf8), Data())
        })
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 94, sdk: sdk)])

        let start = Task {
            try await fixture.controller.withOperation(
                .simStart, requirement: .start(requested: sdk)) { $0 }
        }
        await probeEntered.wait()

        let status = try await fixture.controller.status()
        #expect(status.state == .starting)
        #expect(status.operation == "sim_start")

        await releaseProbe.signal()
        _ = try await start.value
    }

    @Test("status discards a stale readiness observation after concurrent stop")
    func statusDoesNotRepublishStateAfterStop() async throws {
        let probeEntered = AsyncSignal()
        let releaseProbe = AsyncSignal()
        let fixture = try ControllerFixture(runnerHandler: { _ in
            await probeEntered.signal()
            await releaseProbe.wait()
            return (0, Data("p119\nf11\nn127.0.0.1:1234\n".utf8), Data())
        })
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 119, sdk: sdk)])

        let staleStatus = Task { try await fixture.controller.status() }
        await probeEntered.wait()

        let stoppedPID = try await fixture.controller.withOperation(
            .simStop, requirement: .stop
        ) { $0.simulatorPid }
        #expect(stoppedPID == 119)

        await releaseProbe.signal()
        let status = try await staleStatus.value
        #expect(status.state == .notRunning)
        #expect(status.operation == nil)
        #expect(status.pid == nil)
        #expect(status.currentDevice == nil)
        #expect(try await fixture.controller.status().state == .notRunning)
    }

    /// The device readback is a new suspension point inside `status()`, and
    /// it needs the same generation re-check the readiness probe already
    /// has. Mutation testing confirmed this guard is otherwise
    /// indistinguishable from its absence: deleting the `guard
    /// statusObservationIsCurrent(generation)` immediately after the
    /// readback call left the full suite green with no direct test noticing.
    /// This is that test — a concurrent `sim_stop` starts and completes while
    /// the readback is still suspended, and the stale `status()` call must
    /// fall back to `currentStatus`, never reporting the device the readback
    /// observed against a simulator that is no longer running.
    @Test("status discards a stale device observation after concurrent stop")
    func statusDiscardsStaleDeviceObservationAfterStop() async throws {
        let readback = BlockingReadback(
            result: .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro"))
        let fixture = try ControllerFixture(readback: readback)
        defer { fixture.tearDown() }
        _ = try await fixture.startReady(pid: 5200)

        let staleStatus = Task { try await fixture.controller.status() }
        await readback.waitUntilEntered()

        let stoppedPID = try await fixture.controller.withOperation(
            .simStop, requirement: .stop
        ) { $0.simulatorPid }
        #expect(stoppedPID == 5200)

        await readback.releaseNow()
        let status = try await staleStatus.value
        #expect(status.state == .notRunning)
        #expect(status.currentDevice == nil)
        #expect(status.deviceSource == "unobserved")
    }

    @Test("status does not report ready from a wildcard-only single observation")
    func statusRejectsWildcardOnlyObservation() async throws {
        let fixture = try ControllerFixture(runnerHandler: { invocation in
            let pid = invocation.argumentValue(after: "-p") ?? "112"
            return (0, Data("p\(pid)\nf11\nn*:1234\n".utf8), Data())
        })
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 112, sdk: sdk)])

        let status = try await fixture.controller.status()

        #expect(status.state == .starting)
    }

    @Test("status promotes an external simulator only after two samples 100 ms apart")
    func statusProvesExternalReadinessAcrossSamples() async throws {
        let clock = FakeClock()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 115, sdk: sdk)])

        #expect(try await fixture.controller.status().state == .starting)
        clock.advance(by: .milliseconds(99))
        #expect(try await fixture.controller.status().state == .starting)
        clock.advance(by: .milliseconds(1))
        #expect(try await fixture.controller.status().state == .ready)
    }

    @Test("failure refresh cannot replace a stable proof with one transient listener sample")
    func failureRefreshRejectsTransientListener() async throws {
        let listener = MutableListener(port: 1234)
        let fixture = try ControllerFixture(runnerHandler: { invocation in
            let pid = invocation.argumentValue(after: "-p") ?? "113"
            return (0, Data("p\(pid)\nf11\nn127.0.0.1:\(listener.port)\n".utf8), Data())
        })
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 113, sdk: sdk)])
        _ = try await fixture.controller.withOperation(
            .screenshot, requirement: .currentReady) { $0 }

        listener.port = 2345
        do {
            _ = try await fixture.controller.withOperation(
                .screenshot, requirement: .start(requested: sdk)) { _ in 1 }
            Issue.record("invalid lifecycle policy must fail")
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
        }

        #expect(try await fixture.controller.status().state == .starting)
    }

    @Test("stop reports stopping and escalates to SIGKILL only after the monotonic grace deadline")
    func stopEscalatesAfterDeadline() async throws {
        let clock = FakeClock()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setExitOnSignal(9)
        await fixture.system.setProcesses([fixture.system.identity(pid: 95, sdk: sdk)])

        let stop = Task {
            try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
        }
        #expect(await waitUntil {
            await fixture.system.signals == [.init(pid: 95, signal: 15)]
                && clock.pendingSleepCount == 1
        })
        let stopping = try await fixture.controller.status()
        #expect(stopping.state == .stopping)
        #expect(stopping.operation == "sim_stop")

        clock.advance(by: .seconds(5))
        #expect(try await stop.value == 95)
        #expect(await fixture.system.signals == [
            .init(pid: 95, signal: 15), .init(pid: 95, signal: 9),
        ])
    }

    @Test("stop never sends TERM to a PID whose identity changed during session shutdown")
    func stopRevalidatesBeforeTERM() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let replacement = SimulatorProcessIdentity(
            pid: 110,
            executablePath: "/tmp/replacement/bin/ConnectIQ.app/Contents/MacOS/simulator",
            sdk: sdk)
        let replacementHook = SimulatorReplacementHook(replacement: replacement)
        let fixture = try ControllerFixture(stopperHook: {
            await replacementHook.replace()
        })
        defer { fixture.tearDown() }
        await replacementHook.install(system: fixture.system)
        await fixture.system.setProcesses([fixture.system.identity(pid: 110, sdk: sdk)])

        do {
            _ = try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
            Issue.record("changed PID identity must abort stop")
        } catch let error as ToolError {
            #expect(error.code == "simulator_process_changed")
        }
        #expect(await fixture.system.signals.isEmpty)
    }

    @Test("stop never sends KILL after the expected PID is replaced during TERM grace")
    func stopRevalidatesBeforeKILL() async throws {
        let clock = FakeClock()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let original = fixture.system.identity(pid: 111, sdk: sdk)
        let replacement = SimulatorProcessIdentity(
            pid: 111,
            executablePath: "/tmp/replacement/bin/ConnectIQ.app/Contents/MacOS/simulator",
            sdk: sdk)
        await fixture.system.setExitOnSignal(9)
        await fixture.system.setProcesses([original])

        let stop = Task {
            try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
        }
        #expect(await waitUntil {
            await fixture.system.signals == [.init(pid: 111, signal: 15)]
                && clock.pendingSleepCount == 1
        })
        await fixture.system.setProcesses([replacement])
        clock.advance(by: .seconds(5))

        do {
            _ = try await stop.value
            Issue.record("replacement during TERM grace must abort before KILL")
        } catch let error as ToolError {
            #expect(error.code == "simulator_process_changed")
        }
        #expect(await fixture.system.signals == [.init(pid: 111, signal: 15)])
    }

    @Test("a process surviving SIGKILL returns stable timeout and restores ready")
    func postKILLTimeoutRestoresState() async throws {
        let clock = FakeClock()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 114, sdk: sdk)])
        _ = try await fixture.controller.withOperation(
            .simStart, requirement: .start(requested: sdk)) { $0 }
        await fixture.system.setExitOnSignal(-1)

        let stop = Task {
            try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
        }
        #expect(await waitUntil {
            await fixture.system.signals == [.init(pid: 114, signal: 15)]
                && clock.pendingSleepCount == 1
        })
        clock.advance(by: .seconds(5))
        #expect(await waitUntil {
            await fixture.system.signals == [
                .init(pid: 114, signal: 15), .init(pid: 114, signal: 9),
            ] && clock.pendingSleepCount == 1
        })
        clock.advance(by: .seconds(5))

        do {
            _ = try await stop.value
            Issue.record("a process surviving SIGKILL must time out")
        } catch let error as ToolError {
            #expect(error.code == "simulator_stop_timeout")
            #expect(!error.fix.isEmpty)
        }
        let status = try await fixture.controller.status()
        #expect(status.state == .ready)
        #expect(status.operation == nil)
        #expect(status.pid == 114)
    }

    @Test("cancelling while session shutdown is suspended sends no TERM")
    func stopCancellationDuringSessionShutdownSendsNoTERM() async throws {
        let stopperEntered = AsyncSignal()
        let releaseStopper = AsyncSignal()
        let fixture = try ControllerFixture(stopperHook: {
            await stopperEntered.signal()
            await releaseStopper.wait()
        })
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 116, sdk: sdk)])

        let stop = Task {
            try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
        }
        await stopperEntered.wait()
        stop.cancel()
        await releaseStopper.signal()

        do {
            _ = try await stop.value
            Issue.record("cancelled stop must not continue after session shutdown")
        } catch is CancellationError {}
        #expect(await fixture.system.signals.isEmpty)
    }

    @Test("cancelling during TERM grace sends no KILL")
    func stopCancellationDuringTERMGraceSendsNoKILL() async throws {
        let clock = FakeClock()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let lookupPause = LookupPause(targetCall: 5)
        await fixture.system.setLookupHook { call in
            await lookupPause.handle(call: call)
        }
        await fixture.system.setExitOnSignal(9)
        await fixture.system.setProcesses([fixture.system.identity(pid: 117, sdk: sdk)])

        let stop = Task {
            try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
        }
        #expect(await waitUntil {
            await fixture.system.signals == [.init(pid: 117, signal: 15)]
                && clock.pendingSleepCount == 1
        })
        // Expire TERM grace. Lookup call 5 is the identity revalidation
        // immediately before KILL; suspend there so cancellation races the
        // awaited lookup rather than merely cancelling the clock sleep.
        clock.advance(by: .seconds(5))
        await lookupPause.waitUntilPaused()
        stop.cancel()
        await lookupPause.release()

        do {
            _ = try await stop.value
            Issue.record("TERM-grace cancellation must propagate")
        } catch is CancellationError {}
        #expect(await fixture.system.signals == [.init(pid: 117, signal: 15)])
    }

    @Test("cancelling during post-KILL wait propagates and refreshes the live simulator")
    func stopCancellationDuringPostKILLWaitRefreshesState() async throws {
        let clock = FakeClock()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([fixture.system.identity(pid: 118, sdk: sdk)])
        _ = try await fixture.controller.withOperation(
            .simStart, requirement: .start(requested: sdk)) { $0 }
        await fixture.system.setExitOnSignal(-1)

        let stop = Task {
            try await fixture.controller.withOperation(
                .simStop, requirement: .stop) { $0.simulatorPid }
        }
        #expect(await waitUntil {
            await fixture.system.signals == [.init(pid: 118, signal: 15)]
                && clock.pendingSleepCount == 1
        })
        clock.advance(by: .seconds(5))
        #expect(await waitUntil {
            await fixture.system.signals == [
                .init(pid: 118, signal: 15), .init(pid: 118, signal: 9),
            ] && clock.pendingSleepCount == 1
        })
        stop.cancel()

        do {
            _ = try await stop.value
            Issue.record("post-KILL cancellation must propagate")
        } catch is CancellationError {}
        let status = try await fixture.controller.status()
        #expect(status.state == .ready)
        #expect(status.operation == nil)
        #expect(status.pid == 118)
    }

    @Test("restartForDeviceChange stops the old process and returns the new pid")
    func restartReplacesTheProcess() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        let original = try await fixture.startReady(pid: 5000)

        let result = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            let replaced = try await controller.restartForDeviceChange(
                requested: fixture.sdk, inside: .runApp)
            #expect(replaced.simulatorPid != original.simulatorPid)
            #expect(replaced.simulatorPid == 5001)
            return fixture.runAppResult(sessionId: 1)
        }
        #expect(result.sessionId == 1)
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        #expect(fixture.store.read()?.simulatorPid == 5001)
    }

    @Test("restartForDeviceChange clears the recorded current device")
    func restartClearsCurrentDevice() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)
        _ = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            try await controller.setCurrentDevice("fenix6xpro", inside: .runApp)
            let replaced = try await controller.restartForDeviceChange(
                requested: fixture.sdk, inside: .runApp)
            #expect(replaced.currentDevice == nil)
            return fixture.runAppResult(sessionId: 1)
        }
        // The device recorded for the old process must not survive into the
        // new one, in memory or on disk. This is the requested field —
        // `requestedDevice` — not an observation.
        #expect(try await controller.status().requestedDevice == nil)
        // Require the record to exist: `read()?.currentDevice == nil` is
        // vacuously true when the runtime file is absent.
        let record = try #require(fixture.store.read())
        #expect(record.simulatorPid == 5001)
        #expect(record.currentDevice == nil)
    }

    @Test("restartForDeviceChange refuses outside its own active operation")
    func restartRefusesOutsideOperation() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)
        do {
            _ = try await controller.restartForDeviceChange(
                requested: fixture.sdk, inside: .runApp)
            Issue.record("restart outside the active operation must fail")
        } catch let error as ToolError {
            #expect(error.code == "invalid_simulator_state")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        }
        #expect(await fixture.system.signals.isEmpty)
    }

    /// `run_app`'s device-verification retry relies on this and adds no clear
    /// of its own, so the behaviour needs a test of its own: mutation showed
    /// the `currentDevice = nil` in `restartForDeviceChange` was previously
    /// indistinguishable from its absence.
    @Test("a device-change restart forgets the device recorded against the old process")
    func restartClearsRecordedDevice() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)

        _ = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            try await controller.setCurrentDevice("fenix6xpro", inside: .runApp)
            _ = try await controller.restartForDeviceChange(
                requested: fixture.sdk, inside: .runApp)
            return fixture.runAppResult(sessionId: 1)
        }

        #expect(try await controller.status().requestedDevice == nil)
    }

    @Test("clearCurrentDevice refuses outside its own active operation")
    func clearCurrentDeviceRefusesOutsideOperation() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)
        _ = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            try await controller.setCurrentDevice("fenix6xpro", inside: .runApp)
            return fixture.runAppResult(sessionId: 1)
        }

        do {
            try await controller.clearCurrentDevice(inside: .runApp)
            Issue.record("clearing the device outside the active operation must fail")
        } catch let error as ToolError {
            #expect(error.code == "invalid_simulator_state")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        }

        // The refusal must protect the field, not merely report it: a guard
        // that threw after clearing would satisfy the catch above. This is
        // the requested field, not an observation.
        #expect(try await controller.status().requestedDevice == "fenix6xpro")
    }

    @Test("restartForDeviceChange stops the app session before killing the simulator")
    func restartStopsSessionFirst() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)
        _ = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            _ = try await controller.restartForDeviceChange(
                requested: fixture.sdk, inside: .runApp)
            return fixture.runAppResult(sessionId: 1)
        }
        let trace = fixture.trace.values
        let stopIndex = try #require(trace.firstIndex(of: "session.stop"))
        let termIndex = try #require(trace.firstIndex(of: "signal.SIGTERM"))
        #expect(stopIndex < termIndex)
    }

    @Test("restart never sends TERM to a PID whose identity changed during session shutdown")
    func restartRevalidatesBeforeTERM() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let replacement = SimulatorProcessIdentity(
            pid: 5000,
            executablePath: "/tmp/replacement/bin/ConnectIQ.app/Contents/MacOS/simulator",
            sdk: sdk)
        let replacementHook = SimulatorReplacementHook(replacement: replacement)
        let fixture = try ControllerFixture(stopperHook: {
            await replacementHook.replace()
        })
        defer { fixture.tearDown() }
        await replacementHook.install(system: fixture.system)
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)

        do {
            _ = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
                _ = try await controller.restartForDeviceChange(
                    requested: fixture.sdk, inside: .runApp)
                return fixture.runAppResult(sessionId: 1)
            }
            Issue.record("changed PID identity must abort the restart")
        } catch let error as ToolError {
            #expect(error.code == "simulator_process_changed")
            #expect(!error.fix.isEmpty)
        }
        #expect(await fixture.system.signals.isEmpty)
        #expect(await fixture.system.launchedApps.count == 1)
    }

    @Test("restart sends no TERM when the expected PID is already gone")
    func restartSkipsTERMWhenProcessAlreadyExited() async throws {
        // The absent-process branch of the pre-TERM gate: revalidation returns
        // *false* here rather than throwing, which is the case
        // `restartRevalidatesBeforeTERM` cannot reach. Mirrors
        // `absentStopIsIdempotent` for the restart path.
        let exitHook = SimulatorExitHook()
        let fixture = try ControllerFixture(stopperHook: { await exitHook.exitNow() })
        defer { fixture.tearDown() }
        await exitHook.install(system: fixture.system)
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)

        let result = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            let replaced = try await controller.restartForDeviceChange(
                requested: fixture.sdk, inside: .runApp)
            #expect(replaced.simulatorPid == 5001)
            return fixture.runAppResult(sessionId: 1)
        }

        #expect(result.sessionId == 1)
        #expect(await fixture.system.signals.isEmpty)
        #expect(await fixture.system.launchedApps.count == 2)
    }

    @Test("restart consumes another server's persisted monkeydo ownership first")
    func restartConsumesCrossServerMonkeydoOwnership() async throws {
        let path = MutableProcessPath("/bin/bash")
        let fixture = try ControllerFixture(monkeydoPath: path)
        defer { fixture.tearDown() }
        let controller = fixture.controller
        let identity = fixture.system.identity(pid: 5000, sdk: fixture.sdk)
        let owned = controllerOwned(pid: 9_006, sdk: fixture.sdk)
        try fixture.store.write(RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: fixture.sdk.root.path,
            sdkVersion: fixture.sdk.version.description,
            currentDevice: "fenix6xpro",
            monkeydoOwnership: persistedControllerOwnership(
                owned, ownerServerInstance: UUID())))
        _ = try await fixture.startReady(pid: 5000)
        // The seeded ownership must survive start, or the restart would have
        // nothing to consume and this test would pass vacuously.
        #expect(fixture.store.read()?.monkeydoOwnership != nil)

        _ = try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
            _ = try await controller.restartForDeviceChange(
                requested: fixture.sdk, inside: .runApp)
            return fixture.runAppResult(sessionId: 1)
        }

        #expect(fixture.monkeydoSignals.values == [.init(pid: 9_006, signal: 15)])
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        let record = try #require(fixture.store.read())
        #expect(record.simulatorPid == 5001)
        #expect(record.monkeydoOwnership == nil)
    }

    @Test("restart waitForExit revalidates the PID it polls during TERM grace")
    func restartWaitForExitRevalidatesDuringGrace() async throws {
        // Pins `waitForExit`'s own revalidation, not the pre-KILL one: the
        // replacement is seen by the grace poll, which throws before control
        // returns to the escalation branch.
        let clock = FakeClock()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        let controller = fixture.controller
        let replacement = SimulatorProcessIdentity(
            pid: 5000,
            executablePath: "/tmp/replacement/bin/ConnectIQ.app/Contents/MacOS/simulator",
            sdk: fixture.sdk)
        _ = try await fixture.startReady(pid: 5000)
        await fixture.system.setExitOnSignal(9)

        let restart = Task {
            try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
                _ = try await controller.restartForDeviceChange(
                    requested: fixture.sdk, inside: .runApp)
                return fixture.runAppResult(sessionId: 1)
            }
        }
        // The only fake-clock sleeper this fixture ever registers is the one
        // inside `waitForExit`, so this handshake proves TERM has been sent
        // and the grace wait has begun — without a scheduler-dependent spin.
        await clock.waitUntilPendingSleepCount(1)
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        await fixture.system.setProcesses([replacement])
        clock.advance(by: .seconds(5))

        do {
            _ = try await boundedValue(of: restart)
            Issue.record("replacement during TERM grace must abort before KILL")
        } catch let error as ToolError {
            #expect(error.code == "simulator_process_changed")
        }
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        #expect(await fixture.system.launchedApps.count == 1)
    }

    @Test("restart sends no KILL when the PID exits between the grace deadline and escalation")
    func restartRevalidatesBeforeKILL() async throws {
        // The pre-KILL revalidation is the only thing standing between the
        // expired grace deadline and a SIGKILL. Reaching it requires the
        // process to be present at the final grace poll and gone at the
        // revalidation immediately after — a window `waitForExit`'s own
        // revalidation cannot cover.
        let clock = FakeClock()
        let exitHook = SimulatorExitHook()
        let countdown = LookupCountdown()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        await exitHook.install(system: fixture.system)
        await fixture.system.setLookupHook { _ in await countdown.observeLookup() }
        await countdown.setAction { await exitHook.exitNow() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)
        await fixture.system.setExitOnSignal(9)

        let restart = Task {
            try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
                let replaced = try await controller.restartForDeviceChange(
                    requested: fixture.sdk, inside: .runApp)
                #expect(replaced.simulatorPid == 5001)
                return fixture.runAppResult(sessionId: 1)
            }
        }
        await clock.waitUntilPendingSleepCount(1)
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        // From here the restart makes exactly two lookups: the grace poll that
        // finds the deadline expired, then the pre-KILL revalidation. Retire
        // the process on the second one.
        await countdown.arm(afterLookups: 2)
        clock.advance(by: .seconds(5))

        #expect(try await boundedValue(of: restart).sessionId == 1)
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        #expect(await fixture.system.launchedApps.count == 2)
    }

    @Test("restart escalates to KILL and relaunches when TERM is ignored")
    func restartEscalatesToKILL() async throws {
        let clock = FakeClock()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)
        await fixture.system.setExitOnSignal(9)

        let restart = Task {
            try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
                let replaced = try await controller.restartForDeviceChange(
                    requested: fixture.sdk, inside: .runApp)
                #expect(replaced.simulatorPid == 5001)
                return fixture.runAppResult(sessionId: 1)
            }
        }
        await clock.waitUntilPendingSleepCount(1)
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        clock.advance(by: .seconds(5))
        #expect(try await boundedValue(of: restart).sessionId == 1)
        #expect(await fixture.system.signals == [
            .init(pid: 5000, signal: 15), .init(pid: 5000, signal: 9),
        ])
    }

    @Test("cancelling a restart while session shutdown is suspended sends no TERM")
    func restartCancellationDuringSessionShutdownSendsNoTERM() async throws {
        let stopperEntered = AsyncSignal()
        let releaseStopper = AsyncSignal()
        let fixture = try ControllerFixture(stopperHook: {
            await stopperEntered.signal()
            await releaseStopper.wait()
        })
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)

        let restart = Task {
            try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
                _ = try await controller.restartForDeviceChange(
                    requested: fixture.sdk, inside: .runApp)
                return fixture.runAppResult(sessionId: 1)
            }
        }
        await stopperEntered.wait()
        restart.cancel()
        await releaseStopper.signal()

        do {
            _ = try await boundedValue(of: restart)
            Issue.record("cancelled restart must not continue after session shutdown")
        } catch is CancellationError {}
        #expect(await fixture.system.signals.isEmpty)
        #expect(await fixture.system.launchedApps.count == 1)
    }

    @Test("cancelling a restart during TERM grace sends no KILL")
    func restartCancellationDuringTERMGraceSendsNoKILL() async throws {
        let clock = FakeClock()
        let paused = AsyncSignal()
        let release = AsyncSignal()
        let countdown = LookupCountdown()
        let fixture = try ControllerFixture(clock: clock)
        defer { fixture.tearDown() }
        await fixture.system.setLookupHook { _ in await countdown.observeLookup() }
        await countdown.setAction {
            await paused.signal()
            await release.wait()
        }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)
        await fixture.system.setExitOnSignal(9)

        let restart = Task {
            try await controller.withRunAppOperation(requested: fixture.sdk) { _ in
                _ = try await controller.restartForDeviceChange(
                    requested: fixture.sdk, inside: .runApp)
                return fixture.runAppResult(sessionId: 1)
            }
        }
        await clock.waitUntilPendingSleepCount(1)
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        // Suspend inside the pre-KILL revalidation so cancellation races the
        // awaited lookup rather than merely cancelling the clock sleep.
        await countdown.arm(afterLookups: 2)
        clock.advance(by: .seconds(5))
        await paused.wait()
        restart.cancel()
        await release.signal()

        do {
            _ = try await boundedValue(of: restart)
            Issue.record("TERM-grace cancellation must propagate")
        } catch is CancellationError {}
        #expect(await fixture.system.signals == [.init(pid: 5000, signal: 15)])
        #expect(await fixture.system.launchedApps.count == 1)
    }
}

private struct RuntimeEvidence: Codable {
    let sdkVersion: String
    let sdkPath: String
    let simulatorPid: Int32
    let executablePath: String
    let listeningEndpoints: [TCPEndpoint]
}

private struct SDKLayoutSandbox {
    let root: URL
    let simulatorExecutable: URL

    init(version: String) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "connectiq-sdk-mac-\(version)-test-\(UUID().uuidString)")
            .standardizedFileURL
        let bin = root.appending(path: "bin")
        simulatorExecutable = bin.appending(path: "ConnectIQ.app/Contents/MacOS/simulator")
        try FileManager.default.createDirectory(
            at: simulatorExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: simulatorExecutable)
        try Data().write(to: bin.appending(path: "monkeyc"))
        try Data().write(to: bin.appending(path: "monkeydo"))
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }
}

/// Awaits a task under a real-time bound. A restart driven by a `FakeClock`
/// parks forever if a mutation drops the signal a test is waiting on, and an
/// unbounded `task.value` turns that into a hung `swift test` run instead of a
/// red test. Cancelling resumes the fake sleeper, so the await always returns.
private func boundedValue<T: Sendable>(
    of task: Task<T, Error>,
    within duration: Duration = .seconds(10)
) async throws -> T {
    let watchdog = Task {
        try? await Task.sleep(for: duration)
        task.cancel()
    }
    defer { watchdog.cancel() }
    return try await task.value
}

/// Runs an action on the Nth `FakeSimulatorSystem.lookup` after arming. The
/// hook fires before `lookup` reads its process table, so an action that
/// retires the process makes that same lookup observe the exit — the only way
/// to land a state change strictly between two consecutive revalidations.
private actor LookupCountdown {
    private var remaining: Int?
    private var action: @Sendable () async -> Void = {}

    func setAction(_ value: @escaping @Sendable () async -> Void) { action = value }

    func arm(afterLookups count: Int) { remaining = count }

    func observeLookup() async {
        guard let left = remaining else { return }
        let next = left - 1
        remaining = next > 0 ? next : nil
        if next <= 0 { await action() }
    }
}

/// Empties the fake process table, so identity revalidation returns `false`
/// (the process exited) rather than throwing (a different process took the
/// PID). `SimulatorReplacementHook` covers the throwing case.
private actor SimulatorExitHook {
    private var system: FakeSimulatorSystem?

    func install(system: FakeSimulatorSystem) { self.system = system }
    func exitNow() async { await system?.setProcesses([]) }
}

private actor SimulatorReplacementHook {
    private let replacement: SimulatorProcessIdentity
    private var system: FakeSimulatorSystem?

    init(replacement: SimulatorProcessIdentity) { self.replacement = replacement }
    func install(system: FakeSimulatorSystem) { self.system = system }
    func replace() async {
        await system?.setProcesses([replacement])
    }
}

private actor LookupPause {
    private let targetCall: Int
    private let paused = AsyncSignal()
    private let released = AsyncSignal()

    init(targetCall: Int) { self.targetCall = targetCall }

    func handle(call: Int) async {
        guard call == targetCall else { return }
        await paused.signal()
        await released.wait()
    }

    func waitUntilPaused() async { await paused.wait() }
    func release() async { await released.signal() }
}

/// A `DeviceObserving` double that suspends inside `observe` until released,
/// so a test can pin `status()` mid-readback and race a concurrent operation
/// against it.
private actor BlockingReadback: DeviceObserving {
    private let entered = AsyncSignal()
    private let release = AsyncSignal()
    private let result: DeviceObservation

    init(result: DeviceObservation) { self.result = result }

    func observe(simulatorPid: pid_t) async -> DeviceObservation {
        await entered.signal()
        await release.wait()
        return result
    }

    func waitUntilEntered() async { await entered.wait() }
    func releaseNow() async { await release.signal() }
}

private struct ControllerOwnedProcess: RunningProcess, Sendable {
    let pid: Int32
    func wait() async throws -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdout: Data(), stderr: Data())
    }
    func terminate(grace: Duration) async {}
}

private func controllerOwned(pid: Int32, sdk: SdkInfo) -> OwnedMonkeydoProcess {
    let prg = URL(fileURLWithPath: "/tmp/app.prg")
    let arguments = ["/bin/bash", sdk.monkeydo.path, prg.path, "fenix6xpro"]
    return OwnedMonkeydoProcess(
        process: ControllerOwnedProcess(pid: pid),
        launcher: ProcessIdentitySnapshot(
            pid: pid, parentPid: 100, processGroupId: pid,
            start: ProcessStartIdentity(seconds: 1, microseconds: UInt64(pid)),
            executablePath: "/bin/bash", arguments: arguments),
        command: MonkeydoCommand(
            sdk: sdk, prgPath: prg, device: "fenix6xpro", testFilter: nil))
}

private func persistedControllerOwnership(
    _ owned: OwnedMonkeydoProcess,
    ownerServerInstance: UUID
) -> PersistedMonkeydoOwnership {
    PersistedMonkeydoOwnership(
        launcher: owned.launcher.stableIdentity,
        launcherParentPid: owned.launcher.parentPid,
        sdkPath: owned.command.sdk.root.path,
        prgPath: owned.command.prgPath.path,
        device: owned.command.device,
        testFilter: owned.command.testFilter,
        ownerServerInstance: ownerServerInstance)
}

private final class RuntimeOwnershipMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var store: RuntimeStore?
    private var replacement: RuntimeRecord?

    func install(store: RuntimeStore, replacement: RuntimeRecord) {
        lock.withLock {
            self.store = store
            self.replacement = replacement
        }
    }

    func apply() {
        let values = lock.withLock { (store, replacement) }
        guard let store = values.0, let replacement = values.1 else { return }
        try? store.write(replacement)
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class MutableListener: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt16
    init(port: UInt16) { storage = port }
    var port: UInt16 {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class ProcessPathSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]
    private var last: String?

    init(_ values: [String?]) {
        self.values = values
        self.last = values.last ?? nil
    }

    func next() -> String? {
        lock.withLock {
            guard !values.isEmpty else { return last }
            let value = values.removeFirst()
            last = value
            return value
        }
    }
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}

private actor AsyncSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
