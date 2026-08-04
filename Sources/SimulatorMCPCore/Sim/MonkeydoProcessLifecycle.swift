import Darwin
import Foundation

public protocol ProcessSignalSending: Sendable {
    func signal(pid: Int32, signal: Int32) throws
}

public struct DarwinProcessSignalSender: ProcessSignalSending, Sendable {
    public init() {}

    public func signal(pid: Int32, signal: Int32) throws {
        guard Darwin.kill(pid, signal) == 0 || errno == ESRCH else {
            throw ToolError(
                code: "monkeydo_cleanup_failed",
                message: "Could not signal owned monkeydo process \(pid) with signal \(signal) (errno \(errno)).",
                fix: "Stop the simulator, inspect the reported process tree, then retry.",
                details: ["pid": .int(Int(pid)), "signal": .int(Int(signal))])
        }
    }
}

public struct MonkeydoCommand: Equatable, Sendable {
    public let sdk: SdkInfo
    public let prgPath: URL
    public let device: String
    public let testFilter: String?

    public init(sdk: SdkInfo, prgPath: URL, device: String, testFilter: String?) {
        self.sdk = sdk
        self.prgPath = prgPath
        self.device = device
        self.testFilter = testFilter
    }
}

public protocol MonkeydoProcessLifecycling: Sendable {
    func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess

    func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess

    func terminate(_ owned: OwnedMonkeydoProcess, grace: Duration) async throws

    func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership,
        grace: Duration
    ) async throws
}

public struct OwnedMonkeydoProcess: Sendable {
    public let process: any RunningProcess
    public let launcher: ProcessIdentitySnapshot
    public let command: MonkeydoCommand
    private let drain: MonkeydoProcessDrain

    public init(
        process: any RunningProcess,
        launcher: ProcessIdentitySnapshot,
        command: MonkeydoCommand
    ) {
        self.process = process
        self.launcher = launcher
        self.command = command
        self.drain = MonkeydoProcessDrain(process: process)
    }

    /// Returns the one shared child result. Natural-exit observers and the
    /// lifecycle terminator may race to await it, but `RunningProcess.wait()`
    /// is started exactly once and every caller receives that same result.
    public func output() async throws -> ProcessOutput {
        try await drain.output()
    }
}

private actor MonkeydoProcessDrain {
    private let process: any RunningProcess
    private var task: Task<ProcessOutput, Error>?

    init(process: any RunningProcess) {
        self.process = process
    }

    func output() async throws -> ProcessOutput {
        if let task { return try await task.value }
        let process = self.process
        let task = Task { try await process.wait() }
        self.task = task
        return try await task.value
    }
}

/// Starts monkeydo and establishes ownership of its observed Bash wrapper.
///
/// `ProcessRunning.start` is the only suspension before launcher capture. Once
/// it returns, the libproc snapshot and every comparison are synchronous, so
/// no other actor work can interleave between receiving the PID and binding it
/// to its start identity, executable, and exact argv.
public struct MonkeydoProcessLifecycle: MonkeydoProcessLifecycling, Sendable {
    private let processRunner: any ProcessRunning
    private let identityReader: any ProcessIdentityReading
    private let signalSender: any ProcessSignalSending
    private let serverPID: Int32
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline

    public init(
        processRunner: any ProcessRunning = Subprocess(),
        identityReader: any ProcessIdentityReading = DarwinProcessIdentityReader(),
        signalSender: any ProcessSignalSending = DarwinProcessSignalSender(),
        serverPID: Int32 = getpid()
    ) {
        let clock = ContinuousClock()
        self.processRunner = processRunner
        self.identityReader = identityReader
        self.signalSender = signalSender
        self.serverPID = serverPID
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    init<C: Clock>(
        processRunner: any ProcessRunning,
        identityReader: any ProcessIdentityReading,
        signalSender: any ProcessSignalSending,
        serverPID: Int32,
        clock: C
    ) where C.Duration == Duration {
        self.processRunner = processRunner
        self.identityReader = identityReader
        self.signalSender = signalSender
        self.serverPID = serverPID
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    public func launchApp(
        _ command: MonkeydoCommand,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> OwnedMonkeydoProcess {
        guard command.testFilter == nil else {
            throw ToolError(
                code: "invalid_arguments",
                message: "An app launch cannot include a unit-test filter.",
                fix: "Use run_tests for filtered tests, or remove the test filter from run_app.")
        }
        return try await launch(
            command,
            testArguments: [],
            workingDirectory: nil,
            timeout: nil,
            onStdout: onStdout,
            onStderr: onStderr)
    }

    public func launchTests(
        _ command: MonkeydoCommand,
        workingDirectory: URL?,
        timeout: Duration? = .seconds(300),
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> OwnedMonkeydoProcess {
        try await launch(
            command,
            testArguments: TestTranscriptParser.testArguments(filter: command.testFilter),
            workingDirectory: workingDirectory,
            timeout: timeout,
            onStdout: onStdout,
            onStderr: onStderr)
    }

    public func launchTests(_ command: MonkeydoCommand) async throws -> OwnedMonkeydoProcess {
        try await launchTests(command, workingDirectory: nil)
    }

    /// Owns one cancellation-resistant TERM/grace/KILL/drain sequence. The
    /// detached task is deliberate: cleanup must start with a fresh
    /// cancellation context even when its caller is already cancelled, and
    /// this method always awaits that task before returning ownership.
    public func terminate(
        _ owned: OwnedMonkeydoProcess,
        grace: Duration = .seconds(5)
    ) async throws {
        guard grace >= .zero else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The monkeydo cleanup grace period must be zero or positive.",
                fix: "Pass a cleanup grace period that is zero or positive.")
        }
        let cleanup = Task.detached { [self, owned] in
            try await terminateInFreshContext(owned, grace: grace)
        }
        try await cleanup.value
    }

    public func terminatePersisted(
        _ ownership: PersistedMonkeydoOwnership,
        grace: Duration = .seconds(5)
    ) async throws {
        let sdkRoot = URL(fileURLWithPath: ownership.sdkPath, isDirectory: true)
        let sdk = SdkInfo(
            version: SemVer(firstIn: sdkRoot.lastPathComponent)
                ?? SemVer(major: 0, minor: 0, patch: 0),
            root: sdkRoot,
            source: .explicit)
        let snapshot = ProcessIdentitySnapshot(
            pid: ownership.launcher.pid,
            parentPid: ownership.launcherParentPid,
            processGroupId: ownership.launcher.processGroupId,
            start: ownership.launcher.start,
            executablePath: ownership.launcher.executablePath,
            arguments: ownership.launcher.arguments)
        let owned = OwnedMonkeydoProcess(
            process: PersistedMonkeydoProcess(pid: ownership.launcher.pid),
            launcher: snapshot,
            command: MonkeydoCommand(
                sdk: sdk,
                prgPath: URL(fileURLWithPath: ownership.prgPath),
                device: ownership.device,
                testFilter: ownership.testFilter))
        try await terminate(owned, grace: grace)
    }

    private func terminateInFreshContext(
        _ owned: OwnedMonkeydoProcess,
        grace: Duration
    ) async throws {
        guard try identityReader.snapshot(pid: owned.launcher.pid) != nil else {
            try requireNoGroupSurvivorsAfterLauncherExit(owned)
            _ = try await owned.output()
            return
        }

        if try exactDedicatedGroup(owned) != nil {
            try await terminateDedicatedGroup(owned, grace: grace)
        } else {
            try await terminateIndividually(owned, grace: grace)
        }
        _ = try await owned.output()
    }

    /// Returns the exact dedicated group snapshot that authorizes a negative
    /// PGID signal. Tree and group captures must agree on every full identity,
    /// not merely on their PID sets.
    private func exactDedicatedGroup(
        _ owned: OwnedMonkeydoProcess
    ) throws -> [Int32: ProcessIdentitySnapshot]? {
        let tree = try captureCleanupTree(owned)
        let group = try captureGroup(processGroupId: tree.launcher.processGroupId)
        guard let server = try identityReader.snapshot(pid: serverPID) else {
            throw cleanupError("the simulator-mcp server process could not be identity-inspected")
        }
        let treeByPID = Dictionary(uniqueKeysWithValues: tree.all.map { ($0.pid, $0) })
        for (pid, member) in group {
            if let treeMember = treeByPID[pid], member != treeMember {
                throw cleanupError(
                    "launcher-group PID \(pid) changed identity during cleanup authorization")
            }
        }
        guard tree.launcher.processGroupId > 0,
            tree.launcher.processGroupId == tree.launcher.pid,
            tree.launcher.processGroupId != server.processGroupId,
            treeByPID == group,
            group.values.allSatisfy({ $0.processGroupId == tree.launcher.processGroupId })
        else { return nil }
        return group
    }

    private func captureGroup(
        processGroupId: Int32
    ) throws -> [Int32: ProcessIdentitySnapshot] {
        try taggingInspectionSite(
            "cleanup.captureGroup",
            details: ["launcherPgid": .int(Int(processGroupId))]
        ) {
            try captureGroupInspecting(processGroupId: processGroupId)
        }
    }

    private func captureGroupInspecting(
        processGroupId: Int32
    ) throws -> [Int32: ProcessIdentitySnapshot] {
        let pids = try identityReader.processGroupPIDs(processGroupId: processGroupId)
        guard Set(pids).count == pids.count else {
            throw cleanupError("the kernel listed a launcher-group PID more than once")
        }
        var result: [Int32: ProcessIdentitySnapshot] = [:]
        for pid in pids {
            // Deliberately NOT the descendant walk's skip: a group signal hits
            // every member at once, so one unverifiable member means the whole
            // group is unsafe to signal. Fail closed.
            guard let member = try identityReader.snapshot(pid: pid) else {
                throw cleanupError(
                    "kernel-listed launcher-group PID \(pid) could not be identity-inspected")
            }
            result[pid] = member
        }
        return result
    }

    private func terminateDedicatedGroup(
        _ owned: OwnedMonkeydoProcess,
        grace: Duration
    ) async throws {
        guard let termAuthorizedGroup = try exactDedicatedGroup(owned) else {
            try await terminateIndividually(owned, grace: grace)
            return
        }
        try sendSignal(pid: -owned.launcher.processGroupId, signal: SIGTERM)
        if try await waitForDedicatedGroupExit(
            owned, authorizedGroup: termAuthorizedGroup, timeout: grace)
        { return }

        guard let launcher = try identityReader.snapshot(pid: owned.launcher.pid) else {
            throw cleanupError(
                "the launcher exited but its verified dedicated group survived SIGTERM past the cleanup deadline")
        }
        guard launcher.stableIdentity == owned.launcher.stableIdentity else {
            throw cleanupError(
                "the launcher PID changed identity before dedicated-group SIGKILL authorization")
        }
        guard let killAuthorizedGroup = try exactDedicatedGroup(owned) else {
            // The launcher is still present, but group authorization changed.
            // Preserve safety by switching to per-descendant cleanup.
            try await terminateIndividually(owned, grace: grace)
            return
        }
        try sendSignal(pid: -owned.launcher.processGroupId, signal: SIGKILL)
        guard try await waitForDedicatedGroupExit(
            owned, authorizedGroup: killAuthorizedGroup, timeout: .seconds(5))
        else {
            throw cleanupError(
                "the dedicated launcher group survived SIGKILL past the cleanup deadline")
        }
    }

    private func waitForDedicatedGroupExit(
        _ owned: OwnedMonkeydoProcess,
        authorizedGroup: [Int32: ProcessIdentitySnapshot],
        timeout: Duration
    ) async throws -> Bool {
        let deadline = makeDeadline(timeout)
        while true {
            if try authorizedGroupHasExited(owned, authorizedGroup: authorizedGroup) {
                return true
            }
            guard !deadline.hasExpired else { return false }
            try await deadline.sleepUntilNextPoll(maximumInterval: .milliseconds(100))
        }
    }

    /// Observes only; it never authorizes a signal. A PID may naturally exit
    /// between `PROC_PGRP_ONLY` enumeration and its snapshot, so that race is
    /// treated as progress and polled again. Every PID that remains
    /// inspectable must still match the stable identity authorized before the
    /// preceding group signal, and a new or reused PID remains fatal.
    private func authorizedGroupHasExited(
        _ owned: OwnedMonkeydoProcess,
        authorizedGroup: [Int32: ProcessIdentitySnapshot]
    ) throws -> Bool {
        let pids = try identityReader.processGroupPIDs(
            processGroupId: owned.launcher.processGroupId)
        guard Set(pids).count == pids.count else {
            throw cleanupError("the kernel listed a launcher-group PID more than once")
        }
        let listed = Set(pids)
        for (pid, authorized) in authorizedGroup where !listed.contains(pid) {
            guard let current = try identityReader.snapshot(pid: pid) else { continue }
            guard current.pid != authorized.pid || current.start != authorized.start else {
                throw cleanupError(
                    "authorized launcher-group PID \(pid) left group \(owned.launcher.processGroupId) while still alive")
            }
        }
        if pids.isEmpty {
            return true
        }

        for pid in pids {
            guard let member = try identityReader.snapshot(pid: pid) else {
                continue
            }
            guard authorizedGroup[pid]?.stableIdentity == member.stableIdentity else {
                throw cleanupError(
                    "dedicated-group PID \(pid) was new or changed identity while the group was exiting")
            }
        }
        if let launcher = try identityReader.snapshot(pid: owned.launcher.pid) {
            guard launcher.stableIdentity == owned.launcher.stableIdentity,
                pids.contains(launcher.pid)
            else {
                throw cleanupError(
                    "the launcher changed identity or group membership while its dedicated group was exiting")
            }
        }
        return false
    }

    /// Terminates one current deepest descendant completely before touching
    /// its ancestors. The tree is dynamically recaptured after every child,
    /// so late descendants are included and any child failure preserves all
    /// remaining ancestry anchors.
    private func terminateIndividually(
        _ owned: OwnedMonkeydoProcess,
        grace: Duration
    ) async throws {
        while true {
            guard try identityReader.snapshot(pid: owned.launcher.pid) != nil else {
                try requireNoGroupSurvivorsAfterLauncherExit(owned)
                return
            }
            let tree = try captureCleanupTree(owned)
            if let target = tree.descendants.max(by: { lhs, rhs in
                let lhsDepth = tree.depths[lhs.pid] ?? 0
                let rhsDepth = tree.depths[rhs.pid] ?? 0
                return lhsDepth == rhsDepth ? lhs.pid < rhs.pid : lhsDepth < rhsDepth
            }) {
                try await terminateDescendant(target, owned: owned, grace: grace)
                continue
            }
            if try await terminateLauncherWhenTreeEmpty(owned, grace: grace) { return }
        }
    }

    private func terminateDescendant(
        _ target: ProcessIdentitySnapshot,
        owned: OwnedMonkeydoProcess,
        grace: Duration
    ) async throws {
        try requireAnchored(target, owned: owned)
        try sendSignal(pid: target.pid, signal: SIGTERM)
        if try await waitForAnchoredExit(target, owned: owned, timeout: grace) { return }

        try requireAnchored(target, owned: owned)
        try sendSignal(pid: target.pid, signal: SIGKILL)
        guard try await waitForAnchoredExit(
            target, owned: owned, timeout: .seconds(5))
        else {
            throw cleanupError("owned descendant PID \(target.pid) survived SIGKILL")
        }
    }

    private func requireAnchored(
        _ target: ProcessIdentitySnapshot,
        owned: OwnedMonkeydoProcess
    ) throws {
        let tree = try captureCleanupTree(owned)
        guard tree.descendants.first(where: { $0.pid == target.pid }) == target else {
            throw cleanupError(
                "descendant PID \(target.pid) changed identity or ancestry before signalling")
        }
    }

    private func waitForAnchoredExit(
        _ target: ProcessIdentitySnapshot,
        owned: OwnedMonkeydoProcess,
        timeout: Duration
    ) async throws -> Bool {
        let deadline = makeDeadline(timeout)
        while true {
            guard let current = try identityReader.snapshot(pid: target.pid) else { return true }
            guard current == target else {
                throw cleanupError("descendant PID \(target.pid) changed identity while exiting")
            }
            do {
                try requireAnchored(target, owned: owned)
            } catch {
                // Normal exit may occur between the first PID snapshot and
                // the anchored-tree recapture. Accept only confirmed absence;
                // a still-live but reparented/changed target remains fatal.
                if try identityReader.snapshot(pid: target.pid) == nil { return true }
                throw error
            }
            guard !deadline.hasExpired else { return false }
            try await deadline.sleepUntilNextPoll(maximumInterval: .milliseconds(100))
        }
    }

    /// Returns false when a new child appears after launcher TERM. Its caller
    /// then removes that child before considering launcher KILL.
    private func terminateLauncherWhenTreeEmpty(
        _ owned: OwnedMonkeydoProcess,
        grace: Duration
    ) async throws -> Bool {
        let tree = try captureCleanupTree(owned)
        guard tree.descendants.isEmpty else { return false }
        let baselineGroup = try captureGroup(processGroupId: owned.launcher.processGroupId)
        try sendSignal(pid: owned.launcher.pid, signal: SIGTERM)
        let termDeadline = makeDeadline(grace)
        while true {
            guard let launcher = try identityReader.snapshot(pid: owned.launcher.pid) else {
                try auditGroupAfterLauncherExit(owned, baseline: baselineGroup)
                return true
            }
            guard launcher.stableIdentity == owned.launcher.stableIdentity else {
                throw cleanupError("the launcher PID changed identity while exiting")
            }
            do {
                if !(try captureCleanupTree(owned).descendants.isEmpty) { return false }
            } catch {
                if try identityReader.snapshot(pid: owned.launcher.pid) == nil {
                    try auditGroupAfterLauncherExit(owned, baseline: baselineGroup)
                    return true
                }
                throw error
            }
            guard !termDeadline.hasExpired else { break }
            try await termDeadline.sleepUntilNextPoll(maximumInterval: .milliseconds(100))
        }

        let finalTree = try captureCleanupTree(owned)
        guard finalTree.descendants.isEmpty else { return false }
        try sendSignal(pid: owned.launcher.pid, signal: SIGKILL)
        let killDeadline = makeDeadline(.seconds(5))
        while true {
            guard let launcher = try identityReader.snapshot(pid: owned.launcher.pid) else {
                try auditGroupAfterLauncherExit(owned, baseline: baselineGroup)
                return true
            }
            guard launcher.stableIdentity == owned.launcher.stableIdentity else {
                throw cleanupError("the launcher PID changed identity after SIGKILL")
            }
            guard !killDeadline.hasExpired else {
                throw cleanupError("the owned launcher survived SIGKILL")
            }
            try await killDeadline.sleepUntilNextPoll(maximumInterval: .milliseconds(100))
        }
    }

    private func auditGroupAfterLauncherExit(
        _ owned: OwnedMonkeydoProcess,
        baseline: [Int32: ProcessIdentitySnapshot]
    ) throws {
        let current = try captureGroup(processGroupId: owned.launcher.processGroupId)
        for (pid, member) in current {
            guard pid != owned.launcher.pid, baseline[pid] == member else {
                throw cleanupError(
                    "the launcher exited while a new, changed, or owned group PID \(pid) remained")
            }
        }
    }

    private func requireNoGroupSurvivorsAfterLauncherExit(
        _ owned: OwnedMonkeydoProcess
    ) throws {
        let current = try captureGroup(processGroupId: owned.launcher.processGroupId)
        guard current.isEmpty else {
            throw cleanupError(
                "the launcher disappeared while process-group PIDs \(current.keys.sorted()) remained")
        }
    }

    private struct CleanupTree {
        let launcher: ProcessIdentitySnapshot
        let descendants: [ProcessIdentitySnapshot]
        let depths: [Int32: Int]
        var all: [ProcessIdentitySnapshot] { [launcher] + descendants }
    }

    private func captureCleanupTree(_ owned: OwnedMonkeydoProcess) throws -> CleanupTree {
        try taggingInspectionSite(
            "cleanup.captureTree",
            details: [
                "launcherPid": .int(Int(owned.launcher.pid)),
                "launcherPgid": .int(Int(owned.launcher.processGroupId)),
            ]
        ) {
            try captureCleanupTreeInspecting(owned)
        }
    }

    private func captureCleanupTreeInspecting(
        _ owned: OwnedMonkeydoProcess
    ) throws -> CleanupTree {
        guard let launcher = try identityReader.snapshot(pid: owned.launcher.pid) else {
            throw cleanupError(
                "the owned launcher disappeared before its descendants could be authorized")
        }
        guard launcher.stableIdentity == owned.launcher.stableIdentity else {
            throw cleanupError("the launcher PID changed stable identity before signalling")
        }

        var descendants: [ProcessIdentitySnapshot] = []
        var depths: [Int32: Int] = [launcher.pid: 0]
        var pending: [(pid: Int32, depth: Int)] = [(launcher.pid, 0)]
        var visited = Set<Int32>([launcher.pid])
        while let parent = pending.popLast() {
            for pid in try identityReader.childPIDs(parentPid: parent.pid) {
                guard visited.insert(pid).inserted else {
                    throw cleanupError("the owned descendant graph contained PID \(pid) twice")
                }
                // proc_listpids and snapshot are not atomic. A descendant that
                // exits in the window between them is reported by the kernel
                // list and is then uninspectable. That is a normal race, not a
                // fault: the process is gone, there is nothing left to signal,
                // and aborting here would strand the descendants that are still
                // alive. Skipping is the conservative choice — an inspectable
                // PID that is not ours still fails the parent check below.
                guard let child = try identityReader.snapshot(pid: pid) else { continue }
                guard child.parentPid == parent.pid else {
                    throw cleanupError(
                        "owned child PID \(pid) changed parent before signalling")
                }
                let depth = parent.depth + 1
                descendants.append(child)
                depths[pid] = depth
                pending.append((pid, depth))
            }
        }
        return CleanupTree(launcher: launcher, descendants: descendants, depths: depths)
    }

    private func sendSignal(pid: Int32, signal: Int32) throws {
        do {
            try signalSender.signal(pid: pid, signal: signal)
        } catch let error as ToolError {
            throw error
        } catch {
            throw cleanupError(
                "signalling PID \(pid) with signal \(signal) failed: \(error.localizedDescription)")
        }
    }

    private func cleanupError(_ reason: String) -> ToolError {
        ToolError(
            code: "monkeydo_cleanup_failed",
            message: "Could not safely clean up the owned monkeydo tree: \(reason).",
            fix: "Stop the simulator and inspect the reported process identities before retrying.")
    }

    private func launch(
        _ command: MonkeydoCommand,
        testArguments: [String],
        workingDirectory: URL?,
        timeout: Duration?,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> OwnedMonkeydoProcess {
        guard !command.device.isEmpty else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The monkeydo device is empty.",
                fix: "Pass the verified Connect IQ device identifier used for this launch.")
        }

        let monkeydo = canonical(command.sdk.monkeydo)
        let prg = canonical(command.prgPath)
        let launchArguments = [prg.path, command.device] + testArguments
        let process: any RunningProcess
        do {
            process = try await processRunner.start(
                executable: monkeydo,
                arguments: launchArguments,
                environment: nil,
                workingDirectory: workingDirectory,
                timeout: timeout,
                onStdout: onStdout,
                onStderr: onStderr)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError(
                code: "app_launch_failed",
                message: "monkeydo could not be started: \(error.localizedDescription)",
                fix: "Verify the selected SDK and PRG artifact, then retry the run.",
                details: ["executable": .string(monkeydo.path)])
        }

        let launcher: ProcessIdentitySnapshot
        do {
            launcher = try requireExactLauncher(
                pid: process.pid,
                monkeydo: monkeydo,
                prg: prg,
                device: command.device,
                testArguments: testArguments)
        } catch {
            let cleanup = Task.detached { [self, process] in
                try await cleanupAfterInitialCaptureFailure(
                    process: process, rootPID: process.pid, grace: .seconds(5))
            }
            try await cleanup.value
            throw error
        }
        let owned = OwnedMonkeydoProcess(
            process: process, launcher: launcher, command: command)
        if Task.isCancelled {
            try await terminate(owned, grace: .seconds(5))
            throw CancellationError()
        }
        return owned
    }

    /// The Foundation.Process handle still owns the returned wrapper even when
    /// its full libproc snapshot cannot be accepted. Preserve that wrapper as
    /// an ancestry anchor, dynamically remove every inspectable child rooted
    /// at its PID, then terminate and drain the wrapper itself.
    private func cleanupAfterInitialCaptureFailure(
        process: any RunningProcess,
        rootPID: Int32,
        grace: Duration
    ) async throws {
        while true {
            let tree = try captureDescendants(rootPID: rootPID)
            guard let target = tree.snapshots.max(by: { lhs, rhs in
                let lhsDepth = tree.depths[lhs.pid] ?? 0
                let rhsDepth = tree.depths[rhs.pid] ?? 0
                return lhsDepth == rhsDepth ? lhs.pid < rhs.pid : lhsDepth < rhsDepth
            }) else { break }
            try await terminateInitialDescendant(
                target, rootPID: rootPID, grace: grace)
        }
        guard try identityReader.childPIDs(parentPid: rootPID).isEmpty else {
            throw cleanupError(
                "a new or uninspectable child appeared before initial wrapper cleanup")
        }
        let wrapperSnapshot = try identityReader.snapshot(pid: rootPID)
        let baselineGroup = try wrapperSnapshot.map {
            try captureGroup(processGroupId: $0.processGroupId)
        }
        await process.terminate(grace: grace)
        _ = try await process.wait()
        if let wrapperSnapshot, let baselineGroup {
            let currentGroup = try captureGroup(
                processGroupId: wrapperSnapshot.processGroupId)
            for (pid, member) in currentGroup where pid != rootPID {
                guard baselineGroup[pid] == member else {
                    throw cleanupError(
                        "a new or changed group PID \(pid) remained after initial wrapper cleanup")
                }
            }
        }
    }

    private struct RootedDescendants {
        let snapshots: [ProcessIdentitySnapshot]
        let depths: [Int32: Int]
    }

    private func captureDescendants(rootPID: Int32) throws -> RootedDescendants {
        try taggingInspectionSite(
            "cleanup.captureDescendants",
            details: ["rootPid": .int(Int(rootPID))]
        ) {
            try captureDescendantsInspecting(rootPID: rootPID)
        }
    }

    private func captureDescendantsInspecting(rootPID: Int32) throws -> RootedDescendants {
        var snapshots: [ProcessIdentitySnapshot] = []
        var depths: [Int32: Int] = [:]
        var pending: [(pid: Int32, depth: Int)] = [(rootPID, 0)]
        var visited = Set<Int32>([rootPID])
        while let parent = pending.popLast() {
            for pid in try identityReader.childPIDs(parentPid: parent.pid) {
                guard visited.insert(pid).inserted else {
                    throw cleanupError("the initial descendant graph contained PID \(pid) twice")
                }
                guard let child = try identityReader.snapshot(pid: pid) else {
                    throw cleanupError(
                        "kernel-listed initial child PID \(pid) could not be identity-inspected")
                }
                guard child.parentPid == parent.pid else {
                    throw cleanupError(
                        "initial child PID \(pid) changed parent before cleanup")
                }
                let depth = parent.depth + 1
                snapshots.append(child)
                depths[pid] = depth
                pending.append((pid, depth))
            }
        }
        return RootedDescendants(snapshots: snapshots, depths: depths)
    }

    private func terminateInitialDescendant(
        _ target: ProcessIdentitySnapshot,
        rootPID: Int32,
        grace: Duration
    ) async throws {
        try requireInitiallyAnchored(target, rootPID: rootPID)
        try sendSignal(pid: target.pid, signal: SIGTERM)
        if try await waitForInitialExit(target, rootPID: rootPID, timeout: grace) { return }
        try requireInitiallyAnchored(target, rootPID: rootPID)
        try sendSignal(pid: target.pid, signal: SIGKILL)
        guard try await waitForInitialExit(
            target, rootPID: rootPID, timeout: .seconds(5))
        else {
            throw cleanupError("initial descendant PID \(target.pid) survived SIGKILL")
        }
    }

    private func requireInitiallyAnchored(
        _ target: ProcessIdentitySnapshot,
        rootPID: Int32
    ) throws {
        let tree = try captureDescendants(rootPID: rootPID)
        guard tree.snapshots.first(where: { $0.pid == target.pid }) == target else {
            throw cleanupError(
                "initial descendant PID \(target.pid) changed identity or ancestry before signalling")
        }
    }

    private func waitForInitialExit(
        _ target: ProcessIdentitySnapshot,
        rootPID: Int32,
        timeout: Duration
    ) async throws -> Bool {
        let deadline = makeDeadline(timeout)
        while true {
            guard let current = try identityReader.snapshot(pid: target.pid) else { return true }
            guard current == target else {
                throw cleanupError(
                    "initial descendant PID \(target.pid) changed identity while exiting")
            }
            do {
                try requireInitiallyAnchored(target, rootPID: rootPID)
            } catch {
                if try identityReader.snapshot(pid: target.pid) == nil { return true }
                throw error
            }
            guard !deadline.hasExpired else { return false }
            try await deadline.sleepUntilNextPoll(maximumInterval: .milliseconds(100))
        }
    }

    private func requireExactLauncher(
        pid: Int32,
        monkeydo: URL,
        prg: URL,
        device: String,
        testArguments: [String]
    ) throws -> ProcessIdentitySnapshot {
        try taggingInspectionSite(
            "launch.requireExactLauncher",
            details: ["launcherPid": .int(Int(pid))]
        ) {
            try requireExactLauncherInspecting(
                pid: pid, monkeydo: monkeydo, prg: prg, device: device,
                testArguments: testArguments)
        }
    }

    private func requireExactLauncherInspecting(
        pid: Int32,
        monkeydo: URL,
        prg: URL,
        device: String,
        testArguments: [String]
    ) throws -> ProcessIdentitySnapshot {
        guard let snapshot = try identityReader.snapshot(pid: pid) else {
            throw ToolError(
                code: "app_launch_failed",
                message: "The monkeydo launcher exited before its process identity could be captured.",
                fix: "Retry the run; if it repeats, inspect the selected SDK's bin/monkeydo script and server stderr.",
                details: ["pid": .int(Int(pid))])
        }
        let expectedExecutable = canonical(URL(fileURLWithPath: "/bin/bash")).path
        let expectedArguments = [expectedExecutable, monkeydo.path, prg.path, device] + testArguments
        guard snapshot.pid == pid,
            snapshot.executablePath == expectedExecutable,
            snapshot.arguments == expectedArguments
        else {
            throw ToolError(
                code: "app_launch_failed",
                message: "The started monkeydo PID did not match the verified Bash wrapper contract.",
                fix: "Stop the simulator, verify the selected SDK installation, then retry; do not trust or signal the mismatched process.",
                details: [
                    "pid": .int(Int(pid)),
                    "expectedExecutable": .string(expectedExecutable),
                    "observedExecutable": .string(snapshot.executablePath),
                    "expectedArguments": .array(expectedArguments.map(JSONValue.string)),
                    "observedArguments": .array(snapshot.arguments.map(JSONValue.string)),
                ])
        }
        return snapshot
    }

    private func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

private struct PersistedMonkeydoProcess: RunningProcess, Sendable {
    let pid: Int32

    func wait() async throws -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func terminate(grace _: Duration) async {}
}
