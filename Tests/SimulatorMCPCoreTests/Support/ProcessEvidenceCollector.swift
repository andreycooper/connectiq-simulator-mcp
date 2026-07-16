import Darwin
import Foundation

@testable import SimulatorMCPCore

enum ProcessEvidenceError: Error, CustomStringConvertible {
    case invalidSnapshot(String)
    case inspectionFailed(String)
    case ancestryNotVerified(String)

    var description: String {
        switch self {
        case .invalidSnapshot(let reason), .inspectionFailed(let reason),
            .ancestryNotVerified(let reason):
            return reason
        }
    }
}

struct ProcessEvidenceSnapshot: Codable, Equatable, Sendable {
    let pid: Int32
    let parentPid: Int32
    let processGroupId: Int32
    let processStartIdentity: String
    let executablePath: String
    let arguments: [String]
    let displayCommand: String

    init(
        pid: Int32,
        parentPid: Int32,
        processGroupId: Int32,
        processStartIdentity: String,
        executablePath: String,
        arguments: [String]
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.processGroupId = processGroupId
        self.processStartIdentity = processStartIdentity
        self.executablePath = executablePath
        self.arguments = arguments
        self.displayCommand = arguments.map(Self.quoteForDisplay).joined(separator: " ")
    }

    private static func quoteForDisplay(_ argument: String) -> String {
        guard argument.contains(where: \Character.isWhitespace) else { return argument }
        return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum ProcessCleanupPlan: Equatable, Sendable {
    case individual(pids: [Int32])
}

protocol ProcessSignalSending: Sendable {
    func signal(pid: Int32, signal: Int32) throws
}

struct DarwinProcessSignalSender: ProcessSignalSending, Sendable {
    func signal(pid: Int32, signal: Int32) throws {
        guard Darwin.kill(pid, signal) == 0 || errno == ESRCH else {
            throw ProcessEvidenceError.inspectionFailed(
                "signal \(signal) failed for PID \(pid) with errno \(errno)")
        }
    }
}

struct ProcessEvidenceConnection: Codable, Equatable, Sendable {
    let local: TCPEndpoint
    let remote: TCPEndpoint
}

struct CurrentListenerConnection: Equatable, Sendable {
    let connection: ProcessEvidenceConnection
    let listener: TCPEndpoint
}

protocol ProcessIdentityReading: Sendable {
    func snapshot(pid: Int32) throws -> ProcessEvidenceSnapshot?
    func childPIDs(parentPid: Int32) throws -> [Int32]
    func processGroupPIDs(processGroupId: Int32) throws -> [Int32]
}

struct KernelBSDIdentity: Equatable, Sendable {
    let pid: Int32
    let parentPid: Int32
    let processGroupId: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

protocol KernelProcessReading: Sendable {
    func bsdIdentity(pid: Int32) throws -> KernelBSDIdentity?
    func executablePath(pid: Int32) throws -> String?
    func arguments(pid: Int32) throws -> [String]?
    func childPIDs(parentPid: Int32) throws -> [Int32]
    func processGroupPIDs(processGroupId: Int32) throws -> [Int32]
}

struct DarwinKernelProcessReader: KernelProcessReading, Sendable {
    func bsdIdentity(pid: Int32) throws -> KernelBSDIdentity? {
        var info = proc_bsdinfo()
        let captured = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid, PROC_PIDTBSDINFO, 0, pointer,
                Int32(MemoryLayout<proc_bsdinfo>.stride))
        }
        guard captured == Int32(MemoryLayout<proc_bsdinfo>.stride) else {
            if captured == 0, errno == ESRCH || errno == ENOENT { return nil }
            if captured == 0 { return nil }
            throw ProcessEvidenceError.inspectionFailed(
                "proc_pidinfo returned \(captured) bytes for PID \(pid)")
        }
        return KernelBSDIdentity(
            pid: Int32(info.pbi_pid), parentPid: Int32(info.pbi_ppid),
            processGroupId: Int32(info.pbi_pgid), startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec)
    }

    func executablePath(pid: Int32) throws -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathCount = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathCount > 0 else {
            return nil
        }
        let end = pathBuffer.firstIndex(of: 0) ?? min(Int(pathCount), pathBuffer.count)
        let rawPath = String(
            decoding: pathBuffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
        return URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    func childPIDs(parentPid: Int32) throws -> [Int32] {
        try listPIDs(type: UInt32(PROC_PPID_ONLY), typeInfo: UInt32(bitPattern: parentPid))
    }

    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        try listPIDs(type: UInt32(PROC_PGRP_ONLY), typeInfo: UInt32(bitPattern: processGroupId))
    }

    private func listPIDs(type: UInt32, typeInfo: UInt32) throws -> [Int32] {
        let needed = proc_listpids(type, typeInfo, nil, 0)
        guard needed >= 0 else {
            throw ProcessEvidenceError.inspectionFailed(
                "proc_listpids sizing failed for type \(type) info \(typeInfo)")
        }
        var pids = [Int32](
            repeating: 0,
            count: max(32, Int(needed) / MemoryLayout<Int32>.stride + 32))
        let bytes = pids.withUnsafeMutableBytes { raw in
            proc_listpids(
                type, typeInfo, raw.baseAddress, Int32(raw.count))
        }
        guard bytes >= 0 else {
            throw ProcessEvidenceError.inspectionFailed(
                "proc_listpids failed for type \(type) info \(typeInfo)")
        }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride)
            .filter { $0 > 0 }
            .sorted()
    }

    func arguments(pid: Int32) throws -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        let argumentLimit = sysconf(_SC_ARG_MAX)
        guard argumentLimit > 0, argumentLimit <= 16 * 1_024 * 1_024 else {
            throw ProcessEvidenceError.inspectionFailed(
                "sysconf(_SC_ARG_MAX) returned unsafe bound \(argumentLimit) for PID \(pid)")
        }
        var size = Int(argumentLimit)
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            if errno == ESRCH || errno == ENOENT || errno == EINVAL { return nil }
            throw ProcessEvidenceError.inspectionFailed(
                "sysctl KERN_PROCARGS2 failed for PID \(pid) with errno \(errno)")
        }
        guard size > 0, size <= data.count else {
            throw ProcessEvidenceError.inspectionFailed(
                "sysctl KERN_PROCARGS2 returned invalid length \(size) for PID \(pid)")
        }
        data.count = size
        return try Self.parseProcArguments(data)
    }

    static func parseProcArguments(_ data: Data) throws -> [String] {
        guard data.count >= MemoryLayout<Int32>.size else {
            throw ProcessEvidenceError.invalidSnapshot("KERN_PROCARGS2 result has no argc")
        }
        let argc = data.prefix(MemoryLayout<Int32>.size).withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        }
        guard argc > 0 else {
            throw ProcessEvidenceError.invalidSnapshot("KERN_PROCARGS2 argc is not positive")
        }
        let bytes = [UInt8](data.dropFirst(MemoryLayout<Int32>.size))
        var index = 0
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while index < bytes.count, arguments.count < Int(argc) {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            while index < bytes.count, bytes[index] == 0 { index += 1 }
        }
        guard arguments.count == Int(argc) else {
            throw ProcessEvidenceError.invalidSnapshot(
                "KERN_PROCARGS2 exposed \(arguments.count) of \(argc) arguments")
        }
        return arguments
    }
}

struct DarwinProcessIdentityReader: ProcessIdentityReading, Sendable {
    let kernel: any KernelProcessReading

    init(kernel: any KernelProcessReading = DarwinKernelProcessReader()) {
        self.kernel = kernel
    }

    func snapshot(pid: Int32) throws -> ProcessEvidenceSnapshot? {
        guard let before = try kernel.bsdIdentity(pid: pid),
            let executable = try kernel.executablePath(pid: pid),
            let arguments = try kernel.arguments(pid: pid),
            let after = try kernel.bsdIdentity(pid: pid),
            before == after
        else { return nil }
        return ProcessEvidenceSnapshot(
            pid: before.pid,
            parentPid: before.parentPid,
            processGroupId: before.processGroupId,
            processStartIdentity: String(
                format: "%llu.%06llu", before.startSeconds, before.startMicroseconds),
            executablePath: executable,
            arguments: arguments)
    }

    func childPIDs(parentPid: Int32) throws -> [Int32] {
        try kernel.childPIDs(parentPid: parentPid)
    }

    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        try kernel.processGroupPIDs(processGroupId: processGroupId)
    }

    static func parseProcArguments(_ data: Data) throws -> [String] {
        try DarwinKernelProcessReader.parseProcArguments(data)
    }
}

struct ProcessEvidenceCollector: Sendable {
    static let snapshotCommand =
        "proc_pidinfo(PROC_PIDTBSDINFO) + proc_pidpath + sysctl(KERN_PROCARGS2)"
    static let processListCommand = "proc_listpids(PROC_PPID_ONLY) recursive descendant walk"
    static let executableCommand = "proc_pidpath"
    static let connectionCommand =
        "/usr/sbin/lsof -nP -a -p <pid> -iTCP -sTCP:ESTABLISHED -Fpn"

    let runner: any ProcessRunning
    let identityReader: any ProcessIdentityReading

    init(
        runner: any ProcessRunning = Subprocess(),
        identityReader: any ProcessIdentityReading = DarwinProcessIdentityReader()
    ) {
        self.runner = runner
        self.identityReader = identityReader
    }

    func snapshot(pid: Int32) throws -> ProcessEvidenceSnapshot? {
        try identityReader.snapshot(pid: pid)
    }

    func descendants(of launcher: ProcessEvidenceSnapshot) throws -> [ProcessEvidenceSnapshot] {
        var result: [ProcessEvidenceSnapshot] = []
        var pending = [launcher.pid]
        var visited = Set<Int32>([launcher.pid])
        while let parent = pending.popLast() {
            for pid in try identityReader.childPIDs(parentPid: parent) where visited.insert(pid).inserted {
                guard let child = try identityReader.snapshot(pid: pid) else {
                    throw ProcessEvidenceError.inspectionFailed(
                        "listed child PID \(pid) could not be identity-inspected")
                }
                guard child.parentPid == parent else {
                    throw ProcessEvidenceError.ancestryNotVerified(
                        "listed child PID \(pid) changed parent during enumeration")
                }
                result.append(child)
                pending.append(child.pid)
            }
        }
        return result.sorted { $0.pid < $1.pid }
    }

    func processGroupMembers(processGroupId: Int32) throws -> [ProcessEvidenceSnapshot] {
        var members: [ProcessEvidenceSnapshot] = []
        for pid in try identityReader.processGroupPIDs(processGroupId: processGroupId) {
            guard let snapshot = try identityReader.snapshot(pid: pid) else {
                throw ProcessEvidenceError.inspectionFailed(
                    "listed process-group PID \(pid) could not be identity-inspected")
            }
            members.append(snapshot)
        }
        return members.sorted { $0.pid < $1.pid }
    }

    static func withRequiredCleanup<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T,
        cleanup: @escaping @Sendable () async throws -> Void
    ) async throws -> T {
        do {
            let value = try await operation()
            try await cleanup()
            return value
        } catch {
            do {
                try await cleanup()
            } catch let cleanupError {
                throw ProcessEvidenceError.inspectionFailed(
                    "launch cleanup failed after \(error): \(cleanupError)")
            }
            throw error
        }
    }

    func establishedConnections(pid: Int32) async throws -> [ProcessEvidenceConnection] {
        let process = try await runner.start(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:ESTABLISHED", "-Fpn",
            ],
            environment: nil,
            workingDirectory: nil,
            timeout: .seconds(5),
            onStdout: nil,
            onStderr: nil)
        let output = try await process.wait()
        guard output.exitCode == 0 || output.exitCode == 1 else {
            throw ProcessEvidenceError.inspectionFailed(
                "lsof connection inspection for PID \(pid) exited \(output.exitCode)")
        }
        return try Self.parseEstablishedConnections(output.stdout, expectedPid: pid)
    }

    static func parseEstablishedConnections(
        _ data: Data,
        expectedPid: Int32
    ) throws -> [ProcessEvidenceConnection] {
        var reportedPid: Int32?
        var connections: [ProcessEvidenceConnection] = []
        for rawLine in String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
        {
            if rawLine.first == "p" {
                guard let value = Int32(rawLine.dropFirst()) else {
                    throw ProcessEvidenceError.inspectionFailed("lsof reported an invalid PID")
                }
                reportedPid = value
                continue
            }
            guard rawLine.first == "n" else { continue }
            let value = rawLine.dropFirst()
            guard let arrow = value.range(of: "->") else { continue }
            connections.append(ProcessEvidenceConnection(
                local: try parseEndpoint(value[..<arrow.lowerBound]),
                remote: try parseEndpoint(value[arrow.upperBound...])))
        }
        if let reportedPid, reportedPid != expectedPid {
            throw ProcessEvidenceError.inspectionFailed(
                "lsof reported PID \(reportedPid), expected \(expectedPid)")
        }
        if !connections.isEmpty, reportedPid == nil {
            throw ProcessEvidenceError.inspectionFailed(
                "lsof reported connections without a process PID")
        }
        return connections
    }

    static func parentChain(
        ownerPid: Int32,
        launcher: ProcessEvidenceSnapshot,
        snapshots: [Int32: ProcessEvidenceSnapshot]
    ) throws -> [ProcessEvidenceSnapshot] {
        var chain: [ProcessEvidenceSnapshot] = []
        var currentPid = ownerPid
        var seen = Set<Int32>()
        while seen.insert(currentPid).inserted {
            guard let current = snapshots[currentPid] else {
                throw ProcessEvidenceError.ancestryNotVerified(
                    "missing PID \(currentPid) in the owner-to-launcher chain")
            }
            chain.append(current)
            if current.pid == launcher.pid {
                guard current == launcher else {
                    throw ProcessEvidenceError.ancestryNotVerified(
                        "launcher identity changed while proving ancestry")
                }
                return chain
            }
            currentPid = current.parentPid
        }
        throw ProcessEvidenceError.ancestryNotVerified(
            "owner-to-launcher chain contains a cycle or does not reach the launcher")
    }

    static func isExactSDKShellOwner(
        _ snapshot: ProcessEvidenceSnapshot,
        sdkPath: String
    ) -> Bool {
        let executable = URL(fileURLWithPath: sdkPath).appending(path: "bin/shell")
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard snapshot.executablePath == executable else { return false }
        guard snapshot.arguments.count == 3,
            snapshot.arguments[0] == executable,
            snapshot.arguments[1] == "--transport=tcp",
            snapshot.arguments[2].hasPrefix("--transport_args=")
        else { return false }
        let endpoint = snapshot.arguments[2].dropFirst("--transport_args=".count)
        guard let colon = endpoint.lastIndex(of: ":"),
            UInt16(endpoint[endpoint.index(after: colon)...]) != nil else { return false }
        let address = endpoint[..<colon]
        return address == "127.0.0.1" || address == "localhost" || address == "[::1]"
    }

    static func isExactLauncher(
        _ snapshot: ProcessEvidenceSnapshot,
        sdkPath: String,
        prgPath: String,
        device: String
    ) -> Bool {
        let monkeydo = URL(fileURLWithPath: sdkPath).appending(path: "bin/monkeydo")
            .resolvingSymlinksInPath().standardizedFileURL.path
        return snapshot.executablePath == "/bin/bash"
            && snapshot.arguments == ["/bin/bash", monkeydo, prgPath, device]
    }

    static func isExactMonkeyDoDeux(
        _ snapshot: ProcessEvidenceSnapshot,
        sdkPath: String,
        prgPath: String,
        device: String
    ) -> Bool {
        let root = URL(fileURLWithPath: sdkPath)
            .resolvingSymlinksInPath().standardizedFileURL
        return snapshot.arguments == [
            "/usr/bin/java", "-classpath",
            root.appending(path: "bin/monkeybrains.jar").path,
            "com.garmin.monkeybrains.monkeydodeux.MonkeyDoDeux",
            "-f", prgPath, "-d", device, "-s", root.appending(path: "bin/shell").path,
        ]
    }

    static func validateAcceptanceBoundary(
        expectedLauncher: ProcessEvidenceSnapshot,
        expectedOwner: ProcessEvidenceSnapshot,
        currentLauncher: ProcessEvidenceSnapshot,
        currentOwner: ProcessEvidenceSnapshot,
        currentDescendants: [ProcessEvidenceSnapshot],
        sdkPath: String,
        prgPath: String,
        device: String
    ) throws -> [ProcessEvidenceSnapshot] {
        guard currentLauncher == expectedLauncher, currentOwner == expectedOwner else {
            throw ProcessEvidenceError.ancestryNotVerified(
                "launcher or owner identity changed after socket inspection")
        }
        guard isExactLauncher(
            currentLauncher, sdkPath: sdkPath, prgPath: prgPath, device: device),
            isExactSDKShellOwner(currentOwner, sdkPath: sdkPath)
        else {
            throw ProcessEvidenceError.ancestryNotVerified(
                "launcher or connection owner arguments changed after socket inspection")
        }
        var snapshots = Dictionary(uniqueKeysWithValues: currentDescendants.map { ($0.pid, $0) })
        snapshots[currentLauncher.pid] = currentLauncher
        guard snapshots[currentOwner.pid] == currentOwner else {
            throw ProcessEvidenceError.ancestryNotVerified(
                "connection owner is no longer an anchored launcher descendant")
        }
        let chain = try parentChain(
            ownerPid: currentOwner.pid, launcher: currentLauncher, snapshots: snapshots)
        guard chain.count == 3,
            isExactMonkeyDoDeux(
                chain[1], sdkPath: sdkPath, prgPath: prgPath, device: device)
        else {
            throw ProcessEvidenceError.ancestryNotVerified(
                "owner chain is not exact SDK shell -> MonkeyDoDeux -> launcher")
        }
        return chain
    }

    static func cleanupPlan(
        launcher: ProcessEvidenceSnapshot,
        testProcess: ProcessEvidenceSnapshot,
        descendants: [ProcessEvidenceSnapshot],
        groupMembers: [ProcessEvidenceSnapshot]
    ) throws -> ProcessCleanupPlan {
        var anchored = Dictionary(uniqueKeysWithValues: descendants.map { ($0.pid, $0) })
        anchored[launcher.pid] = launcher
        for descendant in descendants {
            _ = try parentChain(
                ownerPid: descendant.pid, launcher: launcher, snapshots: anchored)
        }

        // Group facts are inspected/recorded only. The Task 13A evidence
        // brief forbids process-group signaling even for a dedicated group.
        _ = testProcess
        _ = groupMembers

        let depths = try Dictionary(uniqueKeysWithValues: descendants.map { descendant in
            let chain = try parentChain(
                ownerPid: descendant.pid, launcher: launcher, snapshots: anchored)
            return (descendant.pid, chain.count)
        })
        let ordered = descendants.sorted {
            let lhsDepth = depths[$0.pid] ?? 0
            let rhsDepth = depths[$1.pid] ?? 0
            return lhsDepth == rhsDepth ? $0.pid > $1.pid : lhsDepth > rhsDepth
        }.map(\.pid) + [launcher.pid]
        return .individual(pids: ordered)
    }

    static func launcherGroupFullyAnchored(
        members: [ProcessEvidenceSnapshot],
        launcher: ProcessEvidenceSnapshot,
        descendants: [ProcessEvidenceSnapshot]
    ) -> Bool {
        let anchoredPids = Set(descendants.map(\.pid)).union([launcher.pid])
        return members.allSatisfy { anchoredPids.contains($0.pid) }
    }

    static func matchedSimulatorListener(
        remote: TCPEndpoint,
        listeners: Set<TCPEndpoint>
    ) -> TCPEndpoint? {
        guard ["127.0.0.1", "localhost", "::1"].contains(remote.address) else { return nil }
        return listeners.first { listener in
            guard listener.family == remote.family, listener.port == remote.port else {
                return false
            }
            return listener.address == remote.address
                || (remote.family == "ipv4" && listener.address == "*")
                || (remote.family == "ipv6" && listener.address == "::")
        }
    }

    static func singleCurrentListenerConnection(
        _ connections: [ProcessEvidenceConnection],
        listeners: Set<TCPEndpoint>
    ) throws -> CurrentListenerConnection? {
        let matches = connections.compactMap { connection -> CurrentListenerConnection? in
            guard let listener = matchedSimulatorListener(
                remote: connection.remote, listeners: listeners)
            else { return nil }
            return CurrentListenerConnection(connection: connection, listener: listener)
        }
        if matches.isEmpty { return nil }
        guard matches.count == 1, let match = matches.first else {
            throw ProcessEvidenceError.inspectionFailed(
                "multiple current owner connections match the validated simulator listeners")
        }
        return match
    }

    private static func parseEndpoint(_ raw: Substring) throws -> TCPEndpoint {
        let address: String
        let portText: Substring
        let family: String
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]"),
                raw.index(after: close) < raw.endIndex,
                raw[raw.index(after: close)] == ":"
            else { throw ProcessEvidenceError.inspectionFailed("malformed IPv6 endpoint \(raw)") }
            address = String(raw[raw.index(after: raw.startIndex)..<close]).lowercased()
            portText = raw[raw.index(close, offsetBy: 2)...]
            family = "ipv6"
        } else {
            guard let colon = raw.lastIndex(of: ":") else {
                throw ProcessEvidenceError.inspectionFailed("endpoint \(raw) has no port")
            }
            address = String(raw[..<colon]).lowercased()
            portText = raw[raw.index(after: colon)...]
            family = address.contains(":") ? "ipv6" : "ipv4"
        }
        guard let port = UInt16(portText) else {
            throw ProcessEvidenceError.inspectionFailed("endpoint \(raw) has an invalid port")
        }
        return TCPEndpoint(address: address, port: port, family: family)
    }
}

struct EvidenceCleanupExecutor: Sendable {
    let identityReader: any ProcessIdentityReading
    let signaler: any ProcessSignalSending
    let waitForExit: @Sendable (ProcessEvidenceSnapshot) async throws -> Bool
    let terminateOwnedWrapper: @Sendable () async throws -> Void

    func cleanup(
        launcher: ProcessEvidenceSnapshot?,
        launcherPid: Int32,
        previouslyObserved: [ProcessEvidenceSnapshot]
    ) async throws {
        let collector = ProcessEvidenceCollector(identityReader: identityReader)
        guard let launcher else {
            var known = Dictionary(
                uniqueKeysWithValues: previouslyObserved.map { ($0.pid, $0) })
            while true {
                let (current, depths) = try captureAnchoredDescendants(rootPid: launcherPid)
                let currentByPid = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0) })
                for observed in known.values
                where try identityReader.snapshot(pid: observed.pid) == observed {
                    guard currentByPid[observed.pid] == observed else {
                        throw ProcessEvidenceError.ancestryNotVerified(
                            "previously owned PID \(observed.pid) is alive but no longer anchored")
                    }
                }
                guard let candidate = current.max(by: {
                    let lhsDepth = depths[$0.pid] ?? 0
                    let rhsDepth = depths[$1.pid] ?? 0
                    return lhsDepth == rhsDepth ? $0.pid < $1.pid : lhsDepth < rhsDepth
                }) else { break }
                known[candidate.pid] = candidate
                if let failure = await terminate(
                    candidate,
                    validate: {
                        let (fresh, _) = try captureAnchoredDescendants(rootPid: launcherPid)
                        guard fresh.first(where: { $0.pid == candidate.pid }) == candidate else {
                            throw ProcessEvidenceError.ancestryNotVerified(
                                "descendant PID \(candidate.pid) changed before signal")
                        }
                        return candidate
                    })
                {
                    throw ProcessEvidenceError.inspectionFailed(
                        "partial initial launch cleanup failure: \(failure)")
                }
            }
            guard try identityReader.childPIDs(parentPid: launcherPid).isEmpty else {
                throw ProcessEvidenceError.inspectionFailed(
                    "new or uninspected child appeared before wrapper cleanup")
            }
            try await terminateOwnedWrapper()
            return
        }

        guard let currentLauncher = try identityReader.snapshot(pid: launcher.pid),
            currentLauncher == launcher
        else {
            let survivors = try previouslyObserved.filter {
                try identityReader.snapshot(pid: $0.pid) == $0
            }
            guard survivors.isEmpty else {
                throw ProcessEvidenceError.inspectionFailed(
                    "launcher disappeared while previously owned descendants remain")
            }
            try await terminateOwnedWrapper()
            return
        }

        var known = Dictionary(uniqueKeysWithValues: previouslyObserved.map { ($0.pid, $0) })
        while true {
            guard let currentLauncher = try identityReader.snapshot(pid: launcher.pid) else {
                let survivors = try known.values.filter {
                    try identityReader.snapshot(pid: $0.pid) == $0
                }
                guard survivors.isEmpty else {
                    throw ProcessEvidenceError.inspectionFailed(
                        "launcher disappeared while previously owned descendants remain")
                }
                break
            }
            guard currentLauncher == launcher else {
                throw ProcessEvidenceError.inspectionFailed(
                    "launcher changed identity during descendant cleanup")
            }
            let current = try collector.descendants(of: launcher)
            let currentByPid = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0) })
            for observed in known.values
            where try identityReader.snapshot(pid: observed.pid) == observed {
                guard currentByPid[observed.pid] == observed else {
                    throw ProcessEvidenceError.ancestryNotVerified(
                        "previously owned PID \(observed.pid) is alive but no longer anchored")
                }
            }
            guard !current.isEmpty else { break }
            let plan = try ProcessEvidenceCollector.cleanupPlan(
                launcher: launcher, testProcess: launcher,
                descendants: current, groupMembers: [])
            guard case .individual(let pids) = plan,
                let pid = pids.first(where: { $0 != launcher.pid }),
                let candidate = currentByPid[pid]
            else {
                throw ProcessEvidenceError.inspectionFailed("unexpected cleanup plan")
            }
            known[candidate.pid] = candidate
            if let failure = await terminate(
                candidate,
                validate: {
                    guard try identityReader.snapshot(pid: launcher.pid) == launcher else {
                        throw ProcessEvidenceError.inspectionFailed(
                            "launcher disappeared during descendant cleanup")
                    }
                    let fresh = try collector.descendants(of: launcher)
                    guard fresh.first(where: { $0.pid == candidate.pid }) == candidate else {
                        throw ProcessEvidenceError.ancestryNotVerified(
                            "descendant PID \(candidate.pid) changed identity or ancestry before signal")
                    }
                    return candidate
                })
            {
                // Preserve every ancestor anchor when one child cannot be
                // terminated. Continuing upward would reparent/orphan it.
                throw ProcessEvidenceError.inspectionFailed(
                    "partial launch cleanup failure: \(failure)")
            }
        }

        let finalLauncher = try identityReader.snapshot(pid: launcher.pid)
        if finalLauncher == launcher {
            guard try collector.descendants(of: launcher).isEmpty else {
                throw ProcessEvidenceError.inspectionFailed(
                    "a new descendant appeared before owned-wrapper termination")
            }
            try await terminateOwnedWrapper()
        } else if finalLauncher != nil {
            throw ProcessEvidenceError.inspectionFailed(
                "launcher changed identity before owned-wrapper termination")
        }
        // Bash normally exits after its Java child. Once every captured and
        // freshly enumerated descendant is absent, an absent launcher is safe.
    }

    private func captureAnchoredDescendants(
        rootPid: Int32
    ) throws -> ([ProcessEvidenceSnapshot], [Int32: Int]) {
        var captured: [ProcessEvidenceSnapshot] = []
        var depths: [Int32: Int] = [:]
        var pending: [(parentPid: Int32, depth: Int)] = [(rootPid, 0)]
        var seen = Set<Int32>()
        while let parent = pending.popLast() {
            for pid in try identityReader.childPIDs(parentPid: parent.parentPid) {
                guard seen.insert(pid).inserted else {
                    throw ProcessEvidenceError.inspectionFailed(
                        "initial launcher descendant enumeration repeated PID \(pid)")
                }
                guard let snapshot = try identityReader.snapshot(pid: pid) else {
                    throw ProcessEvidenceError.inspectionFailed(
                        "initial launcher capture failed with uninspectable child PID \(pid)")
                }
                guard snapshot.parentPid == parent.parentPid else {
                    throw ProcessEvidenceError.ancestryNotVerified(
                        "listed child PID \(pid) changed parent before identity capture")
                }
                let depth = parent.depth + 1
                captured.append(snapshot)
                depths[pid] = depth
                pending.append((pid, depth))
            }
        }
        return (captured, depths)
    }

    private func validateAnchoredDescendant(
        _ candidate: ProcessEvidenceSnapshot,
        rootPid: Int32,
        captured: [ProcessEvidenceSnapshot]
    ) throws -> ProcessEvidenceSnapshot {
        let byPid = Dictionary(uniqueKeysWithValues: captured.map { ($0.pid, $0) })
        guard try identityReader.snapshot(pid: candidate.pid) == candidate else {
            throw ProcessEvidenceError.ancestryNotVerified(
                "descendant PID \(candidate.pid) changed identity before signal")
        }
        var current = candidate
        var seen = Set<Int32>()
        while current.parentPid != rootPid {
            guard seen.insert(current.pid).inserted,
                let expectedParent = byPid[current.parentPid],
                try identityReader.snapshot(pid: expectedParent.pid) == expectedParent
            else {
                throw ProcessEvidenceError.ancestryNotVerified(
                    "descendant PID \(candidate.pid) is no longer anchored to launcher PID \(rootPid)")
            }
            current = expectedParent
        }
        return candidate
    }

    private func terminate(
        _ candidate: ProcessEvidenceSnapshot,
        validate: () throws -> ProcessEvidenceSnapshot
    ) async -> String? {
        do {
            _ = try validate()
            try signaler.signal(pid: candidate.pid, signal: SIGTERM)
        } catch {
            return "PID \(candidate.pid) TERM: \(error)"
        }

        let exitedAfterTerm: Bool
        do {
            exitedAfterTerm = try await waitForExit(candidate)
        } catch is CancellationError {
            exitedAfterTerm = false
        } catch {
            exitedAfterTerm = false
        }
        if exitedAfterTerm { return nil }

        do {
            guard try identityReader.snapshot(pid: candidate.pid) == candidate else {
                return nil
            }
            _ = try validate()
            try signaler.signal(pid: candidate.pid, signal: SIGKILL)
        } catch {
            return "PID \(candidate.pid) KILL: \(error)"
        }

        do {
            _ = try await waitForExit(candidate)
        } catch is CancellationError {
            // A synchronous identity check below remains authoritative even
            // when the caller was cancelled during the grace wait.
        } catch {
            // Fail closed through the same final identity check.
        }
        do {
            guard try identityReader.snapshot(pid: candidate.pid) != candidate else {
                return "PID \(candidate.pid) remained alive after SIGKILL"
            }
            return nil
        } catch {
            return "PID \(candidate.pid) final identity inspection: \(error)"
        }
    }
}

struct EvidenceLaunchTimer<C: Clock>: Sendable where C.Duration == Duration, C: Sendable {
    let clock: C

    func markLaunchStart() -> C.Instant { clock.now }

    func elapsedMilliseconds(since start: C.Instant) -> Int {
        let components = start.duration(to: clock.now).components
        let seconds = Double(components.seconds)
        let fractional = Double(components.attoseconds) / 1e18
        return Int((seconds + fractional) * 1_000)
    }
}
