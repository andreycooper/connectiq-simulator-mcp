import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("MonitorState resolution")
struct MonitorStateTests {
    @Test("an owner that revalidates equal is driving")
    func matchingOwnerIsDriving() {
        let resolver = makeResolver(
            active: sampleActive(),
            runtime: sampleRuntime(),
            snapshot: .success(sampleSnapshot()),
            simulatorRunning: true)

        guard case .driving(let summary) = resolver.resolve(previous: nil) else {
            Issue.record("expected driving")
            return
        }
        #expect(summary.operation == "press_button")
        #expect(summary.startedEpochSeconds == 1_785_932_487.5)
    }

    @Test("a probe that succeeds on the first attempt is called exactly once")
    func singleProbeOnSuccessfulMatch() {
        let attempts = ProbeCounter()
        let resolver = MonitorStateResolver(
            readActivity: { sampleActive() },
            readRuntime: { sampleRuntime() },
            snapshot: { _ in
                attempts.count()
                return sampleSnapshot()
            },
            simulatorPresence: { _, _ in true })

        guard case .driving = resolver.resolve(previous: nil) else {
            Issue.record("expected driving")
            return
        }
        #expect(attempts.attempts == 1)
    }

    @Test("an activity record with no runtime record is driving without a simulator")
    func activeDominatesAnEmptyRuntimeRecord() {
        let resolver = makeResolver(
            active: sampleActive(),
            runtime: nil,
            snapshot: .success(sampleSnapshot()),
            simulatorRunning: false)

        guard case .drivingWithoutSimulator = resolver.resolve(previous: nil) else {
            Issue.record("expected drivingWithoutSimulator, not noSimulator")
            return
        }
    }

    @Test("an owner whose identity changed is treated as a reused pid and is idle")
    func reusedPidIsIdle() {
        var other = sampleSnapshot()
        other = ProcessIdentitySnapshot(
            pid: other.pid,
            parentPid: other.parentPid,
            processGroupId: other.processGroupId,
            start: ProcessStartIdentity(seconds: 1_785_932_401, microseconds: 143_221),
            executablePath: other.executablePath,
            arguments: other.arguments)
        let resolver = makeResolver(
            active: sampleActive(),
            runtime: sampleRuntime(),
            snapshot: .success(other),
            simulatorRunning: true)

        guard case .idle = resolver.resolve(previous: nil) else {
            Issue.record("expected idle")
            return
        }
    }

    @Test("an owner that has vanished is idle")
    func vanishedOwnerIsIdle() {
        let resolver = makeResolver(
            active: sampleActive(),
            runtime: sampleRuntime(),
            snapshot: .success(nil),
            simulatorRunning: true)

        guard case .idle = resolver.resolve(previous: nil) else {
            Issue.record("expected idle")
            return
        }
    }

    @Test("a throwing probe is unknown and never idle")
    func throwingProbeIsUnknown() {
        let resolver = makeResolver(
            active: sampleActive(),
            runtime: sampleRuntime(),
            snapshot: .failure(SampleProbeFailure.opaque),
            simulatorRunning: true)

        guard case .unknown(let previous) = resolver.resolve(previous: nil) else {
            Issue.record("expected unknown")
            return
        }
        #expect(previous == nil)
    }

    @Test("a throwing probe retries once before committing to unknown")
    func throwingProbeRetriesOnce() {
        let attempts = ProbeCounter()
        let resolver = MonitorStateResolver(
            readActivity: { sampleActive() },
            readRuntime: { sampleRuntime() },
            snapshot: { _ in
                attempts.count()
                throw SampleProbeFailure.opaque
            },
            simulatorPresence: { _, _ in true })

        _ = resolver.resolve(previous: nil)

        #expect(attempts.attempts == 2)
    }

    @Test("a probe that succeeds on retry does not report unknown")
    func retrySuccessIsDriving() {
        let attempts = ProbeCounter()
        let resolver = MonitorStateResolver(
            readActivity: { sampleActive() },
            readRuntime: { sampleRuntime() },
            snapshot: { _ in
                attempts.count()
                if attempts.attempts == 1 { throw SampleProbeFailure.opaque }
                return sampleSnapshot()
            },
            simulatorPresence: { _, _ in true })

        guard case .driving = resolver.resolve(previous: nil) else {
            Issue.record("expected driving after a successful retry")
            return
        }
    }

    @Test("unknown carries the previous state forward when there is one")
    func unknownCarriesPreviousState() {
        let resolver = makeResolver(
            active: sampleActive(),
            runtime: sampleRuntime(),
            snapshot: .failure(SampleProbeFailure.opaque),
            simulatorRunning: true)
        let earlier = MonitorState.idle(SimulatorSummary(pid: 4102, sdkVersion: "9.1.0", device: "fenix6xpro"))

        guard case .unknown(let previous) = resolver.resolve(previous: earlier) else {
            Issue.record("expected unknown")
            return
        }
        guard case .idle = previous else {
            Issue.record("expected the previous idle state to be carried")
            return
        }
    }

    @Test("no activity and a live simulator is idle")
    func noActivityWithLiveSimulatorIsIdle() {
        let resolver = makeResolver(
            active: nil,
            runtime: sampleRuntime(),
            snapshot: .success(sampleSnapshot()),
            simulatorRunning: true)

        guard case .idle(let summary) = resolver.resolve(previous: nil) else {
            Issue.record("expected idle")
            return
        }
        #expect(summary.pid == 4102)
        #expect(summary.sdkVersion == "9.1.0")
        #expect(summary.device == "fenix6xpro")
    }

    @Test("no activity and a runtime record naming a dead pid is no simulator")
    func deadSimulatorPidIsNoSimulator() {
        let resolver = makeResolver(
            active: nil,
            runtime: sampleRuntime(),
            snapshot: .success(sampleSnapshot()),
            simulatorRunning: false)

        guard case .noSimulator = resolver.resolve(previous: nil) else {
            Issue.record("expected noSimulator")
            return
        }
    }

    @Test("no activity and no runtime record is no simulator")
    func emptyStateIsNoSimulator() {
        let resolver = makeResolver(
            active: nil, runtime: nil, snapshot: .success(nil), simulatorRunning: false)

        guard case .noSimulator = resolver.resolve(previous: nil) else {
            Issue.record("expected noSimulator")
            return
        }
    }
}

private enum SampleProbeFailure: Error { case opaque }

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func count() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

private func sampleSnapshot() -> ProcessIdentitySnapshot {
    ProcessIdentitySnapshot(
        pid: 4711,
        parentPid: 4700,
        processGroupId: 4710,
        start: ProcessStartIdentity(seconds: 1_785_932_401, microseconds: 143_220),
        executablePath: "/Users/dev/.simulator-mcp/bin/simulator-mcp",
        arguments: ["/Users/dev/.simulator-mcp/bin/simulator-mcp"])
}

private func sampleActive() -> ActiveOperation {
    ActiveOperation(
        operation: "press_button",
        owner: sampleSnapshot().stableIdentity,
        startedEpochSeconds: 1_785_932_487.5)
}

private func sampleRuntime() -> RuntimeRecord {
    RuntimeRecord(
        simulatorPid: 4102,
        executablePath: "/SDK/bin/ConnectIQ.app/Contents/MacOS/simulator",
        sdkPath: "/SDK",
        sdkVersion: "9.1.0",
        currentDevice: "fenix6xpro",
        monkeydoOwnership: nil)
}

private func makeResolver(
    active: ActiveOperation?,
    runtime: RuntimeRecord?,
    snapshot: Result<ProcessIdentitySnapshot?, Error>,
    simulatorRunning: Bool
) -> MonitorStateResolver {
    MonitorStateResolver(
        readActivity: { active },
        readRuntime: { runtime },
        snapshot: { _ in try snapshot.get() },
        simulatorPresence: { _, _ in simulatorRunning })
}
