import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("Monkeydo process lifecycle")
struct MonkeydoProcessLifecycleTests {
    @Test("app launch captures the exact Bash wrapper before returning ownership")
    func appLaunchCapturesExactWrapper() async throws {
        let sdk = sampleSdk()
        let prg = URL(fileURLWithPath: "/tmp/App With Spaces.prg")
        let process = LifecycleRunningProcess(pid: 4242)
        let runner = LifecycleRunner(process: process)
        let expectedArguments = [
            "/bin/bash", sdk.monkeydo.path, prg.path, "fenix6xpro",
        ]
        let reader = LifecycleIdentityReader(snapshots: [
            4242: processSnapshot(pid: 4242, arguments: expectedArguments)
        ])
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: runner, identityReader: reader)
        let command = MonkeydoCommand(
            sdk: sdk, prgPath: prg, device: "fenix6xpro", testFilter: nil)

        let owned = try await lifecycle.launchApp(command)

        #expect(owned.process.pid == 4242)
        #expect(owned.launcher == processSnapshot(pid: 4242, arguments: expectedArguments))
        #expect(owned.command == command)
        #expect(runner.invocations == [
            LifecycleInvocation(executable: sdk.monkeydo, arguments: [prg.path, "fenix6xpro"])
        ])
        #expect(await process.terminationCount == 0)
    }

    @Test("test launch appends only the exact structured test suffix", arguments: [
        (filter: Optional<String>.none, suffix: ["-t"]),
        (filter: Optional("Suite Name.test case"), suffix: ["-t", "Suite Name.test case"]),
    ])
    func testLaunchUsesExactSuffix(filter: String?, suffix: [String]) async throws {
        let sdk = sampleSdk()
        let prg = URL(fileURLWithPath: "/tmp/App With Spaces.prg")
        let process = LifecycleRunningProcess(pid: 4242)
        let runner = LifecycleRunner(process: process)
        let wrapperArguments = [
            "/bin/bash", sdk.monkeydo.path, prg.path, "fenix6xpro",
        ] + suffix
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: runner,
            identityReader: LifecycleIdentityReader(snapshots: [
                4242: processSnapshot(pid: 4242, arguments: wrapperArguments)
            ]))
        let command = MonkeydoCommand(
            sdk: sdk, prgPath: prg, device: "fenix6xpro", testFilter: filter)

        let owned = try await lifecycle.launchTests(command)

        #expect(owned.launcher.arguments == wrapperArguments)
        #expect(runner.invocations == [LifecycleInvocation(
            executable: sdk.monkeydo,
            arguments: [prg.path, "fenix6xpro"] + suffix)])
    }

    @Test("a deceptive wrapper argv is rejected and the returned process is cleaned up")
    func deceptiveWrapperIsRejectedAndCleaned() async {
        let sdk = sampleSdk()
        let prg = URL(fileURLWithPath: "/tmp/App.prg")
        let process = LifecycleRunningProcess(pid: 4242)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: process),
            identityReader: LifecycleIdentityReader(snapshots: [
                4242: processSnapshot(
                    pid: 4242,
                    arguments: [
                        "/bin/bash", sdk.monkeydo.path + "-other", prg.path,
                        "fenix6xpro",
                    ])
            ]))

        do {
            _ = try await lifecycle.launchApp(MonkeydoCommand(
                sdk: sdk, prgPath: prg, device: "fenix6xpro", testFilter: nil))
            Issue.record("prefix-like wrapper argv must not establish ownership")
        } catch let error as ToolError {
            #expect(error.code == "app_launch_failed")
            #expect(!error.fix.isEmpty)
        } catch {
            Issue.record("wrapper mismatch must use ToolError: \(error)")
        }
        #expect(await process.terminationCount == 1)
    }

    @Test("a fully anchored dedicated launcher group is signalled as one unit")
    func dedicatedGroupUsesGroupSignal() async throws {
        let fixture = mutableCleanupFixture()
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        try await lifecycle.terminate(fixture.owned, grace: .zero)

        #expect(fixture.runtime.values == [LifecycleSignalCall(pid: -100, signal: SIGTERM)])
    }

    /// proc_listpids and snapshot are not atomic. A descendant that exits in
    /// between is reported by the kernel list and is then uninspectable, which
    /// is a normal race and not a fault: there is nothing left to signal. It
    /// must not abort cleanup of the processes that ARE still alive.
    @Test("a descendant that exits between listing and inspection does not abort cleanup")
    func vanishedDescendantDoesNotAbortCleanup() async throws {
        // 102 is listed as a child of 101 but has no snapshot: it exited in the
        // window between the two calls.
        let fixture = mutableCleanupFixture(uninspectable: [102])
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        try await lifecycle.terminate(fixture.owned, grace: .zero)
        #expect(fixture.runtime.contains(pid: 101) == false)
    }

    @Test("dedicated group TERM passively awaits verified descendants after launcher exit")
    func dedicatedGroupWaitsForVerifiedNaturalExit() async throws {
        let fixture = mutableCleanupFixture(
            survivesTerm: [101, 102],
            naturallyExitGroupAfterFirstPostSignalPoll: true)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        try await lifecycle.terminate(fixture.owned, grace: .milliseconds(10))

        #expect(fixture.runtime.values == [LifecycleSignalCall(pid: -100, signal: SIGTERM)])
        #expect(!fixture.runtime.contains(pid: 101))
        #expect(!fixture.runtime.contains(pid: 102))
    }

    @Test("passive group wait tolerates an authorized PID exiting after enumeration")
    func dedicatedGroupWaitHandlesListSnapshotExitRace() async throws {
        let fixture = mutableCleanupFixture(
            survivesTerm: [101, 102],
            naturallyExitGroupAfterFirstPostSignalPoll: true,
            vanishListedPIDAfterFirstPostSignalGroupList: 101)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        try await lifecycle.terminate(fixture.owned, grace: .milliseconds(10))

        #expect(fixture.runtime.values == [LifecycleSignalCall(pid: -100, signal: SIGTERM)])
        #expect(!fixture.runtime.contains(pid: 101))
        #expect(!fixture.runtime.contains(pid: 102))
    }

    @Test("passive group wait rejects an authorized process that leaves the group alive")
    func dedicatedGroupWaitRejectsLiveProcessOutsideGroup() async {
        let fixture = mutableCleanupFixture(
            survivesTerm: [101],
            movePIDToOtherGroupAfterGroupTERM: 101)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        await #expect(throws: ToolError.self) {
            try await lifecycle.terminate(fixture.owned, grace: .milliseconds(10))
        }

        #expect(fixture.runtime.values == [LifecycleSignalCall(pid: -100, signal: SIGTERM)])
        #expect(fixture.runtime.contains(pid: 101))
    }

    @Test("an extra group member falls back to deepest-first individual signalling")
    func extraGroupMemberUsesIndividualSignals() async throws {
        let fixture = mutableCleanupFixture(includeExtra: true)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        try await lifecycle.terminate(fixture.owned, grace: .zero)

        #expect(fixture.runtime.values == [
            LifecycleSignalCall(pid: 102, signal: SIGTERM),
            LifecycleSignalCall(pid: 101, signal: SIGTERM),
            LifecycleSignalCall(pid: 100, signal: SIGTERM),
        ])
    }

    @Test("an uninspectable listed group member aborts without signalling")
    func uninspectableGroupMemberSendsNothing() async {
        let fixture = mutableCleanupFixture(groupPIDs: [100, 101, 102, 999])
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        do {
            try await lifecycle.terminate(fixture.owned, grace: .zero)
            Issue.record("an unknown group member must fail closed")
        } catch let error as ToolError {
            #expect(error.code == "monkeydo_cleanup_failed")
            #expect(!error.fix.isEmpty)
        } catch {
            Issue.record("cleanup failures must use ToolError: \(error)")
        }
        #expect(fixture.runtime.values.isEmpty)
    }

    @Test("termination revalidates TERM and KILL and drains the owned process exactly once")
    func terminationRevalidatesAndDrainsOnce() async throws {
        let fixture = mutableCleanupFixture(includeExtra: true, survivesTerm: [102])
        let process = try #require(fixture.owned.process as? LifecycleRunningProcess)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: process),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        try await lifecycle.terminate(fixture.owned, grace: .zero)

        #expect(fixture.runtime.values == [
            LifecycleSignalCall(pid: 102, signal: SIGTERM),
            LifecycleSignalCall(pid: 102, signal: SIGKILL),
            LifecycleSignalCall(pid: 101, signal: SIGTERM),
            LifecycleSignalCall(pid: 100, signal: SIGTERM),
        ])
        #expect(await process.waitCount == 1)
    }

    @Test("an already-cancelled caller still awaits one complete cleanup")
    func cancellationCannotAbandonCleanup() async throws {
        let fixture = mutableCleanupFixture()
        let process = try #require(fixture.owned.process as? LifecycleRunningProcess)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: process),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)
        let task = Task {
            try await lifecycle.terminate(fixture.owned, grace: .zero)
        }

        task.cancel()
        try await task.value

        #expect(fixture.runtime.values == [LifecycleSignalCall(pid: -100, signal: SIGTERM)])
        #expect(await process.waitCount == 1)
    }

    @Test("a child surviving SIGKILL preserves every ancestor anchor")
    func childSurvivingKillPreservesAncestors() async {
        let fixture = mutableCleanupFixture(
            includeExtra: true, survivesTerm: [102], survivesKill: [102])
        let clock = FakeClock()
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500,
            clock: clock)
        let cleanup = Task {
            try await lifecycle.terminate(fixture.owned, grace: .zero)
        }

        await fixture.runtime.waitForKillSignal()
        clock.advance(by: .seconds(5))
        await #expect(throws: ToolError.self) {
            try await cleanup.value
        }
        #expect(fixture.runtime.values == [
            LifecycleSignalCall(pid: 102, signal: SIGTERM),
            LifecycleSignalCall(pid: 102, signal: SIGKILL),
        ])
        #expect(fixture.runtime.contains(pid: 101))
        #expect(fixture.runtime.contains(pid: 100))
    }

    @Test("a descendant signal failure preserves every ancestor anchor")
    func partialSignalFailurePreservesAncestors() async {
        let fixture = mutableCleanupFixture(includeExtra: true, failingPID: 102)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        await #expect(throws: ToolError.self) {
            try await lifecycle.terminate(fixture.owned, grace: .zero)
        }

        #expect(fixture.runtime.values == [LifecycleSignalCall(pid: 102, signal: SIGTERM)])
        #expect(fixture.runtime.contains(pid: 101))
        #expect(fixture.runtime.contains(pid: 100))
    }

    @Test("launcher disappearance with a surviving group member fails closed")
    func launcherDisappearanceWithSurvivorFailsClosed() async {
        let fixture = mutableCleanupFixture()
        fixture.runtime.remove(pid: 100)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        await #expect(throws: ToolError.self) {
            try await lifecycle.terminate(fixture.owned, grace: .zero)
        }

        #expect(fixture.runtime.values.isEmpty)
        #expect(fixture.runtime.contains(pid: 102))
    }

    @Test("an inherited server group always uses individual cleanup")
    func inheritedServerGroupUsesIndividualCleanup() async throws {
        let fixture = inheritedGroupCleanupFixture()
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        try await lifecycle.terminate(fixture.owned, grace: .zero)

        #expect(fixture.runtime.values.map(\.pid) == [102, 101, 100])
        #expect(fixture.runtime.contains(pid: 500))
    }

    @Test("a late descendant is removed before its ancestor")
    func lateDescendantIsRemovedBeforeAncestor() async throws {
        let fixture = mutableCleanupFixture(includeExtra: true, spawnAfterSignal: [
            102: ProcessIdentitySnapshot(
                pid: 103, parentPid: 101, processGroupId: 100,
                start: ProcessStartIdentity(seconds: 1000, microseconds: 103),
                executablePath: sampleSdk().root.appending(path: "bin/shell").path,
                arguments: ["late-shell"])
        ])
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        try await lifecycle.terminate(fixture.owned, grace: .zero)

        #expect(fixture.runtime.values.map(\.pid) == [102, 103, 101, 100])
    }

    @Test("group authorization rejects a changed full identity before signalling")
    func changedGroupIdentitySendsNothing() async {
        let replacement = ProcessIdentitySnapshot(
            pid: 102, parentPid: 101, processGroupId: 100,
            start: ProcessStartIdentity(seconds: 2000, microseconds: 102),
            executablePath: sampleSdk().root.appending(path: "bin/shell").path,
            arguments: ["shell"])
        let fixture = mutableCleanupFixture(changeOnFirstGroupCapture: (102, replacement))
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: LifecycleRunningProcess(pid: 100)),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        await #expect(throws: ToolError.self) {
            try await lifecycle.terminate(fixture.owned, grace: .zero)
        }
        #expect(fixture.runtime.values.isEmpty)
    }

    @Test("initial launcher capture failure removes rooted descendants before wrapper cleanup")
    func initialCaptureFailureCleansDescendantsFirst() async {
        let fixture = mutableCleanupFixture(includeExtra: true)
        let process = LifecycleRunningProcess(pid: 100)
        let lifecycle = MonkeydoProcessLifecycle(
            processRunner: LifecycleRunner(process: process),
            identityReader: fixture.runtime,
            signalSender: fixture.runtime,
            serverPID: 500)

        await #expect(throws: ToolError.self) {
            _ = try await lifecycle.launchApp(MonkeydoCommand(
                sdk: sampleSdk(), prgPath: URL(fileURLWithPath: "/tmp/other.prg"),
                device: "fenix6xpro", testFilter: nil))
        }

        #expect(fixture.runtime.values.map(\.pid) == [102, 101])
        #expect(await process.terminationCount == 1)
        #expect(await process.waitCount == 1)
    }

    @Test("natural observation and termination share one process drain")
    func observationAndTerminationDrainExactlyOnce() async throws {
        let fixture = cleanupFixture(groupPIDs: [100, 101, 102])
        let process = try #require(fixture.owned.process as? LifecycleRunningProcess)
        async let first = fixture.owned.output()
        async let second = fixture.owned.output()

        _ = try await (first, second)

        #expect(await process.waitCount == 1)
    }
}

private func sampleSdk() -> SdkInfo {
    SdkInfo(
        version: SemVer(major: 9, minor: 1, patch: 0),
        root: URL(fileURLWithPath: "/SDK With Spaces"),
        source: .explicit)
}

private func processSnapshot(pid: Int32, arguments: [String]) -> ProcessIdentitySnapshot {
    ProcessIdentitySnapshot(
        pid: pid,
        parentPid: 4000,
        processGroupId: pid,
        start: ProcessStartIdentity(seconds: 1_721_234_567, microseconds: 42),
        executablePath: "/bin/bash",
        arguments: arguments)
}

private struct LifecycleInvocation: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
}

private final class LifecycleRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let process: LifecycleRunningProcess
    private var recorded: [LifecycleInvocation] = []

    init(process: LifecycleRunningProcess) {
        self.process = process
    }

    var invocations: [LifecycleInvocation] { lock.withLock { recorded } }

    func start(
        executable: URL,
        arguments: [String],
        environment _: [String: String]?,
        workingDirectory _: URL?,
        timeout _: Duration?,
        onStdout _: (@Sendable (Data) -> Void)?,
        onStderr _: (@Sendable (Data) -> Void)?
    ) async throws -> any RunningProcess {
        lock.withLock {
            recorded.append(LifecycleInvocation(executable: executable, arguments: arguments))
        }
        return process
    }
}

private actor LifecycleRunningProcess: RunningProcess {
    nonisolated let pid: Int32
    private(set) var terminationCount = 0
    private(set) var waitCount = 0

    init(pid: Int32) { self.pid = pid }

    func wait() async throws -> ProcessOutput {
        waitCount += 1
        return ProcessOutput(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func terminate(grace _: Duration) async { terminationCount += 1 }
}

private struct LifecycleIdentityReader: SimulatorMCPCore.ProcessIdentityReading, Sendable {
    let snapshots: [Int32: ProcessIdentitySnapshot]
    let children: [Int32: [Int32]]
    let groups: [Int32: [Int32]]

    init(
        snapshots: [Int32: ProcessIdentitySnapshot],
        children: [Int32: [Int32]] = [:],
        groups: [Int32: [Int32]] = [:]
    ) {
        self.snapshots = snapshots
        self.children = children
        self.groups = groups
    }

    func snapshot(pid: Int32) throws -> ProcessIdentitySnapshot? { snapshots[pid] }
    func childPIDs(parentPid: Int32) throws -> [Int32] { children[parentPid] ?? [] }
    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        groups[processGroupId] ?? []
    }
}

private struct CleanupFixture {
    let reader: LifecycleIdentityReader
    let owned: OwnedMonkeydoProcess
}

private func cleanupFixture(groupPIDs: [Int32], includeExtra: Bool = false) -> CleanupFixture {
    let sdk = sampleSdk()
    let prg = URL(fileURLWithPath: "/tmp/App.prg")
    let launcher = ProcessIdentitySnapshot(
        pid: 100, parentPid: 500, processGroupId: 100,
        start: ProcessStartIdentity(seconds: 1000, microseconds: 100),
        executablePath: "/bin/bash",
        arguments: ["/bin/bash", sdk.monkeydo.path, prg.path, "fenix6xpro"])
    let java = ProcessIdentitySnapshot(
        pid: 101, parentPid: 100, processGroupId: 100,
        start: ProcessStartIdentity(seconds: 1000, microseconds: 101),
        executablePath: "/JDK/bin/java", arguments: ["java"])
    let shell = ProcessIdentitySnapshot(
        pid: 102, parentPid: 101, processGroupId: 100,
        start: ProcessStartIdentity(seconds: 1000, microseconds: 102),
        executablePath: sdk.root.appending(path: "bin/shell").path, arguments: ["shell"])
    let server = ProcessIdentitySnapshot(
        pid: 500, parentPid: 1, processGroupId: 500,
        start: ProcessStartIdentity(seconds: 1000, microseconds: 500),
        executablePath: "/usr/local/bin/simulator-mcp", arguments: ["simulator-mcp"])
    let extra = ProcessIdentitySnapshot(
        pid: 999, parentPid: 1, processGroupId: 100,
        start: ProcessStartIdentity(seconds: 1000, microseconds: 999),
        executablePath: "/unrelated", arguments: ["unrelated"])
    var snapshots: [Int32: ProcessIdentitySnapshot] = [
        100: launcher, 101: java, 102: shell, 500: server,
    ]
    if includeExtra { snapshots[999] = extra }
    return CleanupFixture(
        reader: LifecycleIdentityReader(
            snapshots: snapshots,
            children: [100: [101], 101: [102]],
            groups: [100: groupPIDs]),
        owned: OwnedMonkeydoProcess(
            process: LifecycleRunningProcess(pid: 100),
            launcher: launcher,
            command: MonkeydoCommand(
                sdk: sdk, prgPath: prg, device: "fenix6xpro", testFilter: nil)))
}

private struct MutableCleanupFixture {
    let runtime: LifecycleMutableRuntime
    let owned: OwnedMonkeydoProcess
}

private func mutableCleanupFixture(
    includeExtra: Bool = false,
    groupPIDs: [Int32]? = nil,
    survivesTerm: Set<Int32> = [],
    survivesKill: Set<Int32> = [],
    spawnAfterSignal: [Int32: ProcessIdentitySnapshot] = [:],
    changeOnFirstGroupCapture: (Int32, ProcessIdentitySnapshot)? = nil,
    failingPID: Int32? = nil,
    uninspectable: Set<Int32> = [],
    naturallyExitGroupAfterFirstPostSignalPoll: Bool = false,
    vanishListedPIDAfterFirstPostSignalGroupList: Int32? = nil,
    movePIDToOtherGroupAfterGroupTERM: Int32? = nil
) -> MutableCleanupFixture {
    let staticFixture = cleanupFixture(
        groupPIDs: groupPIDs ?? (includeExtra ? [100, 101, 102, 999] : [100, 101, 102]),
        includeExtra: includeExtra)
    let runtime = LifecycleMutableRuntime(
        snapshots: Array(staticFixture.reader.snapshots.values),
        explicitGroupPIDs: groupPIDs,
        survivesTerm: survivesTerm,
        survivesKill: survivesKill,
        spawnAfterSignal: spawnAfterSignal,
        changeOnFirstGroupCapture: changeOnFirstGroupCapture,
        failingPID: failingPID,
        uninspectable: uninspectable,
        naturallyExitGroupAfterFirstPostSignalPoll:
            naturallyExitGroupAfterFirstPostSignalPoll,
        vanishListedPIDAfterFirstPostSignalGroupList:
            vanishListedPIDAfterFirstPostSignalGroupList,
        movePIDToOtherGroupAfterGroupTERM: movePIDToOtherGroupAfterGroupTERM)
    return MutableCleanupFixture(
        runtime: runtime,
        owned: OwnedMonkeydoProcess(
            process: LifecycleRunningProcess(pid: 100),
            launcher: staticFixture.owned.launcher,
            command: staticFixture.owned.command))
}

private func inheritedGroupCleanupFixture() -> MutableCleanupFixture {
    let base = cleanupFixture(groupPIDs: [100, 101, 102])
    let snapshots = base.reader.snapshots.values.map { snapshot in
        guard [100, 101, 102].contains(snapshot.pid) else { return snapshot }
        return ProcessIdentitySnapshot(
            pid: snapshot.pid,
            parentPid: snapshot.parentPid,
            processGroupId: 500,
            start: snapshot.start,
            executablePath: snapshot.executablePath,
            arguments: snapshot.arguments)
    }
    let launcher = snapshots.first(where: { $0.pid == 100 })!
    let runtime = LifecycleMutableRuntime(
        snapshots: Array(snapshots),
        explicitGroupPIDs: nil,
        survivesTerm: [],
        survivesKill: [],
        spawnAfterSignal: [:],
        changeOnFirstGroupCapture: nil,
        failingPID: nil,
        naturallyExitGroupAfterFirstPostSignalPoll: false,
        vanishListedPIDAfterFirstPostSignalGroupList: nil,
        movePIDToOtherGroupAfterGroupTERM: nil)
    return MutableCleanupFixture(
        runtime: runtime,
        owned: OwnedMonkeydoProcess(
            process: LifecycleRunningProcess(pid: 100),
            launcher: launcher,
            command: base.owned.command))
}

private final class LifecycleMutableRuntime: SimulatorMCPCore.ProcessIdentityReading,
    SimulatorMCPCore.ProcessSignalSending, @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshots: [Int32: ProcessIdentitySnapshot]
    private var recorded: [LifecycleSignalCall] = []
    private let explicitGroupPIDs: [Int32]?
    private let survivesTerm: Set<Int32>
    private let survivesKill: Set<Int32>
    private let spawnAfterSignal: [Int32: ProcessIdentitySnapshot]
    private var changeOnFirstGroupCapture: (Int32, ProcessIdentitySnapshot)?
    private let failingPID: Int32?
    /// Listed by the kernel but not inspectable: the TOCTOU window.
    private let uninspectable: Set<Int32>
    private let naturallyExitGroupAfterFirstPostSignalPoll: Bool
    private var pendingNaturalGroupExit = false
    private var observedPendingNaturalGroupExit = false
    private var vanishListedPIDAfterFirstPostSignalGroupList: Int32?
    private var movePIDToOtherGroupAfterGroupTERM: Int32?
    private var groupTermWasSent = false
    private let killGate = LifecycleSyncGate()

    init(
        snapshots: [ProcessIdentitySnapshot],
        explicitGroupPIDs: [Int32]?,
        survivesTerm: Set<Int32>,
        survivesKill: Set<Int32>,
        spawnAfterSignal: [Int32: ProcessIdentitySnapshot],
        changeOnFirstGroupCapture: (Int32, ProcessIdentitySnapshot)?,
        failingPID: Int32?,
        uninspectable: Set<Int32> = [],
        naturallyExitGroupAfterFirstPostSignalPoll: Bool,
        vanishListedPIDAfterFirstPostSignalGroupList: Int32?,
        movePIDToOtherGroupAfterGroupTERM: Int32?
    ) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        self.explicitGroupPIDs = explicitGroupPIDs
        self.survivesTerm = survivesTerm
        self.survivesKill = survivesKill
        self.spawnAfterSignal = spawnAfterSignal
        self.changeOnFirstGroupCapture = changeOnFirstGroupCapture
        self.failingPID = failingPID
        self.uninspectable = uninspectable
        self.naturallyExitGroupAfterFirstPostSignalPoll =
            naturallyExitGroupAfterFirstPostSignalPoll
        self.vanishListedPIDAfterFirstPostSignalGroupList =
            vanishListedPIDAfterFirstPostSignalGroupList
        self.movePIDToOtherGroupAfterGroupTERM = movePIDToOtherGroupAfterGroupTERM
    }

    var values: [LifecycleSignalCall] { lock.withLock { recorded } }
    func contains(pid: Int32) -> Bool { lock.withLock { snapshots[pid] != nil } }
    func remove(pid: Int32) { lock.withLock { snapshots[pid] = nil } }
    func waitForKillSignal() async { await killGate.wait() }

    func snapshot(pid: Int32) throws -> ProcessIdentitySnapshot? {
        lock.withLock { uninspectable.contains(pid) ? nil : snapshots[pid] }
    }

    func childPIDs(parentPid: Int32) throws -> [Int32] {
        lock.withLock {
            snapshots.values.filter { $0.parentPid == parentPid }.map(\.pid).sorted()
        }
    }

    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        lock.withLock {
            if groupTermWasSent, let pid = movePIDToOtherGroupAfterGroupTERM,
                let snapshot = snapshots[pid]
            {
                snapshots[pid] = ProcessIdentitySnapshot(
                    pid: snapshot.pid,
                    parentPid: snapshot.parentPid,
                    processGroupId: 999,
                    start: snapshot.start,
                    executablePath: snapshot.executablePath,
                    arguments: snapshot.arguments)
                movePIDToOtherGroupAfterGroupTERM = nil
            }
            if let change = changeOnFirstGroupCapture {
                snapshots[change.0] = change.1
                changeOnFirstGroupCapture = nil
            }
            if let explicitGroupPIDs { return explicitGroupPIDs }
            // A dead PID is no longer a group member. Only an already-captured
            // child list can still name it, which is exactly the race the
            // descendant walk has to tolerate.
            let pids = snapshots.values
                .filter { $0.processGroupId == processGroupId }
                .map(\.pid).filter { !uninspectable.contains($0) }.sorted()
            if pendingNaturalGroupExit {
                if observedPendingNaturalGroupExit {
                    pendingNaturalGroupExit = false
                    observedPendingNaturalGroupExit = false
                    for pid in pids { snapshots[pid] = nil }
                    return []
                }
                observedPendingNaturalGroupExit = true
            }
            if groupTermWasSent,
                let vanishPID = vanishListedPIDAfterFirstPostSignalGroupList
            {
                vanishListedPIDAfterFirstPostSignalGroupList = nil
                snapshots[vanishPID] = nil
            }
            return pids
        }
    }

    func signal(pid: Int32, signal: Int32) throws {
        if signal == SIGKILL { killGate.signal() }
        try lock.withLock {
            recorded.append(LifecycleSignalCall(pid: pid, signal: signal))
            if pid == failingPID {
                throw ToolError(
                    code: "monkeydo_cleanup_failed",
                    message: "Injected signal failure for PID \(pid).",
                    fix: "Preserve the ancestor anchors and retry cleanup.")
            }
            if pid < 0 {
                let group = -pid
                let members = snapshots.values
                    .filter { $0.processGroupId == group }.map(\.pid)
                for member in members where shouldExit(pid: member, signal: signal) {
                    snapshots[member] = nil
                }
                if signal == SIGTERM,
                    naturallyExitGroupAfterFirstPostSignalPoll,
                    snapshots[group] == nil
                {
                    pendingNaturalGroupExit = true
                }
                if signal == SIGTERM { groupTermWasSent = true }
                return
            }
            if shouldExit(pid: pid, signal: signal) {
                snapshots[pid] = nil
                if let spawned = spawnAfterSignal[pid] {
                    snapshots[spawned.pid] = spawned
                }
            }
        }
    }

    private func shouldExit(pid: Int32, signal: Int32) -> Bool {
        if signal == SIGTERM { return !survivesTerm.contains(pid) }
        if signal == SIGKILL { return !survivesKill.contains(pid) }
        return true
    }
}

private final class LifecycleSyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if signalled { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            signalled = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private final class LifecycleSignalRecorder: SimulatorMCPCore.ProcessSignalSending,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recorded: [LifecycleSignalCall] = []
    var values: [LifecycleSignalCall] { lock.withLock { recorded } }
    func signal(pid: Int32, signal: Int32) throws {
        lock.withLock { recorded.append(LifecycleSignalCall(pid: pid, signal: signal)) }
    }
}

private struct LifecycleSignalCall: Equatable, Sendable {
    let pid: Int32
    let signal: Int32
}
