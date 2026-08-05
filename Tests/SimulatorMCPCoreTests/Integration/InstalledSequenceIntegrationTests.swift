import Foundation
import MCP
import Testing

@testable import SimulatorMCPCore

private let sequenceIntegrationEnabled =
    ProcessInfo.processInfo.environment["SIM_INTEGRATION"] == "1"

/// Gate 11: `run_sequence` driven through the installed, signed server against
/// the real simulator and the real fixture app.
///
/// Delivery is read only from the fixture's own log markers. A `waitForLog`
/// step that completes *is* that evidence — the marker it matched was printed
/// by the watch app's key handler — so a successful tool result is never taken
/// as proof that the simulator saw the key.
@Suite("Installed sequence", .enabled(if: sequenceIntegrationEnabled), .serialized)
struct InstalledSequenceIntegrationTests {

    @Test("a sequence presses, waits on the fixture's marker, and returns both frames")
    func sequenceDeliversAndReturnsFrames() async throws {
        try await withSequenceSession { session in
            let response = try await session.client.callTool(
                "run_sequence",
                arguments: [
                    "steps": .array([
                        .object(["kind": .string("screenshot"), "label": .string("initial")]),
                        .object(["kind": .string("press"), "button": .string("down")]),
                        // The fixture prints this from its own key handler, so the
                        // wait completing is the delivery evidence.
                        .object([
                            "kind": .string("waitForLog"),
                            "contains": .string("FIXTURE_KEY down PRESS"),
                            "timeoutMs": .int(15_000),
                        ]),
                        .object(["kind": .string("screenshot"), "label": .string("after_down")]),
                    ]),
                    "allowFocus": true,
                ],
                as: SequenceResult.self)

            let result = try requireSequenceSuccess(response)
            #expect(result.steps.map(\.status) == ["completed", "completed", "completed", "completed"])
            #expect(result.steps.map(\.kind) == ["screenshot", "press", "waitForLog", "screenshot"])
            #expect(result.sessionId == session.sessionId)

            // The press reported the verified transport, and the wait actually
            // scanned lines rather than matching something already buffered.
            let press = try #require(result.steps.first { $0.kind == "press" })
            #expect(press.button == "down")
            #expect(press.transport == "focused-keys")
            let wait = try #require(result.steps.first { $0.kind == "waitForLog" })
            #expect((wait.linesScanned ?? 0) >= 1)

            // Two labelled captures, and one inline image block for each.
            let captures = result.steps.filter { $0.kind == "screenshot" }
            #expect(captures.map(\.label) == ["initial", "after_down"])
            #expect(captures.allSatisfy { ($0.path ?? "").hasSuffix(".png") })

            // Gate 7 asks for labels, not a tally. Each frame is announced by its
            // own text block and immediately followed by its image, so asserting
            // the ordered labels proves both that two frames arrived and that each
            // is identifiable -- which a count alone never showed.
            #expect(labelledFrames(response.content) == ["frame 0: initial", "frame 3: after_down"])
        }
    }

    @Test("a marker that never arrives fails the step and still returns the frames")
    func timeoutReturnsPartialEvidence() async throws {
        try await withSequenceSession { session in
            let response = try await session.client.callTool(
                "run_sequence",
                arguments: [
                    "steps": .array([
                        .object(["kind": .string("screenshot"), "label": .string("before")]),
                        .object([
                            "kind": .string("waitForLog"),
                            "contains": .string("MARKER_THE_FIXTURE_NEVER_PRINTS"),
                            "timeoutMs": .int(2_000),
                        ]),
                        .object(["kind": .string("screenshot"), "label": .string("never")]),
                    ]),
                    "allowFocus": true,
                ],
                as: SequenceResult.self)

            #expect(response.isError)
            let failure = try #require(response.envelope.error)
            #expect(failure.code == "sequence_marker_timeout")
            #expect(failure.details?["failedStepIndex"] == .int(1))
            #expect(!failure.fix.isEmpty)

            // Gate 7 asks for labels and statuses, not a frame tally. On a failure
            // the envelope has no result branch, so the per-step record rides in
            // details -- assert on that, and let the block count corroborate it.
            let steps = try #require(failure.details?["steps"])
            guard case .array(let outcomes) = steps else {
                Issue.record("details.steps is not an array")
                return
        }
        #expect(outcomes.count == 3)
        #expect(stepField(outcomes, 0, "status") == .string("completed"))
        #expect(stepField(outcomes, 0, "label") == .string("before"))
        #expect(stepField(outcomes, 1, "status") == .string("failed"))
        #expect(stepField(outcomes, 1, "kind") == .string("waitForLog"))
        #expect(stepField(outcomes, 2, "status") == .string("skipped"))

        // The evidence survives the failure: the frame captured before the
        // failing step, plus the terminal capture taken at the moment it failed.
        #expect(labelledFrames(response.content) == ["frame 0: before", "frame 1: post-failure"])
        }
    }

    @Test("allowFocus=false is refused inside a sequence exactly as for one press")
    func focusRefusalParity() async throws {
        try await withSequenceSession { session in
            let single = try await session.client.callTool(
                "press_button",
                arguments: ["button": .string("enter"), "allowFocus": false],
                as: PressButtonResult.self)
            let sequence = try await session.client.callTool(
                "run_sequence",
                arguments: [
                    "steps": .array([
                        .object(["kind": .string("press"), "button": .string("enter")]),
                    ]),
                    "allowFocus": false,
                ],
                as: SequenceResult.self)

            let singleFailure = try #require(single.envelope.error)
            let sequenceFailure = try #require(sequence.envelope.error)
            #expect(singleFailure.code == "focus_required")
            // Byte-identical refusal: the sequence enters the same service and must
            // not soften or reword what a single press already says.
            #expect(sequenceFailure.code == singleFailure.code)
            #expect(sequenceFailure.message == singleFailure.message)
            #expect(sequenceFailure.fix == singleFailure.fix)
        }
    }
}

// MARK: - Session

/// Brings up the installed server, a clean simulator and the fixture app, and
/// leaves them running for one test.
private struct SequenceIntegrationSession {
    let client: InstalledServerClient
    let sessionId: Int

    static func start() async throws -> SequenceIntegrationSession {
        let executable = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/bin/simulator-mcp")
        let client = InstalledServerClient(executableURL: executable)
        try await client.start()
        // From here on the subprocess exists, so every failure path must stop
        // it: withSequenceSession only owns teardown once start() has returned.
        do {
            return try await bringUp(client: client, executable: executable)
        } catch {
            _ = await client.stop()
            throw error
        }
    }

    private static func bringUp(
        client: InstalledServerClient, executable: URL
    ) async throws -> SequenceIntegrationSession {
        let developerKey = try #require(
            ProcessInfo.processInfo.environment["SIM_DEVELOPER_KEY"],
            "SIM_DEVELOPER_KEY must name an external Connect IQ developer key")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appending(path: "Tests/fixtures/testapp", directoryHint: .isDirectory)
        let sdk = try #require(
            SdkLocator().installedSdks().first { $0.version.description == "9.1.0" },
            "SDK 9.1.0 must be installed")
        try validateTask17ToolAdvertisement(try await client.listTools())

        _ = try await client.callTool("sim_stop", as: SimStopResult.self)
        try await waitForSimulatorStopped(client, deadline: Duration.seconds(30))
        _ = try requireSuccess(
            try await client.callTool(
                "sim_start", arguments: ["sdk": .string(sdk.root.path)], as: SimStartResult.self),
            tool: "sim_start")
        let run = try requireSuccess(
            try await client.callTool(
                "run_app",
                arguments: [
                    "projectPath": .string(fixture.path),
                    "device": .string("fenix6xpro"),
                    "sdk": .string(sdk.root.path),
                    "developerKey": .string(developerKey),
                ], as: RunAppResult.self),
            tool: "run_app")

        let reader = FixtureMarkerReader(client: client, sessionId: run.sessionId)
        let started = try await reader.wait(for: "FIXTURE_STARTED", timeout: .seconds(60))
        // #require, not #expect: continuing would run the sequence against an
        // app that never started and report that as a sequence defect.
        try #require(started, "the fixture app never reported FIXTURE_STARTED")

        return SequenceIntegrationSession(client: client, sessionId: run.sessionId)
    }

    func tearDown() async {
        _ = try? await client.callTool("sim_stop", as: SimStopResult.self)
        _ = await client.stop()
    }
}

private func withSequenceSession(
    _ body: (SequenceIntegrationSession) async throws -> Void
) async throws {
    let session = try await SequenceIntegrationSession.start()
    do {
        try await body(session)
    } catch {
        await session.tearDown()
        throw error
    }
    await session.tearDown()
}

/// The labels of frames actually delivered, in order. A frame is a text block
/// naming it immediately followed by its image block, so a label without an
/// image -- or an image without a label -- is not counted, which is stricter
/// than either half alone.
private func labelledFrames(_ content: [Tool.Content]) -> [String] {
    var labels: [String] = []
    for (index, block) in content.enumerated() {
        guard case .text(let text, _, _) = block, text.hasPrefix("frame ") else { continue }
        guard content.indices.contains(index + 1),
            case .image = content[index + 1]
        else { continue }
        labels.append(text)
    }
    return labels
}

/// Reads one column out of the per-step outcome array carried in a failure's
/// `details`, which is the only structured channel a failure envelope has.
private func stepField(_ outcomes: [JSONValue], _ index: Int, _ key: String) -> JSONValue? {
    guard outcomes.indices.contains(index), case .object(let fields) = outcomes[index]
    else { return nil }
    return fields[key]
}

private func requireSequenceSuccess(
    _ response: InstalledToolResponse<SequenceResult>
) throws -> SequenceResult {
    guard response.isError == false, response.envelope.ok, let result = response.envelope.result
    else {
        let failure = response.envelope.error
        throw InstalledIntegrationError(
            "run_sequence failed [\(failure?.code ?? "unknown")]: "
                + "\(failure?.message ?? "missing message"). Fix: \(failure?.fix ?? "missing fix")"
                + (failure?.details.map { " Details: \($0)" } ?? ""))
    }
    return result
}
