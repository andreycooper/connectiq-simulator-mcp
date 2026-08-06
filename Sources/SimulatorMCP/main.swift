import Foundation
import MCP
import SimulatorMCPCore

@main
enum SimulatorMCPMain {
    static func main() async throws {
        let registry = ToolRegistry(handlers: try ToolHandlers.live())
        let server = Server(
            name: "simulator-mcp",
            version: "0.5.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: await registry.definitions())
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await registry.call(parameters)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
