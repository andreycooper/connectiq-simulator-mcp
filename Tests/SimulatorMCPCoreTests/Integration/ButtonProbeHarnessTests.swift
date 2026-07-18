import Foundation
import Testing
@testable import SimulatorMCPCore

@Suite("Button probe harness")
struct ButtonProbeHarnessTests {
    @Test("serializes through press_button/currentReady and builds exact shell invocation")
    func operationAndShellInvocation() async throws {
        let endpoint = TCPEndpoint(address: "127.0.0.1", port: 4312, family: "ipv4")
        let controller = ProbeController(context: OperationContext(
            simulatorPid: 12, sdk: sampleProbeSDK(), currentDevice: "fenix6xpro",
            listeningEndpoints: [endpoint]))
        let runner = FakeProcessRunner { _ in (7, Data("out".utf8), Data("err".utf8)) }
        let harness = ButtonProbeHarness(controller: controller, runner: runner)

        let transcript = try await harness.withSerializedProbe { context in
            try await harness.runShellCommand(
                sdkRoot: context.sdk.root, endpoint: endpoint,
                arguments: ["help", "--verbose"], timeout: .seconds(9))
        }

        #expect(transcript.exitCode == 7)
        #expect(transcript.stdout == Data("out".utf8))
        #expect(transcript.stderr == Data("err".utf8))
        #expect(controller.operation == .pressButton)
        #expect(controller.requirement == "currentReady")
        let invocation = try #require(runner.invocations.last)
        #expect(invocation.arguments == [
            "--transport=tcp", "--transport_args=127.0.0.1:4312", "help", "--verbose"])
        #expect(invocation.timeout == .seconds(9))
    }

    @Test("rejects shell commands outside the serialized operation")
    func rejectsOutsideOperation() async throws {
        let endpoint = TCPEndpoint(address: "127.0.0.1", port: 4312, family: "ipv4")
        let harness = ButtonProbeHarness(
            controller: ProbeController(context: OperationContext(
                simulatorPid: 12, sdk: sampleProbeSDK(), currentDevice: nil,
                listeningEndpoints: [endpoint])), runner: FakeProcessRunner { _ in (0, Data(), Data()) })
        do {
            _ = try await harness.runShellCommand(
                sdkRoot: sampleProbeSDK().root, endpoint: endpoint, arguments: [], timeout: .seconds(1))
            Issue.record("outside-operation shell command must fail")
        } catch let error as ToolError {
            #expect(error.code == "invalid_simulator_state")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("rejects zero and multiple loopback endpoints")
    func endpointCardinality() async throws {
        let sdk = sampleProbeSDK()
        let endpointSets: [Set<TCPEndpoint>] = [
            [],
            [
                TCPEndpoint(address: "127.0.0.1", port: 4312, family: "ipv4"),
                TCPEndpoint(address: "::1", port: 4312, family: "ipv6")
            ]
        ]
        for endpoints in endpointSets {
            let controller = ProbeController(context: OperationContext(
                simulatorPid: 12, sdk: sdk, currentDevice: nil, listeningEndpoints: endpoints))
            let harness = ButtonProbeHarness(controller: controller, runner: FakeProcessRunner { _ in (0, Data(), Data()) })
            do {
                _ = try await harness.withSerializedProbe { context in
                    try await harness.runShellCommand(sdkRoot: context.sdk.root,
                        endpoint: TCPEndpoint(address: "127.0.0.1", port: 4312, family: "ipv4"),
                        arguments: [], timeout: .seconds(1))
                }
                Issue.record("invalid endpoint cardinality must fail")
            } catch let error as ToolError {
                #expect(error.code == "simulator_not_ready")
            }
        }
    }
}

private final class ProbeController: ButtonProbeControlling, @unchecked Sendable {
    let context: OperationContext
    private let lock = NSLock()
    private var storedOperation: SimOperation?
    private var storedRequirement: String?

    var operation: SimOperation? { lock.withLock { storedOperation } }
    var requirement: String? { lock.withLock { storedRequirement } }

    init(context: OperationContext) { self.context = context }

    func withOperation<T: Sendable>(
        _ operation: SimOperation, requirement: OperationRequirement,
        body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        lock.withLock { storedOperation = operation }
        switch requirement {
        case .currentReady: lock.withLock { storedRequirement = "currentReady" }
        default: lock.withLock { storedRequirement = "other" }
        }
        return try await body(context)
    }
}

private func sampleProbeSDK() -> SdkInfo {
    SdkInfo(version: SemVer(major: 9, minor: 1, patch: 0), root: URL(fileURLWithPath: "/tmp/probe-sdk"), source: .explicit)
}
