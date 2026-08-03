import Foundation
import MCP
import Testing

@testable import SimulatorMCPCore

@Suite("Task 16 live GPS evidence", .serialized)
struct Task16LiveEvidenceTests {
    @Test("opt-in public tools set fixture GPS through checked AX automation")
    func livePublicFixtureGate() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sdkPath = environment["SIM_TASK16_SDK_PATH"],
            let developerKey = environment["SIM_TASK16_DEVELOPER_KEY"],
            let outputPath = environment["SIM_TASK16_EVIDENCE_OUTPUT"]
        else { return }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = root.appending(
            path: "Tests/fixtures/testapp", directoryHint: .isDirectory)
        let fixtureBin = project.appending(path: "bin", directoryHint: .isDirectory)
        let services = try ToolHandlerServices.live()

        do {
            try await withMCPHarness(handlers: ToolHandlers.configured(services)) { harness in
                _ = try requireSuccess(
                    try await harness.call("sim_stop", as: SimStopResult.self),
                    tool: "sim_stop")
                let started = try requireSuccess(
                    try await harness.call(
                        "sim_start", arguments: ["sdk": .string(sdkPath)],
                        as: SimStartResult.self),
                    tool: "sim_start")
                guard started.status.sdkVersion == "9.1.0" else {
                    throw Task16LiveError(
                        "live GPS gate requires exact SDK 9.1.0, observed \(started.status.sdkVersion ?? "none")")
                }
                let launched = try requireSuccess(
                    try await harness.call(
                        "run_app",
                        arguments: [
                            "projectPath": .string(project.path),
                            "device": "fenix6xpro",
                            "sdk": .string(sdkPath),
                            "developerKey": .string(developerKey),
                            "rebuild": true,
                        ],
                        as: RunAppResult.self),
                    tool: "run_app")
                try await waitForMarker(
                    "FIXTURE_STARTED", sessionID: launched.sessionId, harness: harness)

                let gps = try requireSuccess(
                    try await harness.call(
                        "set_gps_position",
                        arguments: ["lat": 48.1351, "lon": 11.5820],
                        as: SetGpsPositionResult.self),
                    tool: "set_gps_position")
                guard gps.latitude == 48.1351, gps.longitude == 11.5820,
                    gps.simulatorPid == started.status.pid
                else {
                    throw Task16LiveError("public set_gps_position returned mismatched coordinates or PID")
                }
                try await waitForMarker(
                    "FIXTURE_GPS 48.1351 11.5820",
                    sessionID: launched.sessionId,
                    harness: harness)

                let stopped = try requireSuccess(
                    try await harness.call("sim_stop", as: SimStopResult.self),
                    tool: "sim_stop")
                guard stopped.status.state == .notRunning else {
                    throw Task16LiveError("public sim_stop did not leave not_running state")
                }

                let evidence = Task16GpsEvidence(
                    schemaVersion: 1,
                    recordedOn: ISO8601DateFormatter().string(from: Date()),
                    sdks: ["8.4.1", "9.1.0"],
                    sourceCaptureHashes: [
                        "8.4.1": "ca5c84d29e8bdae716f56e9ad86d52aa3f42d2731453fdc15b9946e593b80e4c",
                        "9.1.0": "9d33e6da266159a6449b5c43064ed005955d484cb41924471a9eeda26f7fcf01",
                    ],
                    fixtureHashes: [
                        "8.4.1": "f33c7e91b173d0c1430954dc726c2fa64578971ca6c459218962b195ffb40ad6",
                        "9.1.0": "cb343baa9174fba00c81c92bf44ad7a0691ae64b7bd90def294de3a999621302",
                    ],
                    menuPath: ["Settings", "Set Position"],
                    axMessagingTimeoutSeconds: 1,
                    observationMode: "position_get_info_poll",
                    selectedRelationships: .init(
                        instructionValue: "Enter the current position in decimal degrees (latitude, longitude)",
                        instruction: "exactly one direct-child AXStaticText",
                        field: "exactly one AXTextField in the dialog subtree and a direct child of that dialog",
                        defaultButton: "AXDefaultButton is a direct-child AXButton advertising AXPress"),
                    dialogClosed: true,
                    publicFixture: .init(
                        sdkVersion: "9.1.0",
                        device: "fenix6xpro",
                        latitude: gps.latitude,
                        longitude: gps.longitude,
                        simulatorPid: gps.simulatorPid,
                        launchMarker: "FIXTURE_STARTED",
                        gpsMarker: "FIXTURE_GPS 48.1351 11.5820",
                        simulatorStopped: true))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try AtomicFile.replace(
                    at: URL(fileURLWithPath: outputPath), with: try encoder.encode(evidence))
            }
            try? FileManager.default.removeItem(at: fixtureBin)
        } catch {
            _ = try? await services.simStop()
            try? FileManager.default.removeItem(at: fixtureBin)
            throw error
        }
    }
}

private struct Task16GpsEvidence: Codable, Sendable {
    let schemaVersion: Int
    let recordedOn: String
    let sdks: [String]
    let sourceCaptureHashes: [String: String]
    let fixtureHashes: [String: String]
    let menuPath: [String]
    let axMessagingTimeoutSeconds: Int
    let observationMode: String
    let selectedRelationships: Relationships
    let dialogClosed: Bool
    let publicFixture: PublicFixture

    struct Relationships: Codable, Sendable {
        let instructionValue: String
        let instruction: String
        let field: String
        let defaultButton: String
    }

    struct PublicFixture: Codable, Sendable {
        let sdkVersion: String
        let device: String
        let latitude: Double
        let longitude: Double
        let simulatorPid: Int32
        let launchMarker: String
        let gpsMarker: String
        let simulatorStopped: Bool
    }
}

private struct Task16LiveError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func requireSuccess<Result: Codable & Sendable>(
    _ response: (raw: CallTool.Result, envelope: ToolEnvelope<Result>), tool: String
) throws -> Result {
    guard response.envelope.ok, let result = response.envelope.result else {
        throw Task16LiveError(
            "public \(tool) failed: \(response.envelope.error?.message ?? "missing result")")
    }
    return result
}

private func waitForMarker(
    _ marker: String,
    sessionID: Int,
    harness: MCPHarness
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    var cursor: String?
    var observed: [String] = []
    while clock.now < deadline {
        try Task.checkCancellation()
        var arguments: [String: Value] = [
            "sessionId": .int(sessionID), "limit": .int(500),
        ]
        if let cursor { arguments["sinceToken"] = .string(cursor) }
        let response = try await harness.call(
            "get_logs", arguments: arguments, as: GetLogsResult.self)
        let logs = try requireSuccess(response, tool: "get_logs")
        if logs.lines.contains(where: { $0.text == marker }) { return }
        observed.append(contentsOf: logs.lines.map(\.text))
        if observed.count > 50 { observed.removeFirst(observed.count - 50) }
        cursor = logs.nextToken
        if logs.state != "running" {
            throw Task16LiveError(
                "fixture session ended before exact marker \(marker); state=\(logs.state)")
        }
        try await clock.sleep(for: .milliseconds(25))
    }
    throw Task16LiveError(
        "timed out waiting for exact fixture marker \(marker); observed=\(observed)")
}
