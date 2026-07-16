import Foundation
import MCP

/// Holds the server's tool handlers and answers `tools/list` and
/// `tools/call`.
///
/// Dispatch rules (the registry is the last defensive translation layer —
/// see the plan's MCP response contract):
///
/// - An unknown tool name is `invalid_arguments`, not a thrown error.
/// - A handler's thrown `ToolError` keeps its stable code in the failure
///   envelope.
/// - Any other thrown error is logged (type + localized description) to
///   the log sink — stderr in production, never stdout — and surfaces as
///   `internal_error` with a fixed fix string. Raw platform error text
///   never reaches the public envelope.
/// - `definitions()` is sorted by tool name so clients and tests see a
///   deterministic order.
/// - Duplicate tool names are a programmer error and fail a precondition
///   at construction.
public actor ToolRegistry {
    private let handlersByName: [String: any SimulatorTool]
    private let sortedDefinitions: [Tool]
    private let logSink: Log.Sink

    public init(
        handlers: [any SimulatorTool] = [],
        logSink: @escaping Log.Sink = Log.standardError
    ) {
        var byName: [String: any SimulatorTool] = [:]
        for handler in handlers {
            let name = handler.definition.name
            precondition(byName[name] == nil, "duplicate tool name: \(name)")
            byName[name] = handler
        }
        self.handlersByName = byName
        self.sortedDefinitions = handlers.map(\.definition).sorted { $0.name < $1.name }
        self.logSink = logSink
    }

    /// Tool definitions advertised to `tools/list`, sorted by name.
    public func definitions() -> [Tool] {
        sortedDefinitions
    }

    /// Dispatches a `tools/call` request. Never throws and never writes to
    /// stdout: every failure becomes an error envelope.
    public func call(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        guard let handler = handlersByName[parameters.name] else {
            return ToolResultFactory.failure(
                ToolError(
                    code: "invalid_arguments",
                    message: "Unknown tool '\(parameters.name)'.",
                    fix: "Call tools/list and use one of the advertised tool names.",
                    details: ["tool": .string(parameters.name)]
                ))
        }

        do {
            return try await handler.call(arguments: parameters.arguments ?? [:])
        } catch let error as ToolError {
            return ToolResultFactory.failure(error)
        } catch {
            Log.err(
                "tool '\(parameters.name)' threw \(type(of: error)): \(error.localizedDescription)",
                sink: logSink
            )
            return ToolResultFactory.failure(
                ToolError(
                    code: "internal_error",
                    message: "Tool '\(parameters.name)' failed unexpectedly.",
                    fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.",
                    details: ["tool": .string(parameters.name)]
                ))
        }
    }
}
