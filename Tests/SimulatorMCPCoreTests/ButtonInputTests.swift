import Foundation
@preconcurrency import ApplicationServices
import Testing
@testable import SimulatorMCPCore

@Suite("ButtonInput")
struct ButtonInputTests {
    @Test("all transport fixtures decode, equal their hand-built values, and have byte parity")
    func canonicalFixtures() throws {
        for name in ["protocol", "ax-keyboard-post", "focused-keys"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/inputprofiles"))
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(InputProfile.self, from: data)
            #expect(value == (try expectedProfile(name: name)))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(value)
            #expect(encoded == data)
        }
    }

    @Test("validation rejects unknown buttons and hold bounds before dispatch")
    func validation() async throws {
        let fake = RecordingTransport()
        let service = makeService(transport: fake)
        for request in [PressButtonToolRequest(button: "light"), PressButtonToolRequest(button: "up", holdMs: 49), PressButtonToolRequest(button: "up", holdMs: 5001)] {
            let error = await #expect(throws: ToolError.self) { try await service.press(request) }
            #expect(error?.code == "invalid_arguments")
        }
        #expect(fake.requests.isEmpty)
    }

    @Test("no current device, unsupported device, SDK, and button fail closed")
    func capabilityFailures() async throws {
        let fake = RecordingTransport()
        let profile = try expectedProfile(name: "protocol")
        let runner = ButtonOperationRunner { _, _, body in
            try await body(OperationContext(simulatorPid: 42, sdk: sdk("9.1.0"), currentDevice: nil, listeningEndpoints: []))
        }
        let noDevice = ButtonInputService(profile: profile, transport: fake, operationRunner: runner)
        #expect((await #expect(throws: ToolError.self) { try await noDevice.press(PressButtonToolRequest(button: "up")) })?.code == "no_current_device")

        let wrongDeviceRunner = ButtonOperationRunner { _, _, body in
            try await body(OperationContext(simulatorPid: 42, sdk: sdk("8.4.1"), currentDevice: "venu3", listeningEndpoints: []))
        }
        let wrongDevice = ButtonInputService(profile: profile, transport: fake, operationRunner: wrongDeviceRunner)
        #expect((await #expect(throws: ToolError.self) { try await wrongDevice.press(PressButtonToolRequest(button: "up")) })?.code == "input_unsupported")

        let wrongSDKRunner = ButtonOperationRunner { _, _, body in
            try await body(OperationContext(simulatorPid: 42, sdk: sdk("9.1.0"), currentDevice: "fenix6xpro", listeningEndpoints: []))
        }
        let wrongSDK = ButtonInputService(profile: profile, transport: fake, operationRunner: wrongSDKRunner)
        let sdkError = await #expect(throws: ToolError.self) { try await wrongSDK.press(PressButtonToolRequest(button: "up")) }
        #expect(sdkError?.message.contains("8.4.1") == true)

        let incomplete = InputProfile(core: profile.core, transport: .protocolShell(ProtocolShellProfile(sdkEntries: ["8.4.1": ["up": ["argv": .array([.string("--button"), .string("up")])]]], transcriptGrammar: ["successPattern": "ok", "errorPattern": "error"])))
        let missingButton = ButtonInputService(profile: incomplete, transport: fake, operationRunner: readyRunner())
        let mappingError = await #expect(throws: ToolError.self) { try await missingButton.press(PressButtonToolRequest(button: "enter")) }
        #expect(mappingError?.code == "input_unsupported")
    }

    @Test("focus opt-in is enforced and hold is forwarded exactly")
    func focusAndHold() async throws {
        let fake = RecordingTransport(requiresFocus: true)
        let service = makeService(transport: fake)
        let denied = await #expect(throws: ToolError.self) { try await service.press(PressButtonToolRequest(button: "up", holdMs: 300)) }
        #expect(denied?.code == "focus_required")
        let result = try await service.press(PressButtonToolRequest(button: "up", holdMs: 300, allowFocus: true))
        #expect(fake.requests == [ButtonPressRequest(button: "up", holdMs: 300)])
        #expect(result == PressButtonResult(button: "up", pressType: "hold", transport: "protocol", simulatorPid: 42))
        #expect(fake.downCount == 1)
        #expect(fake.upCount == 1)
    }

    @Test("deadline cancels a cancellation-aware transport and balances down/up")
    func deadlineBalancesCleanup() async throws {
        let fake = RecordingTransport(hang: true)
        let clock = FakeClock()
        let service = ButtonInputService(profile: try expectedProfile(name: "protocol"), transports: [fake], operationRunner: readyRunner(), clock: clock)
        let task = Task { try await service.press(PressButtonToolRequest(button: "up", holdMs: 1000)) }
        await clock.waitUntilPendingSleepCount(1)
        #expect(clock.pendingSleepCount == 1)
        clock.advance(by: .seconds(10) + .milliseconds(999))
        #expect(clock.pendingSleepCount == 1)
        #expect(clock.pendingSleepCount == 1)
        clock.advance(by: .milliseconds(1))
        let result = await task.result
        guard case .failure(let rawError) = result else {
            Issue.record("deadline unexpectedly succeeded")
            return
        }
        let error = try #require(rawError as? ToolError)
        #expect(error.code == "operation_timeout")
        #expect(fake.downCount == 1)
        #expect(fake.upCount == 1)
    }

    @Test("direct caller cancellation and transport failure both balance down/up")
    func cancellationAndFailureBalanceCleanup() async throws {
        let cancellationTransport = RecordingTransport(hang: true)
        let cancellationClock = FakeClock()
        let cancellationService = ButtonInputService(profile: try expectedProfile(name: "protocol"), transports: [cancellationTransport], operationRunner: readyRunner(), clock: cancellationClock)
        let task = Task { try await cancellationService.press(PressButtonToolRequest(button: "up", holdMs: 500)) }
        await cancellationClock.waitUntilPendingSleepCount(1)
        task.cancel()
        let cancellationResult = await task.result
        guard case .failure(let cancellationError) = cancellationResult else {
            Issue.record("direct cancellation unexpectedly succeeded")
            return
        }
        #expect(cancellationError is CancellationError)
        #expect(cancellationTransport.downCount == 1)
        #expect(cancellationTransport.upCount == 1)

        let failureTransport = RecordingTransport(error: ButtonInputTransportError.subprocess("raw failure"))
        let failureService = makeService(transport: failureTransport)
        _ = await #expect(throws: ToolError.self) { try await failureService.press(PressButtonToolRequest(button: "up")) }
        #expect(failureTransport.downCount == 1)
        #expect(failureTransport.upCount == 1)
    }

    @Test("runner dispatches pressButton and currentReady")
    func runnerContract() async throws {
        let observation = Observation()
        let runner = ButtonOperationRunner { operation, requirement, body in
            observation.operation = operation
            if case .currentReady = requirement { observation.requirement = "currentReady" }
            return try await body(OperationContext(simulatorPid: 42, sdk: sdk("8.4.1"), currentDevice: "fenix6xpro", listeningEndpoints: []))
        }
        let service = ButtonInputService(profile: try expectedProfile(name: "protocol"), transport: RecordingTransport(), operationRunner: runner)
        _ = try await service.press(PressButtonToolRequest(button: "up"))
        #expect(observation.operation == .pressButton)
        #expect(observation.requirement == "currentReady")
    }

    @Test("transport error families become stable errors without raw public interpolation")
    func translatedErrors() async throws {
        let cases: [(ButtonInputTransportError, String, String, String)] = [
            (.accessibilityDenied("secret"), "accessibility_denied", "Accessibility permission denied button delivery.", "Grant Accessibility permission to simulator-mcp, then retry."),
            (.accessibility("secret"), "input_delivery_failed", "The input transport could not deliver the button.", "Restart the simulator, verify the selected input profile and Accessibility state, then retry."),
            (.subprocess("secret"), "input_delivery_failed", "The input transport could not deliver the button.", "Restart the simulator, verify the selected input profile and Accessibility state, then retry."),
            (.workspaceActivation("secret"), "input_delivery_failed", "The input transport could not deliver the button.", "Restart the simulator, verify the selected input profile and Accessibility state, then retry."),
            (.eventPost("secret"), "input_delivery_failed", "The input transport could not deliver the button.", "Restart the simulator, verify the selected input profile and Accessibility state, then retry."),
        ]
        for (raw, code, message, fix) in cases {
            let fake = RecordingTransport(error: raw)
            let service = makeService(transport: fake)
            let error = await #expect(throws: ToolError.self) { try await service.press(PressButtonToolRequest(button: "up")) }
            #expect(error?.code == code)
            #expect(error?.message == message)
            #expect(error?.fix == fix)
            #expect(error?.details == nil)
        }

        let rawFake = RecordingTransport(error: NSError(domain: "secret-domain", code: 99, userInfo: [NSLocalizedDescriptionKey: "secret message", "details": "secret details"]))
        let rawError = await #expect(throws: ToolError.self) { try await makeService(transport: rawFake).press(PressButtonToolRequest(button: "up")) }
        #expect(rawError?.code == "input_delivery_failed")
        #expect(rawError?.message == "The input transport could not deliver the button.")
        #expect(rawError?.fix == "Restart the simulator, verify the selected input profile and Accessibility state, then retry.")
        #expect(rawError?.message.contains("secret") == false)
        #expect(rawError?.details == nil)
    }

    private func makeService(transport: RecordingTransport) -> ButtonInputService {
        ButtonInputService(profile: try! expectedProfile(name: "protocol"), transport: transport, operationRunner: readyRunner())
    }

    private func readyRunner() -> ButtonOperationRunner {
        ButtonOperationRunner { _, _, body in
            try await body(OperationContext(simulatorPid: 42, sdk: sdk("8.4.1"), currentDevice: "fenix6xpro", listeningEndpoints: []))
        }
    }

    private func sdk(_ version: String) -> SdkInfo {
        SdkInfo(version: SemVer(version)!, root: URL(fileURLWithPath: "/sdk/\(version)"), source: .installed)
    }

    private func expectedProfile(name: String) throws -> InputProfile {
        let buttons = ["enter", "up", "menu", "down", "esc"]
        let keyCodes: [String: Int] = ["enter": 36, "up": 126, "menu": 46, "down": 2, "esc": 53]
        let mappings = Dictionary(uniqueKeysWithValues: buttons.map { button in
            (button, ["keyCode": .int(keyCodes[button] ?? 0)] as [String: JSONValue])
        })
        let core = InputProfileCore(
            device: "fenix6xpro", profileVersion: "test/\(name == "protocol" ? "protocol" : name == "ax-keyboard-post" ? "ax" : "focused")/1", qualification: false,
            buttonOrder: buttons, holdEncoding: HoldEncoding(mechanism: "down-up"),
            evidence: ProfileEvidence(capturedOn: "2026-07-17", macOSVersion: "14.0", sdks: ["8.4.1"], surfaceDigests: [:], gateTranscriptDigests: [:]))
        switch name {
        case "protocol":
            let entries = Dictionary(uniqueKeysWithValues: buttons.map { ($0, ["argv": .array([.string("--button"), .string($0)])] as [String: JSONValue]) })
            return InputProfile(core: core, transport: .protocolShell(ProtocolShellProfile(sdkEntries: ["8.4.1": entries], transcriptGrammar: ["errorPattern": "error", "successPattern": "ok"])))
        case "ax-keyboard-post":
            return InputProfile(core: core, transport: .axKeyboardPost(AXPostProfile(sdkEntries: ["8.4.1": mappings], compatibility: ["api": "AXUIElementPostKeyboardEvent", "deprecatedSince": "10.9", "failureCode": "input_delivery_failed", "verifiedOnMacOS": "14.0"])))
        default:
            return InputProfile(core: core, transport: .focusedKeys(FocusedKeysProfile(sdkEntries: ["8.4.1": mappings], activation: ["frontmostPollTimeoutMs": 2000], restoration: ["verify": true])))
        }
    }
}

private final class Observation: @unchecked Sendable {
    var operation: SimOperation?
    var requirement: String?
}

private final class RecordingTransport: ButtonPressing, @unchecked Sendable {
    let kind: ButtonTransportKind = .protocolShell
    let requiresFocusOptIn: Bool
    private let error: (any Error)?
    private(set) var requests: [ButtonPressRequest] = []
    private(set) var downCount = 0
    private(set) var upCount = 0
    private let hang: Bool
    init(requiresFocus: Bool = false, error: (any Error)? = nil, hang: Bool = false) { requiresFocusOptIn = requiresFocus; self.error = error; self.hang = hang }
    func press(_ request: ButtonPressRequest, context: OperationContext) async throws {
        requests.append(request); downCount += 1
        defer { upCount += 1 }
        if let error { throw error }
        if hang {
            while true {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }
}
