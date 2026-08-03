import Foundation
import MCP

// MARK: - Decoded service requests

public struct ListDevicesToolRequest: Equatable, Sendable {
    public let projectPath: String?
    public let jungle: String?
    public let sdk: String?
    public init(projectPath: String?, jungle: String?, sdk: String?) {
        self.projectPath = projectPath; self.jungle = jungle; self.sdk = sdk
    }
}

public struct BuildToolRequest: Equatable, Sendable {
    public let projectPath: String
    public let device: String?
    public let sdk: String?
    public let jungle: String?
    public let developerKey: String?
    public let mode: BuildMode
    public let force: Bool
    public init(projectPath: String, device: String?, sdk: String?, jungle: String?,
                developerKey: String?, mode: BuildMode, force: Bool) {
        self.projectPath = projectPath; self.device = device; self.sdk = sdk
        self.jungle = jungle; self.developerKey = developerKey; self.mode = mode
        self.force = force
    }
}

public struct SimStartToolRequest: Equatable, Sendable {
    public let sdk: String?
    public init(sdk: String?) {
        self.sdk = sdk
    }
}

public struct RunAppToolRequest: Equatable, Sendable {
    public let projectPath: String
    public let device: String?
    public let sdk: String?
    public let jungle: String?
    public let developerKey: String?
    public let rebuild: Bool
    public init(projectPath: String, device: String?, sdk: String?, jungle: String?,
                developerKey: String?, rebuild: Bool) {
        self.projectPath = projectPath; self.device = device; self.sdk = sdk
        self.jungle = jungle; self.developerKey = developerKey; self.rebuild = rebuild
    }
}

public struct RunTestsToolRequest: Equatable, Sendable {
    public let projectPath: String
    public let device: String?
    public let sdk: String?
    public let jungle: String?
    public let developerKey: String?
    public let testFilter: String?
    public init(projectPath: String, device: String?, sdk: String?, jungle: String?,
                developerKey: String?, testFilter: String?) {
        self.projectPath = projectPath; self.device = device; self.sdk = sdk
        self.jungle = jungle; self.developerKey = developerKey; self.testFilter = testFilter
    }
}

public struct GetLogsToolRequest: Equatable, Sendable {
    public let sessionId: UInt64?
    public let sinceToken: String?
    public let limit: Int
    public init(sessionId: UInt64?, sinceToken: String?, limit: Int) {
        self.sessionId = sessionId; self.sinceToken = sinceToken; self.limit = limit
    }
}

public struct DoctorToolRequest: Equatable, Sendable {
    public let requestPermissions: Bool
    public init(requestPermissions: Bool) { self.requestPermissions = requestPermissions }
}

public struct ScreenshotToolRequest: Equatable, Sendable {
    public let savePath: String?
    public init(savePath: String?) { self.savePath = savePath }
}

public struct SetGpsPositionToolRequest: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One high-level service per public handler. This seam preserves the handler
/// boundary (decode -> one service -> envelope) and lets public MCP tests
/// observe arguments without bypassing Client/Server/ToolRegistry.
public struct ToolHandlerServices: Sendable {
    public let listSdks: @Sendable () async throws -> ListSdksResult
    public let listDevices: @Sendable (ListDevicesToolRequest) async throws -> ListDevicesResult
    public let build: @Sendable (BuildToolRequest) async throws -> BuildResult
    public let simStart: @Sendable (SimStartToolRequest) async throws -> SimStartResult
    public let simStop: @Sendable () async throws -> SimStopResult
    public let simStatus: @Sendable () async throws -> SimStatusResult
    public let runApp: @Sendable (RunAppToolRequest) async throws -> RunAppResult
    public let runTests: @Sendable (RunTestsToolRequest) async throws -> RunTestsResult
    public let getLogs: @Sendable (GetLogsToolRequest) async throws -> GetLogsResult
    public let doctor: @Sendable (DoctorToolRequest) async throws -> DoctorResult
    public let screenshot: @Sendable (ScreenshotToolRequest) async throws -> ScreenshotOutput
    public let setGpsPosition: @Sendable (SetGpsPositionToolRequest) async throws -> SetGpsPositionResult
    public let pressButton: @Sendable (PressButtonToolRequest) async throws -> PressButtonResult

    public init(
        listSdks: @escaping @Sendable () async throws -> ListSdksResult,
        listDevices: @escaping @Sendable (ListDevicesToolRequest) async throws -> ListDevicesResult,
        build: @escaping @Sendable (BuildToolRequest) async throws -> BuildResult,
        simStart: @escaping @Sendable (SimStartToolRequest) async throws -> SimStartResult,
        simStop: @escaping @Sendable () async throws -> SimStopResult,
        simStatus: @escaping @Sendable () async throws -> SimStatusResult,
        runApp: @escaping @Sendable (RunAppToolRequest) async throws -> RunAppResult,
        runTests: @escaping @Sendable (RunTestsToolRequest) async throws -> RunTestsResult,
        getLogs: @escaping @Sendable (GetLogsToolRequest) async throws -> GetLogsResult,
        doctor: @escaping @Sendable (DoctorToolRequest) async throws -> DoctorResult,
        screenshot: @escaping @Sendable (ScreenshotToolRequest) async throws -> ScreenshotOutput = {
            _ in throw ToolError(
                code: "environment_missing",
                message: "Screenshot service is not configured.",
                fix: "Use the live server composition, then retry screenshot.")
        },
        setGpsPosition: @escaping @Sendable (SetGpsPositionToolRequest) async throws -> SetGpsPositionResult = {
            _ in throw ToolError(
                code: "environment_missing",
                message: "GPS automation service is not configured.",
                fix: "Use the live server composition, then retry set_gps_position.")
        },
        pressButton: @escaping @Sendable (PressButtonToolRequest) async throws -> PressButtonResult = {
            _ in throw ToolError(
                code: "input_unsupported",
                message: "Button qualification service is not configured.",
                fix: "Use the qualification candidate composition.")
        }
    ) {
        self.listSdks = listSdks; self.listDevices = listDevices; self.build = build
        self.simStart = simStart; self.simStop = simStop; self.simStatus = simStatus
        self.runApp = runApp; self.runTests = runTests; self.getLogs = getLogs
        self.doctor = doctor
        self.screenshot = screenshot
        self.setGpsPosition = setGpsPosition
        self.pressButton = pressButton
    }

    /// Returns a copy whose extra service remains private to candidate wiring.
    public func qualification(
        profile: QualifiedInputProfile? = nil,
        pressButton: @escaping @Sendable (PressButtonToolRequest) async throws -> PressButtonResult
    ) throws -> ToolHandlerServices {
        let qualified = try profile ?? InputProfileLoader.loadQualificationCandidate()
        let service = QualificationButtonService(profile: qualified, dispatch: pressButton)
        return ToolHandlerServices(
            listSdks: listSdks, listDevices: listDevices, build: build, simStart: simStart,
            simStop: simStop, simStatus: simStatus, runApp: runApp, runTests: runTests,
            getLogs: getLogs, doctor: doctor, screenshot: screenshot,
            setGpsPosition: setGpsPosition, pressButton: { try await service.press($0) })
    }
}

public enum ToolHandlers {
    /// The complete Task 11 surface. Later tasks append doctor and automation
    /// tools only after their services and evidence gates exist.
    public static func live() throws -> [any SimulatorTool] {
        qualificationConfigured(try ToolHandlerServices.live())
    }

    /// Private candidate composition. Profile loading is throwing so a missing
    /// or invalid adjacent resource bundle aborts startup rather than silently
    /// falling back to the immutable v1 surface.
    public static func qualificationCandidate() throws -> [any SimulatorTool] {
        qualificationConfigured(try ToolHandlerServices.qualificationCandidate())
    }

    public static func qualificationConfigured(_ services: ToolHandlerServices) -> [any SimulatorTool] {
        configured(services) + [
            tool(name: "press_button", description: "Press a verified simulator hardware button. With allowFocus=true, this visibly brings Garmin Simulator forward and leaves it frontmost.",
                 input: InputSchemas.pressButton, output: Schemas.pressButtonResult) { arguments in
                var decoder = try Arguments(arguments, allowed: ["button", "holdMs", "allowFocus"])
                let request = PressButtonToolRequest(
                    button: try decoder.requiredString("button"),
                    holdMs: try decoder.optionalInteger("holdMs"),
                    allowFocus: try decoder.boolean("allowFocus", default: false))
                if let hold = request.holdMs, !(50...5000).contains(hold) {
                    throw ToolError(
                        code: "invalid_arguments",
                        message: "holdMs must be between 50 and 5000 milliseconds.",
                        fix: "Omit holdMs for a press or pass a value from 50 through 5000.")
                }
                return try ToolResultFactory.success(try await services.pressButton(request))
            },
        ]
    }

    public static func configured(_ services: ToolHandlerServices) -> [any SimulatorTool] {
        [
            tool(name: "doctor", description: "Diagnose SDK, Java, simulator, signing, and TCC readiness.",
                 input: InputSchemas.doctor, output: Schemas.doctorResult) { arguments in
                var decoder = try Arguments(arguments, allowed: ["requestPermissions"])
                let request = DoctorToolRequest(
                    requestPermissions: try decoder.boolean("requestPermissions", default: false))
                return try ToolResultFactory.success(try await services.doctor(request))
            },
            tool(name: "build", description: "Compile a Connect IQ project.",
                 input: InputSchemas.build, output: Schemas.buildResult) { arguments in
                var decoder = try Arguments(arguments, allowed: [
                    "projectPath", "device", "sdk", "jungle", "developerKey", "release", "unitTests",
                ])
                let mode = try BuildMode(
                    release: decoder.boolean("release", default: false),
                    unitTests: decoder.boolean("unitTests", default: false))
                let request = BuildToolRequest(
                    projectPath: try decoder.requiredPath("projectPath"),
                    device: try decoder.string("device"), sdk: try decoder.path("sdk"),
                    jungle: try decoder.path("jungle"),
                    developerKey: try decoder.path("developerKey"), mode: mode, force: true)
                return try ToolResultFactory.success(try await services.build(request))
            },
            tool(name: "get_logs", description: "Read buffered app-session logs.",
                 input: InputSchemas.getLogs, output: Schemas.getLogsResult) { arguments in
                var decoder = try Arguments(arguments, allowed: ["sessionId", "sinceToken", "limit"])
                let request = GetLogsToolRequest(
                    sessionId: try decoder.unsigned("sessionId"),
                    sinceToken: try decoder.string("sinceToken"),
                    limit: try decoder.integer("limit", default: 500))
                return try ToolResultFactory.success(try await services.getLogs(request))
            },
            tool(name: "list_devices", description: "List installed Connect IQ device profiles.",
                 input: InputSchemas.listDevices, output: Schemas.listDevicesResult) { arguments in
                var decoder = try Arguments(arguments, allowed: ["projectPath", "jungle", "sdk"])
                let request = ListDevicesToolRequest(
                    projectPath: try decoder.path("projectPath"),
                    jungle: try decoder.path("jungle"), sdk: try decoder.path("sdk"))
                return try ToolResultFactory.success(try await services.listDevices(request))
            },
            tool(name: "list_sdks", description: "List installed Connect IQ SDKs.",
                 input: InputSchemas.none, output: Schemas.listSdksResult) { arguments in
                _ = try Arguments(arguments, allowed: [])
                return try ToolResultFactory.success(try await services.listSdks())
            },
            tool(name: "run_app", description: "Build and launch a Connect IQ app.",
                 input: InputSchemas.runApp, output: Schemas.runAppResult) { arguments in
                var decoder = try Arguments(arguments, allowed: [
                    "projectPath", "device", "sdk", "jungle", "developerKey", "rebuild",
                ])
                let request = RunAppToolRequest(
                    projectPath: try decoder.requiredPath("projectPath"),
                    device: try decoder.string("device"), sdk: try decoder.path("sdk"),
                    jungle: try decoder.path("jungle"), developerKey: try decoder.path("developerKey"),
                    rebuild: try decoder.boolean("rebuild", default: true))
                return try ToolResultFactory.success(try await services.runApp(request))
            },
            tool(name: "run_tests", description: "Build and run Connect IQ unit tests.",
                 input: InputSchemas.runTests, output: Schemas.runTestsResult) { arguments in
                var decoder = try Arguments(arguments, allowed: [
                    "projectPath", "device", "sdk", "jungle", "developerKey", "testFilter",
                ])
                let request = RunTestsToolRequest(
                    projectPath: try decoder.requiredPath("projectPath"),
                    device: try decoder.string("device"), sdk: try decoder.path("sdk"),
                    jungle: try decoder.path("jungle"), developerKey: try decoder.path("developerKey"),
                    testFilter: try decoder.string("testFilter"))
                return try ToolResultFactory.success(try await services.runTests(request))
            },
            tool(name: "screenshot", description: "Capture the current Connect IQ simulator window as PNG.",
                 input: InputSchemas.screenshot, output: Schemas.screenshotResult) { arguments in
                var decoder = try Arguments(arguments, allowed: ["savePath"])
                let output = try await services.screenshot(
                    ScreenshotToolRequest(savePath: try decoder.path("savePath")))
                return try ToolResultFactory.success(
                    output.result,
                    additionalContent: [
                        .image(
                            data: output.png.base64EncodedString(), mimeType: "image/png",
                            annotations: nil, _meta: nil)
                    ])
            },
            tool(name: "set_gps_position", description: "Set simulator GPS coordinates in decimal degrees.",
                 input: InputSchemas.setGpsPosition, output: Schemas.setGpsPositionResult) { arguments in
                var decoder = try Arguments(arguments, allowed: ["lat", "lon"])
                let request = SetGpsPositionToolRequest(
                    latitude: try decoder.requiredNumber("lat"),
                    longitude: try decoder.requiredNumber("lon"))
                return try ToolResultFactory.success(try await services.setGpsPosition(request))
            },
            tool(name: "sim_start", description: "Start or adopt the requested SDK simulator.",
                 input: InputSchemas.simStart, output: Schemas.simStartResult) { arguments in
                var decoder = try Arguments(arguments, allowed: ["sdk"])
                return try ToolResultFactory.success(try await services.simStart(
                    SimStartToolRequest(sdk: try decoder.path("sdk"))))
            },
            tool(name: "sim_status", description: "Read validated simulator status.",
                 input: InputSchemas.none, output: Schemas.simStatusResult) { arguments in
                _ = try Arguments(arguments, allowed: [])
                return try ToolResultFactory.success(try await services.simStatus())
            },
            tool(name: "sim_stop", description: "Stop the Connect IQ simulator.",
                 input: InputSchemas.none, output: Schemas.simStopResult) { arguments in
                _ = try Arguments(arguments, allowed: [])
                return try ToolResultFactory.success(try await services.simStop())
            },
        ]
    }

    private static func tool(
        name: String, description: String, input: Value, output: Value,
        call: @escaping @Sendable ([String: Value]) async throws -> CallTool.Result
    ) -> any SimulatorTool {
        ClosureTool(definition: Tool(
            name: name, description: description, inputSchema: input,
            outputSchema: Schemas.envelopeSchema(result: output)), call: call)
    }
}

private struct ClosureTool: SimulatorTool {
    let definition: Tool
    let callClosure: @Sendable ([String: Value]) async throws -> CallTool.Result
    init(definition: Tool,
         call: @escaping @Sendable ([String: Value]) async throws -> CallTool.Result) {
        self.definition = definition; self.callClosure = call
    }
    func call(arguments: [String: Value]) async throws -> CallTool.Result {
        try await callClosure(arguments)
    }
}

// MARK: - Strict argument decoding

private struct Arguments {
    private var values: [String: Value]

    init(_ values: [String: Value], allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw ToolError(
                code: "invalid_arguments",
                message: "Unknown argument field(s): \(unknown.joined(separator: ", ")).",
                fix: "Call tools/list and pass only fields declared by this tool's input schema.",
                details: ["unknownFields": .array(unknown.map(JSONValue.string))])
        }
        self.values = values
    }

    mutating func string(_ key: String) throws -> String? {
        guard let value = values.removeValue(forKey: key) else { return nil }
        guard case .string(let string) = value, !string.isEmpty else { throw typeError(key, "a non-empty string") }
        return string
    }

    mutating func requiredString(_ key: String) throws -> String {
        guard let value = try string(key) else {
            throw ToolError(code: "invalid_arguments", message: "Missing required argument '\(key)'.",
                            fix: "Pass '\(key)' as declared by this tool's input schema.")
        }
        return value
    }

    mutating func path(_ key: String) throws -> String? {
        try string(key).map(canonicalPath)
    }

    mutating func requiredPath(_ key: String) throws -> String {
        guard let value = try path(key) else {
            throw ToolError(code: "invalid_arguments", message: "Missing required argument '\(key)'.",
                            fix: "Pass '\(key)' as declared by this tool's input schema.")
        }
        return value
    }

    mutating func boolean(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = values.removeValue(forKey: key) else { return defaultValue }
        guard case .bool(let boolean) = value else { throw typeError(key, "a boolean") }
        return boolean
    }

    mutating func integer(_ key: String, default defaultValue: Int) throws -> Int {
        guard let value = values.removeValue(forKey: key) else { return defaultValue }
        guard case .int(let integer) = value else { throw typeError(key, "an integer") }
        return integer
    }

    mutating func optionalInteger(_ key: String) throws -> Int? {
        guard let value = values.removeValue(forKey: key) else { return nil }
        guard case .int(let integer) = value else { throw typeError(key, "an integer") }
        return integer
    }

    mutating func unsigned(_ key: String) throws -> UInt64? {
        guard let value = values.removeValue(forKey: key) else { return nil }
        guard case .int(let integer) = value, integer >= 0 else {
            throw typeError(key, "a non-negative integer")
        }
        return UInt64(integer)
    }

    mutating func requiredNumber(_ key: String) throws -> Double {
        guard let value = values.removeValue(forKey: key) else {
            throw ToolError(
                code: "invalid_arguments",
                message: "Missing required argument '\(key)'.",
                fix: "Pass '\(key)' as declared by this tool's input schema.")
        }
        switch value {
        case .int(let integer): return Double(integer)
        case .double(let number): return number
        default: throw typeError(key, "a number")
        }
    }

    private func typeError(_ key: String, _ expected: String) -> ToolError {
        ToolError(code: "invalid_arguments", message: "Argument '\(key)' must be \(expected).",
                  fix: "Correct '\(key)' using the type declared by tools/list, then retry.")
    }

    private func canonicalPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private enum InputSchemas {
    static let none = object([:])
    static let doctor = object(["requestPermissions": boolean(false)])
    static let listDevices = object(["projectPath": string, "jungle": string, "sdk": string])
    static let build = object([
        "projectPath": string, "device": string, "sdk": string, "jungle": string,
        "developerKey": string, "release": boolean(false), "unitTests": boolean(false),
    ], required: ["projectPath"])
    static let simStart = object(["sdk": string])
    static let runApp = object([
        "projectPath": string, "device": string, "sdk": string, "jungle": string,
        "developerKey": string, "rebuild": boolean(true),
    ], required: ["projectPath"])
    static let runTests = object([
        "projectPath": string, "device": string, "sdk": string, "jungle": string,
        "developerKey": string, "testFilter": string,
    ], required: ["projectPath"])
    static let getLogs = object([
        "sessionId": ["type": "integer", "minimum": 0], "sinceToken": string,
        "limit": ["type": "integer", "default": 500],
    ])
    static let screenshot = object(["savePath": string])
    static let setGpsPosition = object([
        "lat": number, "lon": number,
    ], required: ["lat", "lon"])
    static let pressButton = object([
        "button": string,
        "holdMs": ["type": "integer", "minimum": 50, "maximum": 5000],
        "allowFocus": boolean(false),
    ], required: ["button"])

    private static let string: Value = ["type": "string", "minLength": 1]
    private static let number: Value = ["type": "number"]
    private static func boolean(_ value: Bool) -> Value { ["type": "boolean", "default": .bool(value)] }
    private static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        ["type": "object", "properties": .object(properties),
         "required": .array(required.sorted().map(Value.string)), "additionalProperties": false]
    }
}
