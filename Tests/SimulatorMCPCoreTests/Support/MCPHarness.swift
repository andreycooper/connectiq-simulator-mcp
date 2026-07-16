import Foundation
import MCP
import Testing

import SimulatorMCPCore

/// Public-boundary test harness: a real MCP Client and Server connected by
/// paired official SDK transports, with production ToolRegistry dispatch.
struct MCPHarness {
    let client: Client

    private let server: Server
    static func start(handlers: [any SimulatorTool]) async throws -> MCPHarness {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "simulator-mcp", version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false)))
        let registry = ToolRegistry(handlers: handlers)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: await registry.definitions())
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await registry.call(parameters)
        }
        try await server.start(transport: transports.server)

        let client = Client(name: "public-tool-handler-tests", version: "0.0.0")
        _ = try await client.connect(transport: transports.client)
        return MCPHarness(client: client, server: server)
    }

    func listTools() async throws -> [Tool] {
        try await client.listTools().tools
    }

    func call<Result: Codable & Sendable>(
        _ name: String,
        arguments: [String: Value]? = nil,
        as: Result.Type = Result.self
    ) async throws -> (raw: CallTool.Result, envelope: ToolEnvelope<Result>) {
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: name, arguments: arguments)
        let raw = try await context.value
        let structured = try #require(raw.structuredContent)
        let data = try JSONEncoder().encode(structured)
        return (raw, try JSONDecoder().decode(ToolEnvelope<Result>.self, from: data))
    }

    func stop() async {
        await client.disconnect()
        await server.waitUntilCompleted()
        await server.stop()
    }
}

func withMCPHarness<T: Sendable>(
    handlers: [any SimulatorTool],
    _ body: (MCPHarness) async throws -> T
) async throws -> T {
    let harness = try await MCPHarness.start(handlers: handlers)
    do {
        let value = try await body(harness)
        await harness.stop()
        return value
    } catch {
        await harness.stop()
        throw error
    }
}
