import Foundation

public struct SimulatorSummary: Equatable, Sendable {
    public let pid: Int32
    public let sdkVersion: String
    public let device: String?

    public init(pid: Int32, sdkVersion: String, device: String?) {
        self.pid = pid
        self.sdkVersion = sdkVersion
        self.device = device
    }
}

public struct DrivingSummary: Equatable, Sendable {
    public let operation: String
    public let startedEpochSeconds: Double
    public let simulator: SimulatorSummary?

    public init(operation: String, startedEpochSeconds: Double, simulator: SimulatorSummary?) {
        self.operation = operation
        self.startedEpochSeconds = startedEpochSeconds
        self.simulator = simulator
    }
}

/// What the status item shows, resolved from the two published records.
///
/// `unknown` is indirect because it carries the state it could not replace.
public indirect enum MonitorState: Equatable, Sendable {
    case noSimulator
    case idle(SimulatorSummary)
    case driving(DrivingSummary)
    case drivingWithoutSimulator(DrivingSummary)
    case unknown(previous: MonitorState?)
}

/// Resolves one poll into one state.
///
/// Pure and fully injected so every branch is unit-testable without AppKit, a
/// simulator, or a live process to inspect.
public struct MonitorStateResolver: Sendable {
    private let readActivity: @Sendable () -> ActiveOperation?
    private let readRuntime: @Sendable () -> RuntimeRecord?
    private let snapshot: @Sendable (Int32) throws -> ProcessIdentitySnapshot?
    private let simulatorPresence: @Sendable (Int32, String) -> Bool

    public init(
        activityStore: ActivityStore = .standard,
        runtimeStore: RuntimeStore = .standard,
        identityReader: any ProcessIdentityReading = DarwinProcessIdentityReader(),
        presence: ProcessPresence = .standard
    ) {
        self.readActivity = { activityStore.read() }
        self.readRuntime = { runtimeStore.read() }
        self.snapshot = { try identityReader.snapshot(pid: $0) }
        self.simulatorPresence = { presence.isRunning(pid: $0, executablePath: $1) }
    }

    init(
        readActivity: @escaping @Sendable () -> ActiveOperation?,
        readRuntime: @escaping @Sendable () -> RuntimeRecord?,
        snapshot: @escaping @Sendable (Int32) throws -> ProcessIdentitySnapshot?,
        simulatorPresence: @escaping @Sendable (Int32, String) -> Bool
    ) {
        self.readActivity = readActivity
        self.readRuntime = readRuntime
        self.snapshot = snapshot
        self.simulatorPresence = simulatorPresence
    }

    /// Resolves the current state. Must be called off the main thread: the
    /// identity probe reads a process's argument vector, and that call can
    /// busy-wait on `sched_yield` for up to 250 ms while a target's address
    /// space is being replaced.
    public func resolve(previous: MonitorState?) -> MonitorState {
        let runtime = readRuntime()
        let simulator = runtime.flatMap { record -> SimulatorSummary? in
            guard simulatorPresence(record.simulatorPid, record.executablePath) else { return nil }
            return SimulatorSummary(
                pid: record.simulatorPid,
                sdkVersion: record.sdkVersion,
                device: record.currentDevice)
        }

        guard let active = readActivity() else {
            return simulator.map(MonitorState.idle) ?? .noSimulator
        }

        switch revalidate(active.owner) {
        case .matched:
            let summary = DrivingSummary(
                operation: active.operation,
                startedEpochSeconds: active.startedEpochSeconds,
                simulator: simulator)
            return simulator == nil ? .drivingWithoutSimulator(summary) : .driving(summary)
        case .stale:
            return simulator.map(MonitorState.idle) ?? .noSimulator
        case .indeterminate:
            return .unknown(previous: previous)
        }
    }

    private enum Revalidation {
        case matched
        case stale
        case indeterminate
    }

    /// `snapshot` returns exactly three distinguishable results — a snapshot,
    /// `nil`, or a throw — so there are exactly four branches and no more.
    ///
    /// A throw is deliberately not treated as absence. The error is opaque and
    /// carries no errno, and rendering a live gate as idle would invite the
    /// user to touch the keyboard mid-sequence. One retry absorbs a transient
    /// fault; anything past that is reported as indeterminate.
    private func revalidate(_ owner: StableProcessIdentity) -> Revalidation {
        for attempt in 0..<2 {
            do {
                guard let observed = try snapshot(owner.pid) else { return .stale }
                return observed.stableIdentity == owner ? .matched : .stale
            } catch {
                if attempt == 1 { return .indeterminate }
            }
        }
        return .indeterminate
    }
}
