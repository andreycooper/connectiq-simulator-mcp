import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("Activity lifecycle inside withOperation")
struct ActivityLifecycleTests {
    @Test("the lease is held while activity is published and cleared")
    func leaseIsHeldDuringBothWrites() async throws {
        let observations = HoldObserver()
        let sdk = sampleSDK(version: "9.1.0")
        let probe = LeaseHolderProbe()
        let fixture = try ControllerFixture(
            activityStore: ActivityStore(
                activityFile: FileManager.default.temporaryDirectory
                    .appending(path: "activity-\(UUID().uuidString).json"),
                atomicPublish: { target, data in
                    observations.record(probe.isHeld())
                    try AtomicFile.replace(at: target, with: data)
                }))
        probe.install(fixture.externalLease)
        defer { fixture.tearDown() }
        await fixture.system.setProcesses([])
        await fixture.system.setLaunchIdentity(sdk: sdk, pid: 4100)

        _ = try await fixture.controller.withOperation(
            .simStart, requirement: .start(requested: sdk)
        ) { $0 }

        #expect(observations.held.count == 2)
        #expect(observations.held.allSatisfy { $0 })
    }

    @Test("clear runs exactly once when the body succeeds")
    func clearRunsOnceOnSuccess() async throws {
        let counter = WriteCounter()
        let store = countingStore(counter)
        let fixture = try ControllerFixture(activityStore: store)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([])
        await fixture.system.setLaunchIdentity(sdk: sdk, pid: 4100)

        _ = try await fixture.controller.withOperation(
            .simStart, requirement: .start(requested: sdk)
        ) { $0 }

        #expect(counter.publishes == 1)
        #expect(counter.clears == 1)
        #expect(store.read() == nil)
    }

    @Test("clear runs exactly once when the body throws")
    func clearRunsOnceOnFailure() async throws {
        let counter = WriteCounter()
        let store = countingStore(counter)
        let fixture = try ControllerFixture(activityStore: store)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([])
        await fixture.system.setLaunchIdentity(sdk: sdk, pid: 4100)

        await #expect(throws: SampleFailure.self) {
            _ = try await fixture.controller.withOperation(
                .simStart, requirement: .start(requested: sdk)
            ) { _ in throw SampleFailure.expected }
        }

        #expect(counter.publishes == 1)
        #expect(counter.clears == 1)
        #expect(store.read() == nil)
    }

    @Test("clear runs exactly once when the body is cancelled")
    func clearRunsOnceOnCancellation() async throws {
        let counter = WriteCounter()
        let store = countingStore(counter)
        let fixture = try ControllerFixture(activityStore: store)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([])
        await fixture.system.setLaunchIdentity(sdk: sdk, pid: 4100)

        await #expect(throws: CancellationError.self) {
            _ = try await fixture.controller.withOperation(
                .simStart, requirement: .start(requested: sdk)
            ) { _ in throw CancellationError() }
        }

        #expect(counter.publishes == 1)
        #expect(counter.clears == 1)
        #expect(store.read() == nil)
    }

    @Test("a lease acquisition that times out never publishes")
    func failedAcquireNeverPublishes() async throws {
        let counter = WriteCounter()
        let store = countingStore(counter)
        let fixture = try ControllerFixture(activityStore: store)
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        let token = try await fixture.externalLease.acquire(
            operation: "external", timeout: .seconds(5))
        defer { try? token.release() }

        await #expect(throws: ToolError.self) {
            _ = try await fixture.controller.withOperation(
                .simStart, requirement: .start(requested: sdk), leaseTimeout: .zero
            ) { $0 }
        }

        #expect(counter.publishes == 0)
        #expect(counter.clears == 0)
        #expect(store.read() == nil)
    }

    @Test("the published record names the running operation")
    func publishedRecordNamesTheOperation() async throws {
        let seen = OperationCapture()
        let fixture = try ControllerFixture(
            activityStore: ActivityStore(
                activityFile: FileManager.default.temporaryDirectory
                    .appending(path: "activity-\(UUID().uuidString).json"),
                atomicPublish: { target, data in
                    try AtomicFile.replace(at: target, with: data)
                    if let active = try? JSONDecoder().decode(
                        ActivityEnvelope.self, from: data
                    ).active {
                        seen.record(active.operation)
                    }
                }))
        defer { fixture.tearDown() }
        let sdk = sampleSDK(version: "9.1.0")
        await fixture.system.setProcesses([])
        await fixture.system.setLaunchIdentity(sdk: sdk, pid: 4100)

        _ = try await fixture.controller.withOperation(
            .simStart, requirement: .start(requested: sdk)
        ) { $0 }

        #expect(seen.names == ["sim_start"])
    }
}

private enum SampleFailure: Error { case expected }

/// The fixture owns the lock file, so its lease only exists after `init`
/// returns — but the store's closure has to be built before it. A box breaks
/// the knot. Swift 6 rejects the obvious alternative: a `@Sendable` closure
/// cannot capture a mutable local, so `var fixture: ControllerFixture!` is a
/// compile error, not a shortcut.
private final class LeaseHolderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: SimLease?

    func install(_ lease: SimLease) { lock.withLock { self.lease = lease } }

    func isHeld() -> Bool {
        guard let lease = lock.withLock({ self.lease }) else { return false }
        return ((try? lease.holder()) ?? nil) != nil
    }
}

private func countingStore(_ counter: WriteCounter) -> ActivityStore {
    ActivityStore(
        activityFile: FileManager.default.temporaryDirectory
            .appending(path: "activity-\(UUID().uuidString).json"),
        atomicPublish: { target, data in
            if let active = try? JSONDecoder().decode(ActivityEnvelope.self, from: data).active,
                !active.operation.isEmpty
            {
                counter.countPublish()
            } else {
                counter.countClear()
            }
            try AtomicFile.replace(at: target, with: data)
        })
}

private final class HoldObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    var held: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var publishCount = 0
    private var clearCount = 0

    var publishes: Int {
        lock.lock()
        defer { lock.unlock() }
        return publishCount
    }

    var clears: Int {
        lock.lock()
        defer { lock.unlock() }
        return clearCount
    }

    func countPublish() {
        lock.lock()
        defer { lock.unlock() }
        publishCount += 1
    }

    func countClear() {
        lock.lock()
        defer { lock.unlock() }
        clearCount += 1
    }
}

private final class OperationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
}
