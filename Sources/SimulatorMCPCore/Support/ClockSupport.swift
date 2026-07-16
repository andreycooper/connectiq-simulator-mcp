/// Shared `ContinuousClock`-based deadline racing.
///
/// This codebase never uses `Date` for timing (see AGENTS.md): every
/// deadline — subprocess timeouts, simulator-ready polling, lease
/// acquisition — is measured on `ContinuousClock`. `ClockSupport.withDeadline`
/// is the one place that races an operation against a clock-driven deadline,
/// so every task that needs "do X, but give up after N seconds" shares the
/// same, tested, cancellation-safe implementation instead of hand-rolling a
/// task group.
///
/// - Important: `operation` must respond to task cancellation reasonably
///   promptly (checking `Task.isCancelled`, using a cancellation-aware
///   continuation, or calling another `Clock`/`Task.sleep` API, all of
///   which already do). `withThrowingTaskGroup` cannot forcibly stop a
///   child task — losing the race only cancels `operation`'s task
///   advisorily; if `operation` never observes that, this function will not
///   return until `operation` finishes on its own, regardless of the
///   deadline. Callers whose operation cannot be made cancellation-aware
///   (for example, waiting for an OS process to exit) must force real
///   completion themselves (e.g. by killing the process) before relying on
///   `withDeadline` having returned.
public enum ClockSupport {
    /// Thrown when `duration` elapses on `clock` before `operation` finishes.
    public struct DeadlineExceeded: Error, Sendable {}

    /// Races `operation` against `duration` measured on `clock`. Returns
    /// `operation`'s result if it finishes first; throws `DeadlineExceeded`
    /// if the deadline elapses first.
    public static func withDeadline<T: Sendable>(
        _ duration: Duration,
        clock: any Clock<Duration>,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await clock.sleep(for: duration)
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                // Unreachable: the group always has exactly two tasks, so
                // `next()` cannot return `nil` on its first call.
                throw DeadlineExceeded()
            }
            return result
        }
    }
}

/// Type-erased absolute deadline over an injected monotonic `Clock`.
///
/// Capturing the clock's concrete `Instant` once avoids relative-sleep drift
/// and lets the owning actor check expiry even when the sleeper task has not
/// yet been scheduled after its deadline.
struct ClockDeadline: Sendable {
    private let expired: @Sendable () -> Bool
    private let remainingBody: @Sendable () -> Duration
    private let sleepUntilDeadlineBody: @Sendable () async throws -> Void
    private let sleepUntilNextPollBody: @Sendable (Duration) async throws -> Void

    init<C: Clock>(clock: C, timeout: Duration) where C.Duration == Duration {
        let deadline = clock.now.advanced(by: timeout)
        expired = { clock.now >= deadline }
        remainingBody = { max(.zero, clock.now.duration(to: deadline)) }
        sleepUntilDeadlineBody = { try await clock.sleep(until: deadline, tolerance: nil) }
        sleepUntilNextPollBody = { maximumInterval in
            let nextPoll = clock.now.advanced(by: maximumInterval)
            try await clock.sleep(until: min(nextPoll, deadline), tolerance: nil)
        }
    }

    var hasExpired: Bool { expired() }
    var remaining: Duration { remainingBody() }

    func sleepUntilDeadline() async throws {
        try await sleepUntilDeadlineBody()
    }

    func sleepUntilNextPoll(maximumInterval: Duration) async throws {
        try await sleepUntilNextPollBody(maximumInterval)
    }
}
