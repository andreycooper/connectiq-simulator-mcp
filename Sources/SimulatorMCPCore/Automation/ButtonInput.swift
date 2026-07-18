@preconcurrency import ApplicationServices
import Foundation

public struct PressButtonToolRequest: Equatable, Sendable {
    public let button: String
    public let holdMs: Int?
    public let allowFocus: Bool

    public init(button: String, holdMs: Int? = nil, allowFocus: Bool = false) {
        self.button = button
        self.holdMs = holdMs
        self.allowFocus = allowFocus
    }
}

public enum ButtonTransportKind: String, Codable, Sendable {
    case protocolShell = "protocol"
    case axKeyboardPost = "ax-keyboard-post"
    case focusedKeys = "focused-keys"
}

public struct ButtonPressRequest: Equatable, Sendable {
    public let button: String
    public let holdMs: Int?
    public init(button: String, holdMs: Int? = nil) {
        self.button = button
        self.holdMs = holdMs
    }
}

public protocol ButtonPressing: Sendable {
    var kind: ButtonTransportKind { get }
    var requiresFocusOptIn: Bool { get }
    func press(_ request: ButtonPressRequest, context: OperationContext) async throws
}

/// Transport failures are deliberately typed before they cross the service
/// boundary. Their associated values are diagnostics only and are never
/// exposed in a public ToolError message.
public enum ButtonInputTransportError: Error, Sendable {
    case subprocess(String)
    case accessibilityDenied(String)
    case accessibility(String)
    case workspaceActivation(String)
    case eventPost(String)
}

public struct HoldEncoding: Codable, Equatable, Sendable {
    public let mechanism: String
    public let fixtureThresholdMs: Int
    public let gateHoldMs: Int
    public init(mechanism: String, fixtureThresholdMs: Int = 300, gateHoldMs: Int = 1000) {
        self.mechanism = mechanism
        self.fixtureThresholdMs = fixtureThresholdMs
        self.gateHoldMs = gateHoldMs
    }
}

public struct ProfileEvidence: Codable, Equatable, Sendable {
    public let capturedOn: String
    public let macOSVersion: String
    public let sdks: [String]
    public let surfaceDigests: [String: String]
    public let gateTranscriptDigests: [String: String]
    public init(capturedOn: String, macOSVersion: String, sdks: [String],
                surfaceDigests: [String: String], gateTranscriptDigests: [String: String]) {
        self.capturedOn = capturedOn; self.macOSVersion = macOSVersion; self.sdks = sdks
        self.surfaceDigests = surfaceDigests; self.gateTranscriptDigests = gateTranscriptDigests
    }
}

public struct InputProfileCore: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let device: String
    public let profileVersion: String
    public let qualification: Bool
    public let buttonOrder: [String]
    public let holdEncoding: HoldEncoding
    public let evidence: ProfileEvidence
    public init(schemaVersion: Int = 1, device: String, profileVersion: String,
                qualification: Bool, buttonOrder: [String], holdEncoding: HoldEncoding,
                evidence: ProfileEvidence) {
        self.schemaVersion = schemaVersion; self.device = device; self.profileVersion = profileVersion
        self.qualification = qualification; self.buttonOrder = buttonOrder
        self.holdEncoding = holdEncoding; self.evidence = evidence
    }
}

public struct ProtocolShellProfile: Codable, Equatable, Sendable {
    public let sdkEntries: [String: [String: [String: JSONValue]]]
    public let transcriptGrammar: [String: String]
    public init(sdkEntries: [String: [String: [String: JSONValue]]], transcriptGrammar: [String: String]) {
        self.sdkEntries = sdkEntries; self.transcriptGrammar = transcriptGrammar
    }
}

public struct AXPostProfile: Codable, Equatable, Sendable {
    public let sdkEntries: [String: [String: [String: JSONValue]]]
    public let compatibility: [String: JSONValue]
    public init(sdkEntries: [String: [String: [String: JSONValue]]], compatibility: [String: JSONValue]) {
        self.sdkEntries = sdkEntries; self.compatibility = compatibility
    }
}

public struct FocusedKeysProfile: Codable, Equatable, Sendable {
    public let sdkEntries: [String: [String: [String: JSONValue]]]
    public let activation: [String: JSONValue]
    public let restoration: [String: JSONValue]
    public init(sdkEntries: [String: [String: [String: JSONValue]]], activation: [String: JSONValue], restoration: [String: JSONValue]) {
        self.sdkEntries = sdkEntries; self.activation = activation; self.restoration = restoration
    }
}

public enum InputProfileTransport: Codable, Equatable, Sendable {
    case protocolShell(ProtocolShellProfile)
    case axKeyboardPost(AXPostProfile)
    case focusedKeys(FocusedKeysProfile)

    private enum Keys: String, CodingKey { case transport, transportProfile }
    public var kind: ButtonTransportKind {
        switch self { case .protocolShell: return .protocolShell; case .axKeyboardPost: return .axKeyboardPost; case .focusedKeys: return .focusedKeys }
    }
    public var sdkEntries: [String: [String: [String: JSONValue]]] {
        switch self { case .protocolShell(let p): return p.sdkEntries; case .axKeyboardPost(let p): return p.sdkEntries; case .focusedKeys(let p): return p.sdkEntries }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(ButtonTransportKind.self, forKey: .transport) {
        case .protocolShell: self = .protocolShell(try c.decode(ProtocolShellProfile.self, forKey: .transportProfile))
        case .axKeyboardPost: self = .axKeyboardPost(try c.decode(AXPostProfile.self, forKey: .transportProfile))
        case .focusedKeys: self = .focusedKeys(try c.decode(FocusedKeysProfile.self, forKey: .transportProfile))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .transport)
        switch self { case .protocolShell(let p): try c.encode(p, forKey: .transportProfile); case .axKeyboardPost(let p): try c.encode(p, forKey: .transportProfile); case .focusedKeys(let p): try c.encode(p, forKey: .transportProfile) }
    }
}

public struct InputProfile: Codable, Equatable, Sendable {
    public let core: InputProfileCore
    public let transport: InputProfileTransport
    public init(core: InputProfileCore, transport: InputProfileTransport) { self.core = core; self.transport = transport }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, device, profileVersion, qualification, buttonOrder
        case holdEncoding, evidence, transport, transportProfile
    }

    /// The canonical profile is intentionally flat: core fields and the
    /// transport discriminator/profile are siblings. This is hand-written so
    /// associated-value enum synthesis can never change the wire contract.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(ButtonTransportKind.self, forKey: .transport)
        let core = InputProfileCore(
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            device: try c.decode(String.self, forKey: .device),
            profileVersion: try c.decode(String.self, forKey: .profileVersion),
            qualification: try c.decode(Bool.self, forKey: .qualification),
            buttonOrder: try c.decode([String].self, forKey: .buttonOrder),
            holdEncoding: try c.decode(HoldEncoding.self, forKey: .holdEncoding),
            evidence: try c.decode(ProfileEvidence.self, forKey: .evidence))
        switch kind {
        case .protocolShell:
            self.transport = .protocolShell(try c.decode(ProtocolShellProfile.self, forKey: .transportProfile))
        case .axKeyboardPost:
            self.transport = .axKeyboardPost(try c.decode(AXPostProfile.self, forKey: .transportProfile))
        case .focusedKeys:
            self.transport = .focusedKeys(try c.decode(FocusedKeysProfile.self, forKey: .transportProfile))
        }
        self.core = core
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(core.schemaVersion, forKey: .schemaVersion)
        try c.encode(core.device, forKey: .device)
        try c.encode(core.profileVersion, forKey: .profileVersion)
        try c.encode(core.qualification, forKey: .qualification)
        try c.encode(core.buttonOrder, forKey: .buttonOrder)
        try c.encode(core.holdEncoding, forKey: .holdEncoding)
        try c.encode(core.evidence, forKey: .evidence)
        try c.encode(transport.kind, forKey: .transport)
        switch transport {
        case .protocolShell(let value): try c.encode(value, forKey: .transportProfile)
        case .axKeyboardPost(let value): try c.encode(value, forKey: .transportProfile)
        case .focusedKeys(let value): try c.encode(value, forKey: .transportProfile)
        }
    }
}

public struct ButtonOperationRunner: Sendable {
    public typealias Body = @Sendable (OperationContext) async throws -> PressButtonResult
    private let runBody: @Sendable (SimOperation, OperationRequirement, @escaping Body) async throws -> PressButtonResult
    public init(controller: SimulatorController) { runBody = { try await controller.withOperation($0, requirement: $1, body: $2) } }
    public init(_ run: @escaping @Sendable (SimOperation, OperationRequirement, @escaping Body) async throws -> PressButtonResult) { runBody = run }
    public func run(_ operation: SimOperation, requirement: OperationRequirement, body: @escaping Body) async throws -> PressButtonResult { try await runBody(operation, requirement, body) }
}

public struct ButtonInputService: Sendable {
    private let profile: InputProfile
    private let transports: [any ButtonPressing]
    private let runner: ButtonOperationRunner
    private let clock: any Clock<Duration>
    public init(profile: InputProfile, transports: [any ButtonPressing], operationRunner: ButtonOperationRunner) {
        self.init(profile: profile, transports: transports, operationRunner: operationRunner, clock: ContinuousClock())
    }
    public init(profile: InputProfile, transport: any ButtonPressing, operationRunner: ButtonOperationRunner) {
        self.init(profile: profile, transports: [transport], operationRunner: operationRunner)
    }
    public init(profile: InputProfile, transports: [any ButtonPressing], operationRunner: ButtonOperationRunner, clock: any Clock<Duration>) {
        self.profile = profile; self.transports = transports; self.runner = operationRunner; self.clock = clock
    }
    public func press(_ request: PressButtonToolRequest) async throws -> PressButtonResult {
        guard profile.core.buttonOrder.contains(request.button) else {
            throw invalidArguments("Unknown button '\(request.button)'.", fix: "Use one of: \(profile.core.buttonOrder.joined(separator: ", ")).")
        }
        if let hold = request.holdMs, !(50...5000).contains(hold) {
            throw invalidArguments("holdMs must be between 50 and 5000 milliseconds.", fix: "Omit holdMs for a press or pass a value from 50 through 5000.")
        }
        return try await runner.run(.pressButton, requirement: .currentReady) { context in
            guard let device = context.currentDevice else { throw noCurrentDevice() }
            guard device == profile.core.device else { throw inputUnsupported("No verified input profile exists for device \(device).") }
            guard let sdkEntry = profile.transport.sdkEntries[context.sdk.version.description] else {
                throw inputUnsupported("No verified input mapping exists for SDK \(context.sdk.version.description); verified SDKs are \(profile.transport.sdkEntries.keys.sorted().joined(separator: ", ")).", fix: "Use one of the verified SDK versions listed in the message.")
            }
            guard sdkEntry[request.button] != nil else { throw inputUnsupported("No verified input mapping exists for button \(request.button) on SDK \(context.sdk.version.description).", fix: "Use a button with a verified mapping for this SDK.") }
            guard let transport = transports.first(where: { $0.kind == profile.transport.kind }) else { throw inputUnsupported("The verified input transport is unavailable.", fix: "Use a supported transport or restart the simulator.") }
            if transport.requiresFocusOptIn && !request.allowFocus { throw focusRequired() }
            do {
                try await ClockSupport.withDeadline(.seconds(10) + .milliseconds(request.holdMs ?? 0), clock: clock) {
                    try await transport.press(ButtonPressRequest(button: request.button, holdMs: request.holdMs), context: context)
                }
            } catch is ClockSupport.DeadlineExceeded {
                throw operationTimeout()
            } catch is CancellationError { throw CancellationError() }
            catch let error as ButtonInputTransportError {
                throw translate(error)
            }
            catch {
                Log.err("Button input transport failed: \(String(reflecting: error))")
                throw deliveryFailure()
            }
            return PressButtonResult(button: request.button, pressType: request.holdMs == nil ? "press" : "hold", transport: transport.kind.rawValue, simulatorPid: context.simulatorPid)
        }
    }

    private func translate(_ error: ButtonInputTransportError) -> ToolError {
        if case .accessibilityDenied = error {
            Log.err("Button input denied by Accessibility")
            return accessibilityDenied()
        }
        Log.err("Button input platform delivery failed: \(String(reflecting: error))")
        return deliveryFailure()
    }

    private func inputUnsupported(_ message: String, fix: String = "Use a device with a verified input profile.") -> ToolError {
        ToolError(code: "input_unsupported", message: message, fix: fix)
    }
    private func focusRequired() -> ToolError {
        ToolError(code: "focus_required", message: "This input transport requires simulator focus.", fix: "Retry with allowFocus=true.")
    }
    private func invalidArguments(_ message: String, fix: String) -> ToolError {
        ToolError(code: "invalid_arguments", message: message, fix: fix)
    }
    private func noCurrentDevice() -> ToolError {
        ToolError(code: "no_current_device", message: "No simulator device is selected.", fix: "Run the app or select a current device before pressing a button.")
    }
    private func operationTimeout() -> ToolError {
        ToolError(code: "operation_timeout", message: "Button delivery exceeded its deadline.", fix: "Retry after confirming the simulator is ready.")
    }
    private func accessibilityDenied() -> ToolError {
        ToolError(code: "accessibility_denied", message: "Accessibility permission denied button delivery.", fix: "Grant Accessibility permission to simulator-mcp, then retry.")
    }

    private func deliveryFailure() -> ToolError {
        ToolError(code: "input_delivery_failed", message: "The input transport could not deliver the button.", fix: "Restart the simulator, verify the selected input profile and Accessibility state, then retry.")
    }
}
