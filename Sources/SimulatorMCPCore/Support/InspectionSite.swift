import Darwin
import Foundation

/// Names which process-inspection path raised, and the tree it was inspecting.
///
/// Diagnostic only: it changes no control flow and re-throws with the original
/// code, message and fix intact. Modelled on `taggingCleanupSite`.
///
/// This exists because gateD5 aborted with nothing but a bare PID, which could
/// not be identified once the run was over. A failure raised through this
/// wrapper names its site instead.
///
/// Detail the failure already carried is never overwritten — the inner, more
/// specific value wins.
func taggingInspectionSite<T>(
    _ site: String,
    details: [String: JSONValue] = [:],
    _ body: () throws -> T
) throws -> T {
    do {
        return try body()
    } catch let error as ToolError {
        Log.err("inspection_site=\(site) code=\(error.code) message=\(error.message)")
        var merged = error.details ?? [:]
        // Innermost wins, for the site and for every detail alike: the deepest
        // wrapper is the most specific description of what was being inspected.
        if merged["inspectionSite"] == nil { merged["inspectionSite"] = .string(site) }
        for (key, value) in details where merged[key] == nil { merged[key] = value }
        throw ToolError(
            code: error.code, message: error.message, fix: error.fix, details: merged)
    }
}

/// Whether a PID is still resolvable at throw time.
///
/// `EPERM` means the process exists but belongs to another user, which is still
/// very much alive — only `ESRCH` proves absence.
func isProcessAlive(_ pid: Int32) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}
