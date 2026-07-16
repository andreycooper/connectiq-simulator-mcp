import Foundation

/// The result of a finished child process.
public struct ProcessOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A launched child process.
///
/// Conformances are actors with `nonisolated let pid`, so callers can read
/// the pid without `await` while `wait()`/`terminate(grace:)` stay isolated.
public protocol RunningProcess: Sendable {
    var pid: Int32 { get }

    /// Awaits the child's natural exit and the complete drain of its
    /// stdout/stderr, returning the assembled result. If `start(...)` was
    /// given a `timeout` and it elapses first, the child is terminated and
    /// this throws `ToolError(code: "operation_timeout", ...)` instead of
    /// returning. If the calling `Task` is cancelled while this is
    /// suspended, the child is terminated and this throws `CancellationError`.
    func wait() async throws -> ProcessOutput

    /// Sends `SIGTERM`, waits up to `grace` for the child to exit, then
    /// sends `SIGKILL` if it is still alive, then closes every file handle
    /// this process owns. Safe to call more than once and safe to call
    /// whether or not the child has already exited.
    func terminate(grace: Duration) async
}

extension RunningProcess {
    public func terminate() async {
        await terminate(grace: .seconds(5))
    }
}

/// Launches child processes.
public protocol ProcessRunning: Sendable {
    /// Starts `executable`, always piping stdin/stdout/stderr (stdio is
    /// never inherited — see AGENTS.md). `onStdout`/`onStderr`, if given,
    /// are invoked with each chunk of output as it arrives, in order, in
    /// addition to it being retained for the final `ProcessOutput`.
    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess
}

/// The only production type allowed to construct `Foundation.Process` (see
/// AGENTS.md's architecture boundary). Every subprocess launch in this
/// codebase — SDK tools, simulator control, `monkeydo` test runs — goes
/// through this type so pipe wiring, streaming, timeouts, and
/// SIGTERM/SIGKILL termination are implemented exactly once.
public struct Subprocess: ProcessRunning, Sendable {
    public init() {}

    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: Duration? = nil,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> any RunningProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        // Never inherit the parent's stdio (AGENTS.md: stdout is reserved
        // for MCP framing; a child writing to its stdout must never reach
        // ours). Pipes are created and their read ends armed for draining
        // *before* `run()`, so nothing the child writes before we get
        // around to reading can overflow the pipe's kernel buffer and
        // deadlock the child (classic `Process` + `Pipe` pitfall). This
        // arming only needs the `Pipe`s themselves, not the `ManagedProcess`
        // actor, so it happens here — `Process.processIdentifier` is not
        // valid until after `run()` succeeds, so the actor (which reports
        // `pid` `nonisolated`) is only constructed once `run()` has
        // returned and a real pid exists.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        let (stdoutStream, stdoutContinuation) = AsyncStream<Data>.makeStream(of: Data.self)
        let (stderrStream, stderrContinuation) = AsyncStream<Data>.makeStream(of: Data.self)

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
            } else {
                stdoutContinuation.yield(data)
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrContinuation.finish()
            } else {
                stderrContinuation.yield(data)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            stdoutContinuation.finish()
            stderrContinuation.finish()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw Self.translateLaunchFailure(error, executable: executable)
        }

        let managed = ManagedProcess(
            process: process,
            pid: process.processIdentifier,
            stdoutHandle: stdoutHandle,
            stderrHandle: stderrHandle,
            stdoutStream: stdoutStream,
            stdoutContinuation: stdoutContinuation,
            stderrStream: stderrStream,
            stderrContinuation: stderrContinuation,
            executable: executable,
            timeout: timeout,
            clock: ContinuousClock(),
            onStdout: onStdout,
            onStderr: onStderr
        )
        await managed.armTerminationHandlerAndStartDraining()

        return managed
    }

    /// Foundation's `Process.run()` reports both "no such file" and "file
    /// exists but is not executable" as the same `NSCocoaErrorDomain` code 4
    /// (`.fileNoSuchFile`) — verified empirically on this toolchain by
    /// probing both cases directly rather than assumed. Disambiguate with
    /// `FileManager.fileExists` so the two get distinct, actionable codes.
    /// A directory passed as the executable surfaces as a genuine
    /// `NSPOSIXErrorDomain` `EACCES` instead.
    static func translateLaunchFailure(_ error: Error, executable: URL) -> ToolError {
        let nsError = error as NSError
        let fileExists = FileManager.default.fileExists(atPath: executable.path)

        let isNoSuchFile =
            nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.fileNoSuchFile.rawValue
        let isPermissionDenied =
            nsError.domain == NSPOSIXErrorDomain
            && nsError.code == POSIXErrorCode.EACCES.rawValue
        let isNoEnt =
            nsError.domain == NSPOSIXErrorDomain
            && nsError.code == POSIXErrorCode.ENOENT.rawValue

        if isPermissionDenied || (isNoSuchFile && fileExists) {
            return ToolError(
                code: "permission_denied",
                message: "\(executable.path) is not executable: \(nsError.localizedDescription)",
                fix: "Grant execute permission, e.g. `chmod +x \(executable.path)`, then retry.",
                details: ["executable": .string(executable.path)]
            )
        }

        if isNoSuchFile || isNoEnt {
            return ToolError(
                code: "executable_not_found",
                message: "\(executable.path) does not exist: \(nsError.localizedDescription)",
                fix: "Verify the path is correct and the tool is installed, then retry.",
                details: ["executable": .string(executable.path)]
            )
        }

        return ToolError(
            code: "internal_error",
            message: "Failed to launch \(executable.path): \(nsError.localizedDescription)",
            fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.",
            details: ["executable": .string(executable.path)]
        )
    }
}

/// Production `RunningProcess`. An actor with `nonisolated let pid`, backed
/// by exactly one `Foundation.Process`.
///
/// Concurrency design:
///
/// - stdout/stderr are each drained by a single, persistent, actor-isolated
///   consumer `Task` reading an `AsyncStream<Data>` fed by that pipe's
///   `FileHandle.readabilityHandler`. A single ordered consumer per stream
///   is what guarantees chunks are appended in the order they were read,
///   independent of GCD callback scheduling.
/// - Every continuation-based wait that can be on the losing side of a
///   `ClockSupport.withDeadline` race (i.e. `waitForExitStatusRaceable`)
///   is cancellation-aware via `withTaskCancellationHandler`, keyed by a
///   per-call `UUID` so cancelling one waiter never resumes another
///   concurrent waiter on the same signal. `withThrowingTaskGroup` cannot
///   forcibly stop a losing child task — it only flags it cancelled and
///   then *waits for it to finish anyway* before the group returns. A wait
///   that ignores cancellation would hang the whole race past its deadline.
/// - Losing a deadline race (run-level timeout, or the SIGTERM grace
///   period) always leads to an actual, forced completion — SIGKILL if
///   necessary — before the function that lost the race returns, so every
///   other pending waiter on the same process (stdout/stderr EOF,
///   termination) is guaranteed to resolve for real shortly afterward
///   rather than being merely abandoned.
actor ManagedProcess: RunningProcess {
    nonisolated let pid: Int32

    private let process: Process
    private let executable: URL
    private let timeout: Duration?
    private let clock: any Clock<Duration>
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let onStdout: (@Sendable (Data) -> Void)?
    private let onStderr: (@Sendable (Data) -> Void)?

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutDone = false
    private var stderrDone = false
    private var exitStatus: Int32?

    private var stdoutWaiters: [CheckedContinuation<Void, Never>] = []
    private var stderrWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitStatusWaiters: [UUID: CheckedContinuation<Int32, Error>] = [:]

    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?

    private let stdoutStream: AsyncStream<Data>
    private let stderrStream: AsyncStream<Data>

    init(
        process: Process,
        pid: Int32,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        stdoutStream: AsyncStream<Data>,
        stdoutContinuation: AsyncStream<Data>.Continuation,
        stderrStream: AsyncStream<Data>,
        stderrContinuation: AsyncStream<Data>.Continuation,
        executable: URL,
        timeout: Duration?,
        clock: any Clock<Duration>,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) {
        self.process = process
        self.pid = pid
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.stdoutStream = stdoutStream
        self.stdoutContinuation = stdoutContinuation
        self.stderrStream = stderrStream
        self.stderrContinuation = stderrContinuation
        self.executable = executable
        self.timeout = timeout
        self.clock = clock
        self.onStdout = onStdout
        self.onStderr = onStderr
    }

    /// Wires the termination handler and starts draining the two pipe
    /// streams `Subprocess.start` already armed (before `Process.run()`).
    func armTerminationHandlerAndStartDraining() {
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.recordTermination(status: status) }
        }

        Task { [weak self, stdoutStream] in
            for await chunk in stdoutStream {
                await self?.appendStdout(chunk)
            }
            await self?.markStdoutDone()
        }
        Task { [weak self, stderrStream] in
            for await chunk in stderrStream {
                await self?.appendStderr(chunk)
            }
            await self?.markStderrDone()
        }
    }

    // MARK: - RunningProcess

    func wait() async throws -> ProcessOutput {
        try await withTaskCancellationHandler {
            let output = try await self.performWait()
            if Task.isCancelled {
                throw CancellationError()
            }
            return output
        } onCancel: {
            Task { await self.terminate(grace: .seconds(5)) }
        }
    }

    func terminate(grace: Duration) async {
        guard exitStatus == nil else {
            forceCloseHandles()
            return
        }
        process.terminate()  // SIGTERM

        do {
            _ = try await ClockSupport.withDeadline(grace, clock: clock) {
                try await self.waitForExitStatusRaceable()
            }
        } catch is ClockSupport.DeadlineExceeded {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // SIGKILL is unblockable: this now resolves quickly for real.
            _ = try? await waitForExitStatusRaceable()
        } catch {
            // ClockSupport.withDeadline only introduces DeadlineExceeded;
            // `waitForExitStatusRaceable` only throws CancellationError,
            // and nothing cancels this specific call site.
            assertionFailure("unexpected terminate() error: \(error)")
        }

        forceCloseHandles()
    }

    // MARK: - Waiting

    private func performWait() async throws -> ProcessOutput {
        guard let timeout else {
            return try await finalizeResult()
        }
        do {
            _ = try await ClockSupport.withDeadline(timeout, clock: clock) {
                try await self.waitForExitStatusRaceable()
            }
        } catch is ClockSupport.DeadlineExceeded {
            await terminate(grace: .seconds(5))
            throw ToolError(
                code: "operation_timeout",
                message: "\(executable.path) did not finish within \(timeout).",
                fix:
                    "Increase the timeout, or investigate why \(executable.lastPathComponent) is hanging.",
                details: [
                    "executable": .string(executable.path),
                    "timeoutSeconds": .double(timeout.secondsDouble),
                ]
            )
        }
        return try await finalizeResult()
    }

    /// By the time this runs, the exit status is either already known
    /// (normal completion) or has just been forced (timeout/cancellation
    /// already called `terminate`), so every wait here resolves quickly.
    private func finalizeResult() async throws -> ProcessOutput {
        _ = try? await waitForExitStatusRaceable()
        await waitForStdoutDone()
        await waitForStderrDone()
        return ProcessOutput(exitCode: exitStatus ?? -1, stdout: stdoutBuffer, stderr: stderrBuffer)
    }

    private func waitForStdoutDone() async {
        if stdoutDone { return }
        await withCheckedContinuation { stdoutWaiters.append($0) }
    }

    private func waitForStderrDone() async {
        if stderrDone { return }
        await withCheckedContinuation { stderrWaiters.append($0) }
    }

    /// Cancellation-aware wait for `exitStatus`, safe to use as the losing
    /// side of a `ClockSupport.withDeadline` race: cancelling this specific
    /// call resumes only its own continuation (tracked by `id`), leaving
    /// any other concurrent waiter on the same process untouched.
    private func waitForExitStatusRaceable() async throws -> Int32 {
        if let exitStatus { return exitStatus }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exitStatusWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelExitStatusWaiter(id: id) }
        }
    }

    private func cancelExitStatusWaiter(id: UUID) {
        guard let continuation = exitStatusWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    // MARK: - Event sinks

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        onStdout?(data)
    }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        onStderr?(data)
    }

    private func markStdoutDone() {
        guard !stdoutDone else { return }
        stdoutDone = true
        let pending = stdoutWaiters
        stdoutWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func markStderrDone() {
        guard !stderrDone else { return }
        stderrDone = true
        let pending = stderrWaiters
        stderrWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// Resumed exactly once: subsequent terminations (there should be none)
    /// are ignored rather than re-resuming already-fulfilled continuations.
    private func recordTermination(status: Int32) {
        guard exitStatus == nil else { return }
        exitStatus = status
        let pending = exitStatusWaiters
        exitStatusWaiters.removeAll()
        pending.values.forEach { $0.resume(returning: status) }
    }

    /// Detaches both readability handlers, force-finishes their streams
    /// (unblocking the drain loops even if the pipe never saw natural EOF —
    /// e.g. a forcibly-killed child whose own child inherited the write
    /// end), and closes both file handles. Idempotent.
    private func forceCloseHandles() {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }
}

extension Duration {
    fileprivate var secondsDouble: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
