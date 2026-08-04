import Foundation
import Testing

@testable import SimulatorMCPCore

/// Task 0 of the fēnix family qualification plan: measure, do not implement.
///
/// This probe answers one question — do the key codes verified for
/// `fenix6xpro` deliver on other members of the family? It deliberately does
/// NOT go through `ButtonInputService`, whose device guard is the thing under
/// investigation. Instead it drives simulator control through the installed
/// server (`sim_start`, `run_app` and `get_logs` are device-agnostic today) and
/// posts keys in-process with the real `FocusedKeyTransport`, carrying the
/// shipped `fenix6xpro` profile purely for its key codes and dwell floor.
///
/// Posting in-process is sound here because the test runner inherits the
/// Accessibility grant from its responsible process; nothing in the installed
/// payload at `~/.simulator-mcp/bin/` is modified, swapped, or restored.
///
/// Delivery is counted only from the fixture's own markers, read with an
/// advancing cursor, exactly as the shipped gate counts it.
@Suite(
    "Fenix family input probe",
    .enabled(if: ProcessInfo.processInfo.environment["SIM_FAMILY_PROBE"] == "1"))
struct FenixFamilyProbeIntegrationTests {
    /// One device per generation, spanning both display technologies. fēnix 8
    /// requires Connect IQ API level 6.0.0, which SDK 8.4.1 cannot compile.
    private static let probeDevices: [(device: String, sdks: [String])] = [
        ("fenix6", ["9.1.0"]),
        ("fenix6pro", ["8.4.1"]),
        ("fenix7", ["8.4.1"]),
        ("fenix7x", ["9.1.0"]),
    ]

    private static let buttons: [(button: String, holdMs: Int?, marker: String)] = [
        ("enter", nil, "FIXTURE_KEY enter PRESS"),
        ("esc", nil, "FIXTURE_KEY esc PRESS"),
        ("up", nil, "FIXTURE_KEY up PRESS"),
        ("down", nil, "FIXTURE_KEY down PRESS"),
        ("up", 1_000, "FIXTURE_KEY up HOLD"),
    ]

    @Test("verified key codes deliver across the fenix family")
    func familyProbe() async throws {
        let root = repositoryRoot()
        let executable = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/bin/simulator-mcp")
        let developerKey = try #require(
            ProcessInfo.processInfo.environment["SIM_DEVELOPER_KEY"],
            "SIM_DEVELOPER_KEY must name an external Connect IQ developer key")
        let fixture = root.appending(path: "Tests/fixtures/testapp", directoryHint: .isDirectory)
        let installed = Dictionary(uniqueKeysWithValues: SdkLocator().installedSdks().map {
            ($0.version.description, $0)
        })

        let qualified = try InputProfileLoader.loadQualificationCandidate()
        var observations: [ProbeObservation] = []

        for (device, sdkVersions) in Self.probeDevices {
            for sdkVersion in sdkVersions {
                let sdk = try #require(
                    installed[sdkVersion], "Required SDK \(sdkVersion) is not installed")
                let client = InstalledServerClient(executableURL: executable)
                do {
                    try await client.start()
                    _ = try await client.listTools()
                    _ = try await client.callTool("sim_stop", as: SimStopResult.self)
                    _ = try probeSuccess(
                        try await client.callTool(
                            "sim_start", arguments: ["sdk": .string(sdk.root.path)],
                            as: SimStartResult.self), tool: "sim_start")

                    let run = try probeSuccess(
                        try await client.callTool(
                            "run_app",
                            arguments: [
                                "projectPath": .string(fixture.path),
                                "device": .string(device),
                                "sdk": .string(sdk.root.path),
                                "developerKey": .string(developerKey),
                            ], as: RunAppResult.self), tool: "run_app")

                    let reader = ProbeMarkerReader(client: client, sessionId: run.sessionId)
                    let started = try await reader.wait(for: "FIXTURE_STARTED", timeout: .seconds(90))
                    #expect(
                        started,
                        Comment(rawValue: "\(device) on \(sdkVersion): no FIXTURE_STARTED"))
                    guard started else { continue }

                    let status = try probeSuccess(
                        try await client.callTool("sim_status", as: SimStatusResult.self),
                        tool: "sim_status")
                    let simulatorPid = try #require(
                        status.pid, "\(device) on \(sdkVersion): simulator pid unavailable")

                    let transport = try FocusedKeyTransport(profile: qualified)
                    let context = OperationContext(
                        simulatorPid: simulatorPid, sdk: sdk, currentDevice: device,
                        listeningEndpoints: [])

                    for (button, holdMs, marker) in Self.buttons {
                        var delivered = false
                        var transportError: String?
                        do {
                            try await transport.press(
                                ButtonPressRequest(button: button, holdMs: holdMs),
                                context: context)
                            delivered = try await reader.wait(for: marker, timeout: .seconds(15))
                        } catch {
                            transportError = String(reflecting: error)
                        }
                        observations.append(
                            ProbeObservation(
                                device: device, sdk: sdkVersion, button: button, holdMs: holdMs,
                                keyCode: Self.keyCode(qualified, sdk: sdkVersion, button: button),
                                delivered: delivered, transportError: transportError))
                        #expect(
                            delivered,
                            Comment(
                                rawValue:
                                    "\(device) on \(sdkVersion): no \(marker)"
                                    + (transportError.map { " (transport: \($0))" } ?? "")))
                    }
                    _ = try await client.callTool("sim_stop", as: SimStopResult.self)
                } catch {
                    observations.append(
                        ProbeObservation(
                            device: device, sdk: sdkVersion, button: "<setup>", holdMs: nil,
                            keyCode: nil, delivered: false,
                            transportError: String(reflecting: error)))
                    Issue.record("\(device) on \(sdkVersion) failed setup: \(error)")
                }
                await client.stop()
            }
        }

        try ProbeObservation.write(observations, to: root.appending(path: ".build/fenix-family-probe.json"))
    }

    private static func keyCode(
        _ qualified: QualifiedInputProfile, sdk: String, button: String
    ) -> Int? {
        guard case .int(let code)? = qualified.profile.transport
            .sdkEntries[sdk]?[button]?["keyCode"] else { return nil }
        return code
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

private struct ProbeObservation: Codable, Sendable {
    let device: String
    let sdk: String
    let button: String
    let holdMs: Int?
    let keyCode: Int?
    let delivered: Bool
    let transportError: String?

    static func write(_ observations: [ProbeObservation], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(observations).write(to: url, options: .atomic)
    }
}

/// Mirrors the shipped gate's reader: the cursor advances between reads, so a
/// marker produced by an earlier press can never satisfy a later one.
private actor ProbeMarkerReader {
    private let client: InstalledServerClient
    private let sessionId: Int
    private var cursor: String?

    init(client: InstalledServerClient, sessionId: Int) {
        self.client = client
        self.sessionId = sessionId
    }

    func wait(for marker: String, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            var arguments: [String: JSONValue] = ["sessionId": .int(sessionId), "limit": 500]
            if let cursor { arguments["sinceToken"] = .string(cursor) }
            let logs = try probeSuccess(
                try await client.callTool("get_logs", arguments: arguments, as: GetLogsResult.self),
                tool: "get_logs")
            cursor = logs.nextToken
            if logs.lines.contains(where: { $0.text.contains(marker) }) { return true }
            try await Task.sleep(for: .milliseconds(400))
        }
        return false
    }
}

/// `requireSuccess` in the shipped gate is file-private; this is the same
/// unwrap so the probe fails loudly on a tool error instead of decoding junk.
private func probeSuccess<Result: Codable & Sendable>(
    _ response: InstalledToolResponse<Result>,
    tool: String
) throws -> Result {
    guard response.isError == false, response.envelope.ok,
        let result = response.envelope.result
    else {
        let failure = response.envelope.error
        throw ProbeError(
            "\(tool) failed [\(failure?.code ?? "unknown")]: "
                + "\(failure?.message ?? "missing message")")
    }
    return result
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
