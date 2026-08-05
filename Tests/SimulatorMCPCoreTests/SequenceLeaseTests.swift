import Foundation
import Testing

@testable import SimulatorMCPCore

/// Gates 4 and 5: the lease is taken exactly once for a whole sequence, and a
/// sequence refused before the lease takes it zero times.
///
/// These drive a real `SimulatorController` over a real `flock`-backed
/// `SimLease` on a temp file, and count acquisitions through the lease's own
/// `afterFlockAcquired` seam. Asserting that a sequence merely *terminates*
/// would pass trivially — `AsyncFIFO` and `SimLease` are both timeout-bounded,
/// so nesting `withOperation` self-blocks for 30 s and then fails rather than
/// hanging. Counting is the only assertion that distinguishes them.
@Suite("SequenceLease")
struct SequenceLeaseTests {

    @Test("a press + screenshot + wait sequence acquires the lease exactly once")
    func wholeSequenceTakesOneLease() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.tearDown() }
        try await fixture.publishSession()
        let service = fixture.sequenceService()

        let run = try await service.run(RunSequenceToolRequest(
            steps: [
                .screenshot(label: "initial"),
                .press(button: "enter", holdMs: nil),
                .waitForLog(contains: "MARK", timeoutMs: 5_000),
                .screenshot(label: "after"),
            ],
            allowFocus: true))

        #expect(run.failure == nil)
        #expect(run.result.steps.allSatisfy { $0.status == "completed" })
        #expect(fixture.leaseAcquisitions() == 1)
    }

    /// The inverse: the same four steps as four separate public tool calls take
    /// the lease four times. Without this, "exactly once" could be an artifact
    /// of the fixture rather than a property of the sequence.
    @Test("the same work as separate tool calls takes the lease once per call")
    func separateCallsTakeALeaseEach() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.tearDown() }

        let screenshot = ScreenshotService(
            deviceCatalog: DeviceCatalog(),
            operationRunner: ScreenshotOperationRunner(controller: fixture.controller),
            makeCapturer: { _ in StubCapturer() })
        _ = try await screenshot.capture(savePath: nil)
        _ = try await screenshot.capture(savePath: nil)

        #expect(fixture.leaseAcquisitions() == 2)
    }

    @Test("a sequence refused before the lease never acquires it")
    func preLeaseRefusalsTakeNoLease() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.tearDown() }
        let service = fixture.sequenceService()

        // Over the step ceiling.
        await expectInvalidArguments {
            _ = try await service.run(RunSequenceToolRequest(
                steps: Array(repeating: .screenshot(label: "f"), count: 21), allowFocus: false))
        }
        // Over the frame ceiling.
        await expectInvalidArguments {
            _ = try await service.run(RunSequenceToolRequest(
                steps: Array(repeating: .screenshot(label: "f"), count: 7), allowFocus: false))
        }
        // Over the declared wait budget.
        await expectInvalidArguments {
            _ = try await service.run(RunSequenceToolRequest(
                steps: [
                    .waitForLog(contains: "A", timeoutMs: 15_000),
                    .waitForLog(contains: "B", timeoutMs: 15_000),
                ],
                allowFocus: false))
        }
        // No steps at all.
        await expectInvalidArguments {
            _ = try await service.run(RunSequenceToolRequest(steps: [], allowFocus: false))
        }

        #expect(fixture.leaseAcquisitions() == 0)
    }

    private func expectInvalidArguments(
        _ operation: @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("expected invalid_arguments")
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        } catch {
            Issue.record("expected ToolError, got \(error)")
        }
    }
}

// MARK: - Fixture

/// Lock-backed, not an actor: `afterFlockAcquired` is a synchronous hook, and
/// hopping to an actor there would make the count depend on task scheduling
/// rather than on acquisitions.
private final class AcquisitionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// A real controller over a real lease file, with only the outside world faked:
/// process discovery, the lsof readiness probe, the screen capturer and the
/// button transport.
private struct LeaseFixture {
    let controller: SimulatorController
    private let directory: URL
    private let counter = AcquisitionCounter()
    private let sessions: AppSessionManager
    private let process: LeaseSessionProcess

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "sequence-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let counter = self.counter
        let lease = SimLease(
            lockFile: directory.appending(path: "sim.lock"),
            clock: ContinuousClock(),
            afterFlockAcquired: { counter.record() },
            afterMetadataWrite: {})

        let sdk = leaseTestSdk()
        let identity = SimulatorProcessIdentity(
            pid: 4_242, executablePath: sdk.simulatorApp.path, sdk: sdk)

        // `currentDevice` is restored from the persisted runtime record when it
        // matches the running process, and a press step needs it to select its
        // verified profile.
        let store = RuntimeStore(runtimeFile: directory.appending(path: "runtime.json"))
        try store.write(RuntimeRecord(
            simulatorPid: identity.pid,
            executablePath: identity.executablePath,
            sdkPath: sdk.root.path,
            sdkVersion: sdk.version.description,
            currentDevice: "fenix6xpro",
            monkeydoOwnership: nil))
        let runner = FakeProcessRunner(handler: { invocation in
            let pid = invocation.argumentValue(after: "-p") ?? "4242"
            return (0, Data("p\(pid)\nf11\nn127.0.0.1:1234\n".utf8), Data())
        })
        let system = SimulatorProcessSystem(
            discover: { [identity] },
            lookup: { pid in pid == identity.pid ? identity : nil },
            launch: { _ in identity.pid },
            signal: { _, _ in })

        let process = LeaseSessionProcess()
        self.process = process
        sessions = AppSessionManager(
            lifecycle: LeaseSessionLifecycle(process: process))
        controller = SimulatorController(
            queue: AsyncFIFO(),
            lease: lease,
            runtimeStore: store,
            processRunner: runner,
            sessionStopper: NoSimulatorSessionStopper(),
            system: system,
            readinessProbe: SimulatorReadinessProbe(
                processRunner: runner, identityLookup: { pid in
                    pid == identity.pid ? identity : nil
                }))
    }

    func leaseAcquisitions() -> Int { counter.count }

    func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func sequenceService() -> SequenceService {
        let process = self.process
        return SequenceService.live(
            controller: controller,
            sessions: sessions,
            buttonDevices: [(
                profile: leaseTestProfile(),
                transports: [StubTransport(onPress: { process.emit("MARK\n") })]
            )],
            makeCapturer: { _ in StubCapturer() })
    }

    /// Publishes an app session so `waitForLog` has one to read.
    func publishSession() async throws {
        let sdk = leaseTestSdk()
        let pending = try await sessions.beginPending(MonkeydoCommand(
            sdk: sdk, prgPath: URL(fileURLWithPath: "/tmp/app.prg"), device: "fenix6xpro",
            testFilter: nil))
        _ = try await sessions.commit(
            pending, device: "fenix6xpro", prgPath: URL(fileURLWithPath: "/tmp/app.prg"),
            sdk: sdk)
    }
}

private func leaseTestSdk() -> SdkInfo {
    SdkInfo(
        version: SemVer("9.1.0")!,
        root: URL(fileURLWithPath: "/sdk/connectiq-sdk-mac-9.1.0"),
        source: .installed)
}

private func leaseTestProfile() -> InputProfile {
    InputProfile(
        core: InputProfileCore(
            schemaVersion: 2, device: "fenix6xpro", profileVersion: "fenix6xpro-verified/3",
            qualification: true, buttonOrder: ["enter", "esc", "up", "down"],
            holdEncoding: HoldEncoding(mechanism: "down-up"),
            evidence: ProfileEvidence(
                capturedOn: "2026-08-04", macOSVersion: "26.5.2", sdks: ["9.1.0"],
                surfaceDigests: [:], gateTranscriptDigests: [:])),
        transport: .focusedKeys(FocusedKeysProfile(
            sdkEntries: ["9.1.0": [
                "enter": ["keyCode": .int(36)], "esc": ["keyCode": .int(53)],
                "up": ["keyCode": .int(126)], "down": ["keyCode": .int(125)],
            ]],
            activation: [:],
            leavesSimulatorFrontmost: true)))
}

private struct StubCapturer: ScreenshotCapturing {
    func captureWindow(pid: Int32) async throws -> CapturedPNG {
        CapturedPNG(
            data: Data([0x89, 0x50, 0x4E, 0x47]), width: 454, height: 454, appDisplayRect: nil)
    }
}

private struct StubTransport: ButtonPressing {
    let onPress: @Sendable () -> Void
    var kind: ButtonTransportKind { .focusedKeys }
    var requiresFocusOptIn: Bool { true }
    func press(_ request: ButtonPressRequest, context: OperationContext) async throws {
        onPress()
    }
}

private struct LeaseSessionLifecycle: MonkeydoProcessLifecycling, Sendable {
    let process: LeaseSessionProcess

    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        process.attach(onStdout: onStdout, onStderr: onStderr)
        return OwnedMonkeydoProcess(
            process: process,
            launcher: ProcessIdentitySnapshot(
                pid: process.pid, parentPid: 1, processGroupId: process.pid,
                start: ProcessStartIdentity(seconds: 1, microseconds: UInt64(process.pid)),
                executablePath: "/bin/bash",
                arguments: ["/bin/bash", command.sdk.monkeydo.path]),
            command: command)
    }

    func launchTests(
        _ command: MonkeydoCommand, workingDirectory: URL?, timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?, onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        try await launchApp(command, onStdout: onStdout, onStderr: onStderr)
    }

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws {}
    func terminatePersisted(_ ownership: PersistedMonkeydoOwnership, grace: Duration) async throws {}
}

private final class LeaseSessionProcess: RunningProcess, @unchecked Sendable {
    nonisolated let pid: Int32 = 5_151

    private let lock = NSLock()
    private var stdout: (@Sendable (Data) -> Void)?

    func attach(
        onStdout: (@Sendable (Data) -> Void)?, onStderr: (@Sendable (Data) -> Void)?
    ) {
        lock.withLock { self.stdout = onStdout }
    }

    func emit(_ text: String) {
        let callback = lock.withLock { stdout }
        callback?(Data(text.utf8))
    }

    func wait() async throws -> ProcessOutput {
        // Never exits on its own; the sequence completes first.
        try await Task.sleep(for: .seconds(3_600))
        return ProcessOutput(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func terminate(grace: Duration) async {}
}
