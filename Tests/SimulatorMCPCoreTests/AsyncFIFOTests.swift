import Foundation
import Testing

@testable import SimulatorMCPCore

/// Contract: `AsyncFIFO` is the in-process serialization layer (AGENTS.md —
/// actor isolation is reentrant at `await` and is NOT serialization).
/// Waiters acquire in strict arrival order, exactly one body runs at a time
/// across its await points, and the supplied timeout bounds *waiting only*:
/// once a body starts it is never interrupted by its own timeout.
///
/// `queueDepth` (running body + waiters) is internal test observability so
/// the suite can prove deterministic enqueue/removal without exposing a
/// production API that is not part of the plan.
///
/// Every test drives deadlines on `FakeClock`; nothing here waits on real
/// time. The checked continuations inside the FIFO make double-resume a
/// crash, so every passing run is also evidence no continuation resumes
/// twice.
@Suite("AsyncFIFO")
struct AsyncFIFOTests {

    // MARK: - Ordering

    @Test("100 waiters acquire in strict arrival order")
    func testFifoOrderAcross100Tasks() async throws {
        let clock = FakeClock()
        let fifo = AsyncFIFO(clock: clock)
        let gate = Gate()
        let recorder = Recorder()

        let holder = Task {
            try await fifo.withLock(operation: "holder", timeout: .seconds(1)) {
                await gate.wait()
            }
        }
        let holderRunning = await waitUntil { await fifo.queueDepth == 1 }
        #expect(holderRunning)

        var waiters: [Task<Void, Error>] = []
        for index in 0..<100 {
            let task = Task {
                try await fifo.withLock(operation: "op-\(index)", timeout: .seconds(3600)) {
                    await recorder.record(index)
                }
            }
            waiters.append(task)
            // Only release the next waiter once this one is provably
            // enqueued, so arrival order is deterministic.
            let enqueued = await waitUntil { await fifo.queueDepth == index + 2 }
            #expect(enqueued)
        }

        await gate.open()
        for task in waiters {
            try await task.value
        }
        try await holder.value

        let entries = await recorder.entries
        #expect(entries == Array(0..<100))
        let drained = await fifo.queueDepth
        #expect(drained == 0)
    }

    @Test("exactly one body runs at a time across await points")
    func testOneBodyAtATime() async throws {
        let fifo = AsyncFIFO(clock: FakeClock())
        let meter = ConcurrencyMeter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await fifo.withLock(operation: "op-\(index)", timeout: .seconds(3600)) {
                        await meter.enter()
                        // Suspend inside the body: reentrancy at these
                        // awaits must not admit a second body.
                        await Task.yield()
                        await Task.yield()
                        await meter.exit()
                    }
                }
            }
            try await group.waitForAll()
        }

        let peak = await meter.peak
        #expect(peak == 1)
    }

    // MARK: - Queue timeout

    @Test("a timed-out waiter is removed, never runs, and later FIFO order is preserved")
    func testQueueTimeoutRemovesOnlyThatWaiter() async throws {
        let clock = FakeClock()
        let fifo = AsyncFIFO(clock: clock)
        let gate = Gate()
        let recorder = Recorder()

        // The holder acquired immediately with timeout 1 s; advancing the
        // clock past that below must NOT interrupt its running body —
        // timeouts bound waiting only.
        let holder = Task {
            try await fifo.withLock(operation: "long-op", timeout: .seconds(1)) {
                await gate.wait()
            }
        }
        let holderRunning = await waitUntil { await fifo.queueDepth == 1 }
        #expect(holderRunning)

        let impatient = Task {
            try await fifo.withLock(operation: "impatient", timeout: .seconds(1)) {
                await recorder.record(99)
            }
        }
        let impatientQueued = await waitUntil { await fifo.queueDepth == 2 }
        #expect(impatientQueued)

        let patientB = Task {
            try await fifo.withLock(operation: "patient-b", timeout: .seconds(1000)) {
                await recorder.record(1)
            }
        }
        let bQueued = await waitUntil { await fifo.queueDepth == 3 }
        #expect(bQueued)

        let patientC = Task {
            try await fifo.withLock(operation: "patient-c", timeout: .seconds(1000)) {
                await recorder.record(2)
            }
        }
        let cQueued = await waitUntil { await fifo.queueDepth == 4 }
        #expect(cQueued)

        clock.advance(by: .seconds(2))

        do {
            try await impatient.value
            Issue.record("the 1 s waiter must time out behind the held lock")
        } catch let error as ToolError {
            #expect(error.code == "simulator_busy")
            #expect(!error.fix.isEmpty)
            #expect(error.details?["currentOperation"] == .string("long-op"))
        }

        let shrunk = await waitUntil { await fifo.queueDepth == 3 }
        #expect(shrunk, "only the timed-out waiter leaves the queue")

        await gate.open()
        try await holder.value
        try await patientB.value
        try await patientC.value

        let entries = await recorder.entries
        #expect(entries == [1, 2], "timed-out body never runs; survivors keep FIFO order")
    }

    // MARK: - Release on throw and cancellation

    @Test("a throwing body releases the next waiter")
    func testThrowingBodyReleasesNextWaiter() async throws {
        struct Boom: Error {}
        let fifo = AsyncFIFO(clock: FakeClock())
        let gate = Gate()

        let thrower = Task {
            try await fifo.withLock(operation: "boom", timeout: .seconds(1)) {
                await gate.wait()
                throw Boom()
            }
        }
        let throwerRunning = await waitUntil { await fifo.queueDepth == 1 }
        #expect(throwerRunning)

        let waiter = Task {
            try await fifo.withLock(operation: "next", timeout: .seconds(1000)) {
                7
            }
        }
        let waiterQueued = await waitUntil { await fifo.queueDepth == 2 }
        #expect(waiterQueued)

        await gate.open()
        do {
            try await thrower.value
            Issue.record("the body's error must propagate to the caller")
        } catch is Boom {
            // expected
        }

        let value = try await waiter.value
        #expect(value == 7)
    }

    @Test("a cancelled running body releases the next waiter")
    func testCancelledBodyReleasesNextWaiter() async throws {
        let clock = FakeClock()
        let fifo = AsyncFIFO(clock: clock)

        let cancelled = Task {
            try await fifo.withLock(operation: "cancelled-body", timeout: .seconds(1)) {
                // Cancellation-aware suspension: FakeClock.sleep resumes
                // with CancellationError when its task is cancelled.
                try await clock.sleep(for: .seconds(10_000))
            }
        }
        let bodyRunning = await waitUntil { await fifo.queueDepth == 1 }
        #expect(bodyRunning)

        let waiter = Task {
            try await fifo.withLock(operation: "next", timeout: .seconds(1000)) {
                7
            }
        }
        let waiterQueued = await waitUntil { await fifo.queueDepth == 2 }
        #expect(waiterQueued)

        cancelled.cancel()
        do {
            try await cancelled.value
            Issue.record("the cancelled body must surface its cancellation")
        } catch is CancellationError {
            // expected
        } catch let error as ToolError {
            Issue.record("cancellation must not be masked as ToolError \(error.code)")
        }

        let value = try await waiter.value
        #expect(value == 7)
    }

    @Test("a cancelled waiter is removed and never acquires later")
    func testCancelledWaiterNeverAcquires() async throws {
        let clock = FakeClock()
        let fifo = AsyncFIFO(clock: clock)
        let gate = Gate()
        let recorder = Recorder()

        let holder = Task {
            try await fifo.withLock(operation: "holder", timeout: .seconds(1)) {
                await gate.wait()
            }
        }
        let holderRunning = await waitUntil { await fifo.queueDepth == 1 }
        #expect(holderRunning)

        let doomed = Task {
            try await fifo.withLock(operation: "doomed", timeout: .seconds(1000)) {
                await recorder.record(13)
            }
        }
        let doomedQueued = await waitUntil { await fifo.queueDepth == 2 }
        #expect(doomedQueued)

        doomed.cancel()
        do {
            try await doomed.value
            Issue.record("the cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        }
        let removed = await waitUntil { await fifo.queueDepth == 1 }
        #expect(removed, "the cancelled waiter leaves the queue immediately")

        await gate.open()
        try await holder.value

        // The lock is now free; if the cancelled waiter were still
        // enqueued it would acquire here. Prove the queue is clean by
        // running one more operation through it.
        let value = try await fifo.withLock(operation: "after", timeout: .seconds(1)) { 42 }
        #expect(value == 42)

        let entries = await recorder.entries
        #expect(entries.isEmpty, "a cancelled waiter's body must never run")
    }

    @Test("grant racing timeout or cancellation never resumes a waiter twice")
    func testGrantRaceNeverDoubleResumes() async throws {
        for iteration in 0..<100 {
            let clock = FakeClock()
            let fifo = AsyncFIFO(clock: clock)
            let gate = Gate()

            let holder = Task {
                try await fifo.withLock(operation: "holder", timeout: .seconds(1)) {
                    await gate.wait()
                }
            }
            #expect(await waitUntil { await fifo.queueDepth == 1 })

            let waiter = Task {
                try await fifo.withLock(operation: "racer", timeout: .seconds(1)) { iteration }
            }
            #expect(await waitUntil { await fifo.queueDepth == 2 })

            if iteration.isMultiple(of: 2) {
                // Make the deadline and release runnable together. Either
                // result is legal; a double continuation resume is not.
                let release = Task { await gate.open() }
                clock.advance(by: .seconds(1))
                await release.value
                do {
                    let value = try await waiter.value
                    #expect(value == iteration)
                } catch let error as ToolError {
                    #expect(error.code == "simulator_busy")
                }
            } else {
                // Make cancellation and release runnable together. A grant
                // that wins may finish; cancellation that wins must remove
                // the waiter permanently.
                let release = Task { await gate.open() }
                waiter.cancel()
                await release.value
                do {
                    let value = try await waiter.value
                    #expect(value == iteration)
                } catch is CancellationError {
                    // expected when cancellation wins
                }
            }

            try await holder.value
            #expect(await waitUntil { await fifo.queueDepth == 0 })
            let after = try await fifo.withLock(operation: "after", timeout: .seconds(1)) { 7 }
            #expect(after == 7)
        }
    }

    @Test("a waiter at its absolute deadline times out even when its timeout task is delayed")
    func testExpiredWaiterIsNotGrantedByReleaseRace() async throws {
        let clock = FakeClock()
        let fifo = AsyncFIFO(clock: clock)
        let gate = Gate()
        let recorder = Recorder()

        let holder = Task {
            try await fifo.withLock(operation: "holder", timeout: .seconds(1)) {
                await gate.wait()
            }
        }
        #expect(await waitUntil { await fifo.queueDepth == 1 })

        let waiter = Task {
            try await fifo.withLock(operation: "expired", timeout: .milliseconds(10)) {
                await recorder.record(1)
            }
        }
        #expect(await waitUntil { await fifo.queueDepth == 2 })
        #expect(await waitUntil { clock.pendingSleepCount == 1 })

        // Move `now` to the deadline but deliberately leave the timeout
        // sleeper suspended. grantNext must inspect the absolute deadline;
        // it cannot depend on the timeout task winning actor scheduling.
        clock.advanceWithoutResuming(by: .milliseconds(10))
        await gate.open()
        try await holder.value

        do {
            try await waiter.value
            Issue.record("an expired waiter must not enter its body")
        } catch let error as ToolError {
            #expect(error.code == "simulator_busy")
            #expect(error.details?["currentOperation"] == .null)
        }
        #expect(await recorder.entries == [])
        #expect(await fifo.queueDepth == 0)
    }

    @Test("invalid operation and negative timeout return invalid_arguments")
    func testInvalidArgumentsAreToolErrors() async throws {
        let fifo = AsyncFIFO(clock: FakeClock())

        do {
            _ = try await fifo.withLock(operation: "negative", timeout: .milliseconds(-1)) { 1 }
            Issue.record("negative timeout must throw invalid_arguments")
            return  // avoid reaching the current empty-operation precondition during RED
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        }

        do {
            _ = try await fifo.withLock(operation: "", timeout: .seconds(1)) { 1 }
            Issue.record("empty operation must throw invalid_arguments")
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("zero timeout acquires immediately when the FIFO is free")
    func testZeroTimeoutAcquiresFreeFIFO() async throws {
        let fifo = AsyncFIFO(clock: FakeClock())

        let value = try await fifo.withLock(operation: "no-wait", timeout: .zero) { 42 }

        #expect(value == 42)
        #expect(await fifo.queueDepth == 0)
    }

    @Test("zero timeout returns simulator_busy without running when the FIFO is occupied")
    func testZeroTimeoutRejectsOccupiedFIFO() async throws {
        let fifo = AsyncFIFO(clock: FakeClock())
        let gate = Gate()
        let recorder = Recorder()
        let holder = Task {
            try await fifo.withLock(operation: "holder", timeout: .seconds(1)) {
                await gate.wait()
            }
        }
        #expect(await waitUntil { await fifo.queueDepth == 1 })

        do {
            try await fifo.withLock(operation: "no-wait", timeout: .zero) {
                await recorder.record(1)
            }
            Issue.record("occupied zero-timeout FIFO must return simulator_busy")
        } catch let error as ToolError {
            #expect(error.code == "simulator_busy")
            #expect(error.details?["currentOperation"] == .string("holder"))
        }

        #expect(await recorder.entries == [])
        await gate.open()
        try await holder.value
    }
}

// MARK: - Test helpers

/// Suspends waiters until opened. Opening is idempotent and releases
/// everyone; used to hold a FIFO body at a controlled suspension point.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Records the order FIFO bodies ran in.
private actor Recorder {
    private(set) var entries: [Int] = []

    func record(_ value: Int) {
        entries.append(value)
    }
}

/// Tracks how many FIFO bodies are inside their critical section at once.
private actor ConcurrencyMeter {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
    }
}

/// Yields until `condition` holds. Bounded so a broken FIFO fails the test
/// instead of hanging it; no real time is involved anywhere in this suite.
private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
