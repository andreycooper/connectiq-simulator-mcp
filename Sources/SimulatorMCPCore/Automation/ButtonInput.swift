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
    case keyboardLayoutUnsupported
    case eventPostingDenied
    case accessibilityDenied(String)
    case accessibility(String)
    case workspaceActivation(String)
    case eventConstruction(String)
    case eventPost(String)
}

public struct HoldEncoding: Codable, Equatable, Sendable {
    public let mechanism: String
    public let fixtureThresholdMs: Int
    public let gateHoldMs: Int
    /// Minimum wall-clock dwell between key-down and key-up. The simulator's
    /// event loop samples key state, so a pair posted back-to-back is dropped
    /// entirely: measured 0/5 delivered at 0ms and 5/5 at 10ms and above on
    /// both installed SDKs. This is required in the profile JSON rather than
    /// defaulted, so a profile can never silently ship an undeliverable press.
    public let minimumPressMs: Int
    public init(
        mechanism: String, fixtureThresholdMs: Int = 300, gateHoldMs: Int = 1000,
        minimumPressMs: Int = 50
    ) {
        self.mechanism = mechanism
        self.fixtureThresholdMs = fixtureThresholdMs
        self.gateHoldMs = gateHoldMs
        self.minimumPressMs = minimumPressMs
    }
}

public struct KeyboardLayoutPredicate: Codable, Equatable, Sendable {
    public let inputSourceID: String
    public let requiresEnabled: Bool
    public init(inputSourceID: String, requiresEnabled: Bool) {
        self.inputSourceID = inputSourceID
        self.requiresEnabled = requiresEnabled
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
    public let leavesSimulatorFrontmost: Bool
    public init(
        sdkEntries: [String: [String: [String: JSONValue]]],
        activation: [String: JSONValue],
        leavesSimulatorFrontmost: Bool
    ) {
        self.sdkEntries = sdkEntries
        self.activation = activation
        self.leavesSimulatorFrontmost = leavesSimulatorFrontmost
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

public enum InputProfileValidationError: Error, Equatable, Sendable {
    case malformed(String)
}

/// A profile that has passed strict structural and qualification-phase
/// semantic validation. Construction is intentionally confined to the loader.
public struct QualifiedInputProfile: Sendable {
    public let profile: InputProfile
    public let keyboardLayoutPredicate: KeyboardLayoutPredicate
    fileprivate init(profile: InputProfile, keyboardLayoutPredicate: KeyboardLayoutPredicate) {
        self.profile = profile
        self.keyboardLayoutPredicate = keyboardLayoutPredicate
    }
}

public struct InputCapability: Equatable, Sendable {
    public let buttons: [String]
    public let profile: String
}

/// Immutable, exact-match capability data. This registry is private to the
/// qualification composition; v1 PublicToolServices remains fail-closed.
public struct InputCapabilityRegistry: Sendable {
    private struct Entry: Sendable {
        let sdkVersions: Set<String>
        let capability: InputCapability
    }
    private let entries: [String: Entry]

    public init(_ qualified: QualifiedInputProfile) throws { try self.init([qualified]) }

    /// Keyed by exact device id. Two profiles claiming the same device are a
    /// load failure rather than a last-one-wins overwrite: a partially loaded
    /// allowlist is worse than none.
    public init(_ qualified: [QualifiedInputProfile]) throws {
        var entries: [String: Entry] = [:]
        for candidate in qualified {
            let profile = candidate.profile
            guard profile.core.qualification else {
                throw InputProfileValidationError.malformed("profile is not a qualification profile")
            }
            guard entries[profile.core.device] == nil else {
                throw InputProfileValidationError.malformed(
                    "duplicate qualification profile for device \(profile.core.device)")
            }
            entries[profile.core.device] = Entry(
                sdkVersions: Set(profile.transport.sdkEntries.keys),
                capability: InputCapability(
                    buttons: profile.core.buttonOrder, profile: profile.core.profileVersion))
        }
        self.entries = entries
    }

    public func capability(device: String, sdkVersion: String) -> InputCapability? {
        guard let entry = entries[device], entry.sdkVersions.contains(sdkVersion) else { return nil }
        return entry.capability
    }
}

public enum InputProfileLoader {
    public static func qualificationCandidateData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "fenix6xpro-input", withExtension: "json",
            subdirectory: "Resources/InputProfiles")
        else {
            throw InputProfileValidationError.malformed("qualification profile resource is missing")
        }
        return try Data(contentsOf: url)
    }

    public static func loadQualificationCandidate() throws -> QualifiedInputProfile {
        try decodeQualification(qualificationCandidateData())
    }

    /// Every shipped profile resource, validated. The set of devices they
    /// declare must equal `qualifiedDevices` exactly: a missing resource and an
    /// unlisted extra one are both load failures, so capability is never a
    /// filesystem side effect.
    public static func loadQualificationCandidates() throws -> [QualifiedInputProfile] {
        guard let directory = Bundle.module.url(
            forResource: "InputProfiles", withExtension: nil, subdirectory: "Resources")
        else {
            throw InputProfileValidationError.malformed("qualification profile directory is missing")
        }
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-input.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let profiles = try files.map { try decodeQualification(try Data(contentsOf: $0)) }
        guard Set(profiles.map { $0.profile.core.device }) == qualifiedDevices else {
            throw InputProfileValidationError.malformed(
                "shipped profile resources do not match the qualified device set")
        }
        return profiles
    }

    public static func decodeQualification(
        _ data: Data, allowing devices: Set<String>? = nil
    ) throws -> QualifiedInputProfile {
        do {
            let raw = try JSONSerialization.jsonObject(with: data)
            try validateShape(raw)
            let profile = try JSONDecoder().decode(InputProfile.self, from: data)
            let predicate = try validateSemantics(profile, allowing: devices ?? qualifiedDevices)
            return QualifiedInputProfile(profile: profile, keyboardLayoutPredicate: predicate)
        } catch let error as InputProfileValidationError {
            throw error
        } catch {
            throw InputProfileValidationError.malformed("qualification profile could not be decoded")
        }
    }

    private static func validateShape(_ raw: Any) throws {
        let root = try object(raw, keys: [
            "schemaVersion", "device", "profileVersion", "qualification", "buttonOrder",
            "holdEncoding", "evidence", "transport", "transportProfile",
        ])
        _ = try object(root["holdEncoding"], keys: [
            "mechanism", "fixtureThresholdMs", "gateHoldMs", "minimumPressMs",
        ])
        _ = try object(root["evidence"], keys: [
            "capturedOn", "macOSVersion", "sdks", "surfaceDigests", "gateTranscriptDigests",
        ])
        let transport = try object(root["transportProfile"], keys: ["sdkEntries", "activation", "leavesSimulatorFrontmost"])
        let activation = try object(
            transport["activation"], keys: ["requiresFocusOptIn", "keyboardLayoutPredicate"])
        _ = try object(
            activation["keyboardLayoutPredicate"], keys: ["inputSourceID", "requiresEnabled"])
        guard transport["leavesSimulatorFrontmost"] as? Bool == true else {
            throw malformed("focused transport must leave Simulator frontmost")
        }
        let entries = try dictionary(transport["sdkEntries"])
        guard !entries.isEmpty, Set(entries.keys).isSubset(of: recognisedSdkVersions) else {
            throw malformed("SDK allowlist mismatch")
        }
        for value in entries.values {
            let buttons = try dictionary(value)
            guard Set(buttons.keys) == ["enter", "esc", "up", "down"] else {
                throw malformed("button allowlist mismatch")
            }
            for mapping in buttons.values { _ = try object(mapping, keys: ["keyCode"]) }
        }
    }

    /// SDK versions this server has a verified transport story for. A profile
    /// may declare any non-empty subset: fēnix 8 and fēnix E need API level
    /// 6.0.0, which 8.4.1 cannot compile, so they are single-SDK by necessity.
    /// Coverage is per profile; the set of *recognised* versions is not.
    private static let recognisedSdkVersions: Set<String> = ["8.4.1", "9.1.0"]

    /// A1. Capability is an explicit allowlist keyed by exact device id, and it
    /// lives here rather than in the resource directory. A device joins it only
    /// after its own delivery gate has passed, and adding one costs a Swift
    /// edit on purpose: a wrong literal breaks the build, a wrong JSON file
    /// would be silently accepted.
    static let qualifiedDevices: Set<String> = [
        "fenix6",
        "fenix6pro",
        "fenix6s",
        "fenix6spro",
        "fenix6xpro",
        "fenix7",
        "fenix7pro",
        "fenix7pronowifi",
        "fenix7s",
        "fenix7spro",
        "fenix7x",
        "fenix7xpro",
        "fenix7xpronowifi",
        "fenix843mm",
        "fenix847mm",
        "fenix8pro47mm",
        "fenix8solar47mm",
        "fenix8solar51mm",
        "fenixe",
    ]

    /// A2. The layout group's key mapping AND the device-to-group assignment
    /// are both compiled in. A profile's `sdkEntries` must equal the group's
    /// mapping exactly, which is what catches a transposed mapping — every
    /// permutation of the permitted codes is still four permitted codes, so a
    /// membership test cannot.
    enum LayoutGroup: Hashable {
        /// fēnix 6/7/8/E: five physical keys, `menu` being a hold of `up`.
        case fenixPhysicalKeys
    }

    struct LayoutProfile: Sendable {
        let buttonOrder: [String]
        let keyCodes: [String: Int]
    }

    static let layoutGroups: [LayoutGroup: LayoutProfile] = [
        .fenixPhysicalKeys: LayoutProfile(
            buttonOrder: ["enter", "esc", "up", "down"],
            keyCodes: ["enter": 36, "esc": 53, "up": 126, "down": 125])
    ]

    static let deviceLayoutGroups: [String: LayoutGroup] = Dictionary(
        uniqueKeysWithValues: qualifiedDevices.map { ($0, LayoutGroup.fenixPhysicalKeys) })

    /// A3. The permitted virtual key codes. Retained as a blast-radius bound on
    /// what this process may post into a focused foreground application — NOT
    /// as evidence of qualification. A2 carries the evidence.
    private static let permittedKeyCodes: Set<Int> = [36, 53, 126, 125]

    private static func validateSemantics(
        _ profile: InputProfile, allowing devices: Set<String>
    ) throws -> KeyboardLayoutPredicate {
        let declaredSdks = Set(profile.transport.sdkEntries.keys)
        guard devices.contains(profile.core.device) else {
            throw malformed("device is not in the qualified device set")
        }
        // A test may widen the allowlist; it may not invent a layout group.
        let group = deviceLayoutGroups[profile.core.device] ?? .fenixPhysicalKeys
        guard let layout = layoutGroups[group] else { throw malformed("unknown layout group") }
        let expectedCodes = layout.keyCodes
        guard Set(expectedCodes.values).isSubset(of: permittedKeyCodes) else {
            throw malformed("layout group uses a key code outside the permitted set")
        }
        let approvedDigests = [
            "garmin-community-keyboard-shortcuts": "d6ed40565ca4e7d116cac01bac256ff27af64385a4eff30cb7c7806b38f6c7ab",
            "apple-hitoolbox-release-notes": "a47905d4f43b6ecf5f7f24465777870849e578c19d4d9d738f4a84fff08d32c1",
            "preserved-hitoolbox-events-header": "f0c475dbc4500f6f4d867fb224d29b18596a9d8880fabf1ba4fd9cfc84eafac0",
        ]
        guard profile.core.schemaVersion == 2,
              profile.core.profileVersion == "\(profile.core.device)-verified/3",
              profile.core.qualification,
              profile.core.buttonOrder == layout.buttonOrder,
              profile.core.holdEncoding == HoldEncoding(
                  mechanism: "down-up", fixtureThresholdMs: 300, gateHoldMs: 1000,
                  minimumPressMs: 50),
              !declaredSdks.isEmpty,
              declaredSdks.isSubset(of: recognisedSdkVersions),
              Set(profile.core.evidence.sdks) == declaredSdks,
              Set(profile.core.evidence.gateTranscriptDigests.keys) == declaredSdks,
              profile.core.evidence.macOSVersion == "26.5.2",
              profile.core.evidence.surfaceDigests == approvedDigests,
              profile.transport.kind == .focusedKeys
        else { throw malformed("qualification profile semantic mismatch") }
        // A2: equality, not membership. A transposed mapping is still four
        // permitted codes, so only equality against the compiled-in layout
        // group rejects it.
        let expectedEntry = Dictionary(
            uniqueKeysWithValues: expectedCodes.map { ($0, ["keyCode": JSONValue.int($1)]) })
        for sdk in declaredSdks {
            guard let entry = profile.transport.sdkEntries[sdk] else { throw malformed("SDK entry missing") }
            guard entry == expectedEntry else { throw malformed("key mapping mismatch") }
        }
        let predicate = KeyboardLayoutPredicate(
            inputSourceID: "com.apple.keylayout.US", requiresEnabled: true)
        guard case .focusedKeys(let focused) = profile.transport,
               focused.activation == [
                 "requiresFocusOptIn": .bool(true),
                 "keyboardLayoutPredicate": .object([
                     "inputSourceID": .string(predicate.inputSourceID),
                     "requiresEnabled": .bool(predicate.requiresEnabled),
                 ]),
               ],
               focused.leavesSimulatorFrontmost
        else { throw malformed("focused transport parameters mismatch") }
        return predicate
    }

    private static func object(_ raw: Any?, keys: Set<String>) throws -> [String: Any] {
        let value = try dictionary(raw)
        guard Set(value.keys) == keys else { throw malformed("unknown or missing profile field") }
        return value
    }

    private static func dictionary(_ raw: Any?) throws -> [String: Any] {
        guard let value = raw as? [String: Any] else { throw malformed("profile object expected") }
        return value
    }

    private static func malformed(_ message: String) -> InputProfileValidationError { .malformed(message) }
}

/// Qualification-only defense-in-depth around the final request shape.
public struct QualificationButtonService: Sendable {
    private let profile: InputProfile
    private let dispatch: @Sendable (PressButtonToolRequest) async throws -> PressButtonResult

    public init(
        profile: QualifiedInputProfile,
        dispatch: @escaping @Sendable (PressButtonToolRequest) async throws -> PressButtonResult
    ) {
        self.profile = profile.profile
        self.dispatch = dispatch
    }

    public func press(_ request: PressButtonToolRequest) async throws -> PressButtonResult {
        guard profile.core.qualification, profile.core.buttonOrder.contains(request.button) else {
            throw ToolError(code: "invalid_arguments", message: "Unknown button '\(request.button)'.", fix: "Use one of: \(profile.core.buttonOrder.joined(separator: ", ")).")
        }
        if let hold = request.holdMs, !(50...5000).contains(hold) {
            throw ToolError(code: "invalid_arguments", message: "holdMs must be between 50 and 5000 milliseconds.", fix: "Omit holdMs for a press or pass a value from 50 through 5000.")
        }
        return try await dispatch(request)
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
    /// Keyed by exact device id. A device with no entry is refused, so the
    /// service cannot post a mapping belonging to a different device.
    private let profiles: [String: InputProfile]
    private let transports: [String: [any ButtonPressing]]
    private let runner: ButtonOperationRunner
    private let clock: any Clock<Duration>
    /// Only used to phrase the unknown-button message; every in-scope device
    /// shares one button order today.
    private let advertisedButtons: [String]

    public init(profile: InputProfile, transports: [any ButtonPressing], operationRunner: ButtonOperationRunner) {
        self.init(profile: profile, transports: transports, operationRunner: operationRunner, clock: ContinuousClock())
    }
    public init(profile: InputProfile, transport: any ButtonPressing, operationRunner: ButtonOperationRunner) {
        self.init(profile: profile, transports: [transport], operationRunner: operationRunner)
    }
    public init(profile: InputProfile, transports: [any ButtonPressing], operationRunner: ButtonOperationRunner, clock: any Clock<Duration>) {
        self.init(devices: [(profile, transports)], operationRunner: operationRunner, clock: clock)
    }
    public init(
        devices: [(profile: InputProfile, transports: [any ButtonPressing])],
        operationRunner: ButtonOperationRunner, clock: any Clock<Duration> = ContinuousClock()
    ) {
        var profiles: [String: InputProfile] = [:]
        var transports: [String: [any ButtonPressing]] = [:]
        for (profile, deviceTransports) in devices {
            profiles[profile.core.device] = profile
            transports[profile.core.device] = deviceTransports
        }
        self.profiles = profiles
        self.transports = transports
        self.runner = operationRunner
        self.clock = clock
        self.advertisedButtons = devices.min { $0.profile.core.device < $1.profile.core.device }?
            .profile.core.buttonOrder ?? []
    }
    public func press(_ request: PressButtonToolRequest) async throws -> PressButtonResult {
        guard advertisedButtons.contains(request.button) else {
            throw invalidArguments("Unknown button '\(request.button)'.", fix: "Use one of: \(advertisedButtons.joined(separator: ", ")).")
        }
        if let hold = request.holdMs, !(50...5000).contains(hold) {
            throw invalidArguments("holdMs must be between 50 and 5000 milliseconds.", fix: "Omit holdMs for a press or pass a value from 50 through 5000.")
        }
        return try await runner.run(.pressButton, requirement: .currentReady) { context in
            guard let device = context.currentDevice else { throw noCurrentDevice() }
            guard let profile = profiles[device], let deviceTransports = transports[device] else {
                throw inputUnsupported("No verified input profile exists for device \(device).")
            }
            guard profile.core.buttonOrder.contains(request.button) else {
                throw inputUnsupported("Button \(request.button) is not verified for device \(device).", fix: "Use one of: \(profile.core.buttonOrder.joined(separator: ", ")).")
            }
            guard let sdkEntry = profile.transport.sdkEntries[context.sdk.version.description] else {
                throw inputUnsupported("No verified input mapping exists for SDK \(context.sdk.version.description); verified SDKs are \(profile.transport.sdkEntries.keys.sorted().joined(separator: ", ")).", fix: "Use one of the verified SDK versions listed in the message.")
            }
            guard sdkEntry[request.button] != nil else { throw inputUnsupported("No verified input mapping exists for button \(request.button) on SDK \(context.sdk.version.description).", fix: "Use a button with a verified mapping for this SDK.") }
            guard let transport = deviceTransports.first(where: { $0.kind == profile.transport.kind }) else { throw inputUnsupported("The verified input transport is unavailable.", fix: "Use a supported transport or restart the simulator.") }
            if transport.requiresFocusOptIn && !request.allowFocus { throw focusRequired() }
            do {
                try await ClockSupport.withDeadline(.seconds(10) + .milliseconds(request.holdMs ?? 0), clock: clock) {
                    try await transport.press(ButtonPressRequest(button: request.button, holdMs: request.holdMs), context: context)
                }
            } catch is ClockSupport.DeadlineExceeded {
                throw operationTimeout()
            } catch is CancellationError { throw CancellationError() }
            catch let error as ButtonInputTransportError {
                throw translate(
                    error, button: request.button, simulatorPid: context.simulatorPid)
            }
            catch {
                Log.err("Button input transport failed: \(String(reflecting: error))")
                throw deliveryFailure(details: Self.deliveryDetails(
                    button: request.button, simulatorPid: context.simulatorPid,
                    stage: "unclassified"))
            }
            let pressType = (request.holdMs ?? 0) >= profile.core.holdEncoding.fixtureThresholdMs ? "hold" : "press"
            return PressButtonResult(button: request.button, pressType: pressType, transport: transport.kind.rawValue, simulatorPid: context.simulatorPid)
        }
    }

    /// Names the transport stage that gave up, and preserves the description it
    /// produced. Diagnostic only: it changes no classification and no control
    /// flow. Added after two gate runs failed with `input_delivery_failed`
    /// carrying no button, no PID and no stage, which made them undiagnosable
    /// from the returned error alone.
    static func transportStage(
        _ error: ButtonInputTransportError
    ) -> (stage: String, detail: String) {
        switch error {
        case .subprocess(let detail): return ("subprocess", detail)
        case .keyboardLayoutUnsupported: return ("keyboardLayout", "")
        case .eventPostingDenied: return ("eventPostingDenied", "")
        case .accessibilityDenied(let detail): return ("accessibilityDenied", detail)
        case .accessibility(let detail): return ("accessibility", detail)
        case .workspaceActivation(let detail): return ("workspaceActivation", detail)
        case .eventConstruction(let detail): return ("eventConstruction", detail)
        case .eventPost(let detail): return ("eventPost", detail)
        }
    }

    /// Only stable, enumerated values. The transport's own description is a raw
    /// platform string and stays on stderr: this server translates platform
    /// errors at its boundary and never interpolates them into a public error.
    static func deliveryDetails(
        button: String, simulatorPid: Int32, stage: String
    ) -> [String: JSONValue] {
        [
            "button": .string(button),
            "simulatorPid": .int(Int(simulatorPid)),
            "transportStage": .string(stage),
        ]
    }

    private func translate(
        _ error: ButtonInputTransportError, button: String, simulatorPid: Int32
    ) -> ToolError {
        let staged = Self.transportStage(error)
        if !staged.detail.isEmpty {
            Log.err("Button input \(staged.stage) failed: \(staged.detail)")
        }
        let details = Self.deliveryDetails(
            button: button, simulatorPid: simulatorPid, stage: staged.stage)
        if case .keyboardLayoutUnsupported = error {
            return ToolError(
                code: "keyboard_layout_unsupported",
                message: "The current keyboard layout is not supported for button qualification.",
                fix: "Select the ANSI-US input source (com.apple.keylayout.US), then retry.",
                details: details)
        }
        if case .eventPostingDenied = error {
            Log.err("Button event posting denied by Accessibility")
            return accessibilityDenied(details: details)
        }
        if case .accessibilityDenied = error {
            Log.err("Button input denied by Accessibility")
            return accessibilityDenied(details: details)
        }
        if case .workspaceActivation = error {
            return focusFailure(details: details)
        }
        Log.err("Button input platform delivery failed: \(String(reflecting: error))")
        return deliveryFailure(details: details)
    }

    private func inputUnsupported(_ message: String, fix: String = "Use a device with a verified input profile.") -> ToolError {
        ToolError(code: "input_unsupported", message: message, fix: fix)
    }
    private func focusRequired() -> ToolError {
        ToolError(
            code: "focus_required",
            message: "This input transport requires simulator focus; allowFocus=true visibly brings Garmin Simulator forward and leaves it frontmost.",
            fix: "Retry with allowFocus=true if visible Simulator activation and leaving it frontmost are acceptable.")
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
    private func accessibilityDenied(details: [String: JSONValue]? = nil) -> ToolError {
        ToolError(
            code: "accessibility_denied",
            message: "Accessibility permission denied button delivery.",
            fix: Permissions.grantInstructions(
                settingsPath: Permissions.accessibilitySettingsPath,
                executablePath: SignatureInspector.currentExecutableURL().path),
            details: details)
    }

    private func focusFailure(details: [String: JSONValue]? = nil) -> ToolError {
        ToolError(
            code: "input_delivery_failed",
            message: "The input transport could not deliver the button.",
            fix: "sim_stop -> sim_start -> run_app -> press_button(allowFocus=true)",
            details: details)
    }

    private func deliveryFailure(details: [String: JSONValue]? = nil) -> ToolError {
        ToolError(
            code: "input_delivery_failed",
            message: "The input transport could not deliver the button.",
            fix: "Restart the simulator, verify the selected input profile and Accessibility state, then retry.",
            details: details)
    }
}
