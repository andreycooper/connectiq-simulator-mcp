import Foundation
import Testing

@testable import SimulatorMCPCore

// ScriptedReadback and every Coordinator* double come from Task 2A's
// Tests/SimulatorMCPCoreTests/Support/. Do not redefine them here.
//
// Every script below assumes CoordinatorFixture.appRequest requests
// "fenix6xpro"; confirmed in Support/CoordinatorFixtures.swift.

@Suite("run_app device verification")
struct DeviceVerificationTests {
    @Test("a matching readback returns deviceVerified true and never restarts")
    func matchingReadbackVerifies() async throws {
        let fixture = CoordinatorFixture()
        let runner = CoordinatorRunner(processes: [CoordinatorProcess(pid: 7100, output: nil)])
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 7100),
            deviceReadback: ScriptedReadback([
                .idle,
                .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro"),
            ]))

        let result = try await coordinator.runApp(fixture.appRequest)

        #expect(result.device == "fenix6xpro")
        #expect(result.deviceVerified)
        #expect(result.deviceVerificationUnavailable == nil)
        #expect(result.observedDeviceDisplayName == "fēnix 6X Pro")
        #expect(!result.simulatorRestarted)
        #expect(result.invalidatedSessionId == nil)
        #expect(await controller.restarts == 0)
    }

    @Test("a different loaded device restarts the simulator before building or launching")
    func differentDeviceRestarts() async throws {
        let fixture = CoordinatorFixture()
        let trace = CoordinatorTrace()
        // Two spare launches on purpose. Reaching the same end state through
        // the post-launch retry instead would consume both, so
        // `invocations.count == 1` is what pins the restart to *before* the
        // launch; without the spares the same defect only crashes the double.
        let runner = CoordinatorRunner(
            processes: [
                CoordinatorProcess(pid: 7101, output: nil),
                CoordinatorProcess(pid: 7112, output: nil),
            ], trace: trace)
        let controller = CoordinatorController(context: fixture.operationContext, trace: trace)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(
                outcomes: [
                    fixture.successfulBuild(mode: .debugApp),
                    fixture.successfulBuild(mode: .debugApp),
                ], trace: trace),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pids: [7101, 7112], trace: trace),
            deviceReadback: ScriptedReadback([
                .device(deviceId: "fenix7s", displayName: "fēnix 7S"),
                .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro"),
            ]))

        let result = try await coordinator.runApp(fixture.appRequest)

        #expect(result.simulatorRestarted)
        #expect(result.deviceVerified)
        #expect(await controller.restarts == 1)
        #expect(runner.invocations.count == 1)
        // Exact, and ordered: the restart precedes the build, not merely the
        // launch. A correction that arrives after a build has already run for
        // the wrong loaded profile has wasted the build it was meant to
        // protect, and `invocations.count` alone cannot see that.
        #expect(trace.values == [
            "run_app.lease.begin", "restart_for_device_change", "build.debugApp",
            "terminate_shared", "process.start", "connection.probe", "active.pid+device",
            "run_app.lease.end",
        ])
    }

    @Test("a post-launch contradiction restarts once and retries before failing")
    func contradictionRetriesOnce() async throws {
        let fixture = CoordinatorFixture()
        let runner = CoordinatorRunner(processes: [
            CoordinatorProcess(pid: 7106, output: nil), CoordinatorProcess(pid: 7107, output: nil),
        ])
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [
                fixture.successfulBuild(mode: .debugApp), fixture.successfulBuild(mode: .debugApp),
            ]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pids: [7106, 7107]),
            deviceReadback: ScriptedReadback([
                .idle,  // pre-launch
                .device(deviceId: "fenix7s", displayName: "fēnix 7S"),  // post-launch: wrong
                .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro"),  // retry: right
            ]))

        let result = try await coordinator.runApp(fixture.appRequest)

        #expect(result.deviceVerified)
        #expect(result.simulatorRestarted)
        #expect(await controller.restarts == 1)
        // The retry's restart destroyed only the session this same call
        // created and killed, which the caller never received. Naming it
        // would report an id that was never on the wire; the field describes
        // a session the caller was holding, and there was none.
        #expect(result.invalidatedSessionId == nil)
    }

    @Test("a contradiction that survives the retry fails with device_mismatch")
    func contradictionFails() async throws {
        let fixture = CoordinatorFixture()
        let firstLaunch = CoordinatorProcess(pid: 7102, output: nil)
        let secondLaunch = CoordinatorProcess(pid: 7103, output: nil)
        let runner = CoordinatorRunner(processes: [firstLaunch, secondLaunch])
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [
                fixture.successfulBuild(mode: .debugApp), fixture.successfulBuild(mode: .debugApp),
            ]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pids: [7102, 7103]),
            deviceReadback: ScriptedReadback([
                .idle,
                .device(deviceId: "fenix7s", displayName: "fēnix 7S"),
                .device(deviceId: "fenix7s", displayName: "fēnix 7S"),
            ]))

        let error = await #expect(throws: ToolError.self) {
            _ = try await coordinator.runApp(fixture.appRequest)
        }
        #expect(error?.code == "device_mismatch")
        #expect(error?.fix.isEmpty == false)
        #expect(error?.details?["observedDisplayName"] == .string("fēnix 7S"))
        #expect(error?.details?["titleNeverLeftIdle"] == .bool(false))
        // One restart for the retry, and no second one after it also failed.
        #expect(await controller.restarts == 1)
        // Neither contradiction may leave the disproved device claim standing
        // in the runtime record. The retry's restart would clear the first;
        // only the contradicted path itself clears the second, because
        // nothing runs after the device_mismatch throw.
        #expect(await controller.events.filter { $0 == "active:nil:nil" }.count == 2)
        // Neither contradiction may leave an app session behind. The first
        // launch would be terminated by the retry's own replacement anyway;
        // the second is only terminated by the contradicted path itself,
        // because device_mismatch is thrown with no cleanup after it.
        #expect(await firstLaunch.terminationCount >= 1)
        #expect(await secondLaunch.terminationCount == 1)
    }

    @Test("an idle title is polled to the budget, then fails rather than verifying")
    func idleTitleIsPolledThenContradicts() async throws {
        let fixture = CoordinatorFixture()
        let runner = CoordinatorRunner(processes: [
            CoordinatorProcess(pid: 7110, output: nil), CoordinatorProcess(pid: 7111, output: nil),
        ])
        let controller = CoordinatorController(context: fixture.operationContext)
        let readback = AlwaysIdleReadback()
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [
                fixture.successfulBuild(mode: .debugApp), fixture.successfulBuild(mode: .debugApp),
            ]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pids: [7110, 7111]),
            deviceReadback: readback,
            // Auto-advancing: the 50 ms poll interval and the 5 s budget are
            // walked in fake time, so this asserts the loop, not a wait.
            clock: FakeClock(autoAdvance: true))

        let error = await #expect(throws: ToolError.self) {
            _ = try await coordinator.runApp(fixture.appRequest)
        }

        #expect(error?.code == "device_mismatch")
        // Idle is "not yet", never an answer: a single sample would have
        // decided after one call, and never verifies.
        #expect(await readback.polls > 2)
        #expect(await controller.restarts == 1)
        // The idle title is not a display name and no installed device has
        // it, so it must not be laundered into observedDisplayName.
        #expect(error?.details?["observedDisplayName"] == JSONValue.null)
        #expect(error?.details?["titleNeverLeftIdle"] == .bool(true))
        #expect(error?.message.contains(DeviceReadback.idleTitle) == false)
    }

    @Test("a device-change restart reports the session id it invalidated")
    func restartReportsInvalidatedSession() async throws {
        let fixture = CoordinatorFixture()
        let runner = CoordinatorRunner(processes: [
            CoordinatorProcess(pid: 7108, output: nil), CoordinatorProcess(pid: 7109, output: nil),
        ])
        let sessions = AppSessionManager(processRunner: runner)
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [
                fixture.successfulBuild(mode: .debugApp), fixture.successfulBuild(mode: .debugApp),
            ]),
            sessionManager: sessions,
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pids: [7108, 7109]),
            deviceReadback: ScriptedReadback([
                .idle,
                .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro"),
                .device(deviceId: "fenix7s", displayName: "fēnix 7S"),
                .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro"),
            ]))

        // First run commits a session; the second run switches device and must
        // name the session it destroyed. Without a committed session first,
        // invalidatedSessionId is nil either way and the assertion proves
        // nothing — which is why this test runs run_app twice.
        let first = try await coordinator.runApp(fixture.appRequest)
        let second = try await coordinator.runApp(fixture.appRequest)

        #expect(second.simulatorRestarted)
        #expect(second.invalidatedSessionId == first.sessionId)
    }

    /// Against a **real** `SimulatorController`, because the claim is about
    /// state that outlives the operation. `context.currentDevice` is not
    /// cosmetic: `ScreenshotService` reads it to choose a crop rectangle and
    /// `ButtonInput` reads it to choose a key profile and gate the capability
    /// allowlist. Nothing else expires it here — the simulator process is
    /// unchanged after the restart, so `requireReady`, `status()` and
    /// `refreshAfterFailure` all keep the recorded device.
    @Test("a terminal device_mismatch clears the device claim it disproved")
    func mismatchClearsRecordedDevice() async throws {
        let doubles = CoordinatorFixture()
        let fixture = try ControllerFixture()
        defer { fixture.tearDown() }
        let controller = fixture.controller
        _ = try await fixture.startReady(pid: 5000)

        let runner = CoordinatorRunner(processes: [
            CoordinatorProcess(pid: 7120, output: nil), CoordinatorProcess(pid: 7121, output: nil),
        ])
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [
                doubles.successfulBuild(mode: .debugApp), doubles.successfulBuild(mode: .debugApp),
            ]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: doubles.connectedProbe(pids: [7120, 7121]),
            deviceReadback: ScriptedReadback([
                .idle,
                .device(deviceId: "fenix7s", displayName: "fēnix 7S"),
                .device(deviceId: "fenix7s", displayName: "fēnix 7S"),
            ]))
        // The controller fixture's own SDK, so requireReady's SDK match holds.
        let request = RunAppRequest(
            project: doubles.project, buildContext: doubles.buildContext,
            sdk: fixture.sdk, device: "fenix6xpro", rebuild: true)

        let error = await #expect(throws: ToolError.self) {
            _ = try await coordinator.runApp(request)
        }

        #expect(error?.code == "device_mismatch")
        // The controller fixture's own readback always reports unavailable,
        // so this checks the requested field's clearing, not an observation.
        #expect(try await controller.status().requestedDevice == nil)
    }

    @Test("an unavailable readback returns ok with deviceVerified false and a reason")
    func unavailableReadbackDisclosed() async throws {
        let fixture = CoordinatorFixture()
        let runner = CoordinatorRunner(processes: [CoordinatorProcess(pid: 7104, output: nil)])
        let coordinator = RunCoordinator(
            controller: CoordinatorController(context: fixture.operationContext),
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 7104),
            deviceReadback: ScriptedReadback([
                .unavailable(reason: .screenRecordingDenied),
                .unavailable(reason: .screenRecordingDenied),
            ]))

        let result = try await coordinator.runApp(fixture.appRequest)

        #expect(!result.deviceVerified)
        #expect(result.deviceVerificationUnavailable == "screenRecordingDenied")
        #expect(result.observedDeviceDisplayName == nil)
        #expect(!result.simulatorRestarted)
    }

    @Test("an unavailable readback never triggers a restart")
    func unavailableNeverRestarts() async throws {
        let fixture = CoordinatorFixture()
        let runner = CoordinatorRunner(processes: [CoordinatorProcess(pid: 7105, output: nil)])
        let controller = CoordinatorController(context: fixture.operationContext)
        let coordinator = RunCoordinator(
            controller: controller,
            compiler: CoordinatorCompiler(outcomes: [fixture.successfulBuild(mode: .debugApp)]),
            sessionManager: AppSessionManager(processRunner: runner),
            processRunner: runner,
            connectionProbe: fixture.connectedProbe(pid: 7105),
            deviceReadback: ScriptedReadback([
                .unavailable(reason: .titleUnreadable),
                .unavailable(reason: .titleUnreadable),
            ]))

        _ = try await coordinator.runApp(fixture.appRequest)
        #expect(await controller.restarts == 0)
    }

    /// Hermeticity, verified rather than assumed. `RunCoordinator`,
    /// `SimulatorController`, and `ScreenshotService` all default
    /// `deviceReadback` to a live `DeviceReadback`, which calls
    /// `CGPreflightScreenCaptureAccess` and `CGWindowListCopyWindowInfo` —
    /// the window server, and a TCC-gated grant. `SimulatorController`'s own
    /// `status()` (Task 5) is the second caller of that default, so it
    /// carries the identical hazard: a unit test that constructs a
    /// controller without injecting a double is hermetic only by accident,
    /// for as long as none of its assertions call `status()`.
    /// `ScreenshotService.capture` (device-and-capture-trust work) is the
    /// third: every capture now calls the readback to attach the observed
    /// device's identity to the result. AGENTS.md requires `swift test` to
    /// need neither, so every unit-test construction of any of the three
    /// types must inject a double. A source audit is the only way to see the
    /// ones that forgot: a missing argument is silently absorbed by the
    /// default.
    @Test("no unit test constructs a RunCoordinator, SimulatorController, or ScreenshotService with the live device readback")
    func unitTestsNeverReachTheWindowServer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // A dedicated FileManager, never the shared one. Suites run in
        // parallel, and a deep enumeration on `FileManager.default` made
        // `DeviceCatalogTests`' concurrent `copyItem` fail with
        // NSFileWriteNoPermissionError on every full-suite run — reproduced
        // four times, and green the moment this test was disabled. Apple
        // documents the shared instance as thread-safe only for simple
        // operations; directory enumeration is not one of them.
        let fileManager = FileManager()
        let files = try #require(
            fileManager.enumerator(at: root, includingPropertiesForKeys: nil))
        var audited = 0
        var exempted = 0
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            // ScreenshotService gained the identical hazard in the
            // device-and-capture-trust work: a `deviceReadback` parameter
            // that live-defaults to `DeviceReadback()`, calling
            // `CGPreflightScreenCaptureAccess` from every `capture()`.
            for callee in ["RunCoordinator(", "SimulatorController(", "ScreenshotService("] {
                for call in Self.callArguments(of: callee, in: source) {
                    audited += 1
                    // The exemption is per call site, not per file: a hermetic
                    // test added to a file holding a live gate must still be
                    // audited. It is claimed by writing the marker inside the
                    // call itself.
                    if call.contains(Self.liveReadbackMarker) {
                        exempted += 1
                        continue
                    }
                    // Both holes matter: a missing argument takes the live
                    // default, and an explicitly passed `DeviceReadback()`
                    // satisfies the label while still calling
                    // `CGPreflightScreenCaptureAccess`.
                    if !call.contains("deviceReadback:") || call.contains("DeviceReadback(") {
                        offenders.append("\(url.lastPathComponent): \(call.prefix(60))")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        // A silent zero would make the audit vacuous, and a blanket exemption
        // would make it toothless.
        #expect(audited >= 52)
        #expect(exempted == 6)
    }

    /// Written inside a coordinator construction that deliberately uses the
    /// live readback — only legitimate in an opt-in gate that runs against a
    /// real simulator and returns before constructing anything otherwise.
    /// (Spelling the callee out here would make this comment an audit hit:
    /// the scanner reads source text, not syntax.)
    private static let liveReadbackMarker = "live-readback:"

    /// Always idle, and counts every poll. The window title is written by the
    /// simulator's UI thread with nothing ordering it after the TCP accept the
    /// launch proof reads, so verification must keep asking rather than sample
    /// once.
    private actor AlwaysIdleReadback: DeviceObserving {
        private(set) var polls = 0

        func observe(simulatorPid: pid_t) async -> DeviceObservation {
            polls += 1
            return .idle
        }
    }

    /// The balanced-paren argument text of every `callee` call in `source`.
    private static func callArguments(of callee: String, in source: String) -> [String] {
        var found: [String] = []
        var search = source.startIndex..<source.endIndex
        while let start = source.range(of: callee, range: search) {
            // Skip the scanner's own string literal naming the callee.
            guard start.lowerBound == source.startIndex
                || source[source.index(before: start.lowerBound)] != "\""
            else {
                search = start.upperBound..<source.endIndex
                continue
            }
            var depth = 1
            var index = start.upperBound
            while index < source.endIndex, depth > 0 {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" { depth -= 1 }
                index = source.index(after: index)
            }
            found.append(String(source[start.upperBound..<index]))
            search = index..<source.endIndex
        }
        return found
    }
}
