import Foundation
import MCP
import Testing

import SimulatorMCPCore

/// Validates that every declared result schema accepts real encoded
/// success and failure envelopes, using the minimal JSON Schema validator
/// at the bottom of this file. The validator supports exactly the subset
/// `Schemas` emits: type (single or array), enum, properties, required,
/// items.
@Suite("ToolSchema")
struct ToolSchemaTests {

    /// One representative, fully-populated success sample per public
    /// result model, paired with the schema its tool must declare.
    static let representatives:
        [(name: String, schema: Value, encode: @Sendable () throws -> CallTool.Result)] = [
        (
            "doctor", Schemas.doctorResult,
            {
                try ToolResultFactory.success(
                    DoctorResult(
                        executablePath: "/Users/x/.simulator-mcp/bin/simulator-mcp",
                        signatureKind: .stable,
                        signingIdentifier: "simulator-mcp-local",
                        teamIdentifier: nil,
                        cdhash: "abcdef0123456789",
                        sdkFound: true,
                        javaFound: true,
                        simulator: false,
                        screenRecording: PermissionStatus(
                            granted: true, prompted: false,
                            systemSettingsPath: Permissions.screenSettingsPath,
                            restartRequired: false),
                        accessibility: PermissionStatus(
                            granted: false, prompted: false,
                            systemSettingsPath: Permissions.accessibilitySettingsPath,
                            restartRequired: true),
                        responsibleProcessNote: nil,
                        checks: [
                            DoctorCheck(
                                name: "accessibility",
                                ok: false,
                                observed: "Accessibility permission is not granted.",
                                fix: "Open System Settings > Privacy & Security > Accessibility and enable simulator-mcp."
                            )
                        ]
                    ))
            }
        ),
        (
            "run_sequence", Schemas.runSequenceResult,
            {
                try ToolResultFactory.success(
                    SequenceResult(
                        sessionId: 7,
                        steps: [
                            SequenceStepOutcome(
                                index: 0, kind: "screenshot", status: "completed",
                                label: "initial", path: "/tmp/simulator-mcp/a.png",
                                width: 454, height: 454),
                            SequenceStepOutcome(
                                index: 1, kind: "press", status: "completed",
                                button: "enter", pressType: "hold", transport: "focused-keys"),
                            // A failed step reports no per-kind columns: the
                            // wait's elapsed time and line count ride in the
                            // failure's details instead.
                            SequenceStepOutcome(
                                index: 2, kind: "waitForLog", status: "failed"),
                            SequenceStepOutcome(index: 3, kind: "screenshot", status: "skipped",
                                                label: "menu"),
                        ],
                        frameCount: 1),
                    additionalContent: [
                        .image(
                            data: Data([0x89]).base64EncodedString(), mimeType: "image/png",
                            annotations: nil, _meta: nil)
                    ])
            }
        ),
        (
            "list_sdks", Schemas.listSdksResult,
            {
                try ToolResultFactory.success(
                    ListSdksResult(sdks: [
                        SdkSummary(
                            version: "9.1.0",
                            path: "/Users/x/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.0",
                            source: "current-sdk.cfg",
                            active: true
                        )
                    ]))
            }
        ),
        (
            "list_devices", Schemas.listDevicesResult,
            {
                try ToolResultFactory.success(
                    ListDevicesResult(devices: [
                        DeviceSummary(
                            deviceId: "fenix6xpro",
                            displayName: "fēnix 6X Pro",
                            touch: false,
                            buttons: ["up", "down", "select", "back", "light"],
                            inputSupported: true,
                            inputProfile: "fenix6xpro-five-button"
                        ),
                        DeviceSummary(
                            deviceId: "venu3",
                            displayName: "Venu 3",
                            touch: true,
                            buttons: [],
                            inputSupported: false,
                            inputProfile: nil
                        ),
                    ]))
            }
        ),
        (
            "build", Schemas.buildResult,
            {
                try ToolResultFactory.success(
                    BuildResult(
                        succeeded: false,
                        prgPath: nil,
                        rebuilt: false,
                        artifactKey: "9e2f1c",
                        sdk: "9.1.0",
                        device: "fenix6xpro",
                        mode: .debugApp,
                        diagnostics: [
                            Diagnostic(
                                file: "source/App.mc",
                                line: 12,
                                column: 5,
                                severity: "error",
                                message: "Undefined symbol ':frob'"
                            )
                        ]
                    ))
            }
        ),
        (
            "sim_start", Schemas.simStartResult,
            { try ToolResultFactory.success(SimStartResult(status: readyStatusSample)) }
        ),
        (
            "sim_stop", Schemas.simStopResult,
            {
                try ToolResultFactory.success(
                    SimStopResult(
                        status: SimStatusResult(
                            state: .notRunning,
                            operation: nil,
                            pid: nil,
                            executablePath: nil,
                            sdkPath: nil,
                            sdkVersion: nil,
                            currentDevice: nil,
                            leaseHolder: nil
                        )))
            }
        ),
        (
            "sim_status", Schemas.simStatusResult,
            { try ToolResultFactory.success(readyStatusSample) }
        ),
        (
            "run_app", Schemas.runAppResult,
            {
                try ToolResultFactory.success(
                    RunAppResult(
                        sessionId: 3,
                        device: "fenix6xpro",
                        prgPath: "/tmp/build/App-fenix6xpro.prg",
                        sdkPath: "/sdks/connectiq-sdk-mac-9.1.0",
                        sdkVersion: "9.1.0",
                        rebuilt: true
                    ))
            }
        ),
        (
            "run_tests", Schemas.runTestsResult,
            {
                try ToolResultFactory.success(
                    RunTestsResult(
                        passed: 5,
                        failed: 1,
                        errors: 0,
                        overallPassed: false,
                        perTest: [
                            TestCaseResult(
                                name: "testTimerRollover", status: "fail", duration: 0.25,
                                message: "expected 0, got 59"),
                            TestCaseResult(
                                name: "testBoot", status: "pass", duration: nil, message: nil),
                        ],
                        device: "fenix6xpro",
                        sdkPath: "/sdks/connectiq-sdk-mac-9.1.0",
                        prgPath: "/tmp/build/App-fenix6xpro-test.prg"
                    ))
            }
        ),
        (
            "get_logs", Schemas.getLogsResult,
            {
                try ToolResultFactory.success(
                    GetLogsResult(
                        sessionId: 3,
                        state: "ended",
                        terminationReason: "exit",
                        exitCode: 0,
                        crashDetected: false,
                        droppedLines: 0,
                        lines: [
                            LogLine(
                                seq: 1, monotonicNanos: 123_456_789, stream: .stdout,
                                text: "BOOT fixture-app", crash: false)
                        ],
                        nextToken: "eyJ2IjoxLCJzZXEiOjF9",
                        latestToken: "eyJ2IjoxLCJzZXEiOjF9"
                    ))
            }
        ),
        (
            "screenshot", Schemas.screenshotResult,
            {
                try ToolResultFactory.success(
                    ScreenshotResult(
                        path: "/Users/x/.simulator-mcp/screenshots/shot-1.png",
                        mimeType: "image/png",
                        width: 280,
                        height: 280,
                        capturedPid: 4242,
                        appDisplayRect: DisplayRect(x: 76, y: 141, width: 280, height: 280)
                    ))
            }
        ),
        (
            "press_button", Schemas.pressButtonResult,
            {
                try ToolResultFactory.success(
                    PressButtonResult(
                        button: "select",
                        pressType: "press",
                        transport: "protocol",
                        simulatorPid: 4242
                    ))
            }
        ),
        (
            "set_gps_position", Schemas.setGpsPositionResult,
            {
                try ToolResultFactory.success(
                    SetGpsPositionResult(latitude: 48.1351, longitude: 11.582, simulatorPid: 4242)
                )
            }
        ),
    ]

    static let readyStatusSample = SimStatusResult(
        state: .ready,
        operation: nil,
        pid: 4242,
        executablePath: "/sdks/connectiq-sdk-mac-9.1.0/bin/connectiq",
        sdkPath: "/sdks/connectiq-sdk-mac-9.1.0",
        sdkVersion: "9.1.0",
        currentDevice: "fenix6xpro",
        leaseHolder: nil
    )

    @Test(
        "every declared schema accepts its encoded success example",
        arguments: representatives.map(\.name))
    func testSchemaAcceptsSuccessExample(name: String) throws {
        let representative = try #require(
            Self.representatives.first(where: { $0.name == name }))
        let schema = try jsonValue(from: Schemas.envelopeSchema(result: representative.schema))
        let instance = try encodedEnvelope(from: representative.encode())

        let violations = SchemaValidator.violations(instance: instance, schema: schema)
        #expect(violations.isEmpty, "\(name): \(violations.joined(separator: "; "))")
    }

    @Test(
        "every declared schema accepts an encoded failure example",
        arguments: representatives.map(\.name))
    func testSchemaAcceptsFailureExample(name: String) throws {
        let representative = try #require(
            Self.representatives.first(where: { $0.name == name }))
        let schema = try jsonValue(from: Schemas.envelopeSchema(result: representative.schema))
        let failure = ToolResultFactory.failure(
            ToolError(
                code: "simulator_not_running",
                message: "The simulator is not running.",
                fix: "Run sim_start first.",
                details: ["state": "not_running"]
            ))
        let instance = try encodedEnvelope(from: failure)

        let violations = SchemaValidator.violations(instance: instance, schema: schema)
        #expect(violations.isEmpty, "\(name): \(violations.joined(separator: "; "))")
    }

    // MARK: - The validator itself must actually reject bad envelopes

    @Test("an error missing its fix is rejected")
    func testValidatorRejectsMissingFix() throws {
        let schema = try jsonValue(
            from: Schemas.envelopeSchema(result: Schemas.setGpsPositionResult))
        let instance: JSONValue = [
            "ok": false,
            "error": ["code": "internal_error", "message": "boom"],
        ]
        let violations = SchemaValidator.violations(instance: instance, schema: schema)
        #expect(!violations.isEmpty)
    }

    @Test("a success result missing a required field is rejected")
    func testValidatorRejectsMissingRequiredField() throws {
        let schema = try jsonValue(
            from: Schemas.envelopeSchema(result: Schemas.setGpsPositionResult))
        let instance: JSONValue = [
            "ok": true,
            "result": ["latitude": 48.1351, "longitude": 11.582],  // simulatorPid missing
        ]
        let violations = SchemaValidator.violations(instance: instance, schema: schema)
        #expect(!violations.isEmpty)
    }

    @Test("a type mismatch is rejected")
    func testValidatorRejectsTypeMismatch() throws {
        let schema = try jsonValue(
            from: Schemas.envelopeSchema(result: Schemas.setGpsPositionResult))
        let instance: JSONValue = [
            "ok": "yes",
            "result": ["latitude": 48.1351, "longitude": 11.582, "simulatorPid": 4242],
        ]
        let violations = SchemaValidator.violations(instance: instance, schema: schema)
        #expect(!violations.isEmpty)
    }

    @Test("a value outside a declared enum is rejected")
    func testValidatorRejectsUnknownEnumValue() throws {
        let schema = try jsonValue(from: Schemas.envelopeSchema(result: Schemas.simStatusResult))
        var status = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(Self.readyStatusSample))
        guard case .object(var fields) = status else {
            Issue.record("expected an object")
            return
        }
        fields["state"] = "warp_speed"
        status = .object(fields)
        let instance: JSONValue = .object(["ok": .bool(true), "result": status])

        let violations = SchemaValidator.violations(instance: instance, schema: schema)
        #expect(!violations.isEmpty)
    }

    // MARK: - Helpers

    /// The envelope exactly as a client sees it: the JSON text block of a
    /// factory-built result, decoded into a `JSONValue` tree.
    private func encodedEnvelope(from result: CallTool.Result) throws -> JSONValue {
        guard case .text(let json, _, _) = result.content.first else {
            throw ToolError(
                code: "internal_error",
                message: "expected a JSON text content block",
                fix: "Fix the test setup.")
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// Bridges an `MCP.Value` schema into the `JSONValue` tree the
    /// validator walks.
    private func jsonValue(from value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

/// Minimal JSON Schema validator covering exactly the subset `Schemas`
/// emits: `type` (string or array of strings), `enum`, `properties`,
/// `required`, and `items`. Returns human-readable violations; empty means
/// the instance conforms.
private enum SchemaValidator {
    static func violations(
        instance: JSONValue, schema: JSONValue, path: String = "$"
    ) -> [String] {
        guard case .object(let schemaFields) = schema else {
            return ["\(path): schema is not an object"]
        }
        var found: [String] = []

        if let typeField = schemaFields["type"] {
            let allowed = typeNames(from: typeField)
            if !allowed.contains(where: { matches(instance, typeName: $0) }) {
                found.append(
                    "\(path): expected type \(allowed.joined(separator: "|")), got \(describe(instance))"
                )
                return found
            }
            // A permitted null satisfies the schema; nothing below applies.
            if case .null = instance {
                return found
            }
        }

        if case .array(let allowedValues)? = schemaFields["enum"] {
            if !allowedValues.contains(instance) {
                found.append("\(path): value \(describe(instance)) is not in the declared enum")
            }
        }

        if case .array(let requiredNames)? = schemaFields["required"] {
            if case .object(let members) = instance {
                for case .string(let requiredName) in requiredNames
                where members[requiredName] == nil {
                    found.append("\(path): missing required member '\(requiredName)'")
                }
            }
        }

        if case .object(let propertySchemas)? = schemaFields["properties"],
            case .object(let members) = instance
        {
            for (memberName, memberValue) in members {
                if let propertySchema = propertySchemas[memberName] {
                    found += violations(
                        instance: memberValue, schema: propertySchema,
                        path: "\(path).\(memberName)")
                }
            }
        }

        if let itemSchema = schemaFields["items"], case .array(let elements) = instance {
            for (offset, element) in elements.enumerated() {
                found += violations(
                    instance: element, schema: itemSchema, path: "\(path)[\(offset)]")
            }
        }

        return found
    }

    private static func typeNames(from field: JSONValue) -> [String] {
        switch field {
        case .string(let single):
            return [single]
        case .array(let many):
            return many.compactMap {
                if case .string(let name) = $0 { return name }
                return nil
            }
        default:
            return []
        }
    }

    private static func matches(_ instance: JSONValue, typeName: String) -> Bool {
        switch (typeName, instance) {
        case ("null", .null): return true
        case ("boolean", .bool): return true
        case ("integer", .int): return true
        case ("number", .int), ("number", .double): return true
        case ("string", .string): return true
        case ("array", .array): return true
        case ("object", .object): return true
        default: return false
        }
    }

    private static func describe(_ instance: JSONValue) -> String {
        switch instance {
        case .null: return "null"
        case .bool(let value): return "boolean(\(value))"
        case .int(let value): return "integer(\(value))"
        case .double(let value): return "number(\(value))"
        case .string(let value): return "string(\"\(value)\")"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
