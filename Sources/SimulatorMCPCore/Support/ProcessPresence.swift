import Darwin
import Foundation

/// Public liveness check that never reads a process's argument vector.
///
/// `DarwinProcessIdentityReader.snapshot(pid:)` is the only other public route,
/// and it calls `sysctl(KERN_PROCARGS2)`. That is unacceptable for a monitor
/// polling several times a second against the Simulator, which has the largest
/// address space on the machine and is where the errno5 investigation measured
/// `EIO` at up to 12.3% during teardown.
///
/// `proc_pidpath` costs a fraction of that and answers the only question a
/// monitor has: is this pid still the process the record named?
public struct ProcessPresence: Sendable {
    public static let standard = ProcessPresence()

    private let executablePath: @Sendable (Int32) throws -> String?

    public init() {
        let reader = DarwinKernelProcessReader()
        self.executablePath = { pid in try reader.executablePath(pid: pid) }
    }

    init(executablePath: @escaping @Sendable (Int32) throws -> String?) {
        self.executablePath = executablePath
    }

    /// Whether `pid` is live and still running `executablePath`.
    ///
    /// Every ambiguity resolves to `false`. A monitor uses this only to decide
    /// whether a persisted record is stale, and a stale record rendered as
    /// absent is the safe direction: the alternative is an indicator stuck on a
    /// process that no longer exists.
    public func isRunning(pid: Int32, executablePath expected: String) -> Bool {
        guard pid > 0 else { return false }
        // `try?` already flattens the closure's `String?` result.
        guard let observed = try? executablePath(pid) else { return false }
        return observed == expected
    }
}
