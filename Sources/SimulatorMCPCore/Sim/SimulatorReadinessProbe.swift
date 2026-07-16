import Foundation

public struct TCPEndpoint: Codable, Hashable, Sendable {
    public let address: String
    public let port: UInt16
    public let family: String

    public init(address: String, port: UInt16, family: String) {
        self.address = address
        self.port = port
        self.family = family
    }
}

public struct SimulatorProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let sdk: SdkInfo?

    public init(pid: Int32, executablePath: String, sdk: SdkInfo?) {
        self.pid = pid
        self.executablePath = executablePath
        self.sdk = sdk
    }
}

public struct SimulatorReadyObservation: Equatable, Sendable {
    public let identity: SimulatorProcessIdentity
    public let listeningEndpoints: Set<TCPEndpoint>

    public init(identity: SimulatorProcessIdentity, listeningEndpoints: Set<TCPEndpoint>) {
        self.identity = identity
        self.listeningEndpoints = listeningEndpoints
    }
}

/// Proves that one exact Connect IQ simulator process has a stable TCP
/// listener. Process identity is revalidated before every lsof sample.
public struct SimulatorReadinessProbe: Sendable {
    private static let stableInterval: Duration = .milliseconds(100)

    private let processRunner: any ProcessRunning
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline
    private let identityLookup: @Sendable (Int32) async throws -> SimulatorProcessIdentity?

    public init(processRunner: any ProcessRunning) {
        let clock = ContinuousClock()
        let system = SimulatorProcessSystem.live(processRunner: processRunner)
        self.processRunner = processRunner
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.identityLookup = system.lookup
    }

    init<C: Clock>(
        processRunner: any ProcessRunning,
        clock: C,
        identityLookup: @escaping @Sendable (Int32) async throws -> SimulatorProcessIdentity?
    ) where C.Duration == Duration {
        self.processRunner = processRunner
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.identityLookup = identityLookup
    }

    init(
        processRunner: any ProcessRunning,
        identityLookup: @escaping @Sendable (Int32) async throws -> SimulatorProcessIdentity?
    ) {
        let clock = ContinuousClock()
        self.processRunner = processRunner
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.identityLookup = identityLookup
    }

    public func waitUntilReady(
        pid: Int32,
        requested: SdkInfo,
        timeout: Duration = .seconds(30)
    ) async throws -> SimulatorReadyObservation {
        guard timeout >= .zero else {
            throw ToolError(
                code: "invalid_arguments",
                message: "Simulator readiness timeout must be zero or positive.",
                fix: "Pass a timeout that is zero or positive.")
        }
        let deadline = makeDeadline(timeout)
        var candidate: SimulatorReadyObservation?
        var stabilityDeadline: ClockDeadline?
        var lastProbe = "no observation"

        while true {
            try Task.checkCancellation()
            if deadline.hasExpired {
                throw Self.timeoutError(requested: requested, lastProbe: lastProbe)
            }
            let observation = try await observe(pid: pid, requested: requested)
            lastProbe = Self.probeDescription(observation)

            // A probe that finishes on or after the overall deadline is late,
            // even when it happens to match the previous sample.
            if deadline.hasExpired {
                throw Self.timeoutError(requested: requested, lastProbe: lastProbe)
            }
            if Self.hasDirectLoopback(observation.listeningEndpoints) {
                if observation == candidate, stabilityDeadline?.hasExpired == true {
                    return observation
                }
                if observation != candidate {
                    candidate = observation
                    stabilityDeadline = makeDeadline(Self.stableInterval)
                }
            } else {
                candidate = nil
                stabilityDeadline = nil
            }

            if deadline.hasExpired {
                throw Self.timeoutError(requested: requested, lastProbe: lastProbe)
            }
            try await deadline.sleepUntilNextPoll(maximumInterval: Self.stableInterval)
        }
    }

    public func observe(
        pid: Int32,
        requested: SdkInfo
    ) async throws -> SimulatorReadyObservation {
        guard let identity = try await identityLookup(pid) else {
            throw ToolError(
                code: "simulator_exited",
                message: "Connect IQ simulator process \(pid) exited before it became ready.",
                fix: "Call sim_start again and inspect the server stderr log if it exits repeatedly.",
                details: ["pid": .int(Int(pid)), "sdkPath": .string(requested.root.path)])
        }
        guard identity.pid == pid else {
            throw ToolError(
                code: "simulator_process_changed",
                message: "Simulator identity changed from PID \(pid) to PID \(identity.pid) during readiness probing.",
                fix: "Quit all Connect IQ simulator instances, then call sim_start again.",
                details: [
                    "expectedPid": .int(Int(pid)),
                    "observedPid": .int(Int(identity.pid)),
                ])
        }
        guard let runningSDK = identity.sdk else {
            throw ToolError(
                code: "unknown_running_sdk",
                message: "Simulator process \(pid) is not running from a valid Connect IQ SDK path.",
                fix: "Quit all Connect IQ simulator instances, then call sim_start with an installed SDK.",
                details: [
                    "pid": .int(Int(pid)),
                    "executablePath": .string(identity.executablePath),
                ])
        }
        guard Self.canonical(runningSDK.root) == Self.canonical(requested.root) else {
            throw ToolError(
                code: "sdk_mismatch",
                message: "Simulator process \(pid) belongs to SDK \(runningSDK.root.path), not requested SDK \(requested.root.path).",
                fix: "Call sim_stop, then sim_start with the requested SDK.",
                details: [
                    "runningSdkPath": .string(runningSDK.root.path),
                    "requestedSdkPath": .string(requested.root.path),
                ])
        }

        let child = try await processRunner.start(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fpn",
            ],
            environment: nil,
            workingDirectory: nil,
            timeout: .seconds(5),
            onStdout: nil,
            onStderr: nil)
        let output = try await child.wait()
        guard output.exitCode == 0 || output.exitCode == 1 else {
            throw ToolError(
                code: "simulator_probe_failed",
                message: "Could not inspect TCP listeners for simulator process \(pid) (lsof exit \(output.exitCode)).",
                fix: "Verify /usr/sbin/lsof is available, then retry; inspect server stderr if it repeats.",
                details: ["pid": .int(Int(pid)), "exitCode": .int(Int(output.exitCode))])
        }
        guard let identityAfterProbe = try await identityLookup(pid) else {
            throw ToolError(
                code: "simulator_exited",
                message: "Connect IQ simulator process \(pid) exited during readiness probing.",
                fix: "Call sim_start again and inspect the server stderr log if it exits repeatedly.",
                details: ["pid": .int(Int(pid)), "sdkPath": .string(requested.root.path)])
        }
        guard identityAfterProbe == identity else {
            throw ToolError(
                code: "simulator_process_changed",
                message: "Simulator process identity changed while its listeners were being inspected.",
                fix: "Quit all Connect IQ simulator instances, then call sim_start again.",
                details: ["pid": .int(Int(pid))])
        }
        let parsed = try Self.parseLsof(output.stdout)
        if let reportedPID = parsed.pid, reportedPID != pid {
            throw ToolError(
                code: "simulator_process_changed",
                message: "lsof reported PID \(reportedPID) while probing simulator PID \(pid).",
                fix: "Quit all Connect IQ simulator instances, then call sim_start again.",
                details: [
                    "expectedPid": .int(Int(pid)),
                    "observedPid": .int(Int(reportedPID)),
                ])
        }
        return SimulatorReadyObservation(
            identity: identityAfterProbe,
            listeningEndpoints: parsed.endpoints)
    }

    public static func parseLsofListeners(_ data: Data) throws -> Set<TCPEndpoint> {
        try parseLsof(data).endpoints
    }

    private static func parseLsof(_ data: Data) throws -> (pid: Int32?, endpoints: Set<TCPEndpoint>) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw probeParseError("lsof output was not UTF-8")
        }
        var reportedPID: Int32?
        var endpoints = Set<TCPEndpoint>()
        for line in text.split(whereSeparator: \Character.isNewline) {
            if line.first == "p" {
                guard let pid = Int32(line.dropFirst()) else {
                    throw probeParseError("lsof reported an invalid PID")
                }
                if let reportedPID, reportedPID != pid {
                    throw probeParseError("lsof reported multiple PIDs")
                }
                reportedPID = pid
                continue
            }
            guard line.first == "n" else { continue }
            let raw = String(line.dropFirst())
                .replacingOccurrences(of: " (LISTEN)", with: "")
            let address: String
            let portText: Substring
            let family: String

            if raw.hasPrefix("[") {
                guard let close = raw.firstIndex(of: "]"),
                    raw.index(after: close) < raw.endIndex,
                    raw[raw.index(after: close)] == ":"
                else { throw probeParseError("malformed IPv6 listener '\(raw)'") }
                address = String(raw[raw.index(after: raw.startIndex)..<close])
                portText = raw[raw.index(close, offsetBy: 2)...]
                family = "ipv6"
            } else {
                guard let colon = raw.lastIndex(of: ":") else {
                    throw probeParseError("listener '\(raw)' has no port")
                }
                address = String(raw[..<colon])
                portText = raw[raw.index(after: colon)...]
                family = address.contains(":") ? "ipv6" : "ipv4"
            }
            guard let port = UInt16(portText) else {
                throw probeParseError("listener '\(raw)' has an invalid port")
            }
            let normalized = address.lowercased()
            guard ["127.0.0.1", "::1", "localhost", "*", "::"].contains(normalized)
            else { continue }
            endpoints.insert(TCPEndpoint(address: normalized, port: port, family: family))
        }
        return (reportedPID, endpoints)
    }

    private static func probeParseError(_ reason: String) -> ToolError {
        ToolError(
            code: "simulator_probe_failed",
            message: "Could not parse simulator listener evidence: \(reason).",
            fix: "Run doctor and retry; if it repeats, inspect the raw lsof output in the server stderr log.")
    }

    private static func timeoutError(requested: SdkInfo, lastProbe: String) -> ToolError {
        ToolError(
            code: "simulator_ready_timeout",
            message: "Connect IQ simulator did not produce a stable loopback TCP listener before the readiness deadline.",
            fix: "Quit the simulator, call sim_start again, and inspect the simulator logs if readiness still times out.",
            details: [
                "sdkPath": .string(requested.root.path),
                "lastProbe": .string(lastProbe),
            ])
    }

    private static func probeDescription(_ observation: SimulatorReadyObservation) -> String {
        let endpoints = observation.listeningEndpoints
            .sorted { ($0.family, $0.address, $0.port) < ($1.family, $1.address, $1.port) }
            .map { "\($0.family):\($0.address):\($0.port)" }
            .joined(separator: ",")
        return "pid=\(observation.identity.pid) path=\(observation.identity.executablePath) endpoints=[\(endpoints)]"
    }

    static func hasDirectLoopback(_ endpoints: Set<TCPEndpoint>) -> Bool {
        endpoints.contains { ["127.0.0.1", "::1", "localhost"].contains($0.address) }
    }

    static func matchesStableProof(
        _ observation: SimulatorReadyObservation,
        proof: SimulatorReadyObservation?
    ) -> Bool {
        hasDirectLoopback(observation.listeningEndpoints) && observation == proof
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
