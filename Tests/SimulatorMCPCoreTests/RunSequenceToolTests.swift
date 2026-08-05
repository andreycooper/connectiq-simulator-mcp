import Foundation
import MCP
import Testing

@testable import SimulatorMCPCore

/// Gate 8 (nested strictness) and the handler contract: decode → one service →
/// envelope, with frames as inline image blocks on success *and* on failure.
///
/// Nothing between the client and the handler validates `inputSchema` — that is
/// measured in `docs/verification/probes/run-sequence/observations.md` — so
/// every strictness assertion here is a claim about the decoder, which is the
/// only thing that actually runs.
@Suite("RunSequenceTool", .serialized)
struct RunSequenceToolTests {

    // MARK: - Gate 8

    @Test("an unknown key inside a step is rejected, naming the step and the key")
    func unknownKeyInsideAStepIsRejected() async throws {
        try await withSequenceHarness { harness, _ in
            let response = try await harness.callRunSequence([
                "steps": .array([
                    .object(["kind": "screenshot", "label": "a"]),
                    .object(["kind": "press", "buton": "enter"]),
                ]),
            ])
            let error = try #require(response.error)
            #expect(error.code == "invalid_arguments")
            #expect(error.message.contains("1"), "names the offending step index")
            #expect(error.message.contains("buton"), "names the offending key")
            #expect(error.details?["stepIndex"] == .int(1))
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a field belonging to another kind is rejected")
    func crossKindFieldIsRejected() async throws {
        try await withSequenceHarness { harness, _ in
            // `contains` is a waitForLog field; on a press it is unknown.
            let response = try await harness.callRunSequence([
                "steps": .array([.object([
                    "kind": "press", "button": "enter", "contains": "MENU",
                ])]),
            ])
            let error = try #require(response.error)
            #expect(error.code == "invalid_arguments")
            #expect(error.message.contains("contains"))
        }
    }

    @Test("a step missing its required field is rejected")
    func missingRequiredStepFieldIsRejected() async throws {
        try await withSequenceHarness { harness, _ in
            for step in [
                Value.object(["kind": "press"]),
                Value.object(["kind": "screenshot"]),
                Value.object(["kind": "waitForLog"]),
            ] {
                let response = try await harness.callRunSequence(["steps": .array([step])])
                let error = try #require(response.error)
                #expect(error.code == "invalid_arguments")
                #expect(!error.fix.isEmpty)
            }
        }
    }

    @Test("a malformed steps argument is rejected before any service call")
    func malformedStepsAreRejected() async throws {
        try await withSequenceHarness { harness, recorder in
            let cases: [Value] = [
                .string("screenshot"),                       // not an array
                .array([.string("screenshot")]),             // element not an object
                .array([.object(["label": "a"])]),           // no kind
                .array([.object(["kind": "teleport"])]),     // unknown kind
                .array([.object(["kind": "press", "button": "enter", "holdMs": .int(10)])]),
                .array([.object(["kind": "screenshot", "label": ""])]),
            ]
            for value in cases {
                let response = try await harness.callRunSequence(["steps": value])
                let error = try #require(response.error)
                #expect(error.code == "invalid_arguments")
            }
            #expect(await recorder.requests.isEmpty, "no service call for a malformed request")
        }
    }

    @Test("an unknown top-level argument is still rejected")
    func unknownTopLevelArgumentIsRejected() async throws {
        try await withSequenceHarness { harness, _ in
            let response = try await harness.callRunSequence([
                "steps": .array([.object(["kind": "screenshot", "label": "a"])]),
                "allowfocus": .bool(true),
            ])
            let error = try #require(response.error)
            #expect(error.code == "invalid_arguments")
            #expect(error.message.contains("allowfocus"))
        }
    }

    // MARK: - Decoding reaches the service intact

    @Test("a well-formed sequence decodes to the exact request the service receives")
    func wellFormedSequenceDecodes() async throws {
        try await withSequenceHarness { harness, recorder in
            _ = try await harness.callRunSequence([
                "steps": .array([
                    .object(["kind": "screenshot", "label": "initial"]),
                    .object(["kind": "press", "button": "enter", "holdMs": .int(1_000)]),
                    .object(["kind": "waitForLog", "contains": "MENU_OPENED"]),
                    .object(["kind": "waitForLog", "contains": "DONE", "timeoutMs": .int(2_500)]),
                ]),
                "allowFocus": .bool(true),
            ])
            #expect(await recorder.requests == [RunSequenceToolRequest(
                steps: [
                    .screenshot(label: "initial"),
                    .press(button: "enter", holdMs: 1_000),
                    .waitForLog(contains: "MENU_OPENED", timeoutMs: 5_000),
                    .waitForLog(contains: "DONE", timeoutMs: 2_500),
                ],
                allowFocus: true)])
        }
    }

    @Test("allowFocus defaults to false, so a sequence never steals focus unasked")
    func allowFocusDefaultsFalse() async throws {
        try await withSequenceHarness { harness, recorder in
            _ = try await harness.callRunSequence([
                "steps": .array([.object(["kind": "screenshot", "label": "a"])]),
            ])
            #expect(await recorder.requests.first?.allowFocus == false)
        }
    }

    // MARK: - Envelope shape

    @Test("a completed sequence returns structured steps plus one image block per frame")
    func successCarriesFramesInline() async throws {
        let frames = [
            SequenceFrame(stepIndex: 0, label: "initial", png: Data([0x01])),
            SequenceFrame(stepIndex: 3, label: "menu", png: Data([0x02])),
        ]
        try await withSequenceHarness(run: SequenceRun(
            result: SequenceResult(
                sessionId: 7,
                steps: [SequenceStepOutcome(index: 0, kind: "screenshot", status: "completed",
                                            label: "initial")],
                frameCount: 2),
            frames: frames,
            failure: nil)
        ) { harness, _ in
            let response = try await harness.callRunSequence([
                "steps": .array([.object(["kind": "screenshot", "label": "initial"])]),
            ])
            #expect(response.raw.isError == false)
            #expect(response.ok == true)
            #expect(response.result?.frameCount == 2)

            // One text block for the envelope, then a label + image per frame.
            let images = response.raw.content.compactMap { block -> String? in
                if case .image(let data, _, _, _) = block { return data }
                return nil
            }
            #expect(images == [Data([0x01]).base64EncodedString(),
                               Data([0x02]).base64EncodedString()])
            let texts = response.raw.content.compactMap { block -> String? in
                if case .text(let text, _, _) = block { return text }
                return nil
            }
            #expect(texts.contains { $0.contains("initial") })
            #expect(texts.contains { $0.contains("menu") })
        }
    }

    @Test("a failed sequence returns ok:false with the frames it captured")
    func failureCarriesFramesInline() async throws {
        try await withSequenceHarness(run: SequenceRun(
            result: SequenceResult(sessionId: 7, steps: [], frameCount: 1),
            frames: [SequenceFrame(stepIndex: 0, label: "one", png: Data([0x09]))],
            failure: ToolError(
                code: "sequence_marker_timeout",
                message: "'MENU' did not appear within 5000 ms (12 lines scanned).",
                fix: "Confirm the app prints that marker with a trailing newline, or raise timeoutMs.",
                details: ["failedStepIndex": .int(1), "completedSteps": .int(1)]))
        ) { harness, _ in
            let response = try await harness.callRunSequence([
                "steps": .array([.object(["kind": "screenshot", "label": "one"])]),
            ])
            #expect(response.raw.isError == true)
            #expect(response.ok == false)
            #expect(response.error?.code == "sequence_marker_timeout")
            #expect(response.error?.details?["failedStepIndex"] == .int(1))
            #expect(!(response.error?.fix.isEmpty ?? true))

            // The frames are the point: they survive the failure envelope.
            let images = response.raw.content.compactMap { block -> Bool? in
                if case .image = block { return true }
                return nil
            }
            #expect(images.count == 1)
        }
    }

    // MARK: - Advertisement

    @Test("run_sequence is advertised with a strict schema on the qualification surface")
    func toolIsAdvertised() async throws {
        try await withSequenceHarness { harness, _ in
            let tools = try await harness.listTools()
            let tool = try #require(tools.first { $0.name == "run_sequence" })
            guard case .object(let schema) = tool.inputSchema else {
                Issue.record("input schema is not an object")
                return
            }
            #expect(schema["additionalProperties"] == false)
            #expect(schema["required"] == ["steps"])
            #expect(tool.outputSchema != nil)
            #expect(String(describing: tool.description).contains("allowFocus=true"))

            guard case .object(let properties)? = schema["properties"],
                case .object(let steps)? = properties["steps"],
                case .object(let items)? = steps["items"],
                case .array(let variants)? = items["oneOf"]
            else {
                Issue.record("steps is not an array of a three-way step union")
                return
            }
            #expect(variants.count == 3)
        }
    }
}

// MARK: - Harness

private actor SequenceRequestRecorder {
    private(set) var requests: [RunSequenceToolRequest] = []
    func record(_ request: RunSequenceToolRequest) { requests.append(request) }
}

private struct SequenceResponse {
    let raw: CallTool.Result
    let ok: Bool
    let result: SequenceResult?
    let error: ToolFailure?
}

extension MCPHarness {
    fileprivate func callRunSequence(_ arguments: [String: Value]) async throws -> SequenceResponse {
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: "run_sequence", arguments: arguments)
        let raw = try await context.value
        let structured = try #require(raw.structuredContent)
        let envelope = try JSONDecoder().decode(
            ToolEnvelope<SequenceResult>.self, from: try JSONEncoder().encode(structured))
        return SequenceResponse(
            raw: raw, ok: envelope.ok, result: envelope.result, error: envelope.error)
    }
}

private func withSequenceHarness(
    run: SequenceRun? = nil,
    _ body: (MCPHarness, SequenceRequestRecorder) async throws -> Void
) async throws {
    let recorder = SequenceRequestRecorder()
    let outcome = run ?? SequenceRun(
        result: SequenceResult(sessionId: nil, steps: [], frameCount: 0),
        frames: [],
        failure: nil)
    let services = try ToolHandlerServices(
        listSdks: {
            ListSdksResult(
                installed: [],
                active: SdkInfo(
                    version: SemVer("9.1.0")!, root: URL(fileURLWithPath: "/sdk/9.1.0"),
                    source: .installed))
        },
        listDevices: { _ in ListDevicesResult(devices: []) },
        build: { _ in throw unusedService() },
        simStart: { _ in throw unusedService() },
        simStop: { throw unusedService() },
        simStatus: { throw unusedService() },
        runApp: { _ in throw unusedService() },
        runTests: { _ in throw unusedService() },
        getLogs: { _ in throw unusedService() },
        doctor: { _ in throw unusedService() },
        runSequence: { request in
            await recorder.record(request)
            return outcome
        }
    ).qualification(profile: try InputProfileLoader.loadQualificationCandidate()) { _ in
        throw unusedService()
    }
    try await withMCPHarness(handlers: ToolHandlers.qualificationConfigured(services)) { harness in
        try await body(harness, recorder)
    }
}

private func unusedService() -> ToolError {
    ToolError(
        code: "internal_error", message: "service not used by this test",
        fix: "This handler test drives run_sequence only.")
}
