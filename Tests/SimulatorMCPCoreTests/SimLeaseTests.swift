import Darwin
import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("SimLease")
struct SimLeaseTests {
    @Test("acquisition creates secure persistent lock and reports holder metadata")
    func testSecurePersistentLockAndHolder() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let lease = SimLease(lockFile: sandbox.lockFile)

        let token = try await lease.acquire(operation: "run_app", timeout: .seconds(1))
        let holder = try lease.holder()
        #expect(holder?.pid == getpid())
        #expect(holder?.operation == "run_app")
        #expect(holder?.acquiredMonotonicNanos != nil)

        #expect(permissions(of: sandbox.directory) == 0o700)
        #expect(permissions(of: sandbox.lockFile) == 0o600)

        try token.release()
        #expect(FileManager.default.fileExists(atPath: sandbox.lockFile.path))
        #expect(try lease.holder() == nil)
    }

    @Test("contention timeout reports holder PID operation and concrete retry fix")
    func testTimeoutReportsHolder() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let holderLease = SimLease(lockFile: sandbox.lockFile)
        let waiterLease = SimLease(lockFile: sandbox.lockFile)
        let token = try await holderLease.acquire(operation: "test_app", timeout: .seconds(1))
        defer { try? token.release() }

        do {
            _ = try await waiterLease.acquire(operation: "run_app", timeout: .milliseconds(100))
            Issue.record("the contending lease must time out")
        } catch let error as ToolError {
            #expect(error.code == "simulator_lease_timeout")
            #expect(error.details?["holderPid"] == .int(Int(getpid())))
            #expect(error.details?["holderOperation"] == .string("test_app"))
            #expect(error.details?["waitingOperation"] == .string("run_app"))
            #expect(error.fix.contains("retry"))
            #expect(error.fix.contains("do not delete"))
        }
    }

    @Test("empty holder metadata during a lease transition stays diagnostic-only")
    func testEmptyTransitionMetadataDoesNotReplaceLeaseTimeout() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        try sandbox.prepareLockFile()
        let child = try ForkedFlockHolder.start(
            lockFile: sandbox.lockFile, publishMetadata: false)
        defer { child.terminateIfNeeded() }
        let lease = SimLease(lockFile: sandbox.lockFile)

        #expect(try lease.holder() == nil)
        do {
            _ = try await lease.acquire(operation: "waiter", timeout: .zero)
            Issue.record("the transition holder must still retain the flock")
        } catch let error as ToolError {
            #expect(error.code == "simulator_lease_timeout")
            #expect(error.details?["holderPid"] == nil)
            #expect(error.details?["holderOperation"] == nil)
        }
    }

    @Test("non-empty malformed holder metadata still fails closed")
    func testMalformedHolderMetadataIsInternalError() throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        try sandbox.prepareLockFile()
        let child = try ForkedFlockHolder.start(
            lockFile: sandbox.lockFile, publishMetadata: false)
        defer { child.terminateIfNeeded() }
        try writeHolderData(Data("{".utf8), lockFile: sandbox.lockFile)

        do {
            _ = try SimLease(lockFile: sandbox.lockFile).holder()
            Issue.record("non-empty malformed metadata must fail closed")
        } catch let error as ToolError {
            #expect(error.code == "internal_error")
            #expect(error.message.contains("invalid holder metadata"))
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a cancelled acquisition closes its descriptor and cannot retain the lock")
    func testCancellationLeavesNoDescriptorLock() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let clock = FakeClock()
        let lease = SimLease(lockFile: sandbox.lockFile, clock: clock)
        let holder = try await lease.acquire(operation: "holder", timeout: .seconds(1))

        let cancelled = Task {
            try await lease.acquire(operation: "cancelled", timeout: .seconds(3600))
        }
        let sleeping = await waitUntilLease { clock.pendingSleepCount > 0 }
        #expect(sleeping, "the cancelled acquisition must have opened and contended")

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("cancelled acquisition must throw")
        } catch is CancellationError {
            // expected
        }

        try holder.release()
        let next = try await lease.acquire(operation: "next", timeout: .seconds(1))
        try next.release()
    }

    @Test("killing a holder releases flock without deleting or replacing sim.lock")
    func testKilledHolderReleasesWithoutDeletion() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        try sandbox.prepareLockFile()
        let inodeBefore = inode(of: sandbox.lockFile)
        let child = try ForkedFlockHolder.start(lockFile: sandbox.lockFile)
        defer { child.terminateIfNeeded() }

        #expect(try forkedLockProbe(lockFile: sandbox.lockFile) == false)

        let lease = SimLease(lockFile: sandbox.lockFile)
        do {
            _ = try await lease.acquire(operation: "parent", timeout: .milliseconds(100))
            Issue.record("the live child must hold the lock")
        } catch let error as ToolError {
            #expect(error.code == "simulator_lease_timeout")
        }

        child.killAndWait()
        #expect(try forkedLockProbe(lockFile: sandbox.lockFile) == true)
        let token = try await lease.acquire(operation: "after-death", timeout: .seconds(1))
        try token.release()

        #expect(FileManager.default.fileExists(atPath: sandbox.lockFile.path))
        #expect(inode(of: sandbox.lockFile) == inodeBefore)
    }

    @Test("a lease past its absolute deadline cannot acquire after a long clock advance")
    func testAbsoluteDeadlinePreventsLateAcquisition() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let holderLease = SimLease(lockFile: sandbox.lockFile)
        let holder = try await holderLease.acquire(operation: "holder")
        let clock = FakeClock()
        let waiterLease = SimLease(lockFile: sandbox.lockFile, clock: clock)

        let waiter = Task {
            try await waiterLease.acquire(operation: "waiter", timeout: .milliseconds(10))
        }
        #expect(await waitUntilLease { clock.pendingSleepCount == 1 })

        // The old relative 50 ms poll attempted flock again before checking
        // elapsed time, so releasing here allowed a 10 ms request to acquire.
        clock.advanceWithoutResuming(by: .milliseconds(50))
        try holder.release()
        clock.advance(by: .zero)

        do {
            let token = try await waiter.value
            try token.release()
            Issue.record("a lease must not acquire after its absolute deadline")
        } catch let error as ToolError {
            #expect(error.code == "simulator_lease_timeout")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("invalid operation and negative timeout return invalid_arguments")
    func testInvalidArgumentsAreToolErrors() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let lease = SimLease(lockFile: sandbox.lockFile)

        do {
            let token = try await lease.acquire(
                operation: "negative", timeout: .milliseconds(-1))
            try token.release()
            Issue.record("negative timeout must throw invalid_arguments")
            return  // avoid reaching the current empty-operation precondition during RED
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        }

        do {
            _ = try await lease.acquire(operation: "", timeout: .seconds(1))
            Issue.record("empty operation must throw invalid_arguments")
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("cancellation after metadata fsync releases the acquired flock")
    func testCancellationAfterMetadataWriteReleasesLock() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let hook = LeaseMetadataHook()
        let lease = SimLease(
            lockFile: sandbox.lockFile,
            clock: FakeClock(),
            afterMetadataWrite: { await hook.pause() })

        let cancelled = Task {
            try await lease.acquire(operation: "cancel-after-fsync", timeout: .seconds(1))
        }
        await hook.waitUntilPaused()
        cancelled.cancel()
        await hook.release()

        do {
            let token = try await cancelled.value
            try token.release()
            Issue.record("post-fsync cancellation must not return a lease token")
        } catch is CancellationError {
            // expected
        }

        let next = try await SimLease(lockFile: sandbox.lockFile)
            .acquire(operation: "next", timeout: .seconds(1))
        try next.release()
    }

    @Test("deadline expiry immediately after flock returns lease timeout and releases")
    func testDeadlineExpiryAfterFlockReleasesLock() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let clock = FakeClock()
        let lease = SimLease(
            lockFile: sandbox.lockFile,
            clock: clock,
            afterFlockAcquired: { clock.advanceWithoutResuming(by: .milliseconds(10)) },
            afterMetadataWrite: {})

        do {
            _ = try await lease.acquire(operation: "deadline-race", timeout: .milliseconds(10))
            Issue.record("expiry after successful flock must not return a token")
        } catch let error as ToolError {
            #expect(error.code == "simulator_lease_timeout")
            #expect(!error.fix.isEmpty)
        }

        let next = try await SimLease(lockFile: sandbox.lockFile)
            .acquire(operation: "next", timeout: .seconds(1))
        try next.release()
    }

    @Test("zero timeout makes one immediate attempt and acquires a free lease")
    func testZeroTimeoutAcquiresFreeLease() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let acquired = LeaseAtomicFlag()
        let lease = SimLease(
            lockFile: sandbox.lockFile,
            clock: FakeClock(),
            afterFlockAcquired: { acquired.set() },
            afterMetadataWrite: {})

        let token = try await lease.acquire(operation: "no-wait", timeout: .zero)

        #expect(acquired.value, "free zero-timeout lease must attempt flock")
        try token.release()
    }

    @Test("zero timeout returns lease timeout without sleeping when contended")
    func testZeroTimeoutRejectsContendedLeaseWithoutSleep() async throws {
        let sandbox = try LeaseSandbox()
        defer { sandbox.tearDown() }
        let holder = try await SimLease(lockFile: sandbox.lockFile)
            .acquire(operation: "holder", timeout: .seconds(1))
        defer { try? holder.release() }
        let clock = FakeClock()
        let waiter = SimLease(lockFile: sandbox.lockFile, clock: clock)

        do {
            _ = try await waiter.acquire(operation: "no-wait", timeout: .zero)
            Issue.record("contended zero-timeout lease must fail")
        } catch let error as ToolError {
            #expect(error.code == "simulator_lease_timeout")
            #expect(error.details?["holderOperation"] == .string("holder"))
        }
        #expect(clock.pendingSleepCount == 0)
    }
}

private final class LeaseAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }
}

private actor LeaseMetadataHook {
    private var paused = false
    private var released = false
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        let observers = pausedWaiters
        pausedWaiters.removeAll()
        observers.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pausedWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct LeaseSandbox {
    let directory: URL
    let lockFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "simulator-mcp-lease-tests-\(UUID().uuidString)")
        lockFile = directory.appending(path: "sim.lock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func prepareLockFile() throws {
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        close(fd)
    }

    func tearDown() { try? FileManager.default.removeItem(at: directory) }
}

private final class ForkedFlockHolder: @unchecked Sendable {
    let pid: pid_t
    private let releaseFD: Int32
    private let stateLock = NSLock()
    private var reaped = false

    private init(pid: pid_t, releaseFD: Int32) {
        self.pid = pid
        self.releaseFD = releaseFD
    }

    static func start(
        lockFile: URL,
        publishMetadata: Bool = true
    ) throws -> ForkedFlockHolder {
        var readyPipe: [Int32] = [0, 0]
        var releasePipe: [Int32] = [0, 0]
        guard pipe(&readyPipe) == 0, pipe(&releasePipe) == 0 else { throw POSIXError(.EIO) }

        guard let lockPath = strdup(lockFile.path) else { throw POSIXError(.ENOMEM) }
        defer { free(lockPath) }
        let pid = systemFork()
        guard pid >= 0 else { throw POSIXError(.EAGAIN) }
        if pid == 0 {
            close(readyPipe[0])
            close(releasePipe[1])
            let fd = open(lockPath, O_RDWR)
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { _exit(10) }
            var ready: UInt8 = 1
            _ = write(readyPipe[1], &ready, 1)
            close(readyPipe[1])
            var release: UInt8 = 0
            _ = read(releasePipe[0], &release, 1)
            flock(fd, LOCK_UN)
            close(fd)
            close(releasePipe[0])
            _exit(0)
        }

        close(readyPipe[1])
        close(releasePipe[0])
        var ready: UInt8 = 0
        let count = read(readyPipe[0], &ready, 1)
        close(readyPipe[0])
        guard count == 1, ready == 1 else {
            close(releasePipe[1])
            Darwin.kill(pid, SIGKILL)
            _ = waitpid(pid, nil, 0)
            throw POSIXError(.EIO)
        }
        if publishMetadata {
            try writeHolderMetadata(lockFile: lockFile, pid: pid)
        }
        return ForkedFlockHolder(pid: pid, releaseFD: releasePipe[1])
    }

    func killAndWait() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !reaped else { return }
        Darwin.kill(pid, SIGKILL)
        _ = waitpid(pid, nil, 0)
        close(releaseFD)
        reaped = true
    }

    func terminateIfNeeded() {
        killAndWait()
    }
}

/// Runs one nonblocking flock attempt in a separate helper process and
/// reports whether it acquired. Combined with `ForkedFlockHolder`, this
/// proves two distinct helper processes contend on the same inode.
private func forkedLockProbe(lockFile: URL) throws -> Bool {
    var resultPipe: [Int32] = [0, 0]
    guard pipe(&resultPipe) == 0 else { throw POSIXError(.EIO) }
    guard let lockPath = strdup(lockFile.path) else { throw POSIXError(.ENOMEM) }
    defer { free(lockPath) }

    let pid = systemFork()
    guard pid >= 0 else { throw POSIXError(.EAGAIN) }
    if pid == 0 {
        close(resultPipe[0])
        let fd = open(lockPath, O_RDWR)
        var acquired: UInt8 = 0
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 {
            acquired = 1
            flock(fd, LOCK_UN)
        }
        if fd >= 0 { close(fd) }
        _ = write(resultPipe[1], &acquired, 1)
        close(resultPipe[1])
        _exit(0)
    }

    close(resultPipe[1])
    var acquired: UInt8 = 0
    let count = read(resultPipe[0], &acquired, 1)
    close(resultPipe[0])
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
    guard count == 1 else { throw POSIXError(.EIO) }
    return acquired == 1
}

private func writeHolderMetadata(lockFile: URL, pid: pid_t) throws {
    let data = try JSONEncoder().encode(
        LeaseHolder(pid: pid, operation: "child-helper", acquiredMonotonicNanos: 1))
    try writeHolderData(data, lockFile: lockFile)
}

private func writeHolderData(_ data: Data, lockFile: URL) throws {
    let fd = open(lockFile.path, O_RDWR)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) >= 0 else {
        throw POSIXError(.EIO)
    }
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        guard Darwin.write(fd, base, raw.count) == raw.count else { throw POSIXError(.EIO) }
    }
    guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
}

private func permissions(of url: URL) -> mode_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return 0 }
    return info.st_mode & 0o777
}

private func inode(of url: URL) -> ino_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return 0 }
    return info.st_ino
}

private func waitUntilLease(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if condition() { return true }
        await Task.yield()
    }
    return false
}

// Swift's Darwin overlay marks fork unavailable because arbitrary Swift work
// is unsafe after a multithreaded fork. This test child performs only
// async-signal-safe POSIX calls before _exit, so bind the libc symbol directly.
@_silgen_name("fork")
private func systemFork() -> pid_t
