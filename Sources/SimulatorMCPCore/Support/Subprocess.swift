import Foundation
import Darwin

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

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: Duration?,
        stdinData: Data?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess
}

extension ProcessRunning {
    public func start(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        workingDirectory: URL? = nil, timeout: Duration? = nil, stdinData: Data? = nil,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> any RunningProcess {
        guard stdinData == nil else {
            throw ToolError(code: "unsupported_operation",
                message: "This process runner does not support bounded stdin.",
                fix: "Use the production Subprocess runner for commands requiring stdin.")
        }
        return try await start(executable: executable, arguments: arguments,
            environment: environment, workingDirectory: workingDirectory, timeout: timeout,
            onStdout: onStdout, onStderr: onStderr)
    }

}

/// The only production type allowed to construct `Foundation.Process` (see
/// AGENTS.md's architecture boundary). Every subprocess launch in this
/// codebase — SDK tools, simulator control, `monkeydo` test runs — goes
/// through this type so pipe wiring, streaming, timeouts, and
/// SIGTERM/SIGKILL termination are implemented exactly once.
public struct Subprocess: ProcessRunning, Sendable {
    struct TestHooks: Sendable {
        var stdinWriteBlocked: (@Sendable () -> Void)? = nil
        var cleanupHook: (@Sendable () async -> Void)? = nil
        var processStarted: (@Sendable (Int32) -> Void)? = nil
        var waitEntered: (@Sendable () -> Void)? = nil
        var pipeDescriptors: (@Sendable ([Int32]) -> Void)? = nil
        var graceClock: (any Clock<Duration>)? = nil
        var graceDuration: Duration? = nil
        var failReaderConstructionAt: Int? = nil
        var killSent: (@Sendable () -> Void)? = nil
        var firstReaderDescriptors: (@Sendable ([Int32]) -> Void)? = nil
    }

    private let testHooks: TestHooks
    public init() { testHooks = TestHooks() }
    init(testHooks: TestHooks) { self.testHooks = testHooks }

    public func start(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        workingDirectory: URL? = nil, timeout: Duration? = nil,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> any RunningProcess {
        try await start(executable: executable, arguments: arguments,
            environment: environment, workingDirectory: workingDirectory, timeout: timeout,
            stdinData: nil, onStdout: onStdout, onStderr: onStderr)
    }

    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: Duration? = nil,
        stdinData: Data? = nil,
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
        var readerConstruction = 0
        func makeReader(_ handle: FileHandle) throws -> DispatchPipeReader {
            readerConstruction += 1
            if readerConstruction == testHooks.failReaderConstructionAt {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
            return try DispatchPipeReader(readHandle: handle)
        }
        if let stdinData {
            let stdinPipe = Pipe()
            let stdinReadHandle = stdinPipe.fileHandleForReading
            let stdinHandle = stdinPipe.fileHandleForWriting
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let stdoutReader: DispatchPipeReader
            do {
                stdoutReader = try makeReader(stdoutPipe.fileHandleForReading)
            } catch {
                closePipeSetupHandles(stdinReadHandle: stdinReadHandle,
                    stdinHandle: stdinHandle, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
                throw Self.translateReaderSetupFailure(error, executable: executable)
            }
            testHooks.firstReaderDescriptors?([
                stdinReadHandle.fileDescriptor, stdinHandle.fileDescriptor,
                stdoutReader.fd, stdoutPipe.fileHandleForWriting.fileDescriptor,
            ])
            let stderrReader: DispatchPipeReader
            do {
                stderrReader = try makeReader(stderrPipe.fileHandleForReading)
            } catch {
                await stdoutReader.cancelAndWait()
                closePipeSetupHandles(stdinReadHandle: stdinReadHandle,
                    stdinHandle: stdinHandle, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
                throw Self.translateReaderSetupFailure(error, executable: executable)
            }
            testHooks.pipeDescriptors?([
                stdinReadHandle.fileDescriptor,
                stdinHandle.fileDescriptor,
                stdoutReader.fd,
                stdoutPipe.fileHandleForWriting.fileDescriptor,
                stderrReader.fd,
                stderrPipe.fileHandleForWriting.fileDescriptor,
            ])
            do { try process.run() } catch {
                try? stdinReadHandle.close()
                try? stdinHandle.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                await cancelReadersAndAwait([stdoutReader, stderrReader])
                throw Self.translateLaunchFailure(error, executable: executable)
            }
            // The child inherited its stdin read endpoint during run(). The
            // parent owns only the writing endpoint and must close its read
            // reference immediately to preserve bounded-stdin ownership.
            try? stdinReadHandle.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            testHooks.processStarted?(process.processIdentifier)
            let managed = try await makeManagedProcess(
                process: process,
                executable: executable, timeout: timeout, stdinHandle: stdinHandle,
                cleanupHook: testHooks.cleanupHook, waitEntered: testHooks.waitEntered,
                graceClock: testHooks.graceClock,
                graceDuration: testHooks.graceDuration,
                killSent: testHooks.killSent,
                stdoutReader: stdoutReader,
                stderrReader: stderrReader,
                stdoutWriteHandle: stdoutPipe.fileHandleForWriting,
                stderrWriteHandle: stderrPipe.fileHandleForWriting,
                onStdout: onStdout, onStderr: onStderr)
            do {
                try await Self.writeBoundedStdin(
                    stdinData, to: stdinHandle,
                    timeout: timeout ?? .seconds(30), executable: executable,
                    onBlocked: testHooks.stdinWriteBlocked)
            } catch {
                await Task.detached { await managed.cancelAndAwaitExit() }.value
                try? stdinHandle.close()
                throw error
            }
            do {
                try stdinHandle.close()
            } catch {
                await managed.terminate(grace: .seconds(1))
                throw Self.translateStdinCloseFailure(error, executable: executable)
            }
            return managed
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutReader: DispatchPipeReader
        do {
            stdoutReader = try makeReader(stdoutPipe.fileHandleForReading)
        } catch {
            closePipeSetupHandles(stdinReadHandle: nil, stdinHandle: nil,
                stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw Self.translateReaderSetupFailure(error, executable: executable)
        }
        testHooks.firstReaderDescriptors?([
            stdoutReader.fd, stdoutPipe.fileHandleForWriting.fileDescriptor,
        ])
        let stderrReader: DispatchPipeReader
        do {
            stderrReader = try makeReader(stderrPipe.fileHandleForReading)
        } catch {
            await stdoutReader.cancelAndWait()
            closePipeSetupHandles(stdinReadHandle: nil, stdinHandle: nil,
                stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            throw Self.translateReaderSetupFailure(error, executable: executable)
        }
        testHooks.pipeDescriptors?([
            stdoutReader.fd,
            stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderrReader.fd,
            stderrPipe.fileHandleForWriting.fileDescriptor,
        ])

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            await cancelReadersAndAwait([stdoutReader, stderrReader])
            throw Self.translateLaunchFailure(error, executable: executable)
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        testHooks.processStarted?(process.processIdentifier)

        let managed = ManagedProcess(
            process: process,
            pid: process.processIdentifier,
            stdoutReader: stdoutReader,
            stderrReader: stderrReader,
            stdoutWriteHandle: stdoutPipe.fileHandleForWriting,
            stderrWriteHandle: stderrPipe.fileHandleForWriting,
            stdinHandle: nil,
            cleanupHook: testHooks.cleanupHook,
            waitEntered: testHooks.waitEntered,
            graceClock: testHooks.graceClock,
            graceDuration: testHooks.graceDuration,
            killSent: testHooks.killSent,
            executable: executable,
            timeout: timeout,
            clock: ContinuousClock(),
            onStdout: onStdout,
            onStderr: onStderr
        )
        await managed.armTerminationHandlerAndStartDraining()

        return managed
    }

    private static func translateStdinFailure(_ error: Error, executable: URL) -> ToolError {
        ToolError(code: "stdin_write_failed",
            message: "Could not write bounded stdin to \(executable.path): \((error as NSError).localizedDescription)",
            fix: "Retry the command; if it repeats, verify the child accepts bounded stdin.",
            details: ["executable": .string(executable.path)])
    }

    private static func translateStdinCloseFailure(_ error: Error, executable: URL) -> ToolError {
        ToolError(code: "stdin_close_failed",
            message: "Could not close bounded stdin for \(executable.path): \((error as NSError).localizedDescription)",
            fix: "Retry the command; if it repeats, inspect the child process and its stdin handling.",
            details: ["executable": .string(executable.path)])
    }

    private static func translateReaderSetupFailure(_ error: Error, executable: URL) -> ToolError {
        ToolError(code: "internal_error",
            message: "Could not prepare output readers for \(executable.path): \((error as NSError).localizedDescription)",
            fix: "Retry the command; if it repeats, inspect the server stderr log.",
            details: ["executable": .string(executable.path)])
    }

    private func closePipeSetupHandles(
        stdinReadHandle: FileHandle?, stdinHandle: FileHandle?,
        stdoutPipe: Pipe, stderrPipe: Pipe
    ) {
        try? stdinReadHandle?.close()
        try? stdinHandle?.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
    }

    private static func writeBoundedStdin(
        _ data: Data, to handle: FileHandle, timeout: Duration, executable: URL,
        onBlocked: (@Sendable () -> Void)?
    ) async throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw translateStdinFailure(errnoError(), executable: executable)
        }
        guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw translateStdinFailure(errnoError(), executable: executable)
        }
        let deadline = ClockDeadline(clock: ContinuousClock(), timeout: timeout)
        var blockedObserver = onBlocked
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            if deadline.hasExpired {
                throw ToolError(code: "stdin_write_timeout",
                    message: "Writing bounded stdin to \(executable.path) exceeded \(timeout).",
                    fix: "Use a child that consumes stdin, reduce the payload, or increase the timeout.",
                    details: ["executable": .string(executable.path)])
            }
            let count = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                blockedObserver?()
                blockedObserver = nil
                try await deadline.sleepUntilNextPoll(maximumInterval: .milliseconds(2))
                continue
            }
            throw translateStdinFailure(errnoError(), executable: executable)
        }
    }

    private static func errnoError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }

    private func makeManagedProcess(
        process: Process, executable: URL,
        timeout: Duration?, stdinHandle: FileHandle? = nil,
        cleanupHook: (@Sendable () async -> Void)? = nil,
        waitEntered: (@Sendable () -> Void)? = nil,
        graceClock: (any Clock<Duration>)? = nil,
        graceDuration: Duration? = nil,
        killSent: (@Sendable () -> Void)? = nil,
        stdoutReader: DispatchPipeReader,
        stderrReader: DispatchPipeReader,
        stdoutWriteHandle: FileHandle,
        stderrWriteHandle: FileHandle,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?) async throws -> ManagedProcess {
        let managed = ManagedProcess(process: process, pid: process.processIdentifier,
            stdoutReader: stdoutReader, stderrReader: stderrReader,
            stdoutWriteHandle: stdoutWriteHandle, stderrWriteHandle: stderrWriteHandle,
            stdinHandle: stdinHandle,
            cleanupHook: cleanupHook, waitEntered: waitEntered,
            graceClock: graceClock, graceDuration: graceDuration, killSent: killSent,
            executable: executable, timeout: timeout,
            clock: ContinuousClock(),
            onStdout: onStdout, onStderr: onStderr)
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
///   consumer `Task` reading an `AsyncStream<Data>` fed by its exclusive
///   `DispatchPipeReader`. A single ordered consumer per stream guarantees
///   chunks are appended in the order they were read, independent of source
///   callback scheduling.
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
private final class CleanupTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func start(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached(operation: operation)
    }

    func value() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }
}

/// Exclusive owner for one subprocess pipe read endpoint. The raw descriptor
/// is duplicated before the Pipe-owned FileHandle is closed; after that point
/// no Foundation object owns the reader descriptor.
final class DispatchPipeReader: @unchecked Sendable {
    let fd: Int32
    let stream: AsyncStream<Data>

    private let source: DispatchSourceRead
    private let continuation: AsyncStream<Data>.Continuation
    private let onCancellationStarted: (@Sendable () -> Void)?
    private let waitForCancellationRelease: (@Sendable () -> Void)?
    private let onCancellationWaiterRegistered: (@Sendable () -> Void)?
    private let lock = NSLock()
    private enum CancellationState {
        case active
        case cancelling
        case finished
    }
    private var cancellationState: CancellationState = .active
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        readHandle: FileHandle,
        onCancellationStarted: (@Sendable () -> Void)? = nil,
        waitForCancellationRelease: (@Sendable () -> Void)? = nil,
        onCancellationWaiterRegistered: (@Sendable () -> Void)? = nil
    ) throws {
        let duplicated = fcntl(readHandle.fileDescriptor, F_DUPFD_CLOEXEC, 100)
        guard duplicated >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let flags = fcntl(duplicated, F_GETFL, 0)
        guard flags >= 0, fcntl(duplicated, F_SETFL, flags | O_NONBLOCK) == 0 else {
            _ = Darwin.close(duplicated)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        self.fd = duplicated
        let (stream, continuation) = AsyncStream<Data>.makeStream(of: Data.self)
        self.stream = stream
        self.continuation = continuation
        self.source = DispatchSource.makeReadSource(fileDescriptor: duplicated, queue: .global(qos: .utility))
        self.onCancellationStarted = onCancellationStarted
        self.waitForCancellationRelease = waitForCancellationRelease
        self.onCancellationWaiterRegistered = onCancellationWaiterRegistered

        // The Pipe no longer owns this endpoint after the duplicate becomes
        // the reader's exclusive descriptor.
        readHandle.closeFile()

        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [weak self] in self?.finishCancellation() }
        source.resume()
    }

    func cancelAndWait() async {
        await withCheckedContinuation { continuation in
            let action = lock.withLock { () -> CancellationAction in
                switch cancellationState {
                case .active:
                    cancellationState = .cancelling
                    cancelWaiters.append(continuation)
                    return .cancelSource
                case .cancelling:
                    cancelWaiters.append(continuation)
                    return .wait
                case .finished:
                    return .resume
                }
            }
            switch action {
            case .cancelSource:
                onCancellationWaiterRegistered?()
                source.cancel()
            case .resume:
                continuation.resume()
            case .wait:
                onCancellationWaiterRegistered?()
                break
            }
        }
    }

    private enum CancellationAction {
        case cancelSource
        case wait
        case resume
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress!, bytes.count)
            }
            if count > 0 {
                continuation.yield(Data(buffer[0..<count]))
                continue
            }
            if count == 0 {
                source.cancel()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            source.cancel()
            return
        }
    }

    private func finishCancellation() {
        let shouldFinish = lock.withLock {
            guard cancellationState != .finished else { return false }
            cancellationState = .cancelling
            return true
        }
        guard shouldFinish else { return }
        onCancellationStarted?()
        waitForCancellationRelease?()
        _ = Darwin.close(fd)
        continuation.finish()
        let finalWaiters = lock.withLock {
            cancellationState = .finished
            let waiters = cancelWaiters
            cancelWaiters.removeAll()
            return waiters
        }
        finalWaiters.forEach { $0.resume() }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private func cancelReadersAndAwait(_ readers: [DispatchPipeReader]) async {
    await withTaskGroup(of: Void.self) { group in
        for reader in readers {
            group.addTask { await reader.cancelAndWait() }
        }
        await group.waitForAll()
    }
}

actor ManagedProcess: RunningProcess {
    nonisolated let pid: Int32

    private let process: Process
    private let executable: URL
    private let timeout: Duration?
    private let clock: any Clock<Duration>
    private let stdoutReader: DispatchPipeReader
    private let stderrReader: DispatchPipeReader
    private let stdoutWriteHandle: FileHandle
    private let stderrWriteHandle: FileHandle
    private let stdinHandle: FileHandle?
    private let cleanupHook: (@Sendable () async -> Void)?
    private let waitEntered: (@Sendable () -> Void)?
    private let graceClock: (any Clock<Duration>)?
    private let graceDuration: Duration?
    private let killSent: (@Sendable () -> Void)?
    private let onStdout: (@Sendable (Data) -> Void)?
    private let onStderr: (@Sendable (Data) -> Void)?

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutDone = false
    private var stderrDone = false
    private var exitStatus: Int32?
    private var handlesClosed = false

    private var stdoutWaiters: [CheckedContinuation<Void, Never>] = []
    private var stderrWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitStatusWaiters: [UUID: CheckedContinuation<Int32, Error>] = [:]

    private var stdoutDrainTask: Task<Void, Never>?
    private var stderrDrainTask: Task<Void, Never>?

    fileprivate init(
        process: Process,
        pid: Int32,
        stdoutReader: DispatchPipeReader,
        stderrReader: DispatchPipeReader,
        stdoutWriteHandle: FileHandle,
        stderrWriteHandle: FileHandle,
        stdinHandle: FileHandle?,
        cleanupHook: (@Sendable () async -> Void)?,
        waitEntered: (@Sendable () -> Void)?,
        graceClock: (any Clock<Duration>)?,
        graceDuration: Duration?,
        killSent: (@Sendable () -> Void)?,
        executable: URL,
        timeout: Duration?,
        clock: any Clock<Duration>,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) {
        self.process = process
        self.pid = pid
        self.stdoutReader = stdoutReader
        self.stderrReader = stderrReader
        self.stdoutWriteHandle = stdoutWriteHandle
        self.stderrWriteHandle = stderrWriteHandle
        self.stdinHandle = stdinHandle
        self.cleanupHook = cleanupHook
        self.waitEntered = waitEntered
        self.graceClock = graceClock
        self.graceDuration = graceDuration
        self.killSent = killSent
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

        stdoutDrainTask = Task { [weak self, stream = stdoutReader.stream] in
            for await chunk in stream {
                await self?.appendStdout(chunk)
            }
            await self?.markStdoutDone()
        }
        stderrDrainTask = Task { [weak self, stream = stderrReader.stream] in
            for await chunk in stream {
                await self?.appendStderr(chunk)
            }
            await self?.markStderrDone()
        }
    }

    // MARK: - RunningProcess

    func wait() async throws -> ProcessOutput {
        waitEntered?()
        let cleanup = CleanupTaskBox()
        do {
            let output = try await withTaskCancellationHandler {
                try await self.performWait()
            } onCancel: {
                cleanup.start { await self.cancelAndAwaitExit() }
            }
            if let task = cleanup.value() { await task.value }
            if Task.isCancelled { throw CancellationError() }
            return output
        } catch {
            if let task = cleanup.value() { await task.value }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func terminate(grace: Duration) async {
        await terminate(grace: grace, clock: clock)
    }

    private func terminate(grace: Duration, clock: any Clock<Duration>) async {
        guard exitStatus == nil else {
            await closeAndAwaitDrains()
            return
        }
        process.terminate()  // SIGTERM

        do {
            _ = try await ClockSupport.withDeadline(grace, clock: clock) {
                try await self.waitForExitStatusRaceable()
            }
        } catch is ClockSupport.DeadlineExceeded {
            if process.isRunning {
                killSent?()
                kill(process.processIdentifier, SIGKILL)
            }
            // SIGKILL is unblockable: this now resolves quickly for real.
            _ = try? await waitForExitStatusRaceable()
        } catch {
            // Cleanup can itself be entered from a cancelled bounded-stdin
            // write. Do not let cancellation turn child cleanup into a trap;
            // force the child down and close our descriptors immediately.
            if process.isRunning {
                killSent?()
                kill(process.processIdentifier, SIGKILL)
            }
            await closeAndAwaitDrains()
        }

        await closeAndAwaitDrains()
    }

    /// Cancellation cleanup runs in a detached, non-cancelled task and follows
    /// TERM → bounded grace → KILL when needed. It waits for Foundation to
    /// confirm exit and closes every descriptor before cancellation returns.
    func cancelAndAwaitExit() async {
        await cleanupHook?()
        await terminate(
            grace: graceDuration ?? .seconds(5),
            clock: graceClock ?? ContinuousClock()
        )
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

    /// Closes the remaining parent-owned writer handles. Reader cancellation
    /// and drain-task completion are awaited by `closeAndAwaitDrains`.
    private func forceCloseHandles() {
        guard !handlesClosed else { return }
        handlesClosed = true
        try? stdinHandle?.close()
        stdoutWriteHandle.closeFile()
        stderrWriteHandle.closeFile()
        process.waitUntilExit()
    }

    private func closeAndAwaitDrains() async {
        forceCloseHandles()
        await cancelReadersAndAwait([stdoutReader, stderrReader])
        await stdoutDrainTask?.value
        await stderrDrainTask?.value
    }
}

extension Duration {
    fileprivate var secondsDouble: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
