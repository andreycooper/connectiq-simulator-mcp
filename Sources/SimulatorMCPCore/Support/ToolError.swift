/// A stable, actionable failure.
///
/// Every public failure in this codebase carries a stable `code` a caller
/// can branch on, a human-readable `message` describing what happened, and
/// a concrete, non-empty `fix` describing what to do next (see AGENTS.md).
/// Raw platform errors (POSIX errno, `NSError`, thrown `Process.run()`
/// failures, …) are translated into a `ToolError` at the boundary that
/// first observes them — never propagated raw past that point.
public struct ToolError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let fix: String
    public let details: [String: JSONValue]?

    public init(
        code: String,
        message: String,
        fix: String,
        details: [String: JSONValue]? = nil
    ) {
        precondition(!code.isEmpty)
        precondition(!message.isEmpty)
        precondition(!fix.isEmpty)
        self.code = code
        self.message = message
        self.fix = fix
        self.details = details
    }
}
