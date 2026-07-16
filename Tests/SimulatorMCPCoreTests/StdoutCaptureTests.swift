import Foundation
import Testing

@Suite("Stdout capture serializer", .serialized)
struct StdoutCaptureTests {
    @Test("a cancelled queued capture is removed and never redirects stdout later")
    func cancelledWaiterNeverCaptures() async throws {
        let holderGate = StdoutCaptureGate()
        let bodyRecorder = StdoutCaptureRecorder()

        let holder = Task {
            try await captureStdout {
                await holderGate.wait()
            }
        }
        #expect(await waitForStdoutCapture { await stdoutCaptureQueueDepth() == 1 })

        let cancelled = Task {
            try await captureStdout {
                await bodyRecorder.recordRun()
            }
        }
        #expect(await waitForStdoutCapture { await stdoutCaptureQueueDepth() == 2 })

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("the cancelled queued capture unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        #expect(await waitForStdoutCapture { await stdoutCaptureQueueDepth() == 1 })

        await holderGate.open()
        _ = try await holder.value

        let finalCapture = try await captureStdout {}
        #expect(finalCapture.isEmpty)
        #expect(await bodyRecorder.runCount == 0)
        #expect(await stdoutCaptureQueueDepth() == 0)
    }
}

private actor StdoutCaptureGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
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

private func waitForStdoutCapture(
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<10_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}
