import Foundation
import Testing

@Suite("FakeClock")
struct FakeClockTests {
    @Test("cancellation before sleep registration cannot strand the sleeper")
    func testCancellationBeforeRegistration() async {
        let clock = FakeClock()
        let gate = ClockStartGate()
        let result = ClockSleepResult()

        let sleeper = Task {
            await gate.wait()
            do {
                try await clock.sleep(for: .seconds(1))
                await result.set("slept")
            } catch is CancellationError {
                await result.set("cancelled")
            } catch {
                await result.set("unexpected")
            }
        }
        #expect(await waitUntilFakeClock { await gate.waiterCount == 1 })

        sleeper.cancel()
        await gate.open()

        let completed = await waitUntilFakeClock { await result.value != nil }
        #expect(completed, "a pre-cancelled sleeper must finish without clock advancement")
        #expect(await result.value == "cancelled")

        // Cleanup keeps a RED run bounded if the old registration race
        // strands the continuation.
        if !completed { clock.advance(by: .seconds(1)) }
        await sleeper.value
    }
}

private actor ClockStartGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ClockSleepResult {
    private(set) var value: String?
    func set(_ value: String) { self.value = value }
}

private func waitUntilFakeClock(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
