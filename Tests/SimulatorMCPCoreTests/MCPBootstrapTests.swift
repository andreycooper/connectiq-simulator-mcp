import Foundation
import MCP
import Testing

import SimulatorMCPCore

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

// `captureStdout` lives in Support/StdoutCapture.swift, shared with
// SubprocessTests.

/// Exercises the exact bootstrap wiring `SimulatorMCPMain.main()` uses
/// (`Server` + `ToolRegistry` + `StdioTransport`), but over a pair of
/// in-process pipes instead of the process's real stdio, so a real `Client`
/// can drive it end to end without disturbing this test process's actual
/// standard streams.
@Suite("MCP Bootstrap")
struct MCPBootstrapTests {

    /// Builds a `Server` wired the same way as the executable's bootstrap:
    /// `ListTools` and `CallTool` delegate to a `ToolRegistry`.
    private func makeServer(registry: ToolRegistry) async -> Server {
        let server = Server(
            name: "simulator-mcp",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: await registry.definitions())
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await registry.call(parameters)
        }
        return server
    }

    @Test(
        "initialize reports server identity and tools capability, ping completes, shutdown propagates",
        .timeLimit(.minutes(1))
    )
    func testRoundTrip() async throws {
        let (clientToServerRead, clientToServerWrite) = try FileDescriptor.pipe()
        let (serverToClientRead, serverToClientWrite) = try FileDescriptor.pipe()

        let serverTransport = StdioTransport(
            input: clientToServerRead, output: serverToClientWrite, logger: nil)
        let clientTransport = StdioTransport(
            input: serverToClientRead, output: clientToServerWrite, logger: nil)

        let registry = ToolRegistry(handlers: [])
        let server = await makeServer(registry: registry)
        let client = Client(name: "simulator-mcp-test-client", version: "0.0.0")

        try await server.start(transport: serverTransport)

        let initializeResult = try await client.connect(transport: clientTransport)
        #expect(initializeResult.serverInfo.name == "simulator-mcp")
        #expect(initializeResult.serverInfo.version == "0.1.0")
        #expect(initializeResult.capabilities.tools != nil)

        try await client.ping()

        let (tools, _) = try await client.listTools()
        #expect(tools.isEmpty)

        // Simulate the MCP host going away: close the pipe end the server
        // reads as its stdin. This must be what unblocks the bootstrap's
        // `await server.waitUntilCompleted()` so the process can exit.
        await client.disconnect()
        try clientToServerWrite.close()

        await server.waitUntilCompleted()

        await server.stop()
        try? clientToServerRead.close()
        try? serverToClientRead.close()
        try? serverToClientWrite.close()
    }

    @Test("direct registry calls never write to the process's real stdout")
    func testRegistryStaysOffStdout() async throws {
        let registry = ToolRegistry(handlers: [])

        let captured = try await captureStdout {
            _ = await registry.definitions()
            _ = await registry.call(CallTool.Parameters(name: "does-not-exist"))
        }

        #expect(captured.isEmpty)
    }

    @Test("unknown tool calls resolve to an error result instead of throwing")
    func testUnknownToolCallIsAnErrorResult() async throws {
        let registry = ToolRegistry(handlers: [])
        let result = await registry.call(CallTool.Parameters(name: "does-not-exist"))
        #expect(result.isError == true)
    }

    @Test("Log.err writes only through the injected sink, never the process's real stdout")
    func testLogErrUsesInjectedSinkOnly() async throws {
        // `Log.Sink` is `@Sendable`; `Log.err` invokes it synchronously on
        // the calling thread, so a plain mutable capture is safe here even
        // though Swift can't prove that statically. `nonisolated(unsafe)`
        // records that this test, not the compiler, owns that guarantee.
        nonisolated(unsafe) var captured: [String] = []
        let stdoutDuringCall = try await captureStdout {
            Log.err("boom", sink: { captured.append($0) })
        }

        #expect(captured == ["boom"])
        #expect(stdoutDuringCall.isEmpty)
    }
}
