import Foundation

/// Stderr-only diagnostics.
///
/// stdout is reserved for MCP JSON-RPC framing (see AGENTS.md); every
/// diagnostic in this process must go through `Log.err`, never `print`.
/// The sink is injectable so tests can capture output without touching the
/// process's real file descriptors.
public enum Log {
    public typealias Sink = @Sendable (String) -> Void

    /// Writes `message` followed by a newline to real standard error.
    public static let standardError: Sink = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Writes a diagnostic line to `sink`. Defaults to `standardError`;
    /// tests inject their own sink to assert on captured output.
    public static func err(_ message: String, sink: Sink = Log.standardError) {
        sink(message)
    }
}
