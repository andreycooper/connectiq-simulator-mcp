@preconcurrency import CoreGraphics
import Foundation

/// Live frontmost-application observation.
///
/// `NSWorkspace.frontmostApplication` is maintained from workspace
/// notifications delivered on the main run loop. This server is an async MCP
/// stdio process that never pumps one, so that property freezes at whatever
/// was frontmost when the process started: measured here as 154 consecutive
/// identical polls naming the launching terminal while the Simulator was in
/// fact frontmost the whole time. Every focus proof built on it therefore
/// fails against a Simulator that really did come forward.
///
/// The window server is asked directly instead, on every call, so the answer
/// can never be stale. Owner PID and window layer are returned without the
/// Screen Recording grant; only window *names* require it, and none are read.
public enum FrontmostApplication {
    /// The owner of the front-most window in the normal window layer.
    ///
    /// The list is returned front-to-back, so the first normal-layer window is
    /// the frontmost one. Layer 0 is the ordinary application layer; the menu
    /// bar, dock, and status overlays sit above it and are not applications
    /// the user is working in.
    static func pid(inFrontOf windows: [[String: Any]]) -> pid_t? {
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner > 0 else { continue }
            return pid_t(owner)
        }
        return nil
    }

    /// Queries the window server for the current frontmost application.
    public static func current() -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return pid(inFrontOf: windows)
    }
}
