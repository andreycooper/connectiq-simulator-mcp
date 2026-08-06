import Foundation
import Testing

@testable import SimulatorMCPCore

enum ControllerTestError: Error { case expected }

struct SignalCall: Equatable, Sendable {
    let pid: Int32
    let signal: Int32
}

actor FakeSimulatorSystem {
    private var processes: [SimulatorProcessIdentity] = []
    private var launchResult: SimulatorProcessIdentity?
    private var currentFrontmost: Int32? = 7
    private(set) var launchedApps: [URL] = []
    private(set) var activatedLaunchedApps: [URL] = []
    private(set) var frontmostObservations: [Int32?] = []
    private(set) var signals: [SignalCall] = []
    private var exitOnSignal: Int32 = 15
    private var lookupCount = 0
    private var lookupHook: @Sendable (Int) async -> Void = { _ in }
    private let trace: SignalRecorder<String>?

    init(trace: SignalRecorder<String>? = nil) {
        self.trace = trace
    }

    nonisolated func identity(pid: Int32, sdk: SdkInfo) -> SimulatorProcessIdentity {
        SimulatorProcessIdentity(
            pid: pid,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
    }

    func setProcesses(_ value: [SimulatorProcessIdentity]) {
        processes = value
    }
    func setExitOnSignal(_ value: Int32) { exitOnSignal = value }
    func setLookupHook(_ hook: @escaping @Sendable (Int) async -> Void) {
        lookupHook = hook
    }

    func setLaunchIdentity(sdk: SdkInfo, pid: Int32) {
        launchResult = identity(pid: pid, sdk: sdk)
    }

    func setFrontmost(_ value: Int32?) { currentFrontmost = value }

    func discover() -> [SimulatorProcessIdentity] { processes }

    func lookup(_ pid: Int32) async -> SimulatorProcessIdentity? {
        lookupCount += 1
        let call = lookupCount
        await lookupHook(call)
        return processes.first { $0.pid == pid }
    }

    func launch(_ app: URL) throws -> Int32 {
        launchedApps.append(app)
        guard let launchResult else { throw ControllerTestError.expected }
        processes = [launchResult]
        return launchResult.pid
    }

    func sendSignal(pid: Int32, signal: Int32) {
        signals.append(SignalCall(pid: pid, signal: signal))
        switch signal {
        case SIGTERM: trace?.append("signal.SIGTERM")
        case SIGKILL: trace?.append("signal.SIGKILL")
        default: trace?.append("signal.\(signal)")
        }
        if signal == exitOnSignal { processes.removeAll { $0.pid == pid } }
    }
}

actor FakeSessionStopper: SimulatorSessionStopping {
    private(set) var calls = 0
    private let hook: @Sendable () async -> Void
    private let trace: SignalRecorder<String>?

    init(
        hook: @escaping @Sendable () async -> Void = {},
        trace: SignalRecorder<String>? = nil
    ) {
        self.hook = hook
        self.trace = trace
    }

    func stopForSimulatorShutdown() async throws {
        calls += 1
        trace?.append("session.stop")
        await hook()
    }
}

struct ControllerFixture {
    let directory: URL
    let store: RuntimeStore
    let externalLease: SimLease
    let system: FakeSimulatorSystem
    let stopper: FakeSessionStopper
    let queue: AsyncFIFO
    let monkeydoSignals: SignalRecorder<SignalCall>
    let controller: SimulatorController

    /// The SDK every fixture test launches against.
    let sdk: SdkInfo

    /// Ordered record of fixture-visible events, for ordering assertions.
    let trace: SignalRecorder<String>

    /// Passed through to `SimulatorController`'s `deviceReadback`. Defaults
    /// to a readback that always reports unavailable, so `status()`'s
    /// observed `currentDevice` stays `nil` for every fixture test that does
    /// not opt into a `ScriptedReadback` script.
    let readback: any DeviceObserving

    init(
        runnerHandler: FakeProcessRunner.Handler? = nil,
        clock: FakeClock? = nil,
        monkeydoPath: MutableProcessPath? = nil,
        monkeydoPathLookup: (@Sendable (Int32) -> String?)? = nil,
        monkeydoDidSignal: @escaping @Sendable (Int32) -> Void = { _ in },
        stopperHook: @escaping @Sendable () async -> Void = {},
        activityStore: ActivityStore = .disabled,
        readback: any DeviceObserving = ScriptedReadback([])
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "simulator-controller-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = RuntimeStore(runtimeFile: directory.appending(path: "runtime.json"))
        externalLease = SimLease(lockFile: directory.appending(path: "sim.lock"))
        sdk = sampleSDK(version: "9.1.0")
        self.readback = readback
        let localTrace = SignalRecorder<String>()
        trace = localTrace
        let localSystem = FakeSimulatorSystem(trace: localTrace)
        let localStopper = FakeSessionStopper(hook: stopperHook, trace: localTrace)
        let localQueue = AsyncFIFO()
        let localMonkeydoSignals = SignalRecorder<SignalCall>()
        system = localSystem
        stopper = localStopper
        queue = localQueue
        monkeydoSignals = localMonkeydoSignals
        let runner = FakeProcessRunner(handler: runnerHandler ?? { invocation in
            let pid = invocation.argumentValue(after: "-p") ?? "1"
            return (0, Data("p\(pid)\nf11\nn127.0.0.1:1234\n".utf8), Data())
        })
        let pathLookup: @Sendable (Int32) -> String? =
            monkeydoPathLookup ?? { _ in monkeydoPath?.value }
        let simulatorSystem = SimulatorProcessSystem(
            discover: { await localSystem.discover() },
            lookup: { pid in await localSystem.lookup(pid) },
            launch: { app in try await localSystem.launch(app) },
            signal: { pid, signal in await localSystem.sendSignal(pid: pid, signal: signal) })
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            identityLookup: { pid in await localSystem.lookup(pid) })
        let monkeydoLifecycle = ControllerMonkeydoLifecycle(
            pathLookup: pathLookup,
            signals: localMonkeydoSignals,
            didSignal: { pid in
                monkeydoPath?.clearIfMatchingSignal(pid: pid)
                monkeydoDidSignal(pid)
            })
        if let clock {
            controller = SimulatorController(
                queue: localQueue,
                lease: externalLease,
                runtimeStore: store,
                processRunner: runner,
                sessionStopper: localStopper,
                system: simulatorSystem,
                readinessProbe: probe,
                clock: clock,
                monkeydoLifecycle: monkeydoLifecycle,
                activityStore: activityStore,
                deviceReadback: readback)
        } else {
            controller = SimulatorController(
                queue: localQueue,
                lease: externalLease,
                runtimeStore: store,
                processRunner: runner,
                sessionStopper: localStopper,
                system: simulatorSystem,
                readinessProbe: probe,
                monkeydoLifecycle: monkeydoLifecycle,
                activityStore: activityStore,
                deviceReadback: readback)
        }
    }

    func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// Brings the controller to a ready state on `pid`, returning its
    /// context, AND arms the next relaunch so a device-change restart can
    /// succeed: `FakeSimulatorSystem.launch` throws `ControllerTestError.expected`
    /// unless `setLaunchIdentity(sdk:pid:)` was called.
    func startReady(pid: Int32) async throws -> OperationContext {
        await system.setProcesses([])
        await system.setLaunchIdentity(sdk: sdk, pid: pid)
        let context = try await controller.withOperation(
            .simStart, requirement: .start(requested: sdk)
        ) { $0 }
        // Arm the pid a device-change restart would relaunch with.
        await system.setLaunchIdentity(sdk: sdk, pid: pid + 1)
        return context
    }

    /// A minimal `RunAppResult` for closures that must return one.
    func runAppResult(sessionId: Int) -> RunAppResult {
        RunAppResult(
            sessionId: sessionId,
            device: "fenix6xpro",
            prgPath: "/project/bin/app.prg",
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            rebuilt: true,
            rebuildReason: .cacheMiss,
            deviceVerified: false,
            deviceVerificationUnavailable: ReadbackUnavailable.noSimulatorWindow.rawValue,
            observedDeviceDisplayName: nil,
            simulatorRestarted: false,
            invalidatedSessionId: nil)
    }
}

struct ControllerMonkeydoLifecycle: MonkeydoProcessLifecycling, Sendable {
    let pathLookup: @Sendable (Int32) -> String?
    let signals: SignalRecorder<SignalCall>
    let didSignal: @Sendable (Int32) -> Void

    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        throw ToolError(
            code: "app_launch_failed", message: "not used by controller tests",
            fix: "Use the coordinator lifecycle fake for launch tests.")
    }

    func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await launchApp(command, onStdout: onStdout, onStderr: onStderr)
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {
        await owned.process.terminate(grace: grace)
        _ = try await owned.output()
    }

    func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership, grace: Duration
    ) async throws {
        let observed = pathLookup(ownership.launcher.pid)
        let revalidated = pathLookup(ownership.launcher.pid)
        guard observed == ownership.launcher.executablePath,
            revalidated == ownership.launcher.executablePath
        else {
            throw ToolError(
                code: "monkeydo_cleanup_failed",
                message: "The persisted launcher identity changed before cleanup.",
                fix: "Leave the record untouched and inspect the reported PID.")
        }
        signals.append(.init(pid: ownership.launcher.pid, signal: 15))
        didSignal(ownership.launcher.pid)
    }
}

/// Ordered, thread-safe append log, generic so both signal deliveries
/// (`SignalCall`) and string trace events share one implementation.
final class SignalRecorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] { lock.withLock { storage } }
    func append(_ value: Element) { lock.withLock { storage.append(value) } }
}

final class MutableProcessPath: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    init(_ path: String?) { storage = path }

    var value: String? { lock.withLock { storage } }

    func clearIfMatchingSignal(pid: Int32) {
        guard pid >= 9_000 else { return }
        lock.withLock { storage = nil }
    }
}
