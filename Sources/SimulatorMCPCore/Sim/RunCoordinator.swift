import Foundation

public struct RunAppRequest: Sendable {
    public let project: ProjectDescriptor
    public let buildContext: BuildContext
    public let sdk: SdkInfo
    public let device: String
    public let rebuild: Bool

    public init(
        project: ProjectDescriptor,
        buildContext: BuildContext,
        sdk: SdkInfo,
        device: String,
        rebuild: Bool
    ) {
        self.project = project
        self.buildContext = buildContext
        self.sdk = sdk
        self.device = device
        self.rebuild = rebuild
    }
}

public struct RunTestsRequest: Sendable {
    public let project: ProjectDescriptor
    public let buildContext: BuildContext
    public let sdk: SdkInfo
    public let device: String
    public let testFilter: String?

    public init(
        project: ProjectDescriptor,
        buildContext: BuildContext,
        sdk: SdkInfo,
        device: String,
        testFilter: String?
    ) {
        self.project = project
        self.buildContext = buildContext
        self.sdk = sdk
        self.device = device
        self.testFilter = testFilter
    }
}

/// Narrow operation surface used by run orchestration. The concrete
/// SimulatorController keeps FIFO + flock ownership and runtime mutation in
/// one actor; tests can record the same boundaries without touching macOS.
public protocol RunOperationControlling: Sendable {
    func withRunAppOperation(
        requested: SdkInfo,
        body: @escaping @Sendable (OperationContext) async throws -> RunAppResult
    ) async throws -> RunAppResult

    func withRunTestsOperation(
        requested: SdkInfo,
        body: @escaping @Sendable (OperationContext) async throws -> RunTestsResult
    ) async throws -> RunTestsResult

    func terminateActiveMonkeydo(inside operation: SimOperation) async throws

    func publishActiveMonkeydo(
        _ owned: OwnedMonkeydoProcess,
        device: String?,
        inside operation: SimOperation
    ) async throws

    func clearActiveMonkeydo(
        expectedLauncher: StableProcessIdentity,
        device: String?,
        inside operation: SimOperation
    ) async throws

    func revalidateReady(
        _ context: OperationContext,
        inside operation: SimOperation
    ) async throws
}

extension SimulatorController: RunOperationControlling {
    public func withRunAppOperation(
        requested: SdkInfo,
        body: @escaping @Sendable (OperationContext) async throws -> RunAppResult
    ) async throws -> RunAppResult {
        try await withOperation(.runApp, requirement: .ready(requested: requested), body: body)
    }

    public func withRunTestsOperation(
        requested: SdkInfo,
        body: @escaping @Sendable (OperationContext) async throws -> RunTestsResult
    ) async throws -> RunTestsResult {
        try await withOperation(.runTests, requirement: .ready(requested: requested), body: body)
    }
}

public struct RunCoordinator: Sendable {
    private static let maximumAttempts = 3

    private let controller: any RunOperationControlling
    private let compiler: any BuildCompiling
    private let sessionManager: AppSessionManager
    private let lifecycle: any MonkeydoProcessLifecycling
    private let connectionProbe: any MonkeydoConnectionProbing
    private let evidenceObserver: (any RunEvidenceObserving)?
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline
    private let launchTimeout: Duration

    public init(
        controller: any RunOperationControlling,
        compiler: any BuildCompiling = Compiler(),
        sessionManager: AppSessionManager,
        processRunner: any ProcessRunning = Subprocess(),
        lifecycle: (any MonkeydoProcessLifecycling)? = nil,
        connectionProbe: (any MonkeydoConnectionProbing)? = nil,
        evidenceObserver: (any RunEvidenceObserving)? = nil,
        launchTimeout: Duration = .seconds(30)
    ) {
        let clock = ContinuousClock()
        self.controller = controller
        self.compiler = compiler
        self.sessionManager = sessionManager
        self.lifecycle = lifecycle
            ?? (processRunner as? any MonkeydoProcessLifecycling)
            ?? MonkeydoProcessLifecycle(processRunner: processRunner)
        self.connectionProbe = connectionProbe ?? MonkeydoConnectionProbe(processRunner: processRunner)
        self.evidenceObserver = evidenceObserver
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.launchTimeout = launchTimeout
    }

    init<C: Clock>(
        controller: any RunOperationControlling,
        compiler: any BuildCompiling,
        sessionManager: AppSessionManager,
        processRunner: any ProcessRunning,
        lifecycle: (any MonkeydoProcessLifecycling)? = nil,
        connectionProbe: any MonkeydoConnectionProbing,
        evidenceObserver: (any RunEvidenceObserving)? = nil,
        clock: C,
        launchTimeout: Duration = .seconds(30)
    ) where C.Duration == Duration {
        self.controller = controller
        self.compiler = compiler
        self.sessionManager = sessionManager
        self.lifecycle = lifecycle
            ?? (processRunner as? any MonkeydoProcessLifecycling)
            ?? MonkeydoProcessLifecycle(processRunner: processRunner)
        self.connectionProbe = connectionProbe
        self.evidenceObserver = evidenceObserver
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.launchTimeout = launchTimeout
    }

    public func runApp(_ request: RunAppRequest) async throws -> RunAppResult {
        try validate(request.project, matches: request.buildContext)
        return try await controller.withRunAppOperation(requested: request.sdk) { context in
            do {
                let build = try await compiler.build(BuildRequest(
                    context: request.buildContext,
                    sdk: request.sdk,
                    device: request.device,
                    mode: .debugApp,
                    force: request.rebuild))
                let prg = try requireArtifact(build)

                try await sessionManager.prepareCurrentForReplacement()
                try await controller.terminateActiveMonkeydo(inside: .runApp)

                let deadline = makeDeadline(launchTimeout)
                var lastError: Error?
                for attempt in 1...Self.maximumAttempts {
                    try Task.checkCancellation()
                    let pending = try await sessionManager.beginPending(MonkeydoCommand(
                        sdk: request.sdk, prgPath: prg, device: request.device,
                        testFilter: nil))
                    var committed = false
                    do {
                        let accepted = try await connectionProbe.waitUntilConnected(
                            owned: pending.owned,
                            listeningEndpoints: context.listeningEndpoints,
                            isTestCommand: false,
                            timeout: deadline.remaining,
                            elapsedBeforeProbe: launchTimeout - deadline.remaining)
                        await evidenceObserver?.accepted(accepted)
                        // Runtime publication is the only fallible step after
                        // connection proof. Perform it while the candidate is
                        // still pending and the old session is still current;
                        // the OS lease prevents another mutating server from
                        // observing/acting on the staged hint. A failure can
                        // then abort the candidate without losing old logs.
                        try await controller.publishActiveMonkeydo(
                            pending.owned, device: request.device, inside: .runApp)
                        let sessionID = try await sessionManager.commit(
                            pending, device: request.device, prgPath: prg, sdk: request.sdk)
                        committed = true
                        guard let wireID = Int(exactly: sessionID) else {
                            try await sessionManager.terminateCurrent(reason: .killed)
                            throw ToolError(
                                code: "session_id_exhausted",
                                message: "The app session ID cannot be represented on the public wire contract.",
                                fix: "Restart simulator-mcp, then retry run_app.")
                        }
                        return RunAppResult(
                            sessionId: wireID,
                            device: request.device,
                            prgPath: prg.path,
                            sdkPath: request.sdk.root.path,
                            sdkVersion: request.sdk.version.description,
                            rebuilt: build.rebuilt)
                    } catch {
                        var attemptOutput: [String] = []
                        if committed {
                            try await sessionManager.terminateCurrent(reason: .killed)
                        } else {
                            attemptOutput = try await sessionManager.abortCapturingTail(pending)
                            try await controller.clearActiveMonkeydo(
                                expectedLauncher: pending.owned.launcher.stableIdentity,
                                device: nil,
                                inside: .runApp)
                        }
                        lastError = error
                        guard isEarlyExit(error), attempt < Self.maximumAttempts,
                            !deadline.hasExpired
                        else { throw launchAttemptError(error, output: attemptOutput) }
                        try await controller.revalidateReady(context, inside: .runApp)
                    }
                }
                throw lastError ?? launchFailed("monkeydo exhausted its launch attempts")
            } catch {
                throw translateRunError(error, operation: "run_app")
            }
        }
    }

    public func runTests(_ request: RunTestsRequest) async throws -> RunTestsResult {
        try validate(request.project, matches: request.buildContext)
        return try await controller.withRunTestsOperation(requested: request.sdk) { context in
            do {
                try await sessionManager.prepareCurrentForReplacement()
                try await controller.terminateActiveMonkeydo(inside: .runTests)

                let build = try await compiler.build(BuildRequest(
                    context: request.buildContext,
                    sdk: request.sdk,
                    device: request.device,
                    mode: .unitTests,
                    force: true))
                let prg = try requireArtifact(build)
                let deadline = makeDeadline(launchTimeout)
                var lastError: Error?

                for attempt in 1...Self.maximumAttempts {
                    try Task.checkCancellation()
                    let collector = OrderedTranscriptCollector()
                    let owned: OwnedMonkeydoProcess
                    let command = MonkeydoCommand(
                        sdk: request.sdk, prgPath: prg, device: request.device,
                        testFilter: request.testFilter)
                    do {
                        owned = try await lifecycle.launchTests(
                            command,
                            workingDirectory: request.project.root,
                            timeout: .seconds(300),
                            onStdout: { collector.append($0, stream: .stdout) },
                            onStderr: { collector.append($0, stream: .stderr) })
                    } catch {
                        throw launchFailed("monkeydo could not start: \(error.localizedDescription)")
                    }

                    let outputObserver = Task {
                        do {
                            let output = try await owned.output()
                            collector.finish(exitCode: output.exitCode)
                            return output
                        } catch {
                            collector.fail(error)
                            throw error
                        }
                    }
                    do {
                        try await controller.publishActiveMonkeydo(
                            owned, device: nil, inside: .runTests)
                        let accepted = try await connectionProbe.waitUntilConnected(
                            owned: owned,
                            listeningEndpoints: context.listeningEndpoints,
                            isTestCommand: true,
                            timeout: deadline.remaining,
                            elapsedBeforeProbe: launchTimeout - deadline.remaining)
                        await evidenceObserver?.accepted(accepted)
                        let summary = try await collector.waitForSummary()
                        try await lifecycle.terminate(owned, grace: .seconds(5))
                        _ = try await outputObserver.value
                        try await controller.clearActiveMonkeydo(
                            expectedLauncher: owned.launcher.stableIdentity,
                            device: request.device,
                            inside: .runTests)
                        return result(summary, request: request, prg: prg)
                    } catch {
                        if isEarlyExit(error) {
                            if (try? await outputObserver.value) != nil {
                                if let summary = try? await collector.waitForSummary() {
                                    try await lifecycle.terminate(owned, grace: .seconds(5))
                                    try await controller.clearActiveMonkeydo(
                                        expectedLauncher: owned.launcher.stableIdentity,
                                        device: request.device,
                                        inside: .runTests)
                                    return result(summary, request: request, prg: prg)
                                }
                            }
                        }
                        try await lifecycle.terminate(owned, grace: .seconds(5))
                        _ = try? await outputObserver.value
                        // Atomic rename may have published ownership even if
                        // the following directory fsync reported failure.
                        // Matching compare-and-clear is therefore always safe
                        // and necessary after cleanup is proven.
                        try await controller.clearActiveMonkeydo(
                            expectedLauncher: owned.launcher.stableIdentity,
                            device: nil,
                            inside: .runTests)
                        lastError = error
                        guard isEarlyExit(error), attempt < Self.maximumAttempts,
                            !deadline.hasExpired
                        else { throw error }
                        try await controller.revalidateReady(context, inside: .runTests)
                    }
                }
                throw lastError ?? launchFailed("monkeydo exhausted its test launch attempts")
            } catch {
                throw translateRunError(error, operation: "run_tests")
            }
        }
    }

    private func validate(_ project: ProjectDescriptor, matches context: BuildContext) throws {
        guard project == context.project else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The run project does not match the resolved build context.",
                fix: "Resolve one project and use its BuildContext for the same run request.")
        }
    }

    private func requireArtifact(_ outcome: BuildOutcome) throws -> URL {
        guard outcome.succeeded, let prg = outcome.prgPath else {
            throw ToolError(
                code: "build_failed",
                message: "The Connect IQ build failed before monkeydo could start.",
                fix: "Fix the reported compiler diagnostics, then retry the run.",
                details: [
                    "artifactKey": .string(outcome.artifactKey),
                    "diagnosticCount": .int(outcome.diagnostics.count),
                    "diagnostics": .array(outcome.diagnostics.map { diagnostic in
                        .object([
                            "file": diagnostic.file.map(JSONValue.string) ?? .null,
                            "line": diagnostic.line.map(JSONValue.int) ?? .null,
                            "column": diagnostic.column.map(JSONValue.int) ?? .null,
                            "severity": .string(diagnostic.severity.rawValue),
                            "message": .string(diagnostic.message),
                        ])
                    }),
                ])
        }
        return prg
    }

    private func result(
        _ summary: TestSummary,
        request: RunTestsRequest,
        prg: URL
    ) -> RunTestsResult {
        RunTestsResult(
            passed: summary.passed,
            failed: summary.failed,
            errors: summary.errors,
            overallPassed: summary.overallPassed,
            perTest: summary.perTest.map {
                TestCaseResult(
                    name: $0.name,
                    status: $0.status.rawValue,
                    duration: $0.durationSeconds,
                    message: $0.message)
            },
            device: request.device,
            sdkPath: request.sdk.root.path,
            prgPath: prg.path)
    }

    private func isEarlyExit(_ error: Error) -> Bool {
        (error as? ToolError)?.code == "monkeydo_exited"
    }

    private func translateRunError(_ error: Error, operation: String) -> Error {
        if error is CancellationError || error is ToolError { return error }
        return ToolError(
            code: "run_failed",
            message: "\(operation) failed: \(error.localizedDescription)",
            fix: "Retry \(operation); if it repeats, inspect the server stderr log.")
    }

    private func launchAttemptError(_ error: Error, output: [String]) -> Error {
        guard isEarlyExit(error), let toolError = error as? ToolError else { return error }
        return ToolError(
            code: toolError.code,
            message: toolError.message,
            fix: toolError.fix,
            details: [
                "lastOutput": .array(output.map { .string($0) })
            ])
    }

    private func launchFailed(_ reason: String) -> ToolError {
        ToolError(
            code: "app_launch_failed",
            message: "The simulator child launch failed: \(reason).",
            fix: "Retry the run; if it repeats, restart the simulator and inspect its logs.")
    }

}

/// Process callbacks may arrive concurrently from the stdout and stderr pipe
/// consumers. `lock` protects every field below, callbacks never suspend while
/// holding it, and immutable snapshots are the only values crossing into async
/// code; those invariants justify the unchecked Sendable conformance.
final class OrderedTranscriptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let summaryStream: AsyncThrowingStream<TestSummary, any Error>
    private let summaryContinuation: AsyncThrowingStream<TestSummary, any Error>.Continuation
    private var partial: [LogStream: Data] = [.stdout: Data(), .stderr: Data()]
    private var partialStartedAt: [LogStream: Int] = [:]
    private var recorded: [TranscriptEvent] = []
    private var nextSequence = 1
    private var nextPartialOrder = 1
    private var completionPublished = false

    init() {
        let (stream, continuation) = AsyncThrowingStream<TestSummary, any Error>.makeStream(
            of: TestSummary.self, bufferingPolicy: .bufferingNewest(1))
        self.summaryStream = stream
        self.summaryContinuation = continuation
    }

    var events: [TranscriptEvent] { lock.withLock { recorded } }

    func append(_ data: Data, stream: LogStream) {
        let summary = lock.withLock { () -> TestSummary? in
            var bytes = partial[stream] ?? Data()
            if bytes.isEmpty, !data.isEmpty { markPartialStart(stream) }
            bytes.append(data)
            while let newline = bytes.firstIndex(of: 0x0A) {
                var line = Data(bytes[..<newline])
                if line.last == 0x0D { line.removeLast() }
                record(String(decoding: line, as: UTF8.self), stream: stream)
                bytes.removeSubrange(...newline)
                partialStartedAt[stream] = nil
                if !bytes.isEmpty { markPartialStart(stream) }
            }
            partial[stream] = bytes
            return completeSummaryIfAvailable(exitCode: nil)
        }
        publish(summary)
    }

    func finish() {
        let summary = lock.withLock { () -> TestSummary? in
            flushTrailingLines()
            return completeSummaryIfAvailable(exitCode: nil)
        }
        publish(summary)
    }

    func finish(exitCode: Int32?) {
        let completion = lock.withLock { () -> Result<TestSummary, any Error>? in
            flushTrailingLines()
            guard !completionPublished else { return nil }
            do {
                let summary = try TestTranscriptParser.parse(
                    events: recorded, exitCode: exitCode)
                completionPublished = true
                return .success(summary)
            } catch {
                completionPublished = true
                return .failure(error)
            }
        }
        publish(completion)
    }

    func fail(_ error: any Error) {
        let shouldPublish = lock.withLock { () -> Bool in
            guard !completionPublished else { return false }
            completionPublished = true
            return true
        }
        if shouldPublish { summaryContinuation.finish(throwing: error) }
    }

    func waitForSummary() async throws -> TestSummary {
        for try await summary in summaryStream { return summary }
        try Task.checkCancellation()
        throw ToolError(
            code: "test_transcript_invalid",
            message: "The test transcript completion stream ended without a summary.",
            fix: "Re-run the tests and inspect the server stderr log if the stream ends again.")
    }

    private func flushTrailingLines() {
        let trailing = [LogStream.stdout, .stderr].compactMap {
            stream -> (LogStream, Data, Int)? in
            guard let bytes = partial[stream], !bytes.isEmpty else { return nil }
            return (stream, bytes, partialStartedAt[stream] ?? Int.max)
        }.sorted { $0.2 < $1.2 }
        for (stream, bytes, _) in trailing {
            record(String(decoding: bytes, as: UTF8.self), stream: stream)
            partial[stream] = Data()
            partialStartedAt[stream] = nil
        }
    }

    private func completeSummaryIfAvailable(exitCode: Int32?) -> TestSummary? {
        guard !completionPublished,
            let summary = try? TestTranscriptParser.parse(events: recorded, exitCode: exitCode)
        else { return nil }
        completionPublished = true
        return summary
    }

    private func publish(_ summary: TestSummary?) {
        guard let summary else { return }
        summaryContinuation.yield(summary)
        summaryContinuation.finish()
    }

    private func publish(_ completion: Result<TestSummary, any Error>?) {
        guard let completion else { return }
        switch completion {
        case .success(let summary): publish(summary)
        case .failure(let error): summaryContinuation.finish(throwing: error)
        }
    }

    private func markPartialStart(_ stream: LogStream) {
        partialStartedAt[stream] = nextPartialOrder
        nextPartialOrder += 1
    }

    private func record(_ line: String, stream: LogStream) {
        recorded.append(TranscriptEvent(seq: nextSequence, stream: stream, line: line))
        nextSequence += 1
    }
}
