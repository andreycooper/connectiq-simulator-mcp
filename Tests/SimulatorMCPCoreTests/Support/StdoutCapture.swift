import Foundation

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

/// Temporarily redirects the process's real fd 1 (stdout) to a pipe, runs
/// `body`, and returns whatever bytes landed on that fd while it ran.
///
/// Shared by every test suite that needs to prove diagnostics/child output
/// never leak onto the channel reserved for MCP JSON-RPC framing (see
/// AGENTS.md). Originally written for `MCPBootstrapTests`; reused as-is by
/// every caller that needs exactly the same real-fd capture. Because fd 1 is
/// process-global, the serializer spans the complete async body and pipe read.
func captureStdout(_ body: () async throws -> Void) async throws -> Data {
    try await stdoutCaptureSerializer.acquire()
    do {
        try Task.checkCancellation()
        let data = try await captureStdoutExclusively(body)
        await stdoutCaptureSerializer.release()
        return data
    } catch {
        await stdoutCaptureSerializer.release()
        throw error
    }
}

private let stdoutCaptureSerializer = StdoutCaptureSerializer()

private actor StdoutCaptureSerializer {
    private final class Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>

        init(id: UUID, continuation: CheckedContinuation<Void, Error>) {
            self.id = id
            self.continuation = continuation
        }
    }

    private var active = false
    private var waiters: [Waiter] = []

    var queueDepth: Int { (active ? 1 : 0) + waiters.count }

    func acquire() async throws {
        try Task.checkCancellation()
        guard active else {
            active = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            active = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

func stdoutCaptureQueueDepth() async -> Int {
    await stdoutCaptureSerializer.queueDepth
}

private func captureStdoutExclusively(
    _ body: () async throws -> Void
) async rethrows -> Data {
    let savedStdout = dup(STDOUT_FILENO)
    precondition(savedStdout >= 0, "failed to save stdout")

    let (readFD, writeFD) = try! FileDescriptor.pipe()
    dup2(writeFD.rawValue, STDOUT_FILENO)
    try! writeFD.close()

    do {
        try await body()
    } catch {
        fflush(stdout)
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
        try! readFD.close()
        throw error
    }

    fflush(stdout)
    dup2(savedStdout, STDOUT_FILENO)
    close(savedStdout)

    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let bytesRead = try! buffer.withUnsafeMutableBufferPointer { pointer in
            try readFD.read(into: UnsafeMutableRawBufferPointer(pointer))
        }
        if bytesRead == 0 { break }
        collected.append(contentsOf: buffer[..<bytesRead])
    }
    try! readFD.close()

    return collected
}
