import Foundation
import MCP
import Testing

import SimulatorMCPCore

@Suite("PublicToolHandler", .serialized)
struct PublicToolHandlerTests {
    @Test("tool list exposes the implemented names and strict schemas")
    func toolList() async throws {
        let recorder = ServiceRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            let tools = try await harness.listTools()
            #expect(tools.map(\.name) == [
                "build", "doctor", "get_logs", "list_devices", "list_sdks", "run_app", "run_tests",
                "screenshot", "set_gps_position", "sim_start", "sim_status", "sim_stop",
            ])
            for tool in tools {
                #expect(tool.outputSchema != nil)
                guard case .object(let input) = tool.inputSchema else {
                    Issue.record("\(tool.name) input schema is not an object")
                    continue
                }
                #expect(input["additionalProperties"] == false)
            }
            #expect(requiredFields(of: tools, named: "build") == ["projectPath"])
            #expect(requiredFields(of: tools, named: "run_app") == ["projectPath"])
            #expect(requiredFields(of: tools, named: "run_tests") == ["projectPath"])
            #expect(requiredFields(of: tools, named: "list_sdks") == [])
            #expect(requiredFields(of: tools, named: "sim_stop") == [])
            #expect(requiredFields(of: tools, named: "sim_status") == [])

            let expected: [String: [String: FieldSchema]] = [
                "build": [
                    "projectPath": .string, "device": .string, "sdk": .string,
                    "jungle": .string, "developerKey": .string,
                    "release": .boolean(default: false),
                    "unitTests": .boolean(default: false),
                ],
                "doctor": ["requestPermissions": .boolean(default: false)],
                "get_logs": [
                    "sessionId": .integer(default: nil), "sinceToken": .string,
                    "limit": .integer(default: 500),
                ],
                "list_devices": ["projectPath": .string, "jungle": .string, "sdk": .string],
                "list_sdks": [:],
                "run_app": [
                    "projectPath": .string, "device": .string, "sdk": .string,
                    "jungle": .string, "developerKey": .string,
                    "rebuild": .boolean(default: true),
                ],
                "run_tests": [
                    "projectPath": .string, "device": .string, "sdk": .string,
                    "jungle": .string, "developerKey": .string, "testFilter": .string,
                ],
                "screenshot": ["savePath": .string],
                "set_gps_position": ["lat": .number, "lon": .number],
                "sim_start": ["sdk": .string],
                "sim_status": [:], "sim_stop": [:],
            ]
            for tool in tools {
                #expect(fieldSchemas(of: tool) == expected[tool.name])
            }
        }
    }

    @Test("every implemented success has typed structuredContent and identical JSON fallback")
    func successEnvelopes() async throws {
        let recorder = ServiceRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            try await assertSuccess(harness, "doctor", as: DoctorResult.self)
            try await assertSuccess(harness, "list_sdks", as: ListSdksResult.self)
            try await assertSuccess(harness, "list_devices", as: ListDevicesResult.self)
            try await assertSuccess(harness, "build", ["projectPath": "/tmp/project"], as: BuildResult.self)
            try await assertSuccess(harness, "sim_start", as: SimStartResult.self)
            try await assertSuccess(harness, "sim_stop", as: SimStopResult.self)
            try await assertSuccess(harness, "sim_status", as: SimStatusResult.self)
            let status = try await harness.call("sim_status", as: SimStatusResult.self)
            #expect(status.envelope.result?.currentDevice == "fenix6xpro")
            #expect(status.envelope.result?.leaseHolder == "pid=9 operation=run_tests")
            try await assertSuccess(harness, "run_app", ["projectPath": "/tmp/project"], as: RunAppResult.self)
            let tests = try await harness.call(
                "run_tests", arguments: ["projectPath": "/tmp/project"], as: RunTestsResult.self)
            #expect(tests.envelope.result?.perTest.count == 2)
            let logs = try await harness.call("get_logs", as: GetLogsResult.self)
            #expect(logs.envelope.result?.lines.isEmpty == true)
            #expect(logs.envelope.result?.crashDetected == true)
            let screenshot = try await harness.call("screenshot", as: ScreenshotResult.self)
            #expect(screenshot.raw.content.count == 2)
            try await assertSuccess(
                harness, "set_gps_position", ["lat": 48.1351, "lon": 11.582],
                as: SetGpsPositionResult.self)
        }
    }

    @Test("unknown fields and wrong types fail before any service call")
    func strictArguments() async throws {
        let recorder = ServiceRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            for arguments: [String: Value] in [
                ["projectPath": "/tmp/p", "typo": true],
                ["projectPath": 7],
            ] {
                let response = try await harness.call("build", arguments: arguments, as: JSONValue.self)
                #expect(response.raw.isError == true)
                #expect(response.envelope.error?.code == "invalid_arguments")
                #expect(response.envelope.error?.fix.isEmpty == false)
            }
            #expect(await recorder.calls.isEmpty)
        }
    }

    @Test("sim_start takes only an optional sdk and rejects the withdrawn activate field")
    func simStartArguments() async throws {
        let recorder = ServiceRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            _ = try await harness.call("sim_start", as: SimStartResult.self)

            // The activated-start route failed its gate and was withdrawn.
            // press_button performs its own activation, so sim_start must not
            // advertise or accept it.
            let activate = try await harness.call(
                "sim_start", arguments: ["activate": true], as: JSONValue.self)
            #expect(activate.raw.isError == true)
            #expect(activate.envelope.error?.code == "invalid_arguments")

            let unknown = try await harness.call(
                "sim_start", arguments: ["unexpected": true], as: JSONValue.self)
            #expect(unknown.raw.isError == true)
            #expect(unknown.envelope.error?.code == "invalid_arguments")

            #expect(await recorder.simStartRequests == [.init(sdk: nil)])
        }
    }

    @Test("paths are tilde-expanded/canonicalized and jungle/key/sdk overrides flow once")
    func overridesAndPaths() async throws {
        let recorder = ServiceRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            _ = try await harness.call("build", arguments: [
                "projectPath": "~/project/../app",
                "jungle": "~/config/../app.jungle",
                "developerKey": "~/keys/../developer.der",
                "sdk": "~/sdk/../sdk-9.1.0",
                "device": "fenix6xpro",
                "release": true,
            ], as: BuildResult.self)
            let request = try #require(await recorder.buildRequests.first)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            #expect(request.projectPath == home + "/app")
            #expect(request.jungle == home + "/app.jungle")
            #expect(request.developerKey == home + "/developer.der")
            #expect(request.sdk == home + "/sdk-9.1.0")
            #expect(request.mode == .releaseApp)
            #expect(request.force == true)
        }
    }

    @Test("release plus unitTests is rejected before compiler service")
    func conflictingBuildMode() async throws {
        let recorder = ServiceRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            let response = try await harness.call("build", arguments: [
                "projectPath": "/tmp/project", "release": true, "unitTests": true,
            ], as: JSONValue.self)
            #expect(response.raw.isError == true)
            #expect(response.envelope.error?.code == "invalid_arguments")
            #expect(await recorder.buildRequests.isEmpty)
        }
    }

    @Test("defaults and delegation contracts cross the public MCP boundary exactly once")
    func delegation() async throws {
        let recorder = ServiceRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            _ = try await harness.call("list_devices", arguments: [
                "projectPath": "/tmp/project", "jungle": "/tmp/custom.jungle",
                "sdk": "/tmp/sdk",
            ], as: ListDevicesResult.self)
            _ = try await harness.call("run_app", arguments: [
                "projectPath": "/tmp/project", "rebuild": false,
            ], as: RunAppResult.self)
            _ = try await harness.call("run_tests", arguments: [
                "projectPath": "/tmp/project", "testFilter": "Example.test",
            ], as: RunTestsResult.self)
            _ = try await harness.call("get_logs", as: GetLogsResult.self)

            #expect(await recorder.listDeviceRequests.count == 1)
            #expect(await recorder.listDeviceRequests.first?.jungle == "/tmp/custom.jungle")
            #expect(await recorder.runAppRequests == [
                .init(projectPath: "/tmp/project", device: nil, sdk: nil, jungle: nil,
                      developerKey: nil, rebuild: false)
            ])
            #expect(await recorder.runTestsRequests.first?.testFilter == "Example.test")
            #expect(await recorder.logRequests == [.init(sessionId: nil, sinceToken: nil, limit: 500)])
        }
    }

    @Test("representative service failures are actionable and no handler writes stdout")
    func failureAndStdout() async throws {
        let recorder = ServiceRecorder(failure: ToolError(
            code: "sdk_mismatch", message: "Wrong simulator SDK.",
            fix: "Call sim_stop, then sim_start with the requested SDK."))
        let captured = try await captureStdout {
            try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
                let response = try await harness.call("run_app", arguments: [
                    "projectPath": "/tmp/project",
                ], as: JSONValue.self)
                #expect(response.raw.isError == true)
                #expect(response.envelope.error?.code == "sdk_mismatch")
                #expect(response.envelope.error?.fix.isEmpty == false)
            }
        }
        #expect(captured.isEmpty)
        #expect(await recorder.runAppRequests.count == 1)
    }

    @Test("SDK mismatch is returned before the monkeydo coordinator boundary")
    func sdkMismatchStopsBeforeMonkeydo() async throws {
        let boundary = MismatchBoundary()
        try await withMCPHarness(handlers: ToolHandlers.configured(boundary.services)) { harness in
            let response = try await harness.call("run_app", arguments: [
                "projectPath": "/tmp/project", "sdk": "/requested-sdk",
            ], as: JSONValue.self)
            #expect(response.raw.isError == true)
            #expect(response.envelope.error?.code == "sdk_mismatch")
            #expect(await boundary.serviceCalls == 1)
            #expect(await boundary.monkeydoCalls == 0)
        }
    }

    @Test("list_sdks includes an active SDK outside the installed inventory root")
    func activeExternalSDKIsIncluded() throws {
        let installed = SdkInfo(
            version: SemVer(major: 8, minor: 4, patch: 1),
            root: URL(fileURLWithPath: "/installed/sdk-8.4.1"), source: .installed)
        let active = SdkInfo(
            version: SemVer(major: 9, minor: 1, patch: 0),
            root: URL(fileURLWithPath: "/external/sdk-9.1.0"), source: .environment)
        let duplicate = SdkInfo(
            version: installed.version, root: installed.root, source: .installed)
        let result = ListSdksResult(installed: [installed, duplicate], active: active)
        #expect(result.sdks.count == 2)
        #expect(result.sdks.filter(\.active).map(\.path) == ["/external/sdk-9.1.0"])
        #expect(result.sdks.first(where: \.active)?.source == "env")
    }
}

private enum FieldSchema: Equatable {
    case string
    case number
    case boolean(default: Bool?)
    case integer(default: Int?)
}

private func fieldSchemas(of tool: Tool) -> [String: FieldSchema] {
    guard case .object(let schema) = tool.inputSchema,
          case .object(let properties)? = schema["properties"] else { return [:] }
    return properties.reduce(into: [:]) { result, pair in
        guard case .object(let fields) = pair.value,
              case .string(let type)? = fields["type"] else { return }
        switch type {
        case "string": result[pair.key] = .string
        case "number": result[pair.key] = .number
        case "boolean": result[pair.key] = .boolean(default: fields["default"]?.boolValue)
        case "integer": result[pair.key] = .integer(default: fields["default"]?.intValue)
        default: break
        }
    }
}

private func requiredFields(of tools: [Tool], named name: String) -> [String] {
    guard let tool = tools.first(where: { $0.name == name }),
          case .object(let schema) = tool.inputSchema,
          case .array(let values)? = schema["required"]
    else { return [] }
    return values.compactMap(\.stringValue).sorted()
}

private func assertSuccess<Result: Codable & Sendable>(
    _ harness: MCPHarness, _ name: String,
    _ arguments: [String: Value]? = nil, as: Result.Type
) async throws {
    let response = try await harness.call(name, arguments: arguments, as: Result.self)
    #expect(response.raw.isError == false)
    #expect(response.envelope.ok == true)
    #expect(response.envelope.result != nil)
    guard case .text(let text, _, _) = response.raw.content.first,
          let structured = response.raw.structuredContent
    else {
        Issue.record("\(name) did not return JSON text plus structuredContent")
        return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(text == String(decoding: try encoder.encode(structured), as: UTF8.self))
}

private actor ServiceRecorder {
    private(set) var calls: [String] = []
    private(set) var listDeviceRequests: [ListDevicesToolRequest] = []
    private(set) var buildRequests: [BuildToolRequest] = []
    private(set) var simStartRequests: [SimStartToolRequest] = []
    private(set) var runAppRequests: [RunAppToolRequest] = []
    private(set) var runTestsRequests: [RunTestsToolRequest] = []
    private(set) var logRequests: [GetLogsToolRequest] = []
    private let failure: ToolError?

    init(failure: ToolError? = nil) { self.failure = failure }

    nonisolated var services: ToolHandlerServices {
        ToolHandlerServices(
            listSdks: { try await self.record("list_sdks", value: Samples.sdks) },
            listDevices: { request in
                await self.append(request)
                return try await self.record("list_devices", value: Samples.devices)
            },
            build: { request in
                await self.append(request)
                return try await self.record("build", value: Samples.build)
            },
            simStart: { request in
                await self.append(request)
                return try await self.record("sim_start", value: SimStartResult(status: Samples.status))
            },
            simStop: { try await self.record("sim_stop", value: SimStopResult(status: Samples.stopped)) },
            simStatus: { try await self.record("sim_status", value: Samples.status) },
            runApp: { request in
                await self.append(request)
                return try await self.record("run_app", value: Samples.app)
            },
            runTests: { request in
                await self.append(request)
                return try await self.record("run_tests", value: Samples.tests)
            },
            getLogs: { request in
                await self.append(request)
                return try await self.record("get_logs", value: Samples.logs)
            },
            doctor: { _ in try await self.record("doctor", value: Samples.doctor) },
            screenshot: { _ in try await self.record(
                "screenshot", value: ScreenshotOutput(result: Samples.screenshot, png: Samples.png)) },
            setGpsPosition: { _ in try await self.record(
                "set_gps_position", value: Samples.gps) })
    }

    private func append(_ request: ListDevicesToolRequest) { listDeviceRequests.append(request) }
    private func append(_ request: BuildToolRequest) { buildRequests.append(request) }
    private func append(_ request: SimStartToolRequest) { simStartRequests.append(request) }
    private func append(_ request: RunAppToolRequest) { runAppRequests.append(request) }
    private func append(_ request: RunTestsToolRequest) { runTestsRequests.append(request) }
    private func append(_ request: GetLogsToolRequest) { logRequests.append(request) }

    private func record<T>(_ name: String, value: T) throws -> T {
        calls.append(name)
        if let failure { throw failure }
        return value
    }
}

private actor MismatchBoundary {
    private(set) var serviceCalls = 0
    private(set) var monkeydoCalls = 0

    nonisolated var services: ToolHandlerServices {
        let normal = ServiceRecorder().services
        return ToolHandlerServices(
            listSdks: normal.listSdks, listDevices: normal.listDevices, build: normal.build,
            simStart: normal.simStart, simStop: normal.simStop, simStatus: normal.simStatus,
            runApp: { request in try await self.runApp(request) },
            runTests: normal.runTests, getLogs: normal.getLogs, doctor: normal.doctor)
    }

    private func runApp(_ request: RunAppToolRequest) throws -> RunAppResult {
        serviceCalls += 1
        guard request.sdk == "/running-sdk" else {
            throw ToolError(
                code: "sdk_mismatch", message: "Requested SDK does not own the running simulator.",
                fix: "Call sim_stop, then sim_start with the requested SDK.")
        }
        monkeydoCalls += 1
        return Samples.app
    }
}

private enum Samples {
    static let doctor = DoctorResult(
        executablePath: "/installed/simulator-mcp", signatureKind: .stable,
        signingIdentifier: "simulator-mcp-local", teamIdentifier: nil, cdhash: "abcd",
        sdkFound: true, javaFound: true, simulator: true,
        screenRecording: .init(
            granted: true, prompted: false,
            systemSettingsPath: Permissions.screenSettingsPath, restartRequired: false),
        accessibility: .init(
            granted: true, prompted: false,
            systemSettingsPath: Permissions.accessibilitySettingsPath, restartRequired: false),
        responsibleProcessNote: "TCC may use the responsible host.",
        checks: [.init(name: "signature", ok: true, observed: "kind=stable", fix: nil)])
    static let sdks = ListSdksResult(sdks: [.init(version: "9.1.0", path: "/sdk", source: "explicit", active: true)])
    static let devices = ListDevicesResult(devices: [.init(
        deviceId: "fenix6xpro", displayName: "fenix 6X Pro", touch: false,
        buttons: [], inputSupported: false, inputProfile: nil)])
    static let build = BuildResult(
        succeeded: true, prgPath: "/tmp/app.prg", rebuilt: true, artifactKey: "key",
        sdk: "/sdk", device: "fenix6xpro", mode: .debugApp, diagnostics: [])
    static let status = SimStatusResult(
        state: .ready, operation: nil, pid: 42, executablePath: "/sdk/simulator",
        sdkPath: "/sdk", sdkVersion: "9.1.0", currentDevice: "fenix6xpro",
        leaseHolder: "pid=9 operation=run_tests")
    static let stopped = SimStatusResult(
        state: .notRunning, operation: nil, pid: nil, executablePath: nil, sdkPath: nil,
        sdkVersion: nil, currentDevice: nil, leaseHolder: nil)
    static let app = RunAppResult(
        sessionId: 1, device: "fenix6xpro", prgPath: "/tmp/app.prg", sdkPath: "/sdk",
        sdkVersion: "9.1.0", rebuilt: true)
    static let tests = RunTestsResult(
        passed: 2, failed: 0, errors: 0, overallPassed: true,
        perTest: [
            .init(name: "one", status: "passed", duration: 0.1, message: nil),
            .init(name: "two", status: "passed", duration: nil, message: nil),
        ], device: "fenix6xpro", sdkPath: "/sdk", prgPath: "/tmp/app-test.prg")
    static let logs = GetLogsResult(
        sessionId: 1, state: "exited", terminationReason: "crash_detected", exitCode: 1,
        crashDetected: true, droppedLines: 0, lines: [], nextToken: "token")
    static let png = Data("png".utf8)
    static let screenshot = ScreenshotResult(
        path: "/tmp/shot.png", mimeType: "image/png", width: 10, height: 20,
        capturedPid: 42, appDisplayRect: nil)
    static let gps = SetGpsPositionResult(
        latitude: 48.1351, longitude: 11.582, simulatorPid: 42)
}
