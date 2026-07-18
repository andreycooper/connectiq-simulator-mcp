/// Typed public result models — one per tool, all created in Task 3 so
/// later tasks share a single stable wire contract instead of inventing
/// one-off return types.
///
/// Wire rule: every field named in the plan's "Typed public result models"
/// table is always present in the encoded JSON. Optional fields encode as
/// explicit `null` (custom `encode(to:)`, since synthesized Codable would
/// omit them), and their schemas in `Schemas.swift` are nullable. Decoding
/// stays synthesized — `decodeIfPresent` handles explicit null fine.

// MARK: - Closed wire enums

/// The simulator lifecycle state (see the plan's state contract). `busy`'s
/// operation name travels in `SimStatusResult.operation`, not here, so the
/// enum stays a plain closed string on the wire.
public enum SimulatorState: String, Codable, Equatable, Sendable {
    case notRunning = "not_running"
    case starting
    case ready
    case busy
    case stopping
}

/// The build mode (see the plan's build-mode contract). Raw values match
/// the plan's spelling exactly.
public enum BuildMode: String, Codable, Equatable, Sendable {
    case debugApp
    case releaseApp
    case unitTests
}

/// Which pipe of the app child a log line came from.
public enum LogStream: String, Codable, Equatable, Sendable {
    case stdout
    case stderr
}

// MARK: - doctor

public struct DoctorResult: Codable, Equatable, Sendable {
    public let executablePath: String
    public let signatureKind: SignatureKind
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let cdhash: String?
    public let sdkFound: Bool
    public let javaFound: Bool
    public let simulator: Bool
    public let screenRecording: PermissionStatus
    public let accessibility: PermissionStatus
    public let responsibleProcessNote: String?
    public let checks: [DoctorCheck]

    public init(
        executablePath: String,
        signatureKind: SignatureKind,
        signingIdentifier: String?,
        teamIdentifier: String?,
        cdhash: String?,
        sdkFound: Bool,
        javaFound: Bool,
        simulator: Bool,
        screenRecording: PermissionStatus,
        accessibility: PermissionStatus,
        responsibleProcessNote: String?,
        checks: [DoctorCheck]
    ) {
        self.executablePath = executablePath
        self.signatureKind = signatureKind
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.cdhash = cdhash
        self.sdkFound = sdkFound
        self.javaFound = javaFound
        self.simulator = simulator
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.responsibleProcessNote = responsibleProcessNote
        self.checks = checks
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executablePath, forKey: .executablePath)
        try container.encode(signatureKind, forKey: .signatureKind)
        try container.encode(signingIdentifier, forKey: .signingIdentifier)
        try container.encode(teamIdentifier, forKey: .teamIdentifier)
        try container.encode(cdhash, forKey: .cdhash)
        try container.encode(sdkFound, forKey: .sdkFound)
        try container.encode(javaFound, forKey: .javaFound)
        try container.encode(simulator, forKey: .simulator)
        try container.encode(screenRecording, forKey: .screenRecording)
        try container.encode(accessibility, forKey: .accessibility)
        try container.encode(responsibleProcessNote, forKey: .responsibleProcessNote)
        try container.encode(checks, forKey: .checks)
    }
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public let name: String
    public let ok: Bool
    public let observed: String
    public let fix: String?

    public init(name: String, ok: Bool, observed: String, fix: String?) {
        self.name = name
        self.ok = ok
        self.observed = observed
        self.fix = fix
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(ok, forKey: .ok)
        try container.encode(observed, forKey: .observed)
        try container.encode(fix, forKey: .fix)
    }
}

// MARK: - list_sdks

public struct ListSdksResult: Codable, Equatable, Sendable {
    public let sdks: [SdkSummary]

    public init(sdks: [SdkSummary]) {
        self.sdks = sdks
    }

    /// Builds inventory while guaranteeing that the SDK selected by the
    /// resolution precedence is represented exactly once and marked active,
    /// even when CIQ_SDK/current-sdk.cfg points outside the normal Sdks root.
    public init(installed: [SdkInfo], active: SdkInfo) {
        func canonicalRoot(_ sdk: SdkInfo) -> String {
            sdk.root.resolvingSymlinksInPath().standardizedFileURL.path
        }

        var inventoryByRoot: [String: SdkInfo] = [:]
        for sdk in installed where inventoryByRoot[canonicalRoot(sdk)] == nil {
            inventoryByRoot[canonicalRoot(sdk)] = sdk
        }
        let activeRoot = canonicalRoot(active)
        inventoryByRoot[activeRoot] = active

        self.sdks = inventoryByRoot.values
            .sorted { ($0.version, $0.root.path) < ($1.version, $1.root.path) }
            .map { sdk in
                SdkSummary(
                    version: sdk.version.description,
                    path: sdk.root.path,
                    source: canonicalRoot(sdk) == activeRoot
                        ? active.source.rawValue : sdk.source.rawValue,
                    active: canonicalRoot(sdk) == activeRoot)
            }
    }
}

public struct SdkSummary: Codable, Equatable, Sendable {
    public let version: String
    public let path: String
    public let source: String
    public let active: Bool

    public init(version: String, path: String, source: String, active: Bool) {
        self.version = version
        self.path = path
        self.source = source
        self.active = active
    }
}

// MARK: - list_devices

public struct ListDevicesResult: Codable, Equatable, Sendable {
    public let devices: [DeviceSummary]

    public init(devices: [DeviceSummary]) {
        self.devices = devices
    }
}

public struct DeviceSummary: Codable, Equatable, Sendable {
    public let deviceId: String
    public let displayName: String
    public let touch: Bool
    public let buttons: [String]
    public let inputSupported: Bool
    public let inputProfile: String?

    public init(
        deviceId: String,
        displayName: String,
        touch: Bool,
        buttons: [String],
        inputSupported: Bool,
        inputProfile: String?
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.touch = touch
        self.buttons = buttons
        self.inputSupported = inputSupported
        self.inputProfile = inputProfile
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(touch, forKey: .touch)
        try container.encode(buttons, forKey: .buttons)
        try container.encode(inputSupported, forKey: .inputSupported)
        try container.encode(inputProfile, forKey: .inputProfile)
    }
}

// MARK: - build

public struct BuildResult: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public let prgPath: String?
    public let rebuilt: Bool
    public let artifactKey: String
    public let sdk: String
    public let device: String
    public let mode: BuildMode
    public let diagnostics: [Diagnostic]

    public init(
        succeeded: Bool,
        prgPath: String?,
        rebuilt: Bool,
        artifactKey: String,
        sdk: String,
        device: String,
        mode: BuildMode,
        diagnostics: [Diagnostic]
    ) {
        self.succeeded = succeeded
        self.prgPath = prgPath
        self.rebuilt = rebuilt
        self.artifactKey = artifactKey
        self.sdk = sdk
        self.device = device
        self.mode = mode
        self.diagnostics = diagnostics
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(succeeded, forKey: .succeeded)
        try container.encode(prgPath, forKey: .prgPath)
        try container.encode(rebuilt, forKey: .rebuilt)
        try container.encode(artifactKey, forKey: .artifactKey)
        try container.encode(sdk, forKey: .sdk)
        try container.encode(device, forKey: .device)
        try container.encode(mode, forKey: .mode)
        try container.encode(diagnostics, forKey: .diagnostics)
    }
}

/// One compiler diagnostic. `severity`'s vocabulary is owned by Task 5's
/// monkeyc output parser; it is deliberately an open string here.
public struct Diagnostic: Codable, Equatable, Sendable {
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let severity: String
    public let message: String

    public init(file: String?, line: Int?, column: Int?, severity: String, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
        try container.encode(severity, forKey: .severity)
        try container.encode(message, forKey: .message)
    }
}

// MARK: - sim_start / sim_stop / sim_status

public struct SimStartResult: Codable, Equatable, Sendable {
    public let status: SimStatusResult

    public init(status: SimStatusResult) {
        self.status = status
    }
}

public struct SimStopResult: Codable, Equatable, Sendable {
    public let status: SimStatusResult

    public init(status: SimStatusResult) {
        self.status = status
    }
}

public struct SimStatusResult: Codable, Equatable, Sendable {
    public let state: SimulatorState
    public let operation: String?
    public let pid: Int32?
    public let executablePath: String?
    public let sdkPath: String?
    public let sdkVersion: String?
    public let currentDevice: String?
    public let leaseHolder: String?

    public init(
        state: SimulatorState,
        operation: String?,
        pid: Int32?,
        executablePath: String?,
        sdkPath: String?,
        sdkVersion: String?,
        currentDevice: String?,
        leaseHolder: String?
    ) {
        self.state = state
        self.operation = operation
        self.pid = pid
        self.executablePath = executablePath
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
        self.currentDevice = currentDevice
        self.leaseHolder = leaseHolder
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(operation, forKey: .operation)
        try container.encode(pid, forKey: .pid)
        try container.encode(executablePath, forKey: .executablePath)
        try container.encode(sdkPath, forKey: .sdkPath)
        try container.encode(sdkVersion, forKey: .sdkVersion)
        try container.encode(currentDevice, forKey: .currentDevice)
        try container.encode(leaseHolder, forKey: .leaseHolder)
    }
}

// MARK: - run_app

public struct RunAppResult: Codable, Equatable, Sendable {
    public let sessionId: Int
    public let device: String
    public let prgPath: String
    public let sdkPath: String
    public let sdkVersion: String
    public let rebuilt: Bool

    public init(
        sessionId: Int,
        device: String,
        prgPath: String,
        sdkPath: String,
        sdkVersion: String,
        rebuilt: Bool
    ) {
        self.sessionId = sessionId
        self.device = device
        self.prgPath = prgPath
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
        self.rebuilt = rebuilt
    }
}

// MARK: - run_tests

public struct RunTestsResult: Codable, Equatable, Sendable {
    public let passed: Int
    public let failed: Int
    public let errors: Int
    public let overallPassed: Bool
    public let perTest: [TestCaseResult]
    public let device: String
    public let sdkPath: String
    public let prgPath: String

    public init(
        passed: Int,
        failed: Int,
        errors: Int,
        overallPassed: Bool,
        perTest: [TestCaseResult],
        device: String,
        sdkPath: String,
        prgPath: String
    ) {
        self.passed = passed
        self.failed = failed
        self.errors = errors
        self.overallPassed = overallPassed
        self.perTest = perTest
        self.device = device
        self.sdkPath = sdkPath
        self.prgPath = prgPath
    }
}

/// One test's outcome. `status`'s vocabulary is owned by Task 6's
/// transcript parser; it is deliberately an open string here.
public struct TestCaseResult: Codable, Equatable, Sendable {
    public let name: String
    public let status: String
    public let duration: Double?
    public let message: String?

    public init(name: String, status: String, duration: Double?, message: String?) {
        self.name = name
        self.status = status
        self.duration = duration
        self.message = message
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encode(duration, forKey: .duration)
        try container.encode(message, forKey: .message)
    }
}

// MARK: - get_logs

public struct GetLogsResult: Codable, Equatable, Sendable {
    public let sessionId: Int
    public let state: String
    public let terminationReason: String?
    public let exitCode: Int32?
    public let crashDetected: Bool
    public let droppedLines: Int
    public let lines: [LogLine]
    public let nextToken: String

    public init(
        sessionId: Int,
        state: String,
        terminationReason: String?,
        exitCode: Int32?,
        crashDetected: Bool,
        droppedLines: Int,
        lines: [LogLine],
        nextToken: String
    ) {
        self.sessionId = sessionId
        self.state = state
        self.terminationReason = terminationReason
        self.exitCode = exitCode
        self.crashDetected = crashDetected
        self.droppedLines = droppedLines
        self.lines = lines
        self.nextToken = nextToken
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(state, forKey: .state)
        try container.encode(terminationReason, forKey: .terminationReason)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(crashDetected, forKey: .crashDetected)
        try container.encode(droppedLines, forKey: .droppedLines)
        try container.encode(lines, forKey: .lines)
        try container.encode(nextToken, forKey: .nextToken)
    }
}

public struct LogLine: Codable, Equatable, Sendable {
    public let seq: Int
    public let monotonicNanos: Int64
    public let stream: LogStream
    public let text: String
    public let crash: Bool

    public init(seq: Int, monotonicNanos: Int64, stream: LogStream, text: String, crash: Bool) {
        self.seq = seq
        self.monotonicNanos = monotonicNanos
        self.stream = stream
        self.text = text
        self.crash = crash
    }
}

// MARK: - screenshot

public struct ScreenshotResult: Codable, Equatable, Sendable {
    public let path: String
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let capturedPid: Int32
    public let appDisplayRect: DisplayRect?

    public init(
        path: String,
        mimeType: String,
        width: Int,
        height: Int,
        capturedPid: Int32,
        appDisplayRect: DisplayRect?
    ) {
        self.path = path
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.capturedPid = capturedPid
        self.appDisplayRect = appDisplayRect
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(capturedPid, forKey: .capturedPid)
        try container.encode(appDisplayRect, forKey: .appDisplayRect)
    }
}

public struct DisplayRect: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - press_button

public struct PressButtonResult: Codable, Equatable, Sendable {
    public let button: String
    public let pressType: String
    public let transport: String
    public let simulatorPid: Int32

    public init(
        button: String,
        pressType: String,
        transport: String,
        simulatorPid: Int32
    ) {
        self.button = button
        self.pressType = pressType
        self.transport = transport
        self.simulatorPid = simulatorPid
    }
}

// MARK: - set_gps_position

public struct SetGpsPositionResult: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let simulatorPid: Int32

    public init(latitude: Double, longitude: Double, simulatorPid: Int32) {
        self.latitude = latitude
        self.longitude = longitude
        self.simulatorPid = simulatorPid
    }
}
