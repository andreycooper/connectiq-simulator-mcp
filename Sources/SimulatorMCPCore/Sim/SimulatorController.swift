import AppKit
import Darwin
import Foundation
import os

public enum SimOperation: String, Codable, Sendable {
    case simStart = "sim_start"
    case simStop = "sim_stop"
    case runApp = "run_app"
    case runTests = "run_tests"
    case screenshot
    case pressButton = "press_button"
    case setGpsPosition = "set_gps_position"
    case runSequence = "run_sequence"
}

public enum OperationRequirement: Sendable {
    case start(requested: SdkInfo)
    case stop
    case ready(requested: SdkInfo)
    case currentReady
}

public struct OperationContext: Sendable {
    public let simulatorPid: Int32
    public let sdk: SdkInfo
    public let currentDevice: String?
    public let listeningEndpoints: Set<TCPEndpoint>

    public init(
        simulatorPid: Int32,
        sdk: SdkInfo,
        currentDevice: String?,
        listeningEndpoints: Set<TCPEndpoint>
    ) {
        self.simulatorPid = simulatorPid
        self.sdk = sdk
        self.currentDevice = currentDevice
        self.listeningEndpoints = listeningEndpoints
    }
}

public protocol SimulatorSessionStopping: Sendable {
    func stopForSimulatorShutdown() async throws
}

public struct NoSimulatorSessionStopper: SimulatorSessionStopping {
    public init() {}
    public func stopForSimulatorShutdown() async throws {}
}

/// Injectable process boundary. Production uses libproc for enumeration and
/// proc_pidpath, `ps` only when proc_pidpath cannot provide a path, and
/// NSWorkspace for launching the exact requested SDK app URL.
struct SimulatorProcessSystem: Sendable {
    let discover: @Sendable () async throws -> [SimulatorProcessIdentity]
    let lookup: @Sendable (Int32) async throws -> SimulatorProcessIdentity?
    let launch: @Sendable (URL) async throws -> Int32
    let signal: @Sendable (Int32, Int32) async throws -> Void

    init(
        discover: @escaping @Sendable () async throws -> [SimulatorProcessIdentity],
        lookup: @escaping @Sendable (Int32) async throws -> SimulatorProcessIdentity?,
        launch: @escaping @Sendable (URL) async throws -> Int32,
        signal: @escaping @Sendable (Int32, Int32) async throws -> Void,
    ) {
        self.discover = discover
        self.lookup = lookup
        self.launch = launch
        self.signal = signal
    }

    static func live(processRunner: any ProcessRunning) -> SimulatorProcessSystem {
        configured(
            processRunner: processRunner,
            isAlive: { pid in kill(pid, 0) == 0 || errno == EPERM },
            procPath: { pid in procPath(pid: pid) },
            launch: { app in try await launchExactApplication(app) },
)
    }

    static func configured(
        processRunner: any ProcessRunning,
        isAlive: @escaping @Sendable (Int32) -> Bool,
        procPath: @escaping @Sendable (Int32) -> String?,
        launch: @escaping @Sendable (URL) async throws -> Int32
    ) -> SimulatorProcessSystem {
        let lookup: @Sendable (Int32) async throws -> SimulatorProcessIdentity? = { pid in
            guard isAlive(pid) else { return nil }
            let path: String
            if let procPath = procPath(pid) {
                path = procPath
            } else {
                let child = try await processRunner.start(
                    executable: URL(fileURLWithPath: "/bin/ps"),
                    arguments: ["-p", String(pid), "-o", "comm="],
                    environment: nil,
                    workingDirectory: nil,
                    timeout: .seconds(5),
                    onStdout: nil,
                    onStderr: nil)
                let output = try await child.wait()
                guard output.exitCode == 0,
                    let value = String(data: output.stdout, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else { return nil }
                path = value
            }
            return identity(pid: pid, executablePath: path)
        }

        return SimulatorProcessSystem(
            discover: {
                let child = try await processRunner.start(
                    executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                    arguments: ["-x", "simulator"],
                    environment: nil,
                    workingDirectory: nil,
                    timeout: .seconds(5),
                    onStdout: nil,
                    onStderr: nil)
                let output = try await child.wait()
                guard output.exitCode == 0 || output.exitCode == 1 else {
                    throw ToolError(
                        code: "simulator_probe_failed",
                        message: "Could not enumerate Connect IQ simulator processes (pgrep exit \(output.exitCode)).",
                        fix: "Verify /usr/bin/pgrep is available, then retry.")
                }
                guard output.exitCode == 0,
                    let text = String(data: output.stdout, encoding: .utf8)
                else { return [] }
                var matches: [SimulatorProcessIdentity] = []
                for line in text.split(whereSeparator: \Character.isNewline) {
                    guard let pid = Int32(line), let value = try await lookup(pid) else { continue }
                    matches.append(value)
                }
                return matches.sorted { $0.pid < $1.pid }
            },
            lookup: lookup,
            launch: launch,
            signal: { pid, signalValue in
                guard Darwin.kill(pid, signalValue) == 0 else {
                    let code = errno
                    if code == ESRCH { return }
                    throw SimLease.posixError(
                        "kill", path: "pid \(pid)", code: code,
                        fix: "Quit the Connect IQ simulator manually, then retry.")
                }
            })
    }

    static func procPath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro Swift cannot import.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? min(Int(count), buffer.count)
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func identity(pid: Int32, executablePath: String) -> SimulatorProcessIdentity? {
        let canonicalExecutable = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let suffix = "/bin/ConnectIQ.app/Contents/MacOS/simulator"
        guard canonicalExecutable.hasSuffix(suffix) else { return nil }
        let rootPath = String(canonicalExecutable.dropLast(suffix.count))
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        let valid = manager.fileExists(atPath: root.appending(path: "bin/monkeyc").path)
            && manager.fileExists(atPath: root.appending(path: "bin/monkeydo").path)
            && manager.fileExists(atPath: root.appending(path: "bin/ConnectIQ.app").path)
        let sdk: SdkInfo?
        if valid, let version = SemVer(firstIn: root.lastPathComponent) {
            sdk = SdkInfo(version: version, root: root, source: .installed)
        } else {
            sdk = nil
        }
        return SimulatorProcessIdentity(
            pid: pid, executablePath: canonicalExecutable, sdk: sdk)
    }

    private static func launchExactApplication(_ app: URL) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) {
                application, error in
                if let error {
                    Log.err("NSWorkspace simulator launch failed: \(String(reflecting: error))")
                    continuation.resume(throwing: ToolError(
                        code: "simulator_launch_failed",
                        message: "Could not launch Connect IQ simulator at \(app.path).",
                        fix: "Verify the requested SDK is installed and open its simulator manually once, then retry.",
                        details: ["simulatorApp": .string(app.path)]))
                } else if let application {
                    continuation.resume(returning: application.processIdentifier)
                } else {
                    continuation.resume(throwing: ToolError(
                        code: "simulator_launch_failed",
                        message: "NSWorkspace returned no process for Connect IQ simulator at \(app.path).",
                        fix: "Open the requested SDK simulator manually once, quit it, then retry.",
                        details: ["simulatorApp": .string(app.path)]))
                }
            }
        }
    }

}

/// Launch Services has no cancellation token for its completion handler. This
/// gate orders cancellation and callback completion so a late callback cannot
/// resume a cancelled activated-start request.
public actor SimulatorController {
    private enum RefreshResult: Sendable {
        case absent
        case observed(SimulatorProcessIdentity, Set<TCPEndpoint>)
        case ambiguousOrFailed
    }

    private let queue: AsyncFIFO
    private let lease: SimLease
    private let runtimeStore: RuntimeStore
    private let sessionStopper: any SimulatorSessionStopping
    private let system: SimulatorProcessSystem
    private let readinessProbe: SimulatorReadinessProbe
    private let monkeydoLifecycle: any MonkeydoProcessLifecycling
    private let ownerServerInstance = UUID()
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline

    private var lifecycleState: SimulatorState = .notRunning
    private var activeOperation: SimOperation?
    private var currentIdentity: SimulatorProcessIdentity?
    private var currentEndpoints = Set<TCPEndpoint>()
    private var currentDevice: String?
    private var stableReadyObservation: SimulatorReadyObservation?
    private var pendingReadyObservation: SimulatorReadyObservation?
    private var pendingReadyDeadline: ClockDeadline?
    private var operationRequestsInFlight = 0
    private var statusGeneration: UInt64 = 0

    public init(
        queue: AsyncFIFO,
        lease: SimLease,
        runtimeStore: RuntimeStore,
        processRunner: any ProcessRunning,
        sessionStopper: any SimulatorSessionStopping,
        monkeydoLifecycle: (any MonkeydoProcessLifecycling)? = nil
    ) {
        let system = SimulatorProcessSystem.live(processRunner: processRunner)
        let clock = ContinuousClock()
        self.queue = queue
        self.lease = lease
        self.runtimeStore = runtimeStore
        self.sessionStopper = sessionStopper
        self.system = system
        self.readinessProbe = SimulatorReadinessProbe(
            processRunner: processRunner,
            identityLookup: system.lookup)
        self.monkeydoLifecycle = monkeydoLifecycle
            ?? MonkeydoProcessLifecycle(processRunner: processRunner)
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    init<C: Clock>(
        queue: AsyncFIFO,
        lease: SimLease,
        runtimeStore: RuntimeStore,
        processRunner: any ProcessRunning,
        sessionStopper: any SimulatorSessionStopping,
        system: SimulatorProcessSystem,
        readinessProbe: SimulatorReadinessProbe,
        clock: C,
        monkeydoLifecycle: (any MonkeydoProcessLifecycling)? = nil
    ) where C.Duration == Duration {
        self.queue = queue
        self.lease = lease
        self.runtimeStore = runtimeStore
        self.sessionStopper = sessionStopper
        self.system = system
        self.readinessProbe = readinessProbe
        self.monkeydoLifecycle = monkeydoLifecycle
            ?? MonkeydoProcessLifecycle(processRunner: processRunner)
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    init(
        queue: AsyncFIFO,
        lease: SimLease,
        runtimeStore: RuntimeStore,
        processRunner: any ProcessRunning,
        sessionStopper: any SimulatorSessionStopping,
        system: SimulatorProcessSystem,
        readinessProbe: SimulatorReadinessProbe,
        monkeydoLifecycle: (any MonkeydoProcessLifecycling)? = nil
    ) {
        let clock = ContinuousClock()
        self.queue = queue
        self.lease = lease
        self.runtimeStore = runtimeStore
        self.sessionStopper = sessionStopper
        self.system = system
        self.readinessProbe = readinessProbe
        self.monkeydoLifecycle = monkeydoLifecycle
            ?? MonkeydoProcessLifecycle(processRunner: processRunner)
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    public func withOperation<T: Sendable>(
        _ operation: SimOperation,
        requirement: OperationRequirement,
        queueTimeout: Duration = .seconds(30),
        leaseTimeout: Duration = .seconds(30),
        body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        operationRequestsInFlight += 1
        statusGeneration &+= 1
        defer {
            operationRequestsInFlight -= 1
            statusGeneration &+= 1
        }
        return try await queue.withLock(operation: operation.rawValue, timeout: queueTimeout) {
            let token = try await self.lease.acquire(
                operation: operation.rawValue, timeout: leaseTimeout)
            do {
                let value = try await self.perform(
                    operation, requirement: requirement, body: body)
                try token.release()
                return value
            } catch {
                try? token.release()
                throw error
            }
        }
    }

    public func status() async throws -> SimStatusResult {
        statusGeneration &+= 1
        let generation = statusGeneration
        let holder = try lease.holder()
        guard operationRequestsInFlight == 0 else {
            return currentStatus(holder: holder)
        }

        let processes: [SimulatorProcessIdentity]
        do {
            processes = try await discoveredProcesses()
        } catch {
            guard statusObservationIsCurrent(generation) else {
                return currentStatus(holder: holder)
            }
            throw error
        }
        guard statusObservationIsCurrent(generation) else {
            return currentStatus(holder: holder)
        }
        let identity = processes.first

        if identity != currentIdentity {
            currentDevice = nil
            clearReadinessProof()
        }
        currentIdentity = identity

        if let identity {
            guard let sdk = identity.sdk else { throw unknownSDK(identity) }
            synchronizePersistedRuntime(identity: identity, sdk: sdk)
        }

        var state = lifecycleState
        var operation = activeOperation?.rawValue
        if let holder, activeOperation == nil {
            state = .busy
            operation = holder.operation
        } else if activeOperation == nil {
            if let identity, let sdk = identity.sdk {
                let snapshot: SimulatorReadyObservation
                do {
                    snapshot = try await readinessProbe.observe(
                        pid: identity.pid, requested: sdk)
                } catch {
                    guard statusObservationIsCurrent(generation) else {
                        return currentStatus(holder: holder)
                    }
                    throw error
                }
                guard statusObservationIsCurrent(generation) else {
                    return currentStatus(holder: holder)
                }
                state = applySingleReadinessObservation(snapshot) ? .ready : .starting
            } else {
                clearReadinessProof()
                state = .notRunning
            }
        }

        return SimStatusResult(
            state: state,
            operation: operation,
            pid: identity?.pid,
            executablePath: identity?.executablePath,
            sdkPath: identity?.sdk?.root.path,
            sdkVersion: identity?.sdk?.version.description,
            currentDevice: currentDevice,
            leaseHolder: holder.map {
                "pid=\($0.pid) operation=\($0.operation) acquiredMonotonicNanos=\($0.acquiredMonotonicNanos)"
            })
    }

    private func statusObservationIsCurrent(_ generation: UInt64) -> Bool {
        generation == statusGeneration && operationRequestsInFlight == 0
    }

    private func currentStatus(holder: LeaseHolder?) -> SimStatusResult {
        var state = lifecycleState
        var operation = activeOperation?.rawValue
        if let holder, activeOperation == nil {
            state = .busy
            operation = holder.operation
        }
        return SimStatusResult(
            state: state,
            operation: operation,
            pid: currentIdentity?.pid,
            executablePath: currentIdentity?.executablePath,
            sdkPath: currentIdentity?.sdk?.root.path,
            sdkVersion: currentIdentity?.sdk?.version.description,
            currentDevice: currentDevice,
            leaseHolder: holder.map {
                "pid=\($0.pid) operation=\($0.operation) acquiredMonotonicNanos=\($0.acquiredMonotonicNanos)"
            })
    }

    public func setCurrentDevice(_ device: String, inside operation: SimOperation) throws {
        guard activeOperation == operation, lifecycleState == .busy,
            let identity = currentIdentity, let sdk = identity.sdk
        else {
            throw ToolError(
                code: "invalid_simulator_state",
                message: "Current device can only be changed inside the active \(operation.rawValue) simulator operation.",
                fix: "Set the device from the matching simulator operation body after readiness is proven.")
        }
        guard !device.isEmpty else {
            throw ToolError(
                code: "invalid_arguments",
                message: "Current simulator device must not be empty.",
                fix: "Pass a device identifier returned by list_devices.")
        }
        currentDevice = device
        try publish(identity: identity, sdk: sdk)
    }

    /// Terminates only the complete persisted launcher identity. Cleanup
    /// failure deliberately preserves the record so a later server cannot
    /// mistake an uncertain tree for an absent one.
    public func terminateActiveMonkeydo(inside operation: SimOperation) async throws {
        let (identity, sdk) = try activeOperationIdentity(operation)
        guard let record = matchingRuntime(identity: identity, sdk: sdk),
            let ownership = record.monkeydoOwnership
        else { return }
        try await monkeydoLifecycle.terminatePersisted(ownership, grace: .seconds(5))
        try clearActiveMonkeydo(
            expectedLauncher: ownership.launcher, device: nil, inside: operation)
    }

    /// Publishes complete cross-server launcher ownership while the matching
    /// simulator operation and OS lease are still held.
    public func publishActiveMonkeydo(
        _ owned: OwnedMonkeydoProcess,
        device: String?,
        inside operation: SimOperation
    ) throws {
        let (identity, sdk) = try activeOperationIdentity(operation)
        guard canonicalPath(owned.command.sdk.root.path) == canonicalPath(sdk.root.path) else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The monkeydo ownership belongs to a different SDK.",
                fix: "Publish the exact owned process launched for this simulator operation.")
        }
        if let device {
            guard !device.isEmpty else {
                throw ToolError(
                    code: "invalid_arguments",
                    message: "The current simulator device must not be empty.",
                    fix: "Pass the device identifier used for this run.")
            }
            currentDevice = device
        }
        try writeRuntime(
            identity: identity,
            sdk: sdk,
            monkeydoOwnership: PersistedMonkeydoOwnership(
                launcher: owned.launcher.stableIdentity,
                launcherParentPid: owned.launcher.parentPid,
                sdkPath: canonicalPath(owned.command.sdk.root.path),
                prgPath: canonicalPath(owned.command.prgPath.path),
                device: owned.command.device,
                testFilter: owned.command.testFilter,
                ownerServerInstance: ownerServerInstance))
    }

    public func clearActiveMonkeydo(
        expectedLauncher: StableProcessIdentity,
        device: String?,
        inside operation: SimOperation
    ) throws {
        let (identity, sdk) = try activeOperationIdentity(operation)
        guard let record = matchingRuntime(identity: identity, sdk: sdk) else { return }
        if let observed = record.monkeydoOwnership?.launcher,
            observed != expectedLauncher
        {
            throw ToolError(
                code: "runtime_ownership_changed",
                message: "The persisted monkeydo ownership changed before it could be cleared.",
                fix: "Leave the newer record untouched and retry the operation after inspecting runtime state.",
                details: [
                    "expectedPid": .int(Int(expectedLauncher.pid)),
                    "observedPid": .int(Int(observed.pid)),
                ])
        }
        if let device {
            guard !device.isEmpty else {
                throw ToolError(
                    code: "invalid_arguments",
                    message: "The current simulator device must not be empty.",
                    fix: "Pass the verified device used by this run.")
            }
            currentDevice = device
        }
        try writeRuntime(identity: identity, sdk: sdk, monkeydoOwnership: nil)
    }

    public func revalidateReady(
        _ context: OperationContext,
        inside operation: SimOperation
    ) async throws {
        _ = try activeOperationIdentity(operation)
        let observation = try await readinessProbe.observe(
            pid: context.simulatorPid, requested: context.sdk)
        guard observation.listeningEndpoints == context.listeningEndpoints,
            SimulatorReadinessProbe.hasDirectLoopback(observation.listeningEndpoints)
        else {
            throw ToolError(
                code: "simulator_not_ready",
                message: "Simulator readiness changed while retrying monkeydo.",
                fix: "Retry the run; if it repeats, restart the simulator first.")
        }
    }

    private func perform<T: Sendable>(
        _ operation: SimOperation,
        requirement: OperationRequirement,
        body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        do {
            switch requirement {
            case .start(let requested):
                guard operation == .simStart else {
                    throw invalidRequirement(operation, expected: "simStart")
                }
                let context = try await startOrAdopt(requested: requested)
                return try await runBody(operation, context: context, body: body)

            case .ready(let requested):
                let context = try await requireReady(requested: requested)
                return try await runBody(operation, context: context, body: body)

            case .currentReady:
                let identity = try await singleRunningProcess()
                guard let sdk = identity.sdk else { throw unknownSDK(identity) }
                let context = try await requireReady(requested: sdk)
                return try await runBody(operation, context: context, body: body)

            case .stop:
                guard operation == .simStop else {
                    throw invalidRequirement(operation, expected: "simStop")
                }
                return try await stop(body: body)
            }
        } catch {
            await refreshAfterFailure()
            throw error
        }
    }

    private func startOrAdopt(requested: SdkInfo) async throws -> OperationContext {
        let processes = try await discoveredProcesses()
        let selected: SimulatorProcessIdentity
        if let existing = processes.first {
            guard let sdk = existing.sdk else { throw unknownSDK(existing) }
            try requireSDKMatch(running: sdk, requested: requested)
            selected = existing
        } else {
            let launchedPID = try await system.launch(requested.simulatorApp)
            guard let launched = try await system.lookup(launchedPID) else {
                throw ToolError(
                    code: "simulator_launch_failed",
                    message: "Launched simulator PID \(launchedPID) could not be validated.",
                    fix: "Quit all Connect IQ simulator instances, then call sim_start again.",
                    details: ["pid": .int(Int(launchedPID))])
            }
            guard let sdk = launched.sdk else { throw unknownSDK(launched) }
            try requireSDKMatch(running: sdk, requested: requested)
            selected = launched
        }

        let pid = selected.pid
        lifecycleState = .starting
        activeOperation = .simStart
        let ready = try await readinessProbe.waitUntilReady(
            pid: pid, requested: requested, timeout: .seconds(30))
        try Task.checkCancellation()
        currentIdentity = ready.identity
        recordStableProof(ready)
        if runtimeStore.read()?.simulatorPid != pid { currentDevice = nil }
        synchronizePersistedRuntime(identity: ready.identity, sdk: requested)
        try Task.checkCancellation()
        try publish(identity: ready.identity, sdk: requested)
        activeOperation = nil
        lifecycleState = .ready
        return context(identity: ready.identity, sdk: requested, endpoints: ready.listeningEndpoints)
    }

    private func requireReady(requested: SdkInfo) async throws -> OperationContext {
        let identity = try await singleRunningProcess()
        guard let sdk = identity.sdk else { throw unknownSDK(identity) }
        try requireSDKMatch(running: sdk, requested: requested)
        let ready = try await readinessProbe.waitUntilReady(
            pid: identity.pid, requested: requested, timeout: .seconds(30))
        if currentIdentity != identity { currentDevice = nil }
        synchronizePersistedRuntime(identity: identity, sdk: sdk)
        currentIdentity = identity
        recordStableProof(ready)
        try publish(identity: identity, sdk: sdk)
        lifecycleState = .ready
        return context(identity: identity, sdk: sdk, endpoints: ready.listeningEndpoints)
    }

    private func runBody<T: Sendable>(
        _ operation: SimOperation,
        context: OperationContext,
        body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        lifecycleState = .busy
        activeOperation = operation
        do {
            let result = try await body(context)
            activeOperation = nil
            lifecycleState = .ready
            return result
        } catch {
            activeOperation = nil
            lifecycleState = .ready
            throw error
        }
    }

    private func stop<T: Sendable>(
        body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        let processes = try await discoveredProcesses()
        guard let identity = processes.first else {
            try await sessionStopper.stopForSimulatorShutdown()
            try await terminatePersistedMonkeydoWithoutSimulator()
            try runtimeStore.clear()
            currentIdentity = nil
            currentDevice = nil
            clearReadinessProof()
            lifecycleState = .notRunning
            let unavailable = SdkInfo(
                version: SemVer(major: 0, minor: 0, patch: 0),
                root: URL(fileURLWithPath: "/", isDirectory: true),
                source: .installed)
            try Task.checkCancellation()
            return try await body(OperationContext(
                simulatorPid: 0, sdk: unavailable, currentDevice: nil,
                listeningEndpoints: []))
        }
        guard let sdk = identity.sdk else { throw unknownSDK(identity) }
        let context = context(identity: identity, sdk: sdk, endpoints: currentEndpoints)
        lifecycleState = .stopping
        activeOperation = .simStop
        try await sessionStopper.stopForSimulatorShutdown()
        try await terminatePersistedMonkeydoForStop(identity: identity, sdk: sdk)
        try Task.checkCancellation()
        let presentBeforeTERM = try await revalidateExpectedIdentity(identity)
        try Task.checkCancellation()
        if presentBeforeTERM {
            try Task.checkCancellation()
            try await system.signal(identity.pid, SIGTERM)
        }
        try Task.checkCancellation()
        let presentAfterTERM = try await revalidateExpectedIdentity(identity)
        try Task.checkCancellation()
        if presentAfterTERM,
            !(try await waitForExit(expected: identity, timeout: .seconds(5)))
        {
            try Task.checkCancellation()
            // Revalidate again after the grace deadline and immediately
            // before escalation. A reused PID must never receive our KILL.
            let presentBeforeKILL = try await revalidateExpectedIdentity(identity)
            try Task.checkCancellation()
            if presentBeforeKILL {
                try Task.checkCancellation()
                try await system.signal(identity.pid, SIGKILL)
            }
            try Task.checkCancellation()
            guard try await waitForExit(expected: identity, timeout: .seconds(5)) else {
                throw ToolError(
                    code: "simulator_stop_timeout",
                    message: "Simulator process \(identity.pid) remained alive after SIGKILL.",
                    fix: "Quit the simulator from Activity Monitor, then retry.",
                    details: ["pid": .int(Int(identity.pid))])
            }
        }
        try Task.checkCancellation()
        let value = try await body(context)
        try runtimeStore.clear()
        currentIdentity = nil
        currentDevice = nil
        clearReadinessProof()
        activeOperation = nil
        lifecycleState = .notRunning
        return value
    }

    private func waitForExit(
        expected: SimulatorProcessIdentity,
        timeout: Duration
    ) async throws -> Bool {
        let deadline = makeDeadline(timeout)
        while true {
            try Task.checkCancellation()
            let present = try await revalidateExpectedIdentity(expected)
            try Task.checkCancellation()
            guard present else {
                try Task.checkCancellation()
                return true
            }
            if deadline.hasExpired {
                try Task.checkCancellation()
                return false
            }
            try Task.checkCancellation()
            try await deadline.sleepUntilNextPoll(maximumInterval: .milliseconds(50))
            try Task.checkCancellation()
        }
    }

    /// Returns false only when the expected process exited. A different
    /// executable/SDK at the same PID is a replacement, never the process we
    /// are authorized to signal.
    private func revalidateExpectedIdentity(
        _ expected: SimulatorProcessIdentity
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let actual = try await system.lookup(expected.pid) else {
            try Task.checkCancellation()
            return false
        }
        try Task.checkCancellation()
        guard actual == expected else {
            throw ToolError(
                code: "simulator_process_changed",
                message: "Simulator PID \(expected.pid) now belongs to a different process identity.",
                fix: "Do not signal that PID. Inspect sim_status, then retry sim_stop for the currently reported simulator.",
                details: [
                    "pid": .int(Int(expected.pid)),
                    "expectedExecutablePath": .string(expected.executablePath),
                    "observedExecutablePath": .string(actual.executablePath),
                ])
        }
        return true
    }

    private func discoveredProcesses() async throws -> [SimulatorProcessIdentity] {
        let matches = try await system.discover().sorted { $0.pid < $1.pid }
        guard matches.count <= 1 else {
            throw ToolError(
                code: "simulator_busy",
                message: "More than one Connect IQ simulator instance is running.",
                fix: "Quit all Connect IQ simulator instances, then call sim_start.",
                details: ["pids": .array(matches.map { .int(Int($0.pid)) })])
        }
        return matches
    }

    private func singleRunningProcess() async throws -> SimulatorProcessIdentity {
        guard let identity = try await discoveredProcesses().first else {
            throw ToolError(
                code: "simulator_not_running",
                message: "Connect IQ simulator is not running.",
                fix: "Call sim_start before this operation.")
        }
        return identity
    }

    private func publish(identity: SimulatorProcessIdentity, sdk: SdkInfo) throws {
        try writeRuntime(
            identity: identity,
            sdk: sdk,
            monkeydoOwnership: matchingRuntime(identity: identity, sdk: sdk)?.monkeydoOwnership)
    }

    private func writeRuntime(
        identity: SimulatorProcessIdentity,
        sdk: SdkInfo,
        monkeydoOwnership: PersistedMonkeydoOwnership?
    ) throws {
        try runtimeStore.write(RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: currentDevice,
            monkeydoOwnership: monkeydoOwnership))
    }

    /// `sim_stop` may run in a different stdio server from the one that
    /// launched monkeydo. Consume its schema-2 ownership under the same lease
    /// before signalling the simulator; cleanup failure preserves the record
    /// and aborts stop so no orphan can be hidden by runtime clearing.
    private func terminatePersistedMonkeydoForStop(
        identity: SimulatorProcessIdentity,
        sdk: SdkInfo
    ) async throws {
        guard let ownership = matchingRuntime(
            identity: identity, sdk: sdk)?.monkeydoOwnership
        else { return }
        try await monkeydoLifecycle.terminatePersisted(ownership, grace: .seconds(5))
        try compareAndClearPersistedMonkeydo(
            expected: ownership.launcher, identity: identity, sdk: sdk)
    }

    private func terminatePersistedMonkeydoWithoutSimulator() async throws {
        guard let ownership = runtimeStore.read()?.monkeydoOwnership else { return }
        try await monkeydoLifecycle.terminatePersisted(ownership, grace: .seconds(5))
        guard let current = runtimeStore.read() else { return }
        if let observed = current.monkeydoOwnership?.launcher,
            observed != ownership.launcher
        {
            throw ownershipChanged(expected: ownership.launcher, observed: observed)
        }
    }

    private func compareAndClearPersistedMonkeydo(
        expected: StableProcessIdentity,
        identity: SimulatorProcessIdentity,
        sdk: SdkInfo
    ) throws {
        guard let current = matchingRuntime(identity: identity, sdk: sdk) else { return }
        if let observed = current.monkeydoOwnership?.launcher, observed != expected {
            throw ownershipChanged(expected: expected, observed: observed)
        }
        try writeRuntime(identity: identity, sdk: sdk, monkeydoOwnership: nil)
    }

    private func ownershipChanged(
        expected: StableProcessIdentity,
        observed: StableProcessIdentity
    ) -> ToolError {
        ToolError(
            code: "runtime_ownership_changed",
            message: "The persisted monkeydo ownership changed during cleanup.",
            fix: "Leave the newer record untouched and retry after inspecting runtime state.",
            details: [
                "expectedPid": .int(Int(expected.pid)),
                "observedPid": .int(Int(observed.pid)),
            ])
    }

    private func matchingRuntime(
        identity: SimulatorProcessIdentity,
        sdk: SdkInfo
    ) -> RuntimeRecord? {
        guard let record = runtimeStore.read(),
            record.simulatorPid == identity.pid,
            canonicalPath(record.executablePath) == canonicalPath(identity.executablePath),
            canonicalPath(record.sdkPath) == canonicalPath(sdk.root.path)
        else { return nil }
        return record
    }

    private func activeOperationIdentity(
        _ operation: SimOperation
    ) throws -> (SimulatorProcessIdentity, SdkInfo) {
        guard activeOperation == operation, lifecycleState == .busy,
            let identity = currentIdentity, let sdk = identity.sdk
        else {
            throw ToolError(
                code: "invalid_simulator_state",
                message: "Monkeydo runtime state can only change inside the active \(operation.rawValue) operation.",
                fix: "Update monkeydo runtime state from the matching operation body while its lease is held.")
        }
        return (identity, sdk)
    }

    private func context(
        identity: SimulatorProcessIdentity,
        sdk: SdkInfo,
        endpoints: Set<TCPEndpoint>
    ) -> OperationContext {
        OperationContext(
            simulatorPid: identity.pid,
            sdk: sdk,
            currentDevice: currentDevice,
            listeningEndpoints: endpoints)
    }

    private func requireSDKMatch(running: SdkInfo, requested: SdkInfo) throws {
        let runningRoot = running.root.resolvingSymlinksInPath().standardizedFileURL
        let requestedRoot = requested.root.resolvingSymlinksInPath().standardizedFileURL
        guard runningRoot == requestedRoot else {
            throw ToolError(
                code: "sdk_mismatch",
                message: "Running simulator SDK \(runningRoot.path) does not match requested SDK \(requestedRoot.path).",
                fix: "Call sim_stop, then sim_start with the requested SDK.",
                details: [
                    "runningSdkPath": .string(runningRoot.path),
                    "requestedSdkPath": .string(requestedRoot.path),
                ])
        }
    }

    private func unknownSDK(_ identity: SimulatorProcessIdentity) -> ToolError {
        ToolError(
            code: "unknown_running_sdk",
            message: "Simulator process \(identity.pid) is outside a valid installed Connect IQ SDK.",
            fix: "Quit all Connect IQ simulator instances, then call sim_start with an installed SDK.",
            details: [
                "pid": .int(Int(identity.pid)),
                "executablePath": .string(identity.executablePath),
            ])
    }

    private func invalidRequirement(_ operation: SimOperation, expected: String) -> ToolError {
        ToolError(
            code: "invalid_arguments",
            message: "Operation \(operation.rawValue) cannot use the requested lifecycle policy.",
            fix: "Use the \(expected) operation with this lifecycle requirement.")
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func synchronizePersistedRuntime(
        identity: SimulatorProcessIdentity,
        sdk: SdkInfo
    ) {
        guard let persisted = runtimeStore.read(),
            persisted.simulatorPid == identity.pid,
            canonicalPath(persisted.executablePath) == canonicalPath(identity.executablePath),
            canonicalPath(persisted.sdkPath) == canonicalPath(sdk.root.path),
            persisted.sdkVersion == sdk.version.description
        else {
            currentDevice = nil
            return
        }
        currentDevice = persisted.currentDevice
    }

    private func recordStableProof(_ observation: SimulatorReadyObservation) {
        stableReadyObservation = observation
        pendingReadyObservation = nil
        pendingReadyDeadline = nil
        currentEndpoints = observation.listeningEndpoints
    }

    private func clearReadinessProof() {
        stableReadyObservation = nil
        pendingReadyObservation = nil
        pendingReadyDeadline = nil
        currentEndpoints = []
    }

    /// Applies one nonblocking status/failure-refresh sample. A previously
    /// proven observation remains ready while it matches exactly. A fresh
    /// observation becomes ready only after an identical direct-loopback
    /// sample is seen at least 100 monotonic milliseconds later.
    private func applySingleReadinessObservation(
        _ observation: SimulatorReadyObservation
    ) -> Bool {
        if SimulatorReadinessProbe.matchesStableProof(
            observation, proof: stableReadyObservation)
        {
            currentEndpoints = observation.listeningEndpoints
            return true
        }

        stableReadyObservation = nil
        currentEndpoints = []
        guard SimulatorReadinessProbe.hasDirectLoopback(observation.listeningEndpoints) else {
            pendingReadyObservation = nil
            pendingReadyDeadline = nil
            return false
        }

        if observation == pendingReadyObservation,
            pendingReadyDeadline?.hasExpired == true
        {
            recordStableProof(observation)
            return true
        }
        if observation != pendingReadyObservation {
            pendingReadyObservation = observation
            pendingReadyDeadline = makeDeadline(.milliseconds(100))
        }
        return false
    }

    private func refreshAfterFailure() async {
        activeOperation = nil
        // The caller may already be cancelled. Refresh in an independent
        // task so cancellation cleanup still validates real process state
        // instead of immediately aborting its subprocess probe.
        let system = self.system
        let probe = self.readinessProbe
        let refresh = await Task.detached { () -> RefreshResult in
            do {
                let processes = try await system.discover().sorted { $0.pid < $1.pid }
                guard processes.count <= 1 else { return .ambiguousOrFailed }
                guard let identity = processes.first else { return .absent }
                guard let sdk = identity.sdk else { return .ambiguousOrFailed }
                let snapshot = try await probe.observe(pid: identity.pid, requested: sdk)
                return .observed(identity, snapshot.listeningEndpoints)
            } catch {
                return .ambiguousOrFailed
            }
        }.value

        switch refresh {
        case .absent:
            currentIdentity = nil
            currentDevice = nil
            clearReadinessProof()
            lifecycleState = .notRunning
            // A failed cross-server monkeydo cleanup must remain recoverable
            // even when the simulator itself is already gone.
            if runtimeStore.read()?.monkeydoOwnership == nil {
                try? runtimeStore.clear()
            }
        case .observed(let identity, let endpoints):
            if currentIdentity != identity { currentDevice = nil }
            currentIdentity = identity
            let observation = SimulatorReadyObservation(
                identity: identity, listeningEndpoints: endpoints)
            lifecycleState = applySingleReadinessObservation(observation) ? .ready : .starting
            if let sdk = identity.sdk {
                synchronizePersistedRuntime(identity: identity, sdk: sdk)
                try? publish(identity: identity, sdk: sdk)
            }
        case .ambiguousOrFailed:
            // Do not invent not-running when refresh itself was inconclusive.
            // The next status/operation will report the concrete stable error.
            if lifecycleState == .busy { lifecycleState = .ready }
        }
    }
}
