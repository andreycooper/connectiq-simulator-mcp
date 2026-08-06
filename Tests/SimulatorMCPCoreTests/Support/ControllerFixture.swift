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
        if signal == exitOnSignal { processes.removeAll { $0.pid == pid } }
    }
}

actor FakeSessionStopper: SimulatorSessionStopping {
    private(set) var calls = 0
    private let hook: @Sendable () async -> Void

    init(hook: @escaping @Sendable () async -> Void = {}) { self.hook = hook }

    func stopForSimulatorShutdown() async throws {
        calls += 1
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
    let monkeydoSignals: SignalRecorder
    let controller: SimulatorController

    init(
        runnerHandler: FakeProcessRunner.Handler? = nil,
        clock: FakeClock? = nil,
        monkeydoPath: MutableProcessPath? = nil,
        monkeydoPathLookup: (@Sendable (Int32) -> String?)? = nil,
        monkeydoDidSignal: @escaping @Sendable (Int32) -> Void = { _ in },
        stopperHook: @escaping @Sendable () async -> Void = {},
        activityStore: ActivityStore = .disabled
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "simulator-controller-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = RuntimeStore(runtimeFile: directory.appending(path: "runtime.json"))
        externalLease = SimLease(lockFile: directory.appending(path: "sim.lock"))
        let localSystem = FakeSimulatorSystem()
        let localStopper = FakeSessionStopper(hook: stopperHook)
        let localQueue = AsyncFIFO()
        let localMonkeydoSignals = SignalRecorder()
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
                activityStore: activityStore)
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
                activityStore: activityStore)
        }
    }

    func tearDown() { try? FileManager.default.removeItem(at: directory) }
}

struct ControllerMonkeydoLifecycle: MonkeydoProcessLifecycling, Sendable {
    let pathLookup: @Sendable (Int32) -> String?
    let signals: SignalRecorder
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

final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SignalCall] = []

    var values: [SignalCall] { lock.withLock { storage } }
    func append(_ value: SignalCall) { lock.withLock { storage.append(value) } }
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
