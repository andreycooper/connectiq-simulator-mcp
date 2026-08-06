import Darwin
import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("ProcessPresence")
struct ProcessPresenceTests {
    @Test("this process is running at its own executable path")
    func selfIsRunning() throws {
        // Must be qualified. The test target's own DarwinProcessIdentityReader
        // returns a raw proc_pidpath, while ProcessPresence resolves symlinks —
        // so the unqualified form compiles, passes, and compares the wrong two
        // strings the moment a build path contains a symlink.
        let snapshot = try SimulatorMCPCore.DarwinProcessIdentityReader().snapshot(pid: getpid())
        let path = try #require(snapshot).executablePath

        #expect(ProcessPresence.standard.isRunning(pid: getpid(), executablePath: path))
    }

    @Test("a mismatched executable path is not a match")
    func mismatchedPathIsNotRunning() {
        #expect(!ProcessPresence.standard.isRunning(pid: getpid(), executablePath: "/usr/bin/true"))
    }

    @Test("a non-positive pid is never running")
    func nonPositivePidIsNotRunning() {
        #expect(!ProcessPresence.standard.isRunning(pid: 0, executablePath: "/usr/bin/true"))
        #expect(!ProcessPresence.standard.isRunning(pid: -1, executablePath: "/usr/bin/true"))
    }

    @Test("a reader that reports the process gone is not running")
    func vanishedProcessIsNotRunning() {
        let presence = ProcessPresence(executablePath: { _ in nil })

        #expect(!presence.isRunning(pid: 4711, executablePath: "/usr/bin/true"))
    }

    @Test("a reader that throws is not running")
    func throwingReaderIsNotRunning() {
        let presence = ProcessPresence(executablePath: { _ in
            throw ToolError(code: "internal_error", message: "boom", fix: "none")
        })

        #expect(!presence.isRunning(pid: 4711, executablePath: "/usr/bin/true"))
    }
}
