import Foundation
import Testing

@Suite("Stdout capture serializer", .serialized)
struct StdoutCaptureTests {
    @Test("a cancelled queued capture is removed and never redirects stdout later")
    func cancelledWaiterNeverCaptures() async throws {
        let holderGate = StdoutCaptureGate()
        let bodyRecorder = StdoutCaptureRecorder()
        let waiterQueued = StdoutCaptureSignal()

        let holder = Task {
            try await captureStdout {
                await holderGate.wait()
            }
        }
        await holderGate.waitUntilStarted()

        let cancelled = Task {
            try await captureStdout({
                await bodyRecorder.recordRun()
            }, onQueued: {
                waiterQueued.signal()
            })
        }
        await waiterQueued.wait()

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("the cancelled queued capture unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        await holderGate.open()
        _ = try await holder.value

        let finalCapture = try await captureStdout {}
        #expect(finalCapture.isEmpty)
        #expect(await bodyRecorder.runCount == 0)
    }
}

private actor StdoutCaptureGate {
    private var hasStarted = false
    private var isOpen = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasStarted = true
        let pending = startWaiters
        startWaiters.removeAll()
        for waiter in pending { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor StdoutCaptureRecorder {
    private(set) var runCount = 0
    func recordRun() { runCount += 1 }
}

private final class StdoutCaptureSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
