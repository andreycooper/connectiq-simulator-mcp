import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("MenuAutomation")
struct MenuAutomationTests {
    @Test("SDK AX fixtures lock the same prompt-field-default-button relationship", arguments: [
        "8.4.1", "9.1.0",
    ])
    func evidenceFixture(sdk: String) throws {
        let url = try #require(Bundle.module.url(
            forResource: sdk, withExtension: "json", subdirectory: "Fixtures/accessibility/gps"))
        let fixture = try JSONDecoder().decode(AXEvidenceFixture.self, from: Data(contentsOf: url))
        #expect(fixture.sdkVersion == sdk)
        #expect(fixture.sourceCaptureSha256 == [
            "8.4.1": "ca5c84d29e8bdae716f56e9ad86d52aa3f42d2731453fdc15b9946e593b80e4c",
            "9.1.0": "9d33e6da266159a6449b5c43064ed005955d484cb41924471a9eeda26f7fcf01",
        ][sdk])
        #expect(fixture.menuPath == ["Settings", "Set Position"])
        #expect(fixture.dialog.children.filter {
            $0.role == "AXStaticText" && $0.value
                == "Enter the current position in decimal degrees (latitude, longitude)"
        }.count == 1)
        #expect(fixture.dialog.allNodes.filter { $0.role == "AXTextField" }.count == 1)
        #expect(fixture.dialog.children.filter { $0.role == "AXTextField" }.count == 1)
        #expect(fixture.defaultButton.relationship == "direct child")
        #expect(fixture.defaultButton.role == "AXButton")
        #expect(fixture.defaultButton.actions.contains("AXPress"))
    }

    @Test("coordinates are validated before Accessibility is touched", arguments: [
        (Double.nan, 0.0), (.infinity, 0.0), (-.infinity, 0.0),
        (-90.000_001, 0.0), (90.000_001, 0.0), (0.0, -180.000_001),
        (0.0, 180.000_001),
    ])
    func invalidCoordinates(latitude: Double, longitude: Double) async {
        let ax = FixtureAX()
        await #expect(throws: ToolError.self) {
            _ = try await MenuAutomation(accessibility: ax)
                .setPosition(latitude: latitude, longitude: longitude, simulatorPid: 42)
        }
        #expect(await ax.applicationRequests.isEmpty)
    }

    @Test("coordinate boundaries and shortest round-trip tokens are accepted")
    func boundariesAndTokens() async throws {
        let ax = FixtureAX()
        let result = try await MenuAutomation(accessibility: ax)
            .setPosition(latitude: -90, longitude: 180, simulatorPid: 42)
        #expect(result == SetGpsPositionResult(latitude: -90, longitude: 180, simulatorPid: 42))
        #expect(await ax.setValues == ["-90.0, 180.0"])
        #expect(await ax.events.suffix(3) == [
            "settable:9:AXValue", "set:9:AXValue:-90.0, 180.0", "press:10:AXPress",
        ])
    }

    @Test("reordered traversal selects the exact prompt and its unique direct-child field")
    func reorderedTraversal() async throws {
        let ax = FixtureAX(dialogChildren: [FixtureAX.button, FixtureAX.field, FixtureAX.prompt])
        _ = try await MenuAutomation(accessibility: ax)
            .setPosition(latitude: 48.1351, longitude: 11.582, simulatorPid: 42)
        #expect(await ax.setElements == [FixtureAX.field])
        #expect(await ax.performedActions.contains("10:AXPress"))
    }

    @Test("missing Accessibility permission is actionable")
    func permission() async {
        let ax = FixtureAX(trusted: false)
        let error = await toolError {
            _ = try await MenuAutomation(accessibility: ax)
                .setPosition(latitude: 1, longitude: 2, simulatorPid: 42)
        }
        #expect(error?.code == "permission_denied")
        #expect(error?.fix.contains("Accessibility") == true)
    }

    @Test("menu and new-dialog cardinality mismatches fail closed", arguments: [
        FixtureMutation.missingSettings,
        .duplicateSettings,
        .missingSetPosition,
        .duplicateSetPosition,
        .noNewDialog,
        .multipleNewDialogs,
    ])
    func cardinality(mutation: FixtureMutation) async {
        let ax = FixtureAX(mutation: mutation)
        let error = await toolError {
            _ = try await MenuAutomation(accessibility: ax, timeout: .milliseconds(2), pollInterval: .milliseconds(1))
                .setPosition(latitude: 1, longitude: 2, simulatorPid: 42)
        }
        #expect(error?.code == "ax_contract_mismatch")
        #expect(error?.fix.isEmpty == false)
    }

    @Test("missing or wrong-type AXWindows is a contract mismatch with selector metadata", arguments: [
        FixtureMutation.missingWindows,
        .wrongTypeWindows,
    ])
    func windowsContract(mutation: FixtureMutation) async {
        let error = await toolError {
            _ = try await MenuAutomation(accessibility: FixtureAX(mutation: mutation))
                .setPosition(
                    latitude: 1, longitude: 2, simulatorPid: 42,
                    sdkVersion: "9.1.0")
        }
        #expect(error?.code == "ax_contract_mismatch")
        #expect(error?.details?["sdkVersion"] == "9.1.0")
        #expect(error?.details?["attribute"] == "AXWindows")
        #expect(error?.details?["role"] == "AXWindow")
        #expect(error?.details?["title"] == .null)
        #expect(error?.details?["identifier"] == .null)
    }

    @Test("the evidence-backed one-second AX messaging timeout is applied before traversal")
    func messagingTimeout() async throws {
        let ax = FixtureAX()
        _ = try await MenuAutomation(accessibility: ax)
            .setPosition(latitude: 1, longitude: 2, simulatorPid: 42)
        #expect(await ax.messagingTimeouts == [1.0])
        #expect(await ax.events.prefix(1) == ["timeout:1.0"])
    }

    @Test("dialog selector failures are closed", arguments: [
        FixtureMutation.missingPrompt,
        .duplicatePrompt,
        .missingField,
        .duplicateField,
        .fieldUnderWrongParent,
    ])
    func dialogSelector(mutation: FixtureMutation) async {
        let error = await toolError {
            _ = try await MenuAutomation(accessibility: FixtureAX(mutation: mutation))
                .setPosition(latitude: 1, longitude: 2, simulatorPid: 42)
        }
        #expect(error?.code == "ax_contract_mismatch")
    }

    @Test("field set failures are checked", arguments: [
        FixtureMutation.fieldNotSettable,
        .fieldSetFails,
    ])
    func fieldSetFailures(mutation: FixtureMutation) async {
        let error = await toolError {
            _ = try await MenuAutomation(accessibility: FixtureAX(mutation: mutation))
                .setPosition(latitude: 1, longitude: 2, simulatorPid: 42)
        }
        #expect(error?.code == (mutation == .fieldNotSettable ? "ax_contract_mismatch" : "ax_call_failed"))
        #expect(error?.fix.isEmpty == false)
    }

    @Test("readback failures have stable failure kinds", arguments: [
        (FixtureMutation.nonStringReadback, "value_type"),
        (.malformedReadback, "combined_value_format"),
        (.numericMismatch, "numeric_mismatch"),
    ])
    func readback(mutation: FixtureMutation, failureKind: String) async {
        let error = await toolError {
            _ = try await MenuAutomation(accessibility: FixtureAX(mutation: mutation))
                .setPosition(latitude: 48.1351, longitude: 11.582, simulatorPid: 42)
        }
        #expect(error?.code == "ax_contract_mismatch")
        #expect(error?.details?["failureKind"] == .string(failureKind))
    }

    @Test("strict grammar rejects alternate separators, whitespace, extra data, and invalid tokens", arguments: [
        "1.0,2.0", "1.0 , 2.0", "1.0,  2.0", " 1.0, 2.0", "1.0, 2.0 ",
        "1.0; 2.0", "1.0, 2.0, 3.0", "+1.0, 2.0", "01.0, 2.0", "1., 2.0",
        "1.0, NaN", "1.0, inf", "1,0, 2,0",
    ])
    func strictGrammar(value: String) async {
        let ax = FixtureAX(readbackOverride: .string(value))
        let error = await toolError {
            _ = try await MenuAutomation(accessibility: ax)
                .setPosition(latitude: 1, longitude: 2, simulatorPid: 42)
        }
        #expect(error?.details?["failureKind"] == "combined_value_format")
    }

    @Test("default button contract is checked", arguments: [
        FixtureMutation.missingDefaultButton,
        .wrongTypeDefaultButton,
        .nonChildDefaultButton,
        .wrongRoleDefaultButton,
        .missingPressAction,
        .pressFails,
        .dialogDoesNotClose,
    ])
    func defaultButton(mutation: FixtureMutation) async {
        let error = await toolError {
            _ = try await MenuAutomation(
                accessibility: FixtureAX(mutation: mutation),
                timeout: .milliseconds(2), pollInterval: .milliseconds(1))
                .setPosition(latitude: 1, longitude: 2, simulatorPid: 42)
        }
        #expect(error?.code == (mutation == .pressFails ? "ax_call_failed" : "ax_contract_mismatch"))
        #expect(error?.fix.isEmpty == false)
    }

    @Test("cancellation interrupts dialog polling without translation")
    func cancellation() async {
        let clock = FakeClock()
        let automation = MenuAutomation(
            accessibility: FixtureAX(mutation: .noNewDialog),
            timeout: .seconds(10), pollInterval: .seconds(1), clock: clock)
        let task = Task {
            try await automation.setPosition(
                latitude: 1, longitude: 2, simulatorPid: 42)
        }
        var beganPolling = false
        for _ in 0..<10_000 {
            if clock.pendingSleepCount > 0 {
                beganPolling = true
                break
            }
            await Task.yield()
        }
        #expect(beganPolling, "automation did not reach its cancellable poll")
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled GPS automation unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation remains cancellation at the service boundary.
        } catch {
            Issue.record("cancellation was translated to \(error)")
        }
    }

    @Test("each raw AX operation failure is translated with operation details", arguments: AXOperation.allCases)
    func rawAXFailures(operation: AXOperation) async {
        let ax = FixtureAX(failingOperation: operation)
        let error = await toolError {
            _ = try await MenuAutomation(accessibility: ax)
                .setPosition(latitude: 1, longitude: 2, simulatorPid: 42)
        }
        #expect(error?.code == "ax_call_failed")
        #expect(error?.details?["operation"] == .string(operation.rawValue))
        #expect(error?.fix.isEmpty == false)
    }
}

private struct AXEvidenceFixture: Decodable {
    let sdkVersion: String
    let menuPath: [String]
    let sourceCaptureSha256: String
    let dialog: AXEvidenceNode
    let defaultButton: AXEvidenceDefaultButton
}

private struct AXEvidenceDefaultButton: Decodable {
    let relationship: String
    let role: String
    let actions: [String]
}

private struct AXEvidenceNode: Decodable {
    let role: String
    let value: String?
    let actions: [String]
    let children: [AXEvidenceNode]

    var allNodes: [AXEvidenceNode] {
        [self] + children.flatMap(\.allNodes)
    }
}

private func toolError(_ body: () async throws -> Void) async -> ToolError? {
    do { try await body(); return nil }
    catch let error as ToolError { return error }
    catch { Issue.record("unexpected error: \(error)"); return nil }
}

enum FixtureMutation: Sendable {
    case missingSettings, duplicateSettings, missingSetPosition, duplicateSetPosition
    case noNewDialog, multipleNewDialogs, missingWindows, wrongTypeWindows
    case missingPrompt, duplicatePrompt, missingField, duplicateField, fieldUnderWrongParent
    case fieldNotSettable, fieldSetFails
    case nonStringReadback, malformedReadback, numericMismatch
    case missingDefaultButton, wrongTypeDefaultButton, nonChildDefaultButton
    case wrongRoleDefaultButton, missingPressAction, pressFails, dialogDoesNotClose
}

private actor FixtureAX: AXAccessing {
    static let app = AXElementID(1), menuBar = AXElementID(2), settings = AXElementID(3)
    static let settings2 = AXElementID(30), settingsMenu = AXElementID(4)
    static let setPosition = AXElementID(5), setPosition2 = AXElementID(50)
    static let oldWindow = AXElementID(6), dialog = AXElementID(7), dialog2 = AXElementID(70)
    static let prompt = AXElementID(8), prompt2 = AXElementID(80)
    static let field = AXElementID(9), field2 = AXElementID(90), nested = AXElementID(91)
    static let button = AXElementID(10), other = AXElementID(11)

    let trusted: Bool
    let mutation: FixtureMutation?
    let dialogChildren: [AXElementID]
    let readbackOverride: AXAttributeValue?
    let failingOperation: AXOperation?
    var applicationRequests: [Int32] = []
    var setValues: [String] = []
    var setElements: [AXElementID] = []
    var performedActions: [String] = []
    var events: [String] = []
    var messagingTimeouts: [Float] = []
    var opened = false
    var closed = false

    init(
        trusted: Bool = true,
        mutation: FixtureMutation? = nil,
        dialogChildren: [AXElementID] = [FixtureAX.prompt, FixtureAX.field, FixtureAX.button],
        readbackOverride: AXAttributeValue? = nil,
        failingOperation: AXOperation? = nil
    ) {
        self.trusted = trusted
        self.mutation = mutation
        self.dialogChildren = dialogChildren
        self.readbackOverride = readbackOverride
        self.failingOperation = failingOperation
    }

    func accessibilityTrusted() -> Bool { trusted }

    func application(pid: Int32) throws -> AXElementID {
        try fail(.createApplication)
        applicationRequests.append(pid)
        return Self.app
    }

    func setMessagingTimeout(_ seconds: Float, for element: AXElementID) throws {
        try fail(.setMessagingTimeout)
        messagingTimeouts.append(seconds)
        events.append("timeout:\(seconds)")
    }

    func copyAttribute(_ attribute: String, of element: AXElementID) throws -> AXAttributeValue {
        try fail(.copyAttribute)
        switch (element, attribute) {
        case (Self.app, "AXMenuBar"): return .element(Self.menuBar)
        case (Self.app, "AXWindows"):
            if mutation == .missingWindows { return .missing }
            if mutation == .wrongTypeWindows { return .string("not windows") }
            if mutation == .noNewDialog || !opened { return .elements([Self.oldWindow]) }
            if mutation == .multipleNewDialogs { return .elements([Self.oldWindow, Self.dialog, Self.dialog2]) }
            return .elements(closed ? [Self.oldWindow] : [Self.oldWindow, Self.dialog])
        case (Self.settings, "AXRole"), (Self.settings2, "AXRole"): return .string("AXMenuBarItem")
        case (Self.settings, "AXTitle"), (Self.settings2, "AXTitle"): return .string("Settings")
        case (Self.setPosition, "AXRole"), (Self.setPosition2, "AXRole"): return .string("AXMenuItem")
        case (Self.setPosition, "AXTitle"), (Self.setPosition2, "AXTitle"): return .string("Set Position")
        case (Self.dialog, "AXRole"), (Self.dialog2, "AXRole"): return .string("AXWindow")
        case (Self.prompt, "AXRole"), (Self.prompt2, "AXRole"): return .string("AXStaticText")
        case (Self.prompt, "AXValue"), (Self.prompt2, "AXValue"):
            return .string("Enter the current position in decimal degrees (latitude, longitude)")
        case (Self.field, "AXRole"), (Self.field2, "AXRole"): return .string("AXTextField")
        case (Self.nested, "AXRole"): return .string("AXGroup")
        case (Self.field, "AXValue"):
            if let readbackOverride { return readbackOverride }
            if mutation == .nonStringReadback { return .bool(true) }
            if mutation == .malformedReadback { return .string("1.0,2.0") }
            if mutation == .numericMismatch { return .string("48.1352, 11.582") }
            return .string(setValues.last ?? "0.000000, 0.000000")
        case (Self.dialog, "AXDefaultButton"):
            if mutation == .missingDefaultButton { return .missing }
            if mutation == .wrongTypeDefaultButton { return .string("OK") }
            if mutation == .nonChildDefaultButton { return .element(Self.other) }
            return .element(Self.button)
        case (Self.button, "AXRole"):
            return .string(mutation == .wrongRoleDefaultButton ? "AXStaticText" : "AXButton")
        case (Self.other, "AXRole"): return .string("AXButton")
        default: return .missing
        }
    }

    func copyChildren(of element: AXElementID) throws -> [AXElementID] {
        try fail(.copyAttributeValues)
        switch element {
        case Self.menuBar:
            if mutation == .missingSettings { return [] }
            if mutation == .duplicateSettings { return [Self.settings, Self.settings2] }
            return [Self.settings]
        case Self.settings: return [Self.settingsMenu]
        case Self.settings2: return []
        case Self.settingsMenu:
            if mutation == .missingSetPosition { return [] }
            if mutation == .duplicateSetPosition { return [Self.setPosition, Self.setPosition2] }
            return [Self.setPosition]
        case Self.dialog:
            var children = dialogChildren
            if mutation == .missingPrompt { children.removeAll { $0 == Self.prompt } }
            if mutation == .duplicatePrompt { children.append(Self.prompt2) }
            if mutation == .missingField { children.removeAll { $0 == Self.field } }
            if mutation == .duplicateField { children.append(Self.field2) }
            if mutation == .fieldUnderWrongParent {
                children.removeAll { $0 == Self.field }
                children.append(Self.nested)
            }
            if mutation == .nonChildDefaultButton { children.removeAll { $0 == Self.other } }
            return children
        case Self.nested: return mutation == .fieldUnderWrongParent ? [Self.field] : []
        default: return []
        }
    }

    func actions(of element: AXElementID) throws -> [String] {
        try fail(.copyActions)
        if element == Self.setPosition || element == Self.setPosition2 { return ["AXPress"] }
        if element == Self.button { return mutation == .missingPressAction ? [] : ["AXPress"] }
        return []
    }

    func isAttributeSettable(_ attribute: String, of element: AXElementID) throws -> Bool {
        try fail(.isAttributeSettable)
        events.append("settable:\(element.rawValue):\(attribute)")
        return mutation != .fieldNotSettable
    }

    func setString(_ value: String, attribute: String, of element: AXElementID) throws {
        try fail(.setAttribute)
        if mutation == .fieldSetFails { throw AXCallFailure(operation: .setAttribute, axError: -25204) }
        setValues.append(value)
        setElements.append(element)
        events.append("set:\(element.rawValue):\(attribute):\(value)")
    }

    func perform(_ action: String, on element: AXElementID) throws {
        try fail(.performAction)
        performedActions.append("\(element.rawValue):\(action)")
        if element == Self.setPosition || element == Self.setPosition2 { opened = true }
        if element == Self.button {
            if mutation == .pressFails { throw AXCallFailure(operation: .performAction, axError: -25204) }
            if mutation != .dialogDoesNotClose { closed = true }
            events.append("press:\(element.rawValue):\(action)")
        }
    }

    private func fail(_ operation: AXOperation) throws {
        if failingOperation == operation {
            throw AXCallFailure(operation: operation, axError: -25204)
        }
    }
}
