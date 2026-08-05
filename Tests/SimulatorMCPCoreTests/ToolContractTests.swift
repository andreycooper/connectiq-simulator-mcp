import Foundation
import MCP
import Testing

import SimulatorMCPCore

/// Exercises the typed MCP response contract (`ToolEnvelope`,
/// `ToolResultFactory`) and `ToolRegistry`'s error mapping.
@Suite("ToolContract")
struct ToolContractTests {

    // MARK: - ToolResultFactory

    @Test("success carries structuredContent and an identical JSON text block")
    func testSuccessEnvelope() async throws {
        let sample = PressButtonResult(
            button: "select",
            pressType: "press",
            transport: "protocol",
            simulatorPid: 4242
        )

        let result = try ToolResultFactory.success(sample)

        #expect(result.isError == false)

        // Exactly one content block: the JSON text fallback.
        #expect(result.content.count == 1)
        guard case .text(let json, _, _) = result.content.first else {
            Issue.record("expected first content block to be .text, got \(result.content)")
            return
        }

        // The text JSON decodes back to the same envelope.
        let decoded = try JSONDecoder().decode(
            ToolEnvelope<PressButtonResult>.self, from: Data(json.utf8))
        #expect(decoded.ok == true)
        #expect(decoded.result == sample)
        #expect(decoded.error == nil)

        // The JSON text is deterministic (sorted keys).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedJSON = String(
            decoding: try encoder.encode(ToolEnvelope(ok: true, result: sample, error: nil)),
            as: UTF8.self)
        #expect(json == expectedJSON)

        // structuredContent is the same envelope, converted to MCP.Value.
        let structured = try #require(result.structuredContent)
        let structuredJSON = String(decoding: try encoder.encode(structured), as: UTF8.self)
        #expect(structuredJSON == json)
    }

    @Test("failure carries isError=true and a structured non-empty fix")
    func testFailureEnvelope() async throws {
        let error = ToolError(
            code: "sdk_not_found",
            message: "No Connect IQ SDK is installed.",
            fix: "Install an SDK with the Connect IQ SDK Manager, then retry.",
            details: ["searchedPath": "/Users/x/Library/Application Support/Garmin/ConnectIQ"]
        )

        let result = ToolResultFactory.failure(error)

        #expect(result.isError == true)
        guard case .text(let json, _, _) = result.content.first else {
            Issue.record("expected first content block to be .text, got \(result.content)")
            return
        }

        let decoded = try JSONDecoder().decode(ToolEnvelope<JSONValue>.self, from: Data(json.utf8))
        #expect(decoded.ok == false)
        #expect(decoded.result == nil)
        let failure = try #require(decoded.error)
        #expect(failure.code == "sdk_not_found")
        #expect(!failure.message.isEmpty)
        #expect(!failure.fix.isEmpty)
        #expect(
            failure.details?["searchedPath"]
                == "/Users/x/Library/Application Support/Garmin/ConnectIQ")

        // structuredContent mirrors the text JSON exactly.
        let structured = try #require(result.structuredContent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let structuredJSON = String(decoding: try encoder.encode(structured), as: UTF8.self)
        #expect(structuredJSON == json)
    }

    @Test("screenshot success preserves image content after the JSON block")
    func testScreenshotSuccessKeepsImageContent() async throws {
        let sample = ScreenshotResult(
            path: "/Users/x/.simulator-mcp/screenshots/shot-1.png",
            mimeType: "image/png",
            width: 280,
            height: 280,
            capturedPid: 4242,
            appDisplayRect: DisplayRect(x: 76, y: 141, width: 280, height: 280)
        )
        let base64 = Data("not-really-a-png".utf8).base64EncodedString()

        let result = try ToolResultFactory.success(
            sample,
            additionalContent: [.image(data: base64, mimeType: "image/png", annotations: nil, _meta: nil)]
        )

        #expect(result.isError == false)
        #expect(result.content.count == 2)
        guard case .text = result.content[0] else {
            Issue.record("expected content[0] to be the JSON text block, got \(result.content[0])")
            return
        }
        guard case .image(let data, let mimeType, _, _) = result.content[1] else {
            Issue.record("expected content[1] to be the image block, got \(result.content[1])")
            return
        }
        #expect(data == base64)
        #expect(mimeType == "image/png")
    }

    // MARK: - ToolRegistry dispatch

    @Test("unknown tool becomes a stable invalid_arguments failure")
    func testUnknownToolBecomesInvalidArguments() async throws {
        let registry = ToolRegistry(handlers: [])
        let result = await registry.call(.init(name: "no_such_tool", arguments: nil))

        #expect(result.isError == true)
        let failure = try failureEnvelope(from: result)
        #expect(failure.code == "invalid_arguments")
        #expect(!failure.fix.isEmpty)
    }

    @Test("a handler's thrown ToolError keeps its stable code")
    func testHandlerToolErrorKeepsCode() async throws {
        let registry = ToolRegistry(handlers: [
            StubTool(name: "boom") { _ in
                throw ToolError(
                    code: "device_required",
                    message: "No device was given.",
                    fix: "Pass a deviceId from list_devices."
                )
            }
        ])
        let result = await registry.call(.init(name: "boom", arguments: nil))

        #expect(result.isError == true)
        let failure = try failureEnvelope(from: result)
        #expect(failure.code == "device_required")
        #expect(failure.fix == "Pass a deviceId from list_devices.")
    }

    @Test("a thrown raw NSError becomes internal_error and is logged to stderr")
    func testRawErrorBecomesInternalErrorAndIsLogged() async throws {
        let logLines = LineCollector()
        let registry = ToolRegistry(
            handlers: [
                StubTool(name: "boom") { _ in
                    throw NSError(
                        domain: "TestDomain", code: 99,
                        userInfo: [NSLocalizedDescriptionKey: "kaput"])
                }
            ],
            logSink: { logLines.append($0) }
        )
        let result = await registry.call(.init(name: "boom", arguments: nil))

        #expect(result.isError == true)
        let failure = try failureEnvelope(from: result)
        #expect(failure.code == "internal_error")
        #expect(failure.fix == "Run doctor, then retry. If it repeats, inspect the server stderr log.")

        // The raw error's type and localized description went to the log
        // sink (stderr in production), not into the public envelope.
        let logged = logLines.lines.joined(separator: "\n")
        #expect(logged.contains("NSError"))
        #expect(logged.contains("kaput"))
        #expect(!failure.message.contains("kaput"))
    }

    @Test("a handler's returned result passes through unchanged")
    func testHandlerSuccessPassesThrough() async throws {
        let sample = SetGpsPositionResult(latitude: 48.1351, longitude: 11.582, simulatorPid: 4242)
        let registry = ToolRegistry(handlers: [
            StubTool(name: "set_gps_position") { _ in
                try ToolResultFactory.success(sample)
            }
        ])
        let result = await registry.call(.init(name: "set_gps_position", arguments: nil))

        #expect(result.isError == false)
        guard case .text(let json, _, _) = result.content.first else {
            Issue.record("expected a JSON text block")
            return
        }
        let decoded = try JSONDecoder().decode(
            ToolEnvelope<SetGpsPositionResult>.self, from: Data(json.utf8))
        #expect(decoded.result == sample)
    }

    @Test("definitions are sorted by tool name regardless of registration order")
    func testDefinitionsSortedByName() async throws {
        let registry = ToolRegistry(handlers: [
            StubTool(name: "zeta") { _ in try ToolResultFactory.success(JSONValue.null) },
            StubTool(name: "alpha") { _ in try ToolResultFactory.success(JSONValue.null) },
            StubTool(name: "mid") { _ in try ToolResultFactory.success(JSONValue.null) },
        ])
        let names = await registry.definitions().map(\.name)
        #expect(names == ["alpha", "mid", "zeta"])
    }

    // MARK: - Duplicate-name precondition (subprocess)

    @Test(
        "duplicate tool names fail the construction precondition",
        .disabled(
            if: ProcessInfo.processInfo.environment[duplicateCrasherGate] == "1",
            "this test is the parent; the gated crasher below is the child"),
        .timeLimit(.minutes(2)))
    func testDuplicateToolNamesFailPrecondition() async throws {
        // Respawn this exact test process (swiftpm-testing-helper +
        // bundle), filtered down to the env-gated crasher test below. The
        // child must die by the precondition — not exit 0 (test passed,
        // i.e. no precondition fired) and not exit 1 (test failed).
        var arguments = CommandLine.arguments
        let executable = URL(fileURLWithPath: arguments.removeFirst())

        var respawnArguments: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--filter" || arguments[index] == "--skip" {
                index += 2
                continue
            }
            respawnArguments.append(arguments[index])
            index += 1
        }
        respawnArguments += ["--filter", "duplicateToolNamesCrash"]

        let environment = ProcessInfo.processInfo.environment
            .merging([duplicateCrasherGate: "1"]) { _, new in new }

        let process = try await Subprocess().start(
            executable: executable,
            arguments: respawnArguments,
            environment: environment,
            workingDirectory: nil,
            timeout: .seconds(60),
            onStdout: nil,
            onStderr: nil
        )
        let output = try await process.wait()

        let stderr = String(decoding: output.stderr, as: UTF8.self)
        #expect(
            output.exitCode != 0 && output.exitCode != 1,
            "expected the child to die by the precondition, got exit \(output.exitCode); stderr: \(stderr)"
        )
        #expect(stderr.contains("duplicate tool name"))
    }
}

private let duplicateCrasherGate = "SIMULATOR_MCP_RUN_DUPLICATE_CRASHER"

/// Only ever runs in the child process spawned by
/// `testDuplicateToolNamesFailPrecondition`; constructing the registry is
/// expected to kill this process via precondition failure.
@Suite("ToolRegistryDuplicateCrasher")
struct ToolRegistryDuplicateCrasher {
    @Test(
        "duplicateToolNamesCrash",
        .enabled(if: ProcessInfo.processInfo.environment[duplicateCrasherGate] == "1"))
    func duplicateToolNamesCrash() async throws {
        _ = ToolRegistry(handlers: [
            StubTool(name: "twin") { _ in try ToolResultFactory.success(JSONValue.null) },
            StubTool(name: "twin") { _ in try ToolResultFactory.success(JSONValue.null) },
        ])
        Issue.record("constructing a registry with duplicate tool names must not survive")
    }
}

// MARK: - Test doubles and helpers

struct StubTool: SimulatorTool {
    let definition: Tool
    private let handler: @Sendable ([String: Value]) async throws -> CallTool.Result

    init(
        name: String,
        handler: @escaping @Sendable ([String: Value]) async throws -> CallTool.Result
    ) {
        self.definition = Tool(
            name: name,
            description: "stub tool for tests",
            inputSchema: ["type": "object"],
            outputSchema: nil
        )
        self.handler = handler
    }

    func call(arguments: [String: Value]) async throws -> CallTool.Result {
        try await handler(arguments)
    }
}

/// Decodes the failure envelope out of a `CallTool.Result`'s JSON text block.
func failureEnvelope(from result: CallTool.Result) throws -> ToolFailure {
    guard case .text(let json, _, _) = result.content.first else {
        throw ToolError(
            code: "internal_error",
            message: "expected a JSON text content block, got \(result.content)",
            fix: "Fix the test setup.")
    }
    let envelope = try JSONDecoder().decode(ToolEnvelope<JSONValue>.self, from: Data(json.utf8))
    guard let failure = envelope.error else {
        throw ToolError(
            code: "internal_error",
            message: "expected a failure envelope, got ok=\(envelope.ok)",
            fix: "Fix the test setup.")
    }
    return failure
}

/// `@Sendable` line collector for injected log sinks (same pattern as
/// `ChunkCollector` in SubprocessTests).
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("ToolResultFactory failure content")
struct ToolFailureContentTests {
    private let frame = Tool.Content.image(
        data: Data([0x89, 0x50]).base64EncodedString(), mimeType: "image/png",
        annotations: nil, _meta: nil)

    @Test("a failure carries additional content after its envelope text")
    func failureCarriesContent() throws {
        let result = ToolResultFactory.failure(
            ToolError(
                code: "sequence_marker_timeout", message: "no marker", fix: "raise timeoutMs",
                details: ["failedStepIndex": .int(3)]),
            additionalContent: [frame])

        #expect(result.isError == true)
        #expect(result.content.count == 2)
        guard case .text = result.content.first else {
            Issue.record("the envelope text must come first")
            return
        }
        guard case .image = result.content.last else {
            Issue.record("additional content must follow it")
            return
        }
    }

    @Test("an omitted additionalContent leaves existing callers byte-identical")
    func defaultIsUnchanged() throws {
        let error = ToolError(code: "invalid_arguments", message: "bad", fix: "fix it")
        let plain = ToolResultFactory.failure(error)
        #expect(plain.content.count == 1)
        #expect(plain.isError == true)
        guard case .text(let text, _, _) = plain.content.first else {
            Issue.record("expected one text block")
            return
        }
        #expect(text.contains("invalid_arguments"))
        #expect(!text.contains("details"))
    }

    /// The stripped-retry branch exists because arbitrary `details` might not
    /// encode. `failedStepIndex` is a plain integer that cannot be the member
    /// that failed, so a partial run must not lose which step it was.
    @Test("the details-stripped retry still names the failed step")
    func strippedRetryRetainsStepIndex() throws {
        // A non-finite double cannot be represented in JSON, so encoding the
        // full details fails and the retry path runs.
        let result = ToolResultFactory.failure(
            ToolError(
                code: "sequence_app_exited", message: "app exited", fix: "run the app again",
                details: [
                    "failedStepIndex": .int(2),
                    "unencodable": .double(.infinity),
                ]),
            additionalContent: [frame])

        #expect(result.isError == true)
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected an envelope text block")
            return
        }
        #expect(text.contains("sequence_app_exited"))
        #expect(text.contains("failedStepIndex"))
        #expect(!text.contains("unencodable"))
        // Content still rides along on the retry path.
        #expect(result.content.count == 2)
    }
}
