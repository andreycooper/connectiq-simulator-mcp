import Foundation
import Testing

@testable import SimulatorMCPCore

/// Shared `RunCoordinator` test doubles, moved out of `RunCoordinatorTests.swift`
/// so Tasks 3, 4, 5 and 8 can build on them without duplicating fixtures.
struct CoordinatorFixture {
    let sdk = SdkInfo(
        version: SemVer(major: 9, minor: 1, patch: 0),
        root: URL(fileURLWithPath: "/sdk/9.1.0", isDirectory: true),
        source: .installed)
    let prg = URL(fileURLWithPath: "/project/bin/app.prg")

    var project: ProjectDescriptor {
        ProjectDescriptor(
            root: URL(fileURLWithPath: "/project", isDirectory: true),
            jungle: URL(fileURLWithPath: "/project/monkey.jungle"),
            manifest: URL(fileURLWithPath: "/project/manifest.xml"),
            appName: "app",
            applicationId: "0123456789abcdef0123456789abcdef",
            manifestDevices: ["fenix6xpro"])
    }

    var buildContext: BuildContext {
        BuildContext(
            project: project,
            developerKey: URL(fileURLWithPath: "/keys/developer.der"))
    }

    var operationContext: OperationContext {
        OperationContext(
            simulatorPid: 42,
            sdk: sdk,
            currentDevice: nil,
            listeningEndpoints: [
                TCPEndpoint(address: "127.0.0.1", port: 1234, family: "ipv4")
            ])
    }

    /// The default readback for tests that are not about device verification.
    /// `RunCoordinator.deviceReadback` defaults to a live `DeviceReadback`,
    /// which calls `CGPreflightScreenCaptureAccess` and
    /// `CGWindowListCopyWindowInfo` — the window server, plus a TCC grant that
    /// `swift test` must never need. An empty script runs dry as
    /// `.unavailable(reason: .noSimulatorWindow)`, so verification reports
    /// itself unavailable and nothing restarts, polls, or waits.
    var deviceReadback: ScriptedReadback { ScriptedReadback([]) }

    var appRequest: RunAppRequest {
        RunAppRequest(
            project: project, buildContext: buildContext, sdk: sdk,
            device: "fenix6xpro", rebuild: true)
    }

    func testsRequest(filter: String?) -> RunTestsRequest {
        RunTestsRequest(
            project: project, buildContext: buildContext, sdk: sdk,
            device: "fenix6xpro", testFilter: filter)
    }

    func successfulBuild(mode: BuildMode) -> BuildOutcome {
        BuildOutcome(
            succeeded: true, prgPath: prg, rebuilt: true, rebuildReason: .cacheMiss,
            artifactKey: "artifact",
            device: "fenix6xpro", mode: mode, diagnostics: [])
    }

    func failedBuild(mode: BuildMode) -> BuildOutcome {
        BuildOutcome(
            succeeded: false, prgPath: nil, rebuilt: false, rebuildReason: .cacheMiss,
            artifactKey: "artifact",
            device: "fenix6xpro", mode: mode,
            diagnostics: [
                BuildDiagnostic(
                    file: "source/App.mc", line: 1, column: 1, severity: .error,
                    message: "captured compile failure")
            ])
    }

    func connectedProbe(pid: Int32, trace: CoordinatorTrace? = nil) -> CoordinatorProbe {
        CoordinatorProbe { owned in
            trace?.append("connection.probe")
            #expect(owned.launcher.pid == pid)
            return coordinatorConnection(owned)
        }
    }

    /// Accepts any of the given pids, in any order, so a test that relaunches
    /// (a device-change restart, or a post-launch retry) can supply the whole
    /// set instead of pinning the first.
    func connectedProbe(pids: [Int32], trace: CoordinatorTrace? = nil) -> CoordinatorProbe {
        CoordinatorProbe { owned in
            trace?.append("connection.probe")
            #expect(pids.contains(owned.launcher.pid))
            return coordinatorConnection(owned)
        }
    }

    static let passingTranscript = """
        ------------------------------------------------------------------------------
        Executing test probe_pass...
        DEBUG (19:07): probe_pass ran
        PASS

        ===============================================================================
        RESULTS
        Test:                               Status:
        probe_pass                          PASS
        Ran 1 test

        PASSED (passed=1, failed=0, errors=0)
        """

    static let failingTranscript = """
        ------------------------------------------------------------------------------
        Executing test probe_fail...
        DEBUG (19:07): probe_fail ran
        FAIL

        ===============================================================================
        RESULTS
        Test:                               Status:
        probe_fail                          FAIL
        Ran 1 test

        FAILED (passed=0, failed=1, errors=0)
        """
}

struct CoordinatorProbe: MonkeydoConnectionProbing, Sendable {
    let operation: @Sendable (OwnedMonkeydoProcess) async throws
        -> VerifiedMonkeydoConnection

    func waitUntilConnected(
        owned: OwnedMonkeydoProcess,
        listeningEndpoints: Set<TCPEndpoint>,
        isTestCommand: Bool,
        timeout: Duration,
        elapsedBeforeProbe: Duration
    ) async throws -> VerifiedMonkeydoConnection {
        try await operation(owned)
    }
}

actor CoordinatorCompiler: BuildCompiling {
    private var outcomes: [BuildOutcome]
    private let trace: CoordinatorTrace?
    private(set) var requests: [BuildRequest] = []

    init(outcomes: [BuildOutcome], trace: CoordinatorTrace? = nil) {
        self.outcomes = outcomes
        self.trace = trace
    }

    func build(_ request: BuildRequest) async throws -> BuildOutcome {
        trace?.append("build.\(request.mode)")
        requests.append(request)
        return outcomes.removeFirst()
    }
}

actor CoordinatorController: RunOperationControlling {
    let context: OperationContext
    let startError: ToolError?
    let publishErrorOnActive: ToolError?
    let trace: CoordinatorTrace?
    private(set) var events: [String] = []
    private(set) var restarts = 0

    init(
        context: OperationContext,
        startError: ToolError? = nil,
        publishErrorOnActive: ToolError? = nil,
        trace: CoordinatorTrace? = nil
    ) {
        self.context = context
        self.startError = startError
        self.publishErrorOnActive = publishErrorOnActive
        self.trace = trace
    }

    func withRunAppOperation(
        requested: SdkInfo,
        body: @escaping @Sendable (OperationContext) async throws -> RunAppResult
    ) async throws -> RunAppResult {
        if let startError { throw startError }
        trace?.append("run_app.lease.begin")
        events.append("run_app.begin")
        defer {
            events.append("run_app.end")
            trace?.append("run_app.lease.end")
        }
        let result = try await body(context)
        return result
    }

    func withRunTestsOperation(
        requested: SdkInfo,
        body: @escaping @Sendable (OperationContext) async throws -> RunTestsResult
    ) async throws -> RunTestsResult {
        if let startError { throw startError }
        trace?.append("run_tests.lease.begin")
        events.append("run_tests.begin")
        defer {
            events.append("run_tests.end")
            trace?.append("run_tests.lease.end")
        }
        let result = try await body(context)
        return result
    }

    func terminateActiveMonkeydo(inside operation: SimOperation) async throws {
        trace?.append("terminate_shared")
        events.append("terminate_shared")
    }

    func publishActiveMonkeydo(
        _ owned: OwnedMonkeydoProcess, device: String?, inside operation: SimOperation
    ) async throws {
        if let publishErrorOnActive { throw publishErrorOnActive }
        trace?.append(device == nil ? "active.pid" : "active.pid+device")
        events.append("active:\(owned.launcher.pid):\(device ?? "nil")")
    }

    func clearActiveMonkeydo(
        expectedLauncher: StableProcessIdentity,
        device: String?,
        inside operation: SimOperation
    ) async throws {
        trace?.append(device == nil ? "active.clear" : "active.device")
        events.append("active:nil:\(device ?? "nil")")
    }

    func revalidateReady(_ context: OperationContext, inside operation: SimOperation) async throws {
        events.append("revalidate:\(operation.rawValue)")
    }

    func clearCurrentDevice(inside operation: SimOperation) async throws {
        trace?.append("current_device.clear")
        events.append("device:nil")
    }

    /// The `RunOperationControlling` device-change restart. The double
    /// returns the same context it always had — the coordinator only needs a
    /// ready context back — and counts the calls.
    func restartForDeviceChange(
        requested: SdkInfo,
        inside operation: SimOperation
    ) async throws -> OperationContext {
        restarts += 1
        trace?.append("restart_for_device_change")
        return context
    }
}

final class CoordinatorRunner: ProcessRunning, MonkeydoProcessLifecycling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var processes: [CoordinatorProcess]
    private var recorded: [FakeInvocation] = []
    private let trace: CoordinatorTrace?

    init(processes: [CoordinatorProcess], trace: CoordinatorTrace? = nil) {
        self.processes = processes
        self.trace = trace
    }

    var invocations: [FakeInvocation] { lock.withLock { recorded } }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess {
        trace?.append("process.start")
        let process = lock.withLock { () -> CoordinatorProcess in
            recorded.append(FakeInvocation(
                executable: executable, arguments: arguments, environment: environment,
                workingDirectory: workingDirectory, timeout: timeout))
            return processes.removeFirst()
        }
        await process.install(stdout: onStdout, stderr: onStderr)
        return process
    }

    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await launch(
            command, suffix: [], workingDirectory: nil, timeout: nil,
            onStdout: onStdout, onStderr: onStderr)
    }

    func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await launch(
            command, suffix: TestTranscriptParser.testArguments(filter: command.testFilter),
            workingDirectory: workingDirectory, timeout: timeout,
            onStdout: onStdout, onStderr: onStderr)
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {
        let cleanup = Task.detached {
            await owned.process.terminate(grace: grace)
            _ = try await owned.output()
        }
        try await cleanup.value
    }

    func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership, grace: Duration
    ) async throws {}

    private func launch(
        _ command: MonkeydoCommand,
        suffix: [String],
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        let process = try await start(
            executable: command.sdk.monkeydo,
            arguments: [command.prgPath.path, command.device] + suffix,
            environment: nil, workingDirectory: workingDirectory, timeout: timeout,
            onStdout: onStdout, onStderr: onStderr)
        return OwnedMonkeydoProcess(
            process: process,
            launcher: ProcessIdentitySnapshot(
                pid: process.pid, parentPid: 1, processGroupId: process.pid,
                start: ProcessStartIdentity(seconds: 1, microseconds: UInt64(process.pid)),
                executablePath: "/bin/bash",
                arguments: ["/bin/bash", command.sdk.monkeydo.path,
                    command.prgPath.path, command.device] + suffix),
            command: command)
    }
}

// Only `init(processRunner:)` is the produced interface (Tasks 3/4/5/8
// construct coordinator-flavoured `AppSessionManager`s with it). The original
// `beginPending(executable:arguments:)` convenience overload did not move: an
// unrelated, identically-named private helper already lives in
// `AppSessionManagerTests.swift`, so making both internal would be a genuine
// redeclaration. Its four call sites in `RunCoordinatorTests.swift` now
// construct `MonkeydoCommand` directly instead.
extension AppSessionManager {
    init(processRunner: CoordinatorRunner) {
        self.init(lifecycle: processRunner)
    }
}

final class CoordinatorTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

actor CoordinatorProcess: RunningProcess {
    nonisolated let pid: Int32
    private let output: ProcessOutput?
    private let waitError: ToolError?
    private let initialStdout: Data
    private var stdout: (@Sendable (Data) -> Void)?
    private var stderr: (@Sendable (Data) -> Void)?
    private var continuation: CheckedContinuation<ProcessOutput, Error>?
    private var completedOutput: ProcessOutput?
    private var outputEmitted = false
    private(set) var terminationCount = 0

    init(
        pid: Int32,
        output: ProcessOutput?,
        waitError: ToolError? = nil,
        initialStdout: Data = Data()
    ) {
        self.pid = pid
        self.output = output
        self.waitError = waitError
        self.initialStdout = initialStdout
    }

    func install(
        stdout: (@Sendable (Data) -> Void)?, stderr: (@Sendable (Data) -> Void)?
    ) {
        self.stdout = stdout
        self.stderr = stderr
        if !initialStdout.isEmpty { stdout?(initialStdout) }
    }

    func wait() async throws -> ProcessOutput {
        if let waitError { throw waitError }
        if let completedOutput { return completedOutput }
        if let output {
            emitIfNeeded(output)
            return output
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func terminate(grace: Duration) async {
        terminationCount += 1
        let result: ProcessOutput
        if let output {
            emitIfNeeded(output)
            result = output
        } else {
            result = ProcessOutput(exitCode: 15, stdout: Data(), stderr: Data())
        }
        completedOutput = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func emitIfNeeded(_ output: ProcessOutput) {
        guard !outputEmitted else { return }
        outputEmitted = true
        if !output.stdout.isEmpty { stdout?(output.stdout) }
        if !output.stderr.isEmpty { stderr?(output.stderr) }
    }
}
