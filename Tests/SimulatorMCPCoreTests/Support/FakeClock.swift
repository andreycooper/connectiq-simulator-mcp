import Foundation

/// A manually-advanced clock conforming to Swift's `Clock` protocol, for
/// deterministic tests of deadline logic without waiting on real time.
/// Mirrors `ContinuousClock`'s shape (`now`, `sleep(until:tolerance:)`) so
/// any production code written against `any Clock<Duration>` — such as
/// `ClockSupport.withDeadline` — can be driven by this instead of real time.
///
/// `SubprocessTests` uses short *real* durations against `/bin/sleep` for
/// timeout/termination coverage, because that race
/// ultimately depends on a real child process actually exiting, which a
/// fake clock cannot accelerate. `FakeClock` is provided here, fully
/// working, for later tasks whose deadlines guard pure in-process polling
/// (simulator readiness, lease acquisition) where no real subprocess sits
/// in the loop.
///
/// `sleep(until:tolerance:)` is cancellation-aware: a sleeper that is never
/// reached by `advance(by:)` but whose task is cancelled resumes promptly
/// with `CancellationError` instead of hanging forever, matching
/// `ContinuousClock`'s own cancellation behavior.
public final class FakeClock: Clock, @unchecked Sendable {
    private enum SleepRegistration {
        case waiting
        case due
        case cancelled
    }

    public struct Instant: InstantProtocol {
        fileprivate let offset: Duration

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        public static func == (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset == rhs.offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }
    }

    private let lock = NSLock()
    private var currentOffset: Duration = .zero
    private var waiters: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var registrationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    public var now: Instant {
        withLock { Instant(offset: currentOffset) }
    }

    public var minimumResolution: Duration { .zero }

    /// Test-only observability for proving a polling operation has reached
    /// its cancellation-aware suspension before cancelling it.
    public var pendingSleepCount: Int { withLock { waiters.count } }

    /// Deterministic registration handshake for tests that must prove a
    /// deadline sleeper exists before advancing the fake clock. This avoids
    /// scheduler-dependent `Task.yield()` loops at call sites.
    public func waitUntilPendingSleepCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = withLock {
                if waiters.count >= count { return true }
                registrationWaiters.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (registration, ready) = withLock { () -> (SleepRegistration, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (.cancelled, []) }
                    if currentOffset >= deadline.offset { return (.due, []) }
                    waiters[id] = (deadline, continuation)
                    let ready = registrationWaiters.filter { waiters.count >= $0.count }.map(\.continuation)
                    registrationWaiters.removeAll { waiters.count >= $0.count }
                    return (.waiting, ready)
                }
                ready.forEach { $0.resume() }
                switch registration {
                case .waiting:
                    break
                case .due:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    /// Advances the fake clock by `duration`, resuming (in deadline order)
    /// every sleeper whose deadline has now passed.
    public func advance(by duration: Duration) {
        let ready: [CheckedContinuation<Void, Error>] = withLock {
            currentOffset += duration
            let due =
                waiters
                .filter { $0.value.deadline.offset <= currentOffset }
                .sorted { $0.value.deadline.offset < $1.value.deadline.offset }
            for (id, _) in due {
                waiters.removeValue(forKey: id)
            }
            return due.map(\.value.continuation)
        }
        ready.forEach { $0.resume() }
    }

    /// Test hook for deadline consumers that must detect expiry themselves
    /// even when a clock sleeper has not yet won executor scheduling.
    public func advanceWithoutResuming(by duration: Duration) {
        withLock { currentOffset += duration }
    }

    private func cancelWaiter(id: UUID) {
        let removed = withLock { waiters.removeValue(forKey: id) }
        removed?.continuation.resume(throwing: CancellationError())
    }

    /// `NSLock.lock()`/`unlock()` are `noasync`-annotated; wrapping them in
    /// a synchronous helper keeps every call site (including ones inside
    /// `async` functions) compiling under Swift 6 strict concurrency.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
