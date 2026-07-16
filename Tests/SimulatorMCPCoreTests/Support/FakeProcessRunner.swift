import Foundation

import SimulatorMCPCore

/// One recorded `ProcessRunning.start` call.
struct FakeInvocation: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]?
    let workingDirectory: URL?
    let timeout: Duration?

    /// The value following `flag`, if present.
    func argumentValue(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}

/// In-memory `ProcessRunning` for driving `Compiler` (and later services)
/// without real child processes. The handler performs any side effects a
/// real child would (e.g. fake monkeyc writing the `-o` output file) and
/// returns the exit code and captured streams.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    typealias Handler = @Sendable (FakeInvocation) async throws -> (
        exitCode: Int32, stdout: Data, stderr: Data
    )

    private let lock = NSLock()
    private var recorded: [FakeInvocation] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var invocations: [FakeInvocation] {
        lock.withLock { recorded }
    }

    private func record(_ invocation: FakeInvocation) {
        lock.withLock { recorded.append(invocation) }
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess {
        let invocation = FakeInvocation(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        record(invocation)
        return FakeRunningProcess(
            invocation: invocation, handler: handler, onStdout: onStdout, onStderr: onStderr)
    }
}

/// The fake child: runs the handler once inside `wait()`.
actor FakeRunningProcess: RunningProcess {
    nonisolated let pid: Int32 = 4242

    private let invocation: FakeInvocation
    private let handler: FakeProcessRunner.Handler
    private let onStdout: (@Sendable (Data) -> Void)?
    private let onStderr: (@Sendable (Data) -> Void)?

    init(
        invocation: FakeInvocation,
        handler: @escaping FakeProcessRunner.Handler,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) {
        self.invocation = invocation
        self.handler = handler
        self.onStdout = onStdout
        self.onStderr = onStderr
    }

    func wait() async throws -> ProcessOutput {
        let result = try await handler(invocation)
        if !result.stdout.isEmpty { onStdout?(result.stdout) }
        if !result.stderr.isEmpty { onStderr?(result.stderr) }
        return ProcessOutput(
            exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    func terminate(grace: Duration) async {}
}
