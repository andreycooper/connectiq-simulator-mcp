import Foundation

/// In-process serialization for simulator operations.
///
/// Actor isolation alone is reentrant at `await`; this actor therefore keeps
/// an explicit active permit and resumes queued callers in strict arrival
/// order. The timeout applies only while waiting for the permit.
public actor AsyncFIFO {
    private final class Waiter {
        let id: UUID
        let operation: String
        let deadline: ClockDeadline
        let continuation: CheckedContinuation<Void, Error>
        var timeoutTask: Task<Void, Never>?

        init(
            id: UUID,
            operation: String,
            deadline: ClockDeadline,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.id = id
            self.operation = operation
            self.deadline = deadline
            self.continuation = continuation
        }
    }

    private let makeDeadline: @Sendable (Duration) -> ClockDeadline
    private var activeID: UUID?
    private var activeOperation: String?
    private var waiters: [Waiter] = []

    public init() {
        let clock = ContinuousClock()
        makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    public init<C: Clock>(clock: C) where C.Duration == Duration {
        makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    /// Internal observability used by deterministic coordination tests.
    var queueDepth: Int { (activeID == nil ? 0 : 1) + waiters.count }

    public func withLock<T: Sendable>(
        operation: String,
        timeout: Duration,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        guard !operation.isEmpty else {
            throw invalidArguments("operation must not be empty")
        }
        guard timeout >= .zero else {
            throw invalidArguments("timeout must be zero or positive")
        }
        let deadline = makeDeadline(timeout)
        let id = UUID()
        try await acquire(id: id, operation: operation, deadline: deadline)

        do {
            // Cancellation may race the actor message that grants this
            // permit. Re-check before entering the body so a caller that was
            // cancelled while queued can never perform simulator work later.
            try Task.checkCancellation()
            let result = try await body()
            release(id: id)
            return result
        } catch {
            release(id: id)
            throw error
        }
    }

    private func acquire(id: UUID, operation: String, deadline: ClockDeadline) async throws {
        try Task.checkCancellation()
        if activeID == nil {
            activeID = id
            activeOperation = operation
            return
        }
        guard !deadline.hasExpired else {
            throw busyError(waitingOperation: operation)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let waiter = Waiter(
                    id: id,
                    operation: operation,
                    deadline: deadline,
                    continuation: continuation)
                waiters.append(waiter)
                waiter.timeoutTask = Task {
                    do {
                        try await deadline.sleepUntilDeadline()
                        self.timeoutWaiter(id: id)
                    } catch {
                        // Cancellation means the waiter was granted, caller
                        // cancellation removed it, or the FIFO was torn down.
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func timeoutWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(throwing: busyError(waitingOperation: waiter.operation))
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        activeOperation = nil
        grantNext()
    }

    private func grantNext() {
        guard activeID == nil else { return }
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.timeoutTask?.cancel()
            if waiter.deadline.hasExpired {
                waiter.continuation.resume(
                    throwing: busyError(waitingOperation: waiter.operation))
                continue
            }
            activeID = waiter.id
            activeOperation = waiter.operation
            waiter.continuation.resume()
            return
        }
    }

    private func invalidArguments(_ reason: String) -> ToolError {
        ToolError(
            code: "invalid_arguments",
            message: "Invalid simulator queue arguments: \(reason).",
            fix: "Provide a non-empty operation and a timeout that is zero or positive."
        )
    }

    private func busyError(waitingOperation: String) -> ToolError {
        ToolError(
            code: "simulator_busy",
            message: "Simulator operation '\(waitingOperation)' timed out waiting for the local operation queue.",
            fix: "Wait for the current simulator operation to finish, then retry.",
            details: [
                "currentOperation": activeOperation.map(JSONValue.string) ?? .null,
                "waitingOperation": .string(waitingOperation),
            ]
        )
    }
}
