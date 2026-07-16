import Foundation
import MCP

/// The wire form of a failed tool call (the `error` branch of
/// `ToolEnvelope`). Mirrors `ToolError`, which is the in-process form.
public struct ToolFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let fix: String
    public let details: [String: JSONValue]?

    public init(code: String, message: String, fix: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.fix = fix
        self.details = details
    }

    public init(_ error: ToolError) {
        self.init(code: error.code, message: error.message, fix: error.fix, details: error.details)
    }
}

/// Every tool response is exactly one of these: `ok == true` with a
/// non-nil `result`, or `ok == false` with a non-nil `error`. The absent
/// branch is omitted from the encoded JSON entirely.
public struct ToolEnvelope<Result: Codable & Sendable>: Codable, Sendable {
    public let ok: Bool
    public let result: Result?
    public let error: ToolFailure?

    public init(ok: Bool, result: Result?, error: ToolFailure?) {
        self.ok = ok
        self.result = result
        self.error = error
    }
}

/// One MCP tool: its advertised definition (which must declare
/// `Schemas.envelopeSchema(result:)` as `outputSchema`) and its handler.
/// Handlers decode arguments, call exactly one service, and encode the
/// typed result through `ToolResultFactory` — no `Process`, CGEvent,
/// ScreenCaptureKit, or AX calls at this layer (see AGENTS.md).
public protocol SimulatorTool: Sendable {
    var definition: Tool { get }
    func call(arguments: [String: Value]) async throws -> CallTool.Result
}

/// Builds the two-representation response the contract requires: the
/// envelope as `structuredContent` and the identical JSON (sorted keys)
/// as a `Tool.Content.text` block for clients that ignore
/// `structuredContent`.
public enum ToolResultFactory {
    public static func success<Result: Codable & Sendable>(
        _ result: Result,
        additionalContent: [Tool.Content] = []
    ) throws -> CallTool.Result {
        let envelope = ToolEnvelope(ok: true, result: result, error: nil)
        let json = try sortedJSON(envelope)
        return try CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)] + additionalContent,
            structuredContent: envelope,
            isError: false,
            _meta: nil
        )
    }

    public static func failure(_ error: ToolError) -> CallTool.Result {
        let envelope = ToolEnvelope<JSONValue>(ok: false, result: nil, error: ToolFailure(error))
        if let result = try? failureResult(for: envelope) {
            return result
        }

        // The only theoretically fallible member above is `details`
        // (arbitrary JSONValue); retry without it rather than lose the
        // failure entirely.
        let stripped = ToolEnvelope<JSONValue>(
            ok: false,
            result: nil,
            error: ToolFailure(code: error.code, message: error.message, fix: error.fix)
        )
        if let result = try? failureResult(for: stripped) {
            return result
        }

        // Unreachable in practice (Bool + String cannot fail to encode),
        // but a failure path must never throw, so return a constant,
        // hand-verified envelope as the last resort.
        return CallTool.Result(
            content: [
                .text(
                    text:
                        #"{"error":{"code":"internal_error","fix":"Run doctor, then retry. If it repeats, inspect the server stderr log.","message":"Failed to encode a failure envelope."},"ok":false}"#,
                    annotations: nil, _meta: nil)
            ],
            structuredContent: [
                "ok": false,
                "error": [
                    "code": "internal_error",
                    "message": "Failed to encode a failure envelope.",
                    "fix": "Run doctor, then retry. If it repeats, inspect the server stderr log.",
                ],
            ],
            isError: true,
            _meta: nil
        )
    }

    private static func failureResult(
        for envelope: ToolEnvelope<JSONValue>
    ) throws -> CallTool.Result {
        let json = try sortedJSON(envelope)
        return try CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: envelope,
            isError: true,
            _meta: nil
        )
    }

    private static func sortedJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
