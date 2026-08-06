import Foundation
import Testing

import SimulatorMCPCore

private let integrationEnabled =
    ProcessInfo.processInfo.environment["SIM_INTEGRATION"] == "1"

/// Gate 8.2: proves the device-switch fix against the real simulator through
/// the installed signed server. Ground truth for the defect this closes is
/// `docs/verification/simulator-contracts/simulator-window-title.json` —
/// `run_app(device: "fenix7s")` after `fenix6xpro` returned `ok` with a fresh
/// `sessionId` while the window still showed fēnix 6X Pro.
///
/// Two devices with different display widths (`fenix6xpro` 280×280,
/// `fenix7s` 240×240 — read from each device's own `simulator.json` via
/// `DeviceCatalog`, never assumed) make the corroboration meaningful: a
/// mislabeled capture would report the wrong device's own name but the
/// FIXTURE-app's true screen width, so matching `deviceVerified: true`
/// against a SECOND, independent observation (the fixture's own logged
/// `FIXTURE_SCREEN_WIDTH`, read back through `get_logs`) is what makes this a
/// real acceptance gate rather than a single unverified claim — which is
/// exactly what shipped and was wrong before this fix.
@Suite("Device switch acceptance", .enabled(if: integrationEnabled), .serialized)
struct DeviceSwitchIntegrationTests {
    @Test(
        "run_app across A, B, A verifies device, restarts on switch, and is corroborated by the fixture's own logged screen width",
        .timeLimit(.minutes(6)))
    func deviceSwitchRoundTrip() async throws {
        let root = repositoryRoot()
        let executable = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/bin/simulator-mcp")
        let developerKey = try #require(
            ProcessInfo.processInfo.environment["SIM_DEVELOPER_KEY"],
            "SIM_DEVELOPER_KEY must name an external Connect IQ developer key")
        #expect(FileManager.default.isReadableFile(atPath: developerKey))
        let fixture = root.appending(path: "Tests/fixtures/testapp")

        let deviceA = "fenix6xpro"
        let deviceB = "fenix7s"
        let catalog = DeviceCatalog()
        let installed = Dictionary(
            uniqueKeysWithValues: catalog.installedDevices().map { ($0.deviceId, $0) })
        let widthA = try #require(
            installed[deviceA]?.displayRect?.width,
            "\(deviceA) must have a display.location.width in its installed simulator.json")
        let widthB = try #require(
            installed[deviceB]?.displayRect?.width,
            "\(deviceB) must have a display.location.width in its installed simulator.json")
        #expect(
            widthA != widthB,
            "the two devices must have different display widths for the corroboration to be meaningful")

        let client = InstalledServerClient(executableURL: executable)
        try await client.start()

        do {
            try validateTask17ToolAdvertisement(try await client.listTools())
            _ = try requireSuccess(
                try await client.callTool("sim_start", as: SimStartResult.self), tool: "sim_start")

            // 1. First launch on device A: nothing was loaded before, so this
            //    is not a switch.
            let runA1 = try await runApp(deviceA, fixture: fixture, developerKey: developerKey, client: client)
            debugDump("runA1", runA1)
            #expect(runA1.device == deviceA)
            #expect(runA1.deviceVerified == true)
            #expect(runA1.simulatorRestarted == false)
            try await assertCorroboratedWidth(
                expected: widthA, sessionId: runA1.sessionId, device: deviceA, client: client)

            // 2. Switch to device B: must restart and verify B, not silently
            //    keep reporting A while the window still shows it.
            let runB = try await runApp(deviceB, fixture: fixture, developerKey: developerKey, client: client)
            debugDump("runB", runB)
            #expect(runB.device == deviceB)
            #expect(runB.deviceVerified == true)
            #expect(runB.simulatorRestarted == true)
            try await assertCorroboratedWidth(
                expected: widthB, sessionId: runB.sessionId, device: deviceB, client: client)

            // 3. Switch back to device A: this is the exact defect
            //    reproduction shape (A -> B -> A), so it must also restart
            //    and verify, and the corroborating width must go back too.
            let runA2 = try await runApp(deviceA, fixture: fixture, developerKey: developerKey, client: client)
            debugDump("runA2", runA2)
            #expect(runA2.device == deviceA)
            #expect(runA2.deviceVerified == true)
            #expect(runA2.simulatorRestarted == true)
            try await assertCorroboratedWidth(
                expected: widthA, sessionId: runA2.sessionId, device: deviceA, client: client)

            // 4. Same-device re-run: no switch occurred, so no restart is
            //    expected even though a new app session is launched. This is
            //    part of the release's own gate wording (simulatorRestarted
            //    must be false here) and stays asserted.
            //
            //    Deliberately NOT corroborated by FIXTURE_SCREEN_WIDTH like
            //    launches 1-3: a same-device relaunch with no intervening
            //    simulator restart loses log capture for the new session
            //    (get_logs returns zero lines indefinitely even though the
            //    app is genuinely running) on BOTH this branch and shipped
            //    v0.5.0. It is pre-existing and out of this release's scope
            //    — see
            //    docs/verification/simulator-contracts/same-device-relaunch-log-loss.json.
            //    Asserting the corroboration here would fail on a defect
            //    this release neither caused nor fixes.
            let runA3 = try await runApp(deviceA, fixture: fixture, developerKey: developerKey, client: client)
            debugDump("runA3", runA3)
            #expect(runA3.device == deviceA)
            #expect(runA3.deviceVerified == true)
            #expect(runA3.simulatorRestarted == false)

            _ = try await client.callTool("sim_stop", as: SimStopResult.self)
        } catch {
            Log.err("device_switch_gate: server diagnostics on failure:\n\(await client.diagnosticText())")
            _ = try? await client.callTool("sim_stop", as: SimStopResult.self)
            await client.stop()
            throw error
        }
        #expect(await client.stop())
    }

    private func debugDump(_ label: String, _ result: RunAppResult) {
        Log.err(
            "device_switch_gate: \(label) sessionId=\(result.sessionId) device=\(result.device) "
                + "deviceVerified=\(result.deviceVerified) "
                + "deviceVerificationUnavailable=\(result.deviceVerificationUnavailable ?? "nil") "
                + "observedDeviceDisplayName=\(result.observedDeviceDisplayName ?? "nil") "
                + "simulatorRestarted=\(result.simulatorRestarted) "
                + "invalidatedSessionId=\(result.invalidatedSessionId.map(String.init) ?? "nil") "
                + "rebuilt=\(result.rebuilt)")
    }

    private func runApp(
        _ device: String, fixture: URL, developerKey: String, client: InstalledServerClient
    ) async throws -> RunAppResult {
        try requireSuccess(
            try await client.callTool(
                "run_app",
                arguments: [
                    "projectPath": .string(fixture.path),
                    "device": .string(device),
                    "developerKey": .string(developerKey),
                    "rebuild": true,
                ],
                as: RunAppResult.self),
            tool: "run_app")
    }

    /// Waits for the fixture's own `FIXTURE_SCREEN_WIDTH <n>` marker for this
    /// session and asserts it equals the device's real display width. This is
    /// the second, independent observation: `deviceVerified` comes from the
    /// simulator window title, and this comes from the app-owned log stream,
    /// so a capture mislabeled with a claimed device (rather than the one the
    /// simulator actually loaded) cannot pass both checks at once.
    private func assertCorroboratedWidth(
        expected: Int, sessionId: Int, device: String, client: InstalledServerClient
    ) async throws {
        let observed = try await waitForScreenWidth(sessionID: sessionId, client: client)
        #expect(
            observed == expected,
            "fixture-logged screen width for \(device) (session \(sessionId)) was \(observed), expected \(expected)"
        )
    }

    private func waitForScreenWidth(
        sessionID: Int, client: InstalledServerClient
    ) async throws -> Int {
        let marker = "FIXTURE_SCREEN_WIDTH "
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var token: String?
        var seen: [String] = []
        var lastLogs: GetLogsResult?
        while ContinuousClock.now < deadline {
            var arguments: [String: JSONValue] = ["sessionId": .int(sessionID), "limit": 500]
            if let token { arguments["sinceToken"] = .string(token) }
            let logs = try requireSuccess(
                try await client.callTool(
                    "get_logs", arguments: arguments, as: GetLogsResult.self),
                tool: "get_logs")
            lastLogs = logs
            for line in logs.lines {
                seen.append(line.text)
                if line.text.hasPrefix(marker), let width = Int(line.text.dropFirst(marker.count)) {
                    return width
                }
            }
            token = logs.nextToken
            try await Task.sleep(for: .milliseconds(25))
        }
        throw InstalledIntegrationError(
            "Timed out waiting for a \(marker)<width> log line for session \(sessionID). "
                + "Saw \(seen.count) lines: \(seen). "
                + "Last get_logs state=\(lastLogs?.state ?? "nil") "
                + "crashDetected=\(lastLogs.map { String($0.crashDetected) } ?? "nil") "
                + "exitCode=\(lastLogs?.exitCode.map(String.init) ?? "nil") "
                + "terminationReason=\(lastLogs?.terminationReason ?? "nil") "
                + "droppedLines=\(lastLogs.map { String($0.droppedLines) } ?? "nil")")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // Integration
            .deletingLastPathComponent() // SimulatorMCPCoreTests
            .deletingLastPathComponent() // Tests
    }
}
