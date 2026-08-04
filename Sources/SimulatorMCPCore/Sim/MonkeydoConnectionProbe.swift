import Darwin
import Foundation

public struct TCPConnection: Hashable, Sendable {
    public let local: TCPEndpoint
    public let remote: TCPEndpoint

    public init(local: TCPEndpoint, remote: TCPEndpoint) {
        self.local = local
        self.remote = remote
    }
}

public struct VerifiedMonkeydoConnection: Equatable, Sendable {
    public let launcher: ProcessIdentitySnapshot
    public let connectionOwner: ProcessIdentitySnapshot
    public let parentChain: [ProcessIdentitySnapshot]
    public let launcherGroupMembers: [ProcessIdentitySnapshot]
    public let serverProcess: ProcessIdentitySnapshot
    public let launcherGroupFullyAnchored: Bool
    public let postSocketRevalidationVerified: Bool
    public let localEndpoint: TCPEndpoint
    public let remoteEndpoint: TCPEndpoint
    public let matchedSimulatorListener: TCPEndpoint
    public let elapsedMonotonicMilliseconds: UInt64

    public init(
        launcher: ProcessIdentitySnapshot,
        connectionOwner: ProcessIdentitySnapshot,
        parentChain: [ProcessIdentitySnapshot],
        launcherGroupMembers: [ProcessIdentitySnapshot],
        serverProcess: ProcessIdentitySnapshot,
        launcherGroupFullyAnchored: Bool,
        postSocketRevalidationVerified: Bool,
        localEndpoint: TCPEndpoint,
        remoteEndpoint: TCPEndpoint,
        matchedSimulatorListener: TCPEndpoint,
        elapsedMonotonicMilliseconds: UInt64
    ) {
        self.launcher = launcher
        self.connectionOwner = connectionOwner
        self.parentChain = parentChain
        self.launcherGroupMembers = launcherGroupMembers
        self.serverProcess = serverProcess
        self.launcherGroupFullyAnchored = launcherGroupFullyAnchored
        self.postSocketRevalidationVerified = postSocketRevalidationVerified
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.matchedSimulatorListener = matchedSimulatorListener
        self.elapsedMonotonicMilliseconds = elapsedMonotonicMilliseconds
    }
}

public protocol RunEvidenceObserving: Sendable {
    func accepted(_ connection: VerifiedMonkeydoConnection) async
}

public protocol MonkeydoConnectionProbing: Sendable {
    func waitUntilConnected(
        owned: OwnedMonkeydoProcess,
        listeningEndpoints: Set<TCPEndpoint>,
        isTestCommand: Bool,
        timeout: Duration,
        elapsedBeforeProbe: Duration
    ) async throws -> VerifiedMonkeydoConnection
}

/// Proves that one monkeydo child has an established TCP connection to one
/// of the listeners observed on the validated simulator process. A merely
/// live child is not launch evidence.
public struct MonkeydoConnectionProbe: MonkeydoConnectionProbing, Sendable {
    private static let pollInterval: Duration = .milliseconds(100)

    private let processRunner: any ProcessRunning
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline
    private let identityReader: any ProcessIdentityReading
    private let serverPID: Int32

    public init(processRunner: any ProcessRunning = Subprocess()) {
        let clock = ContinuousClock()
        self.processRunner = processRunner
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.identityReader = DarwinProcessIdentityReader()
        self.serverPID = getpid()
    }

    init<C: Clock>(
        processRunner: any ProcessRunning,
        identityReader: any ProcessIdentityReading,
        clock: C,
        serverPID: Int32
    ) where C.Duration == Duration {
        self.processRunner = processRunner
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.identityReader = identityReader
        self.serverPID = serverPID
    }

    public func waitUntilConnected(
        owned: OwnedMonkeydoProcess,
        listeningEndpoints: Set<TCPEndpoint>,
        isTestCommand: Bool = false,
        timeout: Duration = .seconds(30),
        elapsedBeforeProbe: Duration = .zero
    ) async throws -> VerifiedMonkeydoConnection {
        guard timeout >= .zero else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The monkeydo connection timeout must be zero or positive.",
                fix: "Pass a timeout that is zero or positive.")
        }
        guard elapsedBeforeProbe >= .zero else {
            throw ToolError(
                code: "invalid_arguments",
                message: "Elapsed monkeydo launch time must be zero or positive.",
                fix: "Pass the nonnegative monotonic time already spent in this launch deadline.")
        }
        guard !listeningEndpoints.isEmpty else {
            throw ToolError(
                code: "simulator_not_ready",
                message: "The validated simulator has no TCP listener to match against.",
                fix: "Call sim_start and wait for ready state, then retry run_app or run_tests.")
        }

        let deadline = makeDeadline(timeout)
        while true {
            try Task.checkCancellation()
            if deadline.hasExpired {
                throw Self.timeoutError(pid: owned.launcher.pid, observed: [])
            }

            let tree = try captureTree(owned: owned)
            let candidates = try exactConnectionOwners(
                in: tree, command: owned.command, isTestCommand: isTestCommand)
            var firstMatches: [(ProcessIdentitySnapshot, TCPConnection, TCPEndpoint)] = []
            for candidate in candidates {
                let connections = try await observePairs(
                    pid: candidate.pid, timeout: min(.seconds(5), deadline.remaining))
                for connection in connections {
                    if let listener = Self.matchingListener(
                        for: connection.remote, listeners: listeningEndpoints)
                    {
                        firstMatches.append((candidate, connection, listener))
                    }
                }
            }
            if deadline.hasExpired {
                throw Self.timeoutError(pid: owned.launcher.pid, observed: [])
            }
            if firstMatches.count > 1 {
                throw Self.probeError(
                    "multiple owned SDK-shell connections matched validated simulator listeners")
            }
            if let first = firstMatches.first {
                let freshConnections = try await observePairs(
                    pid: first.0.pid, timeout: min(.seconds(5), deadline.remaining))
                if deadline.hasExpired {
                    throw Self.timeoutError(pid: owned.launcher.pid, observed: [])
                }
                // Final acceptance boundary: every operation below is synchronous.
                // No actor hop or other suspension can split socket evidence from
                // the identities and ancestry that authorize it.
                if let verified = try finalize(
                    owned: owned,
                    observedTree: tree,
                    candidate: first.0,
                    freshConnections: freshConnections,
                    listeners: listeningEndpoints,
                    isTestCommand: isTestCommand,
                    elapsed: Self.elapsedMilliseconds(
                        total: elapsedBeforeProbe + timeout,
                        remaining: deadline.remaining))
                {
                    return verified
                }
                try await deadline.sleepUntilNextPoll(maximumInterval: Self.pollInterval)
                continue
            }

            guard try identityReader.snapshot(pid: owned.launcher.pid)?.stableIdentity
                == owned.launcher.stableIdentity
            else {
                throw ToolError(
                    code: "monkeydo_exited",
                    message: "The owned monkeydo launcher exited or changed identity before connecting.",
                    fix: "Retry the run; never trust or signal a vanished or reused PID.",
                    details: ["pid": .int(Int(owned.launcher.pid))])
            }
            try await deadline.sleepUntilNextPoll(maximumInterval: Self.pollInterval)
        }
    }

    private func observePairs(
        pid: Int32,
        timeout: Duration
    ) async throws -> Set<TCPConnection> {
        let child = try await processRunner.start(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:ESTABLISHED", "-Fpn",
            ],
            environment: nil,
            workingDirectory: nil,
            timeout: timeout,
            onStdout: nil,
            onStderr: nil)
        let output = try await child.wait()
        guard output.exitCode == 0 || output.exitCode == 1 else {
            throw ToolError(
                code: "monkeydo_probe_failed",
                message: "Could not inspect TCP connections for monkeydo process \(pid) (lsof exit \(output.exitCode)).",
                fix: "Verify /usr/sbin/lsof is available, then retry; inspect server stderr if it repeats.",
                details: ["pid": .int(Int(pid)), "exitCode": .int(Int(output.exitCode))])
        }
        return try Self.parseEstablishedConnectionPairs(output.stdout, expectedPID: pid)
    }

    private struct CapturedTree {
        let launcher: ProcessIdentitySnapshot
        let descendants: [ProcessIdentitySnapshot]
        let depths: [Int32: Int]

        var all: [ProcessIdentitySnapshot] { [launcher] + descendants }
    }

    private func captureTree(owned: OwnedMonkeydoProcess) throws -> CapturedTree {
        try taggingInspectionSite(
            "probe.captureTree",
            details: [
                "launcherPid": .int(Int(owned.launcher.pid)),
                "launcherPgid": .int(Int(owned.launcher.processGroupId)),
            ]
        ) {
            try captureTreeInspecting(owned: owned)
        }
    }

    private func captureTreeInspecting(owned: OwnedMonkeydoProcess) throws -> CapturedTree {
        guard let launcher = try identityReader.snapshot(pid: owned.launcher.pid) else {
            throw ToolError(
                code: "monkeydo_exited",
                message: "The owned monkeydo launcher exited before connection evidence was complete.",
                fix: "Retry the run; never trust or signal a vanished launcher PID.",
                details: ["pid": .int(Int(owned.launcher.pid))])
        }
        guard launcher.stableIdentity == owned.launcher.stableIdentity else {
            throw Self.probeError("the monkeydo launcher PID changed stable identity")
        }

        var descendants: [ProcessIdentitySnapshot] = []
        var pending: [(pid: Int32, depth: Int)] = [(launcher.pid, 0)]
        var visited = Set<Int32>([launcher.pid])
        var depths: [Int32: Int] = [launcher.pid: 0]
        while let parent = pending.popLast() {
            for pid in try identityReader.childPIDs(parentPid: parent.pid) {
                guard visited.insert(pid).inserted else {
                    throw Self.probeError("the launcher descendant graph contained PID \(pid) twice")
                }
                // proc_listpids and snapshot are not atomic, and a process
                // leaves its group only when it is REAPED, not when it dies:
                // a killed, unreaped process stays listed while being
                // uninspectable, measured against the kernel.
                // So a listed child that cannot be inspected is an ordinary
                // zombie. The probe signals nothing, and a zombie can neither
                // run nor own a socket, so it is irrelevant to every question
                // asked here. An inspectable PID that is not ours still fails
                // the parent check below.
                guard let child = try identityReader.snapshot(pid: pid) else { continue }
                guard child.parentPid == parent.pid else {
                    throw Self.probeError(
                        "launcher child PID \(pid) changed parent during identity capture")
                }
                let depth = parent.depth + 1
                descendants.append(child)
                depths[pid] = depth
                pending.append((pid, depth))
            }
        }
        descendants.sort { $0.pid < $1.pid }
        return CapturedTree(launcher: launcher, descendants: descendants, depths: depths)
    }

    private func exactConnectionOwners(
        in tree: CapturedTree,
        command: MonkeydoCommand,
        isTestCommand: Bool
    ) throws -> [ProcessIdentitySnapshot] {
        let sdkRoot = command.sdk.root.resolvingSymlinksInPath().standardizedFileURL
        let prg = command.prgPath.resolvingSymlinksInPath().standardizedFileURL.path
        let shell = sdkRoot.appending(path: "bin/shell").path
        let testArguments = isTestCommand
            ? TestTranscriptParser.testArguments(filter: command.testFilter) : []
        let javaArguments = [
            "/usr/bin/java",
            "-classpath", sdkRoot.appending(path: "bin/monkeybrains.jar").path,
            "com.garmin.monkeybrains.monkeydodeux.MonkeyDoDeux",
            "-f", prg,
            "-d", command.device,
            "-s", shell,
        ] + testArguments

        let javaChildren = tree.descendants.filter {
            $0.parentPid == tree.launcher.pid
                && $0.arguments == javaArguments
                && URL(fileURLWithPath: $0.executablePath).lastPathComponent == "java"
        }
        guard javaChildren.count <= 1 else {
            throw Self.probeError("multiple exact MonkeyDoDeux children were observed")
        }
        guard let java = javaChildren.first else { return [] }

        return tree.descendants.filter { child in
            guard child.parentPid == java.pid,
                child.executablePath == shell,
                child.arguments.count == 3,
                child.arguments[0] == shell,
                child.arguments[1] == "--transport=tcp",
                child.arguments[2].hasPrefix("--transport_args=")
            else { return false }
            let raw = child.arguments[2].dropFirst("--transport_args=".count)
            guard let endpoint = try? Self.parseEndpoint(raw) else { return false }
            return Self.isLoopback(endpoint)
        }
    }

    private func finalize(
        owned: OwnedMonkeydoProcess,
        observedTree: CapturedTree,
        candidate: ProcessIdentitySnapshot,
        freshConnections: Set<TCPConnection>,
        listeners: Set<TCPEndpoint>,
        isTestCommand: Bool,
        elapsed: UInt64
    ) throws -> VerifiedMonkeydoConnection? {
        let finalTree = try captureTree(owned: owned)
        guard finalTree.launcher.stableIdentity == observedTree.launcher.stableIdentity else {
            throw Self.probeError("the launcher changed stable identity after lsof")
        }
        guard let observedJava = observedTree.descendants.first(where: {
            $0.pid == candidate.parentPid
        }), observedJava.parentPid == observedTree.launcher.pid else {
            throw Self.probeError(
                "the observed connection-owner to Java to launcher chain was incomplete")
        }
        let finalCandidates = try exactConnectionOwners(
            in: finalTree, command: owned.command, isTestCommand: isTestCommand)
        guard let finalOwner = finalCandidates.first(where: {
            $0.stableIdentity == candidate.stableIdentity
        }), finalCandidates.count == 1 else {
            throw Self.probeError(
                "the SDK-shell connection owner changed identity or became ambiguous after lsof",
                details: [
                    "observedCandidate": .string(Self.identitySummary(candidate)),
                    "finalCandidates": .array(
                        finalCandidates.map { .string(Self.identitySummary($0)) }),
                    "finalDescendants": .array(
                        finalTree.descendants.map { .string(Self.identitySummary($0)) }),
                ])
        }
        guard let java = finalTree.descendants.first(where: { $0.pid == finalOwner.parentPid }),
            java.parentPid == finalTree.launcher.pid,
            java.stableIdentity == observedJava.stableIdentity
        else {
            throw Self.probeError(
                "the connection-owner Java parent changed identity or ancestry after lsof")
        }

        let transportRaw = finalOwner.arguments[2].dropFirst("--transport_args=".count)
        let transportEndpoint = try Self.parseEndpoint(transportRaw)
        let matches = freshConnections.compactMap {
            connection -> (TCPConnection, TCPEndpoint)? in
            guard connection.remote == transportEndpoint,
                let listener = Self.matchingListener(for: connection.remote, listeners: listeners)
            else { return nil }
            return (connection, listener)
        }
        if matches.isEmpty { return nil }
        guard matches.count == 1, let match = matches.first else {
            throw Self.probeError(
                "multiple fresh SDK-shell sockets matched validated simulator listeners")
        }

        var groupMembers = try taggingInspectionSite(
            "probe.finalizeGroup",
            details: [
                "launcherPid": .int(Int(finalTree.launcher.pid)),
                "launcherPgid": .int(Int(finalTree.launcher.processGroupId)),
            ]
        ) { () -> [ProcessIdentitySnapshot] in
            let groupPIDs = try identityReader.processGroupPIDs(
                processGroupId: finalTree.launcher.processGroupId)
            guard Set(groupPIDs).count == groupPIDs.count else {
                throw Self.probeError("the kernel listed a launcher-group PID more than once")
            }
            var members: [ProcessIdentitySnapshot] = []
            for pid in groupPIDs {
                // Same reasoning as the descendant walk: a group member that
                // cannot be inspected is a zombie awaiting reaping, not an
                // anomaly. Unlike MonkeydoProcessLifecycle.captureGroup, this
                // capture authorizes no signal — cleanup re-derives its own
                // authorization through exactDedicatedGroup.
                guard let member = try identityReader.snapshot(pid: pid) else { continue }
                members.append(member)
            }
            return members
        }
        groupMembers.sort { $0.pid < $1.pid }

        guard let serverProcess = try identityReader.snapshot(pid: serverPID) else {
            throw Self.probeError("the simulator-mcp server process could not be identity-inspected")
        }
        let finalTreeByPID = Dictionary(
            uniqueKeysWithValues: finalTree.all.map { ($0.pid, $0) })
        let groupByPID = Dictionary(
            uniqueKeysWithValues: groupMembers.map { ($0.pid, $0) })
        // Every group member must be part of the owned tree, with the same
        // identity. A live process in our group that is not ours is exactly
        // what the anchoring requirement exists to catch.
        for (pid, member) in groupByPID {
            guard let treeMember = finalTreeByPID[pid] else {
                throw Self.probeError(
                    "launcher-group PID \(pid) is not part of the owned tree")
            }
            if treeMember != member {
                throw Self.probeError(
                    "launcher-group PID \(pid) changed identity during final acceptance")
            }
        }
        // The tree is captured before the group, so a descendant reaped in
        // between is legitimately in one and not the other. Exact equality
        // cannot express that. Tolerated only when confirmed gone: one that
        // left the group while still alive stays fatal.
        for pid in finalTreeByPID.keys where groupByPID[pid] == nil {
            guard try identityReader.snapshot(pid: pid) == nil else {
                throw Self.probeError(
                    "owned PID \(pid) left launcher group "
                        + "\(finalTree.launcher.processGroupId) while still alive")
            }
        }
        let fullyAnchored = finalTree.launcher.processGroupId > 0
            && finalTree.launcher.processGroupId == finalTree.launcher.pid
            && finalTree.launcher.processGroupId != serverProcess.processGroupId
            && groupByPID[finalTree.launcher.pid] != nil
            && groupMembers.allSatisfy {
                $0.processGroupId == finalTree.launcher.processGroupId
            }
        guard fullyAnchored else {
            throw Self.probeError(
                "the final launcher group was not complete, fully anchored, and separate from the MCP server",
                details: [
                    "treePids": .array(finalTree.all.map { .int(Int($0.pid)) }),
                    "groupPids": .array(groupMembers.map { .int(Int($0.pid)) }),
                    "launcherGroupId": .int(Int(finalTree.launcher.processGroupId)),
                    "serverGroupId": .int(Int(serverProcess.processGroupId)),
                ])
        }

        return VerifiedMonkeydoConnection(
            launcher: finalTree.launcher,
            connectionOwner: finalOwner,
            parentChain: [finalOwner, java, finalTree.launcher],
            launcherGroupMembers: groupMembers,
            serverProcess: serverProcess,
            launcherGroupFullyAnchored: fullyAnchored,
            postSocketRevalidationVerified: true,
            localEndpoint: match.0.local,
            remoteEndpoint: match.0.remote,
            matchedSimulatorListener: match.1,
            elapsedMonotonicMilliseconds: elapsed)
    }

    private static func matchingListener(
        for remote: TCPEndpoint,
        listeners: Set<TCPEndpoint>
    ) -> TCPEndpoint? {
        guard isLoopback(remote) else { return nil }
        return listeners.sorted {
            ($0.family, $0.address, $0.port) < ($1.family, $1.address, $1.port)
        }.first { listener in
            listener == remote
                || (listener.family == remote.family
                    && listener.port == remote.port
                    && isWildcard(listener.address))
        }
    }

    private static func isLoopback(_ endpoint: TCPEndpoint) -> Bool {
        (endpoint.family == "ipv4" && endpoint.address == "127.0.0.1")
            || (endpoint.family == "ipv6" && endpoint.address == "::1")
    }

    private static func isWildcard(_ address: String) -> Bool {
        address == "*" || address == "0.0.0.0" || address == "::" || address == "[::]"
    }

    private static func elapsedMilliseconds(total: Duration, remaining: Duration) -> UInt64 {
        let elapsed = max(.zero, total - remaining).components
        let seconds = UInt64(max(0, elapsed.seconds))
        let attoseconds = UInt64(max(0, elapsed.attoseconds))
        let (wholeMilliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        if overflow { return UInt64.max }
        let fractionalMilliseconds = attoseconds / 1_000_000_000_000_000
        let (result, additionOverflow) = wholeMilliseconds.addingReportingOverflow(
            fractionalMilliseconds)
        return additionOverflow ? UInt64.max : result
    }

    public static func parseEstablishedConnections(
        _ data: Data,
        expectedPID: Int32
    ) throws -> Set<TCPEndpoint> {
        Set(try parseEstablishedConnectionPairs(data, expectedPID: expectedPID).map(\.remote))
    }

    public static func parseEstablishedConnectionPairs(
        _ data: Data,
        expectedPID: Int32
    ) throws -> Set<TCPConnection> {
        guard let text = String(data: data, encoding: .utf8) else {
            throw parseError("lsof output was not UTF-8")
        }
        var reportedPID: Int32?
        var connections = Set<TCPConnection>()
        for line in text.split(whereSeparator: \Character.isNewline) {
            if line.first == "p" {
                guard let pid = Int32(line.dropFirst()) else {
                    throw parseError("lsof reported an invalid PID")
                }
                if let reportedPID, reportedPID != pid {
                    throw parseError("lsof reported multiple PIDs")
                }
                reportedPID = pid
                continue
            }
            guard line.first == "n" else { continue }
            let connection = line.dropFirst()
            guard let arrow = connection.range(of: "->") else { continue }
            let local = connection[..<arrow.lowerBound]
            let remote = connection[arrow.upperBound...]
            connections.insert(TCPConnection(
                local: try parseEndpoint(local), remote: try parseEndpoint(remote)))
        }
        if let reportedPID, reportedPID != expectedPID {
            throw parseError(
                "lsof reported PID \(reportedPID) while monkeydo PID \(expectedPID) was requested")
        }
        if !connections.isEmpty, reportedPID == nil {
            throw parseError("lsof reported connections without a process PID")
        }
        return connections
    }

    private static func parseEndpoint(_ raw: Substring) throws -> TCPEndpoint {
        let address: String
        let portText: Substring
        let family: String
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]"),
                raw.index(after: close) < raw.endIndex,
                raw[raw.index(after: close)] == ":"
            else { throw parseError("malformed IPv6 endpoint '\(raw)'") }
            address = String(raw[raw.index(after: raw.startIndex)..<close]).lowercased()
            portText = raw[raw.index(close, offsetBy: 2)...]
            family = "ipv6"
        } else {
            guard let colon = raw.lastIndex(of: ":") else {
                throw parseError("endpoint '\(raw)' has no port")
            }
            address = String(raw[..<colon]).lowercased()
            portText = raw[raw.index(after: colon)...]
            family = address.contains(":") ? "ipv6" : "ipv4"
        }
        guard let port = UInt16(portText) else {
            throw parseError("endpoint '\(raw)' has an invalid port")
        }
        return TCPEndpoint(address: address, port: port, family: family)
    }

    private static func parseError(_ reason: String) -> ToolError {
        ToolError(
            code: "monkeydo_probe_failed",
            message: "Could not parse monkeydo connection evidence: \(reason).",
            fix: "Retry the run; if it repeats, inspect the raw lsof output in the server stderr log.")
    }

    private static func identitySummary(_ snapshot: ProcessIdentitySnapshot) -> String {
        "pid=\(snapshot.pid),parent=\(snapshot.parentPid),start="
            + "\(snapshot.start.seconds).\(snapshot.start.microseconds)"
    }

    private static func probeError(
        _ reason: String,
        details: [String: JSONValue]? = nil
    ) -> ToolError {
        ToolError(
            code: "monkeydo_probe_failed",
            message: "Could not prove the owned monkeydo connection: \(reason).",
            fix: "Retry the run; if it repeats, stop the simulator and inspect the reported process tree before retrying.",
            details: details)
    }

    private static func timeoutError(pid: Int32, observed: Set<TCPEndpoint>) -> ToolError {
        let endpoints = observed
            .sorted { ($0.family, $0.address, $0.port) < ($1.family, $1.address, $1.port) }
            .map { "\($0.family):\($0.address):\($0.port)" }
            .joined(separator: ",")
        return ToolError(
            code: "app_launch_timeout",
            message: "monkeydo process \(pid) did not connect to the validated simulator before the launch deadline.",
            fix: "Retry run_app or run_tests; if it repeats, restart the simulator and inspect its logs.",
            details: [
                "pid": .int(Int(pid)),
                "observedRemoteEndpoints": .string(endpoints),
            ])
    }
}
