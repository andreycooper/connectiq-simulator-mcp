// ApplicationServices imports mutable framework globals and non-Sendable AX
// references. The live actor below is the sole owner of those references;
// callers exchange only Sendable integer handles and typed value snapshots.
@preconcurrency import ApplicationServices
import Foundation

struct AXElementID: Hashable, Sendable {
    let rawValue: Int
    init(_ rawValue: Int) { self.rawValue = rawValue }
}

enum AXAttributeValue: Equatable, Sendable {
    case string(String)
    case element(AXElementID)
    case elements([AXElementID])
    case bool(Bool)
    case missing
    case unsupportedType(String)

    var typeName: String {
        switch self {
        case .string: "string"
        case .element: "element"
        case .elements: "elements"
        case .bool: "bool"
        case .missing: "missing"
        case .unsupportedType(let type): "unsupported:\(type)"
        }
    }
}

enum AXOperation: String, CaseIterable, Sendable {
    case createApplication = "AXUIElementCreateApplication"
    case setMessagingTimeout = "AXUIElementSetMessagingTimeout"
    case copyAttribute = "AXUIElementCopyAttributeValue"
    case copyAttributeValues = "AXUIElementCopyAttributeValues"
    case copyActions = "AXUIElementCopyActionNames"
    case isAttributeSettable = "AXUIElementIsAttributeSettable"
    case setAttribute = "AXUIElementSetAttributeValue"
    case performAction = "AXUIElementPerformAction"
}

struct AXCallFailure: Error, Equatable, Sendable {
    let operation: AXOperation
    let axError: Int32
    let attribute: String?

    init(operation: AXOperation, axError: Int32, attribute: String? = nil) {
        self.operation = operation
        self.axError = axError
        self.attribute = attribute
    }
}

protocol AXAccessing: Actor {
    func accessibilityTrusted() -> Bool
    func application(pid: Int32) throws -> AXElementID
    func setMessagingTimeout(_ seconds: Float, for element: AXElementID) throws
    func copyAttribute(_ attribute: String, of element: AXElementID) throws -> AXAttributeValue
    func copyChildren(of element: AXElementID) throws -> [AXElementID]
    func actions(of element: AXElementID) throws -> [String]
    func isAttributeSettable(_ attribute: String, of element: AXElementID) throws -> Bool
    func setString(_ value: String, attribute: String, of element: AXElementID) throws
    func perform(_ action: String, on element: AXElementID) throws
}

actor LiveAXAccess: AXAccessing {
    private var nextID = 1
    private var elements: [AXElementID: AXUIElement] = [:]

    func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    func application(pid: Int32) throws -> AXElementID {
        register(AXUIElementCreateApplication(pid))
    }

    func setMessagingTimeout(_ seconds: Float, for element: AXElementID) throws {
        let error = AXUIElementSetMessagingTimeout(try resolve(element), seconds)
        try requireSuccess(error, operation: .setMessagingTimeout)
    }

    func copyAttribute(_ attribute: String, of element: AXElementID) throws -> AXAttributeValue {
        let source = try resolve(element)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(source, attribute as CFString, &raw)
        if error == .noValue || error == .attributeUnsupported { return .missing }
        try requireSuccess(error, operation: .copyAttribute, attribute: attribute)
        guard let raw else { return .missing }
        if CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return .element(register(unsafeDowncast(raw, to: AXUIElement.self)))
        }
        if let string = raw as? String { return .string(string) }
        if let values = raw as? [AXUIElement] {
            return .elements(values.map(register))
        }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return .bool(CFBooleanGetValue(unsafeDowncast(raw, to: CFBoolean.self)))
        }
        return .unsupportedType(String(describing: type(of: raw)))
    }

    func copyChildren(of element: AXElementID) throws -> [AXElementID] {
        let source = try resolve(element)
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(
            source, kAXChildrenAttribute as CFString, &count)
        if countError == .noValue || countError == .attributeUnsupported { return [] }
        try requireSuccess(
            countError, operation: .copyAttributeValues, attribute: kAXChildrenAttribute)
        guard count > 0 else { return [] }
        var raw: CFArray?
        let error = AXUIElementCopyAttributeValues(
            source, kAXChildrenAttribute as CFString, 0, count, &raw)
        try requireSuccess(error, operation: .copyAttributeValues, attribute: kAXChildrenAttribute)
        guard let raw else { return [] }
        let values = raw as NSArray
        var result: [AXElementID] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
                throw AXCallFailure(
                    operation: .copyAttributeValues,
                    axError: AXError.illegalArgument.rawValue,
                    attribute: kAXChildrenAttribute)
            }
            result.append(register(value as! AXUIElement))
        }
        return result
    }

    func actions(of element: AXElementID) throws -> [String] {
        var raw: CFArray?
        let error = AXUIElementCopyActionNames(try resolve(element), &raw)
        try requireSuccess(error, operation: .copyActions)
        return (raw as? [String]) ?? []
    }

    func isAttributeSettable(_ attribute: String, of element: AXElementID) throws -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(
            try resolve(element), attribute as CFString, &settable)
        try requireSuccess(error, operation: .isAttributeSettable, attribute: attribute)
        return settable.boolValue
    }

    func setString(_ value: String, attribute: String, of element: AXElementID) throws {
        let error = AXUIElementSetAttributeValue(
            try resolve(element), attribute as CFString, value as CFString)
        try requireSuccess(error, operation: .setAttribute, attribute: attribute)
    }

    func perform(_ action: String, on element: AXElementID) throws {
        let error = AXUIElementPerformAction(try resolve(element), action as CFString)
        try requireSuccess(error, operation: .performAction)
    }

    private func register(_ element: AXUIElement) -> AXElementID {
        if let existing = elements.first(where: { CFEqual($0.value, element) })?.key {
            return existing
        }
        let id = AXElementID(nextID)
        nextID += 1
        elements[id] = element
        return id
    }

    private func resolve(_ id: AXElementID) throws -> AXUIElement {
        guard let element = elements[id] else {
            throw AXCallFailure(operation: .copyAttribute, axError: AXError.invalidUIElement.rawValue)
        }
        return element
    }

    private func requireSuccess(
        _ error: AXError, operation: AXOperation, attribute: String? = nil
    ) throws {
        guard error == .success else {
            throw AXCallFailure(
                operation: operation, axError: error.rawValue, attribute: attribute)
        }
    }
}

struct MenuAutomation: Sendable {
    private static let instruction =
        "Enter the current position in decimal degrees (latitude, longitude)"
    private static let tokenPattern =
        #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?"#

    private let accessibility: any AXAccessing
    private let timeout: Duration
    private let pollInterval: Duration
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline

    init(
        accessibility: any AXAccessing = LiveAXAccess(),
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(25)
    ) {
        let clock = ContinuousClock()
        self.accessibility = accessibility
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    init<C: Clock>(
        accessibility: any AXAccessing,
        timeout: Duration,
        pollInterval: Duration,
        clock: C
    ) where C.Duration == Duration {
        self.accessibility = accessibility
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
    }

    func setPosition(
        latitude: Double,
        longitude: Double,
        simulatorPid: Int32,
        sdkVersion: String = "unknown"
    ) async throws -> SetGpsPositionResult {
        try Self.validate(latitude: latitude, longitude: longitude)
        do {
            try Task.checkCancellation()
            guard await accessibility.accessibilityTrusted() else {
                throw ToolError(
                    code: "permission_denied",
                    message: "Accessibility permission is required to set simulator GPS position.",
                    fix: Permissions.grantInstructions(
                        settingsPath: Permissions.accessibilitySettingsPath,
                        executablePath: SignatureInspector.currentExecutableURL().path))
            }
            let application = try await accessibility.application(pid: simulatorPid)
            try await accessibility.setMessagingTimeout(1, for: application)
            let windowsBefore = Set(try await windows(of: application, sdkVersion: sdkVersion))
            let menuBar = try await requiredElement("AXMenuBar", of: application, sdkVersion: sdkVersion)
            let settings = try await uniqueDescendant(
                of: menuBar, role: "AXMenuBarItem", title: "Settings",
                sdkVersion: sdkVersion, relationship: "simulator menu bar")
            let setPosition = try await uniqueDescendant(
                of: settings, role: "AXMenuItem", title: "Set Position",
                sdkVersion: sdkVersion, relationship: "Settings menu")
            try await requireAction("AXPress", on: setPosition, sdkVersion: sdkVersion)
            try await accessibility.perform("AXPress", on: setPosition)

            let dialog = try await waitForNewDialog(
                application: application, before: windowsBefore, sdkVersion: sdkVersion)
            let directChildren = try await accessibility.copyChildren(of: dialog)
            let instructionMatches = try await directChildren.asyncFilter {
                let role = try await string("AXRole", of: $0)
                let value = try await string("AXValue", of: $0)
                return role == "AXStaticText" && value == Self.instruction
            }
            guard instructionMatches.count == 1 else {
                throw contractMismatch(
                    "The GPS dialog did not contain exactly one direct-child decimal-degrees instruction.",
                    fix: "Use a supported Connect IQ SDK with the approved GPS dialog contract, then retry.",
                    sdkVersion: sdkVersion, attribute: "AXValue",
                    role: "AXStaticText", title: nil,
                    extra: ["matchCount": .int(instructionMatches.count)])
            }
            let subtree = try await descendants(of: dialog)
            let fields = try await subtree.asyncFilter {
                try await string("AXRole", of: $0) == "AXTextField"
            }
            guard fields.count == 1, directChildren.contains(fields[0]) else {
                throw contractMismatch(
                    "The GPS dialog did not contain exactly one direct-child coordinate text field.",
                    fix: "Use a supported Connect IQ SDK with the approved combined GPS field contract, then retry.",
                    sdkVersion: sdkVersion, attribute: "AXRole",
                    role: "AXTextField", title: nil,
                    extra: ["matchCount": .int(fields.count)])
            }
            let field = fields[0]
            guard try await accessibility.isAttributeSettable("AXValue", of: field) else {
                throw contractMismatch(
                    "The approved GPS coordinate field is not settable.",
                    fix: "Close the GPS dialog, restart the supported simulator, and retry.",
                    sdkVersion: sdkVersion, attribute: "AXValue", role: "AXTextField", title: nil)
            }
            let combined = "\(latitude.description), \(longitude.description)"
            guard Self.validToken(latitude.description), Self.validToken(longitude.description) else {
                throw ToolError(
                    code: "internal_error",
                    message: "Swift generated a coordinate token outside the approved ASCII grammar.",
                    fix: "Report the coordinate and Swift runtime version to simulator-mcp maintainers.")
            }
            try await accessibility.setString(combined, attribute: "AXValue", of: field)
            try verifyReadback(
                try await accessibility.copyAttribute("AXValue", of: field),
                latitude: latitude, longitude: longitude, sdkVersion: sdkVersion)

            let buttonValue = try await accessibility.copyAttribute("AXDefaultButton", of: dialog)
            guard case .element(let button) = buttonValue else {
                throw contractMismatch(
                    "The GPS dialog default button attribute was missing or was not an AX element.",
                    fix: "Use a supported Connect IQ SDK whose GPS dialog exposes AXDefaultButton, then retry.",
                    sdkVersion: sdkVersion, attribute: "AXDefaultButton",
                    role: "AXButton", title: nil)
            }
            guard directChildren.contains(button), try await string("AXRole", of: button) == "AXButton" else {
                throw contractMismatch(
                    "The GPS dialog default button was not a direct-child AXButton.",
                    fix: "Use a supported Connect IQ SDK with the approved default-button relationship, then retry.",
                    sdkVersion: sdkVersion, attribute: "AXDefaultButton",
                    role: "AXButton", title: nil)
            }
            try await requireAction("AXPress", on: button, sdkVersion: sdkVersion)
            try await accessibility.perform("AXPress", on: button)
            try await waitForDialogToClose(
                dialog, application: application, sdkVersion: sdkVersion)
            return SetGpsPositionResult(
                latitude: latitude, longitude: longitude, simulatorPid: simulatorPid)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolError {
            throw error
        } catch let error as AXCallFailure {
            throw ToolError(
                code: "ax_call_failed",
                message: "Accessibility operation \(error.operation.rawValue) failed with AXError \(error.axError).",
                fix: "Verify Accessibility permission, close any open simulator dialogs, restart the supported simulator, and retry.",
                details: [
                    "operation": .string(error.operation.rawValue),
                    "axError": .int(Int(error.axError)),
                    "attribute": error.attribute.map(JSONValue.string) ?? .null,
                    "sdkVersion": .string(sdkVersion),
                ])
        } catch {
            Log.err("GPS Accessibility automation failed: \(String(reflecting: error))")
            throw ToolError(
                code: "internal_error",
                message: "GPS Accessibility automation failed unexpectedly.",
                fix: "Retry once; if it repeats, inspect simulator-mcp stderr and report the failure.")
        }
    }

    static func validate(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite,
            (-90.0 ... 90.0).contains(latitude),
            (-180.0 ... 180.0).contains(longitude)
        else {
            throw ToolError(
                code: "invalid_arguments",
                message: "GPS coordinates must be finite with latitude in -90...90 and longitude in -180...180.",
                fix: "Pass finite decimal-degree coordinates inside the declared latitude and longitude ranges.")
        }
    }

    private func waitForNewDialog(
        application: AXElementID, before: Set<AXElementID>, sdkVersion: String
    ) async throws -> AXElementID {
        let deadline = makeDeadline(timeout)
        while true {
            try Task.checkCancellation()
            let current = Set(try await windows(of: application, sdkVersion: sdkVersion))
            let new = current.subtracting(before)
            if new.count > 1 {
                throw contractMismatch(
                    "The Set Position action opened multiple new simulator windows.",
                    fix: "Close every simulator dialog, then retry Set Position once.",
                    sdkVersion: sdkVersion, attribute: "AXWindows", role: "AXWindow", title: nil,
                    extra: ["newWindowCount": .int(new.count)])
            }
            if let only = new.first {
                guard try await string("AXRole", of: only) == "AXWindow" else {
                    throw contractMismatch(
                        "The Set Position action created a non-window AX element.",
                        fix: "Restart the supported simulator and retry.",
                        sdkVersion: sdkVersion, attribute: "AXRole", role: "AXWindow", title: nil)
                }
                return only
            }
            guard !deadline.hasExpired else {
                throw contractMismatch(
                    "The Set Position action did not open exactly one new simulator window before the monotonic deadline.",
                    fix: "Close simulator dialogs, verify Accessibility permission, and retry.",
                    sdkVersion: sdkVersion, attribute: "AXWindows", role: "AXWindow", title: nil,
                    extra: ["newWindowCount": .int(0)])
            }
            try await deadline.sleepUntilNextPoll(maximumInterval: pollInterval)
        }
    }

    private func waitForDialogToClose(
        _ dialog: AXElementID, application: AXElementID, sdkVersion: String
    ) async throws {
        let deadline = makeDeadline(timeout)
        while true {
            try Task.checkCancellation()
            if !(try await windows(of: application, sdkVersion: sdkVersion)).contains(dialog) { return }
            guard !deadline.hasExpired else {
                throw contractMismatch(
                    "The exact GPS dialog remained present after its checked default-button press.",
                    fix: "Close the dialog manually, restart the supported simulator, and retry.",
                    sdkVersion: sdkVersion, attribute: "AXWindows", role: "AXWindow", title: nil)
            }
            try await deadline.sleepUntilNextPoll(maximumInterval: pollInterval)
        }
    }

    private func requiredElement(
        _ attribute: String, of element: AXElementID, sdkVersion: String
    ) async throws -> AXElementID {
        guard case .element(let result) = try await accessibility.copyAttribute(attribute, of: element) else {
            throw contractMismatch(
                "The simulator Accessibility tree did not expose required attribute \(attribute).",
                fix: "Restart the supported simulator, verify Accessibility permission, and retry.",
                sdkVersion: sdkVersion, attribute: attribute, role: nil, title: nil)
        }
        return result
    }

    private func windows(
        of application: AXElementID, sdkVersion: String
    ) async throws -> [AXElementID] {
        let observed = try await accessibility.copyAttribute("AXWindows", of: application)
        guard case .elements(let values) = observed else {
            throw contractMismatch(
                "The simulator Accessibility application did not expose AXWindows as an element array.",
                fix: "Restart the supported simulator, verify Accessibility permission, and retry.",
                sdkVersion: sdkVersion, attribute: "AXWindows",
                role: "AXWindow", title: nil,
                extra: ["observedType": .string(observed.typeName)])
        }
        return values
    }

    private func string(_ attribute: String, of element: AXElementID) async throws -> String? {
        guard case .string(let value) = try await accessibility.copyAttribute(attribute, of: element) else {
            return nil
        }
        return value
    }

    private func uniqueDescendant(
        of root: AXElementID,
        role: String,
        title: String,
        sdkVersion: String,
        relationship: String
    ) async throws -> AXElementID {
        let matches = try await descendants(of: root).asyncFilter {
            let observedRole = try await string("AXRole", of: $0)
            let observedTitle = try await string("AXTitle", of: $0)
            return observedRole == role && observedTitle == title
        }
        guard matches.count == 1 else {
            throw contractMismatch(
                "Expected exactly one \(role) titled '\(title)' in the \(relationship); found \(matches.count).",
                fix: "Close simulator menus and dialogs, use a supported SDK, then retry the exact Settings > Set Position path.",
                sdkVersion: sdkVersion, attribute: "AXTitle", role: role, title: title,
                extra: ["matchCount": .int(matches.count)])
        }
        return matches[0]
    }

    private func descendants(of root: AXElementID) async throws -> [AXElementID] {
        var result: [AXElementID] = []
        var pending: [(AXElementID, Int)] = try await accessibility.copyChildren(of: root)
            .map { ($0, 1) }
        var visited: Set<AXElementID> = [root]
        while let (element, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard depth <= 16, result.count < 512 else {
                throw ToolError(
                    code: "ax_contract_mismatch",
                    message: "The simulator Accessibility tree exceeded the approved traversal bounds.",
                    fix: "Close extra simulator dialogs, restart the supported simulator, and retry.")
            }
            guard visited.insert(element).inserted else { continue }
            result.append(element)
            pending.append(contentsOf: try await accessibility.copyChildren(of: element).map { ($0, depth + 1) })
        }
        return result
    }

    private func requireAction(
        _ action: String, on element: AXElementID, sdkVersion: String
    ) async throws {
        guard try await accessibility.actions(of: element).contains(action) else {
            throw contractMismatch(
                "The selected Accessibility element does not advertise required action \(action).",
                fix: "Use a supported Connect IQ SDK exposing the approved Accessibility action, then retry.",
                sdkVersion: sdkVersion, attribute: "AXActions", role: nil, title: nil)
        }
    }

    private func verifyReadback(
        _ value: AXAttributeValue,
        latitude: Double,
        longitude: Double,
        sdkVersion: String
    ) throws {
        guard case .string(let combined) = value else {
            throw contractMismatch(
                "The GPS coordinate field readback was not a string.",
                fix: "Use a supported SDK whose combined GPS field exposes a string AXValue, then retry.",
                sdkVersion: sdkVersion, attribute: "AXValue", role: "AXTextField", title: nil,
                extra: ["failureKind": "value_type"])
        }
        let components = combined.components(separatedBy: ", ")
        guard components.count == 2,
            !components[0].isEmpty, !components[1].isEmpty,
            Self.validToken(components[0]), Self.validToken(components[1]),
            let parsedLatitude = Double(components[0]),
            let parsedLongitude = Double(components[1]),
            parsedLatitude.isFinite, parsedLongitude.isFinite
        else {
            throw contractMismatch(
                "The GPS coordinate field readback did not match the exact '<latitude>, <longitude>' ASCII grammar.",
                fix: "Close the dialog, use a supported SDK with the approved combined GPS value grammar, and retry.",
                sdkVersion: sdkVersion, attribute: "AXValue", role: "AXTextField", title: nil,
                extra: ["failureKind": "combined_value_format"])
        }
        guard parsedLatitude == latitude, parsedLongitude == longitude else {
            throw contractMismatch(
                "The GPS coordinate field readback was numerically different from the requested coordinates.",
                fix: "Close the dialog and retry the exact requested coordinates without locale-specific formatting.",
                sdkVersion: sdkVersion, attribute: "AXValue", role: "AXTextField", title: nil,
                extra: ["failureKind": "numeric_mismatch"])
        }
    }

    private static func validToken(_ token: String) -> Bool {
        token.range(
            of: "\\A\(tokenPattern)\\z",
            options: .regularExpression,
            range: token.startIndex ..< token.endIndex,
            locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    private func contractMismatch(
        _ message: String,
        fix: String,
        sdkVersion: String,
        attribute: String?,
        role: String?,
        title: String?,
        extra: [String: JSONValue] = [:]
    ) -> ToolError {
        var details: [String: JSONValue] = [
            "sdkVersion": .string(sdkVersion),
            "attribute": attribute.map(JSONValue.string) ?? .null,
            "role": role.map(JSONValue.string) ?? .null,
            "title": title.map(JSONValue.string) ?? .null,
            "identifier": .null,
        ]
        details.merge(extra) { _, replacement in replacement }
        return ToolError(
            code: "ax_contract_mismatch", message: message, fix: fix, details: details)
    }
}

private extension Array where Element == AXElementID {
    func asyncFilter(
        _ predicate: (AXElementID) async throws -> Bool
    ) async rethrows -> [AXElementID] {
        var result: [AXElementID] = []
        for element in self where try await predicate(element) { result.append(element) }
        return result
    }
}

struct GpsPositionOperationRunner: Sendable {
    typealias Body = @Sendable (OperationContext) async throws -> SetGpsPositionResult
    private let runBody: @Sendable (
        SimOperation, OperationRequirement, @escaping Body
    ) async throws -> SetGpsPositionResult

    init(controller: SimulatorController) {
        runBody = { operation, requirement, body in
            try await controller.withOperation(
                operation, requirement: requirement, body: body)
        }
    }

    init(
        _ run: @escaping @Sendable (
            SimOperation, OperationRequirement, @escaping Body
        ) async throws -> SetGpsPositionResult
    ) {
        runBody = run
    }

    func run(
        _ operation: SimOperation,
        requirement: OperationRequirement,
        body: @escaping Body
    ) async throws -> SetGpsPositionResult {
        try await runBody(operation, requirement, body)
    }
}

struct GpsPositionService: Sendable {
    private let operationRunner: GpsPositionOperationRunner
    private let automate: @Sendable (
        Double, Double, OperationContext
    ) async throws -> SetGpsPositionResult

    init(controller: SimulatorController) {
        let automation = MenuAutomation()
        self.init(
            operationRunner: GpsPositionOperationRunner(controller: controller),
            automate: { latitude, longitude, context in
                try await automation.setPosition(
                    latitude: latitude,
                    longitude: longitude,
                    simulatorPid: context.simulatorPid,
                    sdkVersion: context.sdk.version.description)
            })
    }

    init(
        operationRunner: GpsPositionOperationRunner,
        automate: @escaping @Sendable (
            Double, Double, OperationContext
        ) async throws -> SetGpsPositionResult
    ) {
        self.operationRunner = operationRunner
        self.automate = automate
    }

    func setPosition(_ request: SetGpsPositionToolRequest) async throws -> SetGpsPositionResult {
        try MenuAutomation.validate(
            latitude: request.latitude, longitude: request.longitude)
        return try await operationRunner.run(
            .setGpsPosition, requirement: .currentReady
        ) { context in
            try await automate(request.latitude, request.longitude, context)
        }
    }
}
