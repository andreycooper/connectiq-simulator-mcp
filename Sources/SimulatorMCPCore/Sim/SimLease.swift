import Darwin
import Foundation

public struct LeaseHolder: Codable, Equatable, Sendable {
    public let pid: Int32
    public let operation: String
    public let acquiredMonotonicNanos: UInt64

    public init(pid: Int32, operation: String, acquiredMonotonicNanos: UInt64) {
        self.pid = pid
        self.operation = operation
        self.acquiredMonotonicNanos = acquiredMonotonicNanos
    }
}

/// An acquired lease. Release is idempotent; deinitialization is a best-effort
/// safety net, while explicit release reports stable actionable errors.
public final class LeaseToken: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?
    private let lockPath: String

    fileprivate init(descriptor: Int32, lockPath: String) {
        self.descriptor = descriptor
        self.lockPath = lockPath
    }

    public func release() throws {
        guard let fd = takeDescriptor() else { return }
        if let error = Self.releaseDescriptor(fd, lockPath: lockPath) {
            throw error
        }
    }

    deinit {
        guard let fd = takeDescriptor() else { return }
        _ = Self.releaseDescriptor(fd, lockPath: lockPath)
    }

    private func takeDescriptor() -> Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        defer { descriptor = nil }
        return descriptor
    }

    private static func releaseDescriptor(_ fd: Int32, lockPath: String) -> ToolError? {
        var firstFailure: (call: String, code: Int32)?
        if ftruncate(fd, 0) != 0 { firstFailure = ("ftruncate", errno) }
        if fsync(fd) != 0, firstFailure == nil { firstFailure = ("fsync", errno) }
        if flock(fd, LOCK_UN) != 0, firstFailure == nil { firstFailure = ("flock(LOCK_UN)", errno) }
        if close(fd) != 0, firstFailure == nil { firstFailure = ("close", errno) }

        guard let failure = firstFailure else { return nil }
        return SimLease.posixError(
            failure.call,
            path: lockPath,
            code: failure.code,
            fix: "Run doctor, then retry. If it repeats, inspect the server stderr log."
        )
    }
}

/// OS-wide simulator lease backed by one persistent inode and `flock(2)`.
public struct SimLease: Sendable {
    public static let standard = SimLease(
        lockFile: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/sim.lock")
    )

    private static let pollInterval: Duration = .milliseconds(50)
    private static let monotonicOrigin = ContinuousClock.now

    public let lockFile: URL
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline
    private let processID: Int32
    private let monotonicNanos: @Sendable () -> UInt64
    private let afterFlockAcquired: @Sendable () -> Void
    private let afterMetadataWrite: @Sendable () async -> Void

    public init(
        lockFile: URL,
        processID: Int32 = getpid()
    ) {
        let clock = ContinuousClock()
        self.lockFile = lockFile
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.processID = processID
        self.monotonicNanos = SimLease.currentMonotonicNanos
        self.afterFlockAcquired = {}
        self.afterMetadataWrite = {}
    }

    public init<C: Clock>(
        lockFile: URL,
        clock: C,
        processID: Int32 = getpid()
    ) where C.Duration == Duration {
        self.lockFile = lockFile
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.processID = processID
        self.monotonicNanos = SimLease.currentMonotonicNanos
        self.afterFlockAcquired = {}
        self.afterMetadataWrite = {}
    }

    init<C: Clock>(
        lockFile: URL,
        clock: C,
        processID: Int32 = getpid(),
        afterFlockAcquired: @escaping @Sendable () -> Void = {},
        afterMetadataWrite: @escaping @Sendable () async -> Void
    ) where C.Duration == Duration {
        self.lockFile = lockFile
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.processID = processID
        self.monotonicNanos = SimLease.currentMonotonicNanos
        self.afterFlockAcquired = afterFlockAcquired
        self.afterMetadataWrite = afterMetadataWrite
    }

    public func acquire(
        operation: String,
        timeout: Duration = .seconds(30)
    ) async throws -> LeaseToken {
        guard !operation.isEmpty else {
            throw invalidArguments("operation must not be empty")
        }
        guard timeout >= .zero else {
            throw invalidArguments("timeout must be zero or positive")
        }
        let deadline = makeDeadline(timeout)
        try Task.checkCancellation()
        let fd = try openLockDescriptor()

        do {
            if timeout == .zero {
                try Task.checkCancellation()
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    let code = errno
                    guard code == EWOULDBLOCK else {
                        throw Self.posixError(
                            "flock(LOCK_EX|LOCK_NB)", path: lockFile.path, code: code,
                            fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.")
                    }
                    throw try leaseTimeoutError(
                        waitingOperation: operation,
                        timeout: timeout)
                }

                // A zero timeout is a single no-wait acquisition attempt, not
                // an already-expired deadline. Once acquired, finish publishing
                // the holder while continuing to honor cancellation.
                afterFlockAcquired()
                try Task.checkCancellation()
                let metadata = LeaseHolder(
                    pid: processID,
                    operation: operation,
                    acquiredMonotonicNanos: monotonicNanos()
                )
                try writeHolder(metadata, to: fd)
                await afterMetadataWrite()
                try Task.checkCancellation()
                return LeaseToken(descriptor: fd, lockPath: lockFile.path)
            }

            while true {
                try Task.checkCancellation()
                guard !deadline.hasExpired else {
                    throw try leaseTimeoutError(waitingOperation: operation, timeout: timeout)
                }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    // Cancellation and deadline expiry can race the successful
                    // syscall. Neither may leak a held descriptor to a caller.
                    afterFlockAcquired()
                    try Task.checkCancellation()
                    guard !deadline.hasExpired else {
                        throw try leaseTimeoutError(
                            waitingOperation: operation,
                            timeout: timeout,
                            inspectHolder: false)
                    }

                    let metadata = LeaseHolder(
                        pid: processID,
                        operation: operation,
                        acquiredMonotonicNanos: monotonicNanos()
                    )
                    try writeHolder(metadata, to: fd)
                    await afterMetadataWrite()
                    try Task.checkCancellation()
                    guard !deadline.hasExpired else {
                        throw try leaseTimeoutError(
                            waitingOperation: operation,
                            timeout: timeout,
                            inspectHolder: false)
                    }
                    return LeaseToken(descriptor: fd, lockPath: lockFile.path)
                }
                let code = errno
                guard code == EWOULDBLOCK else {
                    throw Self.posixError(
                        "flock(LOCK_EX|LOCK_NB)", path: lockFile.path, code: code,
                        fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.")
                }
                guard !deadline.hasExpired else {
                    throw try leaseTimeoutError(waitingOperation: operation, timeout: timeout)
                }
                try await deadline.sleepUntilNextPoll(maximumInterval: Self.pollInterval)
            }
        } catch {
            close(fd)
            throw error
        }
    }

    public func holder() throws -> LeaseHolder? {
        let fd = try openLockDescriptor()
        defer { close(fd) }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        let code = errno
        guard code == EWOULDBLOCK else {
            throw Self.posixError(
                "flock(LOCK_EX|LOCK_NB)", path: lockFile.path, code: code,
                fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.")
        }

        let data = try readAll(from: fd)
        // Release deliberately truncates this persistent inode before
        // unlocking it. A contender can therefore observe EWOULDBLOCK and
        // then read the zero-byte transition after the holder has begun
        // releasing. Holder metadata is diagnostic only; absence must not
        // replace the caller's stable lease result with an internal error.
        guard !data.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(LeaseHolder.self, from: data)
        } catch {
            throw ToolError(
                code: "internal_error",
                message: "The held simulator lease at \(lockFile.path) has invalid holder metadata: \(error.localizedDescription)",
                fix: "Wait for the current holder to exit, then run doctor; do not delete the lock file.",
                details: ["lockFile": .string(lockFile.path)]
            )
        }
    }

    private func leaseTimeoutError(
        waitingOperation: String,
        timeout: Duration,
        inspectHolder: Bool = true
    ) throws -> ToolError {
        let current = inspectHolder ? try holder() : nil
        var details: [String: JSONValue] = [
            "waitingOperation": .string(waitingOperation),
            "lockFile": .string(lockFile.path),
        ]
        if let current {
            details["holderPid"] = .int(Int(current.pid))
            details["holderOperation"] = .string(current.operation)
            details["holderAcquiredMonotonicNanos"] = .int(
                Int(clamping: current.acquiredMonotonicNanos))
        }
        return ToolError(
            code: "simulator_lease_timeout",
            message:
                inspectHolder
                ? "Another client still holds the simulator lease after \(timeout)."
                : "Simulator lease acquisition exceeded its \(timeout) deadline.",
            fix: "Wait for the reported operation to finish, then retry; if it is hung, terminate its process, but do not delete sim.lock.",
            details: details
        )
    }

    private func invalidArguments(_ reason: String) -> ToolError {
        ToolError(
            code: "invalid_arguments",
            message: "Invalid simulator lease arguments: \(reason).",
            fix: "Provide a non-empty operation and a timeout that is zero or positive.",
            details: ["lockFile": .string(lockFile.path)]
        )
    }

    private func openLockDescriptor() throws -> Int32 {
        try ensureSecureDirectory()
        let fd = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw Self.posixError(
                "open", path: lockFile.path, code: errno,
                fix: "Check that ~/.simulator-mcp is writable, then retry.")
        }
        guard fchmod(fd, 0o600) == 0 else {
            let code = errno
            close(fd)
            throw Self.posixError(
                "fchmod", path: lockFile.path, code: code,
                fix: "Check ownership of ~/.simulator-mcp/sim.lock, then retry.")
        }
        return fd
    }

    private func ensureSecureDirectory() throws {
        let directory = lockFile.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ToolError(
                code: "internal_error",
                message: "Could not create simulator state directory \(directory.path): \(error.localizedDescription)",
                fix: "Check that the parent directory is writable, then retry.",
                details: ["directory": .string(directory.path)]
            )
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw Self.posixError(
                "chmod", path: directory.path, code: errno,
                fix: "Check ownership of the simulator state directory, then retry.")
        }
    }

    private func writeHolder(_ holder: LeaseHolder, to fd: Int32) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(holder)
        } catch {
            throw ToolError(
                code: "internal_error",
                message: "Could not encode simulator lease holder metadata: \(error.localizedDescription)",
                fix: "Run doctor, then retry. If it repeats, inspect the server stderr log."
            )
        }
        guard ftruncate(fd, 0) == 0 else {
            throw Self.posixError(
                "ftruncate", path: lockFile.path, code: errno,
                fix: "Check ownership of sim.lock, then retry.")
        }
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw Self.posixError(
                "lseek", path: lockFile.path, code: errno,
                fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.")
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(fd, base, remaining)
                guard count >= 0 else {
                    throw Self.posixError(
                        "write", path: lockFile.path, code: errno,
                        fix: "Check available disk space and ownership of sim.lock, then retry.")
                }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
        guard fsync(fd) == 0 else {
            throw Self.posixError(
                "fsync", path: lockFile.path, code: errno,
                fix: "Check the filesystem containing sim.lock, then retry.")
        }
    }

    private func readAll(from fd: Int32) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw Self.posixError(
                "lseek", path: lockFile.path, code: errno,
                fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else {
                throw Self.posixError(
                    "read", path: lockFile.path, code: errno,
                    fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.")
            }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func posixError(
        _ call: String,
        path: String,
        code: Int32,
        fix: String
    ) -> ToolError {
        ToolError(
            code: "internal_error",
            message: "\(call)(\(path)) failed with errno \(code): \(String(cString: strerror(code)))",
            fix: fix,
            details: [
                "call": .string(call),
                "path": .string(path),
                "errno": .int(Int(code)),
            ]
        )
    }

    private static func currentMonotonicNanos() -> UInt64 {
        let components = monotonicOrigin.duration(to: ContinuousClock.now).components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return UInt64.max }
        return whole.addingReportingOverflow(nanos).overflow ? UInt64.max : whole + nanos
    }
}
