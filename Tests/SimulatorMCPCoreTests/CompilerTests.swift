import Foundation
import Testing

import SimulatorMCPCore

@Suite("Compiler")
struct CompilerTests {

    // MARK: - Argument matrix

    @Test("debugApp passes exactly the base arguments")
    func testDebugAppArguments() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = writingRunner()
        let request = try sandbox.makeRequest(mode: .debugApp)

        _ = try await Compiler(runner: runner).build(request)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable == request.sdk.monkeyc)
        #expect(invocation.argumentValue(after: "-f") == request.context.project.jungle.path)
        #expect(invocation.argumentValue(after: "-d") == "fenix6xpro")
        #expect(invocation.argumentValue(after: "-y") == request.context.developerKey.path)
        #expect(invocation.arguments.contains("-w"))
        #expect(!invocation.arguments.contains("-r"))
        #expect(!invocation.arguments.contains("-t"))

        let temp = try #require(invocation.argumentValue(after: "-o"))
        #expect(temp.hasPrefix(sandbox.binDirectory.path + "/."))
        #expect(temp.hasSuffix(".tmp"))
        #expect(temp.contains("Probe_App-fenix6xpro.prg"))
    }

    @Test("releaseApp appends -r and unitTests appends -t, never both")
    func testReleaseAndTestArguments() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }

        let releaseRunner = writingRunner()
        _ = try await Compiler(runner: releaseRunner).build(sandbox.makeRequest(mode: .releaseApp))
        let releaseArguments = try #require(releaseRunner.invocations.first).arguments
        #expect(releaseArguments.contains("-r"))
        #expect(!releaseArguments.contains("-t"))

        let testsRunner = writingRunner()
        _ = try await Compiler(runner: testsRunner).build(sandbox.makeRequest(mode: .unitTests))
        let testsArguments = try #require(testsRunner.invocations.first).arguments
        #expect(testsArguments.contains("-t"))
        #expect(!testsArguments.contains("-r"))
    }

    @Test("release together with unitTests is rejected at argument decoding")
    func testReleasePlusUnitTestsRejected() throws {
        #expect(try BuildMode(release: false, unitTests: false) == .debugApp)
        #expect(try BuildMode(release: true, unitTests: false) == .releaseApp)
        #expect(try BuildMode(release: false, unitTests: true) == .unitTests)

        do {
            _ = try BuildMode(release: true, unitTests: true)
            Issue.record("expected invalid_arguments")
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
        }
    }

    // MARK: - Success, reuse, force

    @Test("a successful build publishes the PRG and sidecar and reports rebuilt")
    func testSuccessfulBuildPublishes() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = writingRunner(content: "PRG-BYTES")
        let request = try sandbox.makeRequest()

        let outcome = try await Compiler(runner: runner).build(request)

        #expect(outcome.succeeded)
        #expect(outcome.rebuilt)
        #expect(outcome.device == "fenix6xpro")
        #expect(outcome.mode == .debugApp)
        let prgPath = try #require(outcome.prgPath)
        #expect(String(decoding: try Data(contentsOf: prgPath), as: UTF8.self) == "PRG-BYTES")
        let sidecarURL = URL(fileURLWithPath: prgPath.path + ".meta.json")
        let sidecar = try JSONDecoder().decode(
            ArtifactSidecar.self, from: Data(contentsOf: sidecarURL))
        #expect(sidecar.artifactKey == outcome.artifactKey)
        #expect(sidecar.schemaVersion == 1)
        #expect(!sidecar.prgSha256.isEmpty)
    }

    @Test("an unchanged second build reuses without invoking monkeyc again")
    func testReuseSkipsSecondInvocation() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = writingRunner()
        let compiler = Compiler(runner: runner)

        let first = try await compiler.build(sandbox.makeRequest())
        let second = try await compiler.build(sandbox.makeRequest())

        #expect(first.rebuilt)
        #expect(!second.rebuilt)
        #expect(second.succeeded)
        #expect(second.prgPath == first.prgPath)
        #expect(runner.invocations.count == 1)
    }

    @Test("force rebuilds even when the artifact is compatible")
    func testForceRebuilds() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = writingRunner()
        let compiler = Compiler(runner: runner)

        _ = try await compiler.build(sandbox.makeRequest())
        let second = try await compiler.build(sandbox.makeRequest(force: true))

        #expect(second.rebuilt)
        #expect(runner.invocations.count == 2)
    }

    @Test("an input mtime bump invalidates reuse")
    func testMtimeBumpRebuilds() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = writingRunner()
        let compiler = Compiler(runner: runner)

        _ = try await compiler.build(sandbox.makeRequest())
        try sandbox.bumpMtime(of: "source/CompilerProbe.mc")
        let second = try await compiler.build(sandbox.makeRequest())

        #expect(second.rebuilt)
        #expect(runner.invocations.count == 2)
    }

    // MARK: - rebuildReason

    @Test("a reusable artifact reports cacheHit and does not rebuild")
    func reportsCacheHit() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let compiler = Compiler(runner: writingRunner())
        _ = try await compiler.build(sandbox.makeRequest(mode: .debugApp))
        let second = try await compiler.build(sandbox.makeRequest(mode: .debugApp))
        #expect(!second.rebuilt)
        #expect(second.rebuildReason == .cacheHit)
    }

    @Test("a first build for a device reports cacheMiss, not forced")
    func reportsCacheMiss() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let compiler = Compiler(runner: writingRunner())
        let outcome = try await compiler.build(sandbox.makeRequest(mode: .debugApp))
        #expect(outcome.rebuilt)
        #expect(outcome.rebuildReason == .cacheMiss)
    }

    @Test("force reports forced even when a reusable artifact exists")
    func reportsForced() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let compiler = Compiler(runner: writingRunner())
        _ = try await compiler.build(sandbox.makeRequest(mode: .debugApp))
        let forced = try await compiler.build(sandbox.makeRequest(mode: .debugApp, force: true))
        #expect(forced.rebuildReason == .forced)
    }

    @Test("an artifact whose sidecar key no longer matches reports keyChanged")
    func reportsKeyChanged() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let compiler = Compiler(runner: writingRunner())
        _ = try await compiler.build(sandbox.makeRequest(mode: .debugApp))
        try sandbox.bumpMtime(of: "source/CompilerProbe.mc")
        let rebuilt = try await compiler.build(sandbox.makeRequest(mode: .debugApp))
        #expect(rebuilt.rebuildReason == .keyChanged)
    }

    @Test("a failed build never reports cacheHit")
    func failedBuildNeverReportsCacheHit() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = FakeProcessRunner { _ in
            (100, Data(), Data("ERROR: fenix6xpro: /p/X.mc:1,1: Broken.\n".utf8))
        }
        let outcome = try await Compiler(runner: runner).build(sandbox.makeRequest())
        #expect(!outcome.succeeded)
        #expect(outcome.rebuildReason != .cacheHit)
    }

    // MARK: - Failure paths

    @Test("ordinary compile errors return succeeded=false with diagnostics, not a throw")
    func testCompileFailureIsAnOutcome() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let stderr = """
            WARNING: fenix6xpro: /p/CompilerProbe.mc:13,8: Local variable 'unusedLocal' is not used.
            ERROR: fenix6xpro: /p/CompilerProbe.mc:17,8: Undefined symbol ':nope' detected.
            """
        let runner = FakeProcessRunner { _ in (100, Data(), Data(stderr.utf8)) }

        let outcome = try await Compiler(runner: runner).build(sandbox.makeRequest())

        #expect(!outcome.succeeded)
        #expect(outcome.prgPath == nil)
        #expect(!outcome.rebuilt)
        let hasError17 = outcome.diagnostics.contains(where: { $0.severity == .error && $0.line == 17 })
        let hasWarning13 = outcome.diagnostics.contains(where: { $0.severity == .warning && $0.line == 13 })
        #expect(hasError17)
        #expect(hasWarning13)
    }

    @Test("a failed build leaves the previous PRG and sidecar bytes unchanged")
    func testFailedBuildPreservesPreviousArtifact() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let behavior = SwitchableBehavior(content: "GOOD-PRG")
        let runner = FakeProcessRunner { invocation in
            try behavior.run(invocation)
        }
        let compiler = Compiler(runner: runner)

        let first = try await compiler.build(sandbox.makeRequest())
        let prgPath = try #require(first.prgPath)
        let sidecarURL = URL(fileURLWithPath: prgPath.path + ".meta.json")
        let prgBytes = try Data(contentsOf: prgPath)
        let sidecarBytes = try Data(contentsOf: sidecarURL)

        try sandbox.bumpMtime(of: "source/CompilerProbe.mc")  // defeat reuse
        behavior.failFromNowOn()
        let second = try await compiler.build(sandbox.makeRequest())

        #expect(!second.succeeded)
        #expect(try Data(contentsOf: prgPath) == prgBytes)
        #expect(try Data(contentsOf: sidecarURL) == sidecarBytes)
    }

    @Test("a build failure with no parsed error still carries one error diagnostic")
    func testFailureWithNoParsedErrorGetsSummary() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = FakeProcessRunner { _ in
            (1, Data(), Data("something exploded in an unstructured way\n".utf8))
        }

        let outcome = try await Compiler(runner: runner).build(sandbox.makeRequest())

        #expect(!outcome.succeeded)
        let errors = outcome.diagnostics.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors[0].message.contains("something exploded"))
    }

    @Test("a launch failure or timeout remains a thrown ToolError")
    func testLaunchFailureThrows() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = FakeProcessRunner { _ in
            throw ToolError(
                code: "operation_timeout",
                message: "monkeyc did not finish within 120s.",
                fix: "Increase the timeout.")
        }

        do {
            _ = try await Compiler(runner: runner).build(sandbox.makeRequest())
            Issue.record("expected the ToolError to propagate")
        } catch let error as ToolError {
            #expect(error.code == "operation_timeout")
        }
    }

    @Test("an empty temp PRG after a zero exit is an internal error, not a publication")
    func testEmptyTempPrgIsInternalError() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = writingRunner(content: "")

        do {
            _ = try await Compiler(runner: runner).build(sandbox.makeRequest())
            Issue.record("expected internal_error")
        } catch let error as ToolError {
            #expect(error.code == "internal_error")
        }
    }

    // MARK: - Concurrency

    @Test("concurrent same-target builds invoke monkeyc once", .timeLimit(.minutes(1)))
    func testConcurrentSameTargetBuildsOnce() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let runner = writingRunner(delay: .milliseconds(150))
        let compiler = Compiler(runner: runner)
        let request = try sandbox.makeRequest()

        async let first = compiler.build(request)
        async let second = compiler.build(request)
        let outcomes = try await [first, second]

        let allSucceeded = outcomes.allSatisfy { $0.succeeded }
        #expect(allSucceeded)
        #expect(runner.invocations.count == 1)
        #expect(outcomes.contains(where: { !$0.rebuilt }))
    }

    @Test("different-target builds proceed concurrently", .timeLimit(.minutes(1)))
    func testDifferentTargetsBuildConcurrently() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let rendezvous = Rendezvous(expected: 2, timeout: .seconds(5))
        let runner = FakeProcessRunner { invocation in
            guard let out = invocation.argumentValue(after: "-o") else {
                return (1, Data(), Data("missing -o".utf8))
            }
            // Both builds must be inside monkeyc at the same time;
            // serialized builds time out here and fail the assertion below.
            let overlapped = await rendezvous.arriveAndWait()
            try Data("PRG".utf8).write(to: URL(fileURLWithPath: out))
            return (overlapped ? 0 : 1, Data(), Data())
        }
        let compiler = Compiler(runner: runner)

        async let first = compiler.build(sandbox.makeRequest(device: "fenix6xpro"))
        async let second = compiler.build(sandbox.makeRequest(device: "venu3fixture"))
        let outcomes = try await [first, second]

        let allSucceeded = outcomes.allSatisfy { $0.succeeded }
        #expect(allSucceeded, "both builds must have overlapped in monkeyc")
        #expect(runner.invocations.count == 2)
    }
}

// MARK: - Helpers

/// A fake monkeyc that writes `content` to the `-o` path and exits 0.
private func writingRunner(
    content: String = "PRG-DEFAULT", delay: Duration? = nil
) -> FakeProcessRunner {
    FakeProcessRunner { invocation in
        if let delay {
            try await Task.sleep(for: delay)
        }
        guard let out = invocation.argumentValue(after: "-o") else {
            return (1, Data(), Data("missing -o".utf8))
        }
        try Data(content.utf8).write(to: URL(fileURLWithPath: out))
        return (0, Data(), Data())
    }
}

/// Fake monkeyc whose behavior can be flipped to failure mid-test.
private final class SwitchableBehavior: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    private let content: String

    init(content: String) {
        self.content = content
    }

    func failFromNowOn() {
        lock.lock()
        defer { lock.unlock() }
        failing = true
    }

    func run(_ invocation: FakeInvocation) throws -> (
        exitCode: Int32, stdout: Data, stderr: Data
    ) {
        lock.lock()
        let isFailing = failing
        lock.unlock()
        if isFailing {
            return (100, Data(), Data("ERROR: fenix6xpro: /p/X.mc:1,1: Broken.\n".utf8))
        }
        guard let out = invocation.argumentValue(after: "-o") else {
            return (1, Data(), Data("missing -o".utf8))
        }
        try Data(content.utf8).write(to: URL(fileURLWithPath: out))
        return (0, Data(), Data())
    }
}

/// Counts arrivals and resolves `true` once `expected` callers are inside
/// simultaneously; resolves `false` for a caller whose wait exceeds
/// `timeout` (i.e. the calls were serialized).
private actor Rendezvous {
    private let expected: Int
    private let timeout: Duration
    private var arrived = 0

    init(expected: Int, timeout: Duration) {
        self.expected = expected
        self.timeout = timeout
    }

    func arriveAndWait() async -> Bool {
        arrived += 1
        let deadline = ContinuousClock.now + timeout
        while arrived < expected {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
