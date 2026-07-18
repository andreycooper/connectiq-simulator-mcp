import Foundation
import SimulatorMCPCore

struct ShellTranscript: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

protocol ButtonProbeControlling: Sendable {
    func withOperation<T: Sendable>(
        _ operation: SimOperation,
        requirement: OperationRequirement,
        body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T
}

extension SimulatorController: ButtonProbeControlling {
    func withOperation<T: Sendable>(
        _ operation: SimOperation,
        requirement: OperationRequirement,
        body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        try await withOperation(operation, requirement: requirement,
            queueTimeout: .seconds(30), leaseTimeout: .seconds(30), body: body)
    }
}

/// Test-only entry point for live button probes. The controller operation is
/// deliberately the only way to establish the validated endpoint context.
actor ButtonProbeHarness {
    private let controller: any ButtonProbeControlling
    private let runner: any ProcessRunning
    private var context: OperationContext?

    init(controller: any ButtonProbeControlling, runner: any ProcessRunning = Subprocess()) {
        self.controller = controller
        self.runner = runner
    }

    static func live(runner: any ProcessRunning = Subprocess()) throws -> ButtonProbeHarness {
        guard ProcessInfo.processInfo.environment["SIM_BUTTON_PROBE"] == "1" else {
            throw ToolError(code: "probe_disabled",
                message: "The live button probe is disabled.",
                fix: "Set SIM_BUTTON_PROBE=1 only when an evidence capture is explicitly authorized.")
        }
        return ButtonProbeHarness(controller: SimulatorController(
            queue: AsyncFIFO(), lease: .standard, runtimeStore: .standard,
            processRunner: runner, sessionStopper: NoSimulatorSessionStopper()), runner: runner)
    }

    func withSerializedProbe<T: Sendable>(
        body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        try await controller.withOperation(.pressButton, requirement: .currentReady) { context in
            try Self.requireExactlyOneLoopbackEndpoint(context)
            await self.install(context)
            do {
                let result = try await body(context)
                await self.clear()
                return result
            } catch {
                await self.clear()
                throw error
            }
        }
    }

    func runShellCommand(
        sdkRoot: URL,
        endpoint: TCPEndpoint,
        arguments: [String],
        timeout: Duration
    ) async throws -> ShellTranscript {
        guard let context else { throw Self.outsideOperation() }
        let loopback = context.listeningEndpoints.filter(Self.isLoopback)
        guard loopback.count == 1, loopback.first == endpoint else {
            throw ToolError(code: "simulator_not_ready",
                message: "The probe endpoint was not the unique validated simulator listener.",
                fix: "Run the command inside withSerializedProbe and use its OperationContext endpoint.")
        }
        let transport = endpoint.family == "ipv6"
            ? "[\(endpoint.address)]:\(endpoint.port)"
            : "\(endpoint.address):\(endpoint.port)"
        let shell = sdkRoot.appending(path: "bin/shell")
        let process = try await runner.start(
            executable: shell,
            arguments: ["--transport=tcp", "--transport_args=\(transport)"] + arguments,
            timeout: timeout)
        let output = try await process.wait()
        return ShellTranscript(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
    }

    private func install(_ value: OperationContext) { context = value }
    private func clear() { context = nil }

    private static func isLoopback(_ endpoint: TCPEndpoint) -> Bool {
        (endpoint.family == "ipv4" && endpoint.address == "127.0.0.1")
            || (endpoint.family == "ipv6" && endpoint.address == "::1")
            || endpoint.address == "localhost"
    }

    private static func requireExactlyOneLoopbackEndpoint(_ context: OperationContext) throws {
        guard context.listeningEndpoints.filter(isLoopback).count == 1 else {
            throw ToolError(code: "simulator_not_ready",
                message: "Button probes require exactly one validated loopback listener.",
                fix: "Retry after simulator readiness proves one direct loopback endpoint.")
        }
    }

    private static func outsideOperation() -> ToolError {
        ToolError(code: "invalid_simulator_state",
            message: "Button probes may only run inside the serialized simulator operation.",
            fix: "Call withSerializedProbe and use the OperationContext passed to its body.")
    }
}
