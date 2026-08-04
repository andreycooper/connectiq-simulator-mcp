import Darwin
import Foundation
import Testing

@testable import SimulatorMCPCore

/// Covers the measured `KERN_PROCARGS2` teardown window.
///
/// `errno 5` (`EIO`) is returned while a dying process's argument region can no
/// longer be copied because its address space has already been removed. It is
/// the terminal phase of process death — the same fact as `ESRCH`, observed a
/// few microseconds earlier — and it must not abort an operation.
///
/// Measured 2026-08-04 at 6.3% of force-kills for a 64 MB target rising to
/// 12.3% at 1 GB, and never once on a live process across 3.4M samples.
@Suite("Process inspection teardown")
struct ProcessInspectionTeardownTests {
    @Test("KERN_PROCARGS2 errno classification is exhaustive and documented")
    func argumentsErrnoClassification() {
        typealias Reader = SimulatorMCPCore.DarwinKernelProcessReader

        // A process the kernel can no longer find at all.
        #expect(Reader.disposition(forArgumentsErrno: ESRCH) == .vanished)
        #expect(Reader.disposition(forArgumentsErrno: ENOENT) == .vanished)
        // proc_find failed, or the caller may not read this process's argv.
        #expect(Reader.disposition(forArgumentsErrno: EINVAL) == .vanished)

        // The argument region could not be copied. Two causes, told apart only
        // by observation: a dying process, or one replacing its address space
        // mid-exec. Measured 2026-08-04.
        #expect(Reader.disposition(forArgumentsErrno: EIO) == .addressSpaceUnreadable)

        // Anything else stays a fault and must fail closed.
        #expect(Reader.disposition(forArgumentsErrno: EPERM) == .fault)
        #expect(Reader.disposition(forArgumentsErrno: EACCES) == .fault)
        #expect(Reader.disposition(forArgumentsErrno: ENOMEM) == .fault)
        #expect(Reader.disposition(forArgumentsErrno: EFAULT) == .fault)
    }

    @Test("a torn-down address space is absence, but only once independently confirmed")
    func teardownResolvesToAbsenceWhenConfirmed() throws {
        typealias Reader = SimulatorMCPCore.DarwinKernelProcessReader
        var confirmations = 0

        // EIO with the process confirmed gone: absence, not a fault.
        let resolved = try Reader.resolveArgumentsFailure(
            errno: EIO, pid: 4100, deadlineExpired: false) {
            confirmations += 1
            return true
        }
        #expect(resolved == .vanished)
        #expect(confirmations == 1, "the teardown disposition must take a second opinion")

        // A plain vanished errno needs no confirmation at all.
        confirmations = 0
        #expect(try Reader.resolveArgumentsFailure(
            errno: ESRCH, pid: 4100, deadlineExpired: false) {
            confirmations += 1
            return true
        } == .vanished)
        #expect(confirmations == 0)
    }

    /// EIO has two causes, measured 2026-08-04. A dying process whose address
    /// space has been removed no longer resolves; a process REPLACING its
    /// address space mid-exec still does, and will have a readable argv once
    /// exec completes. Treating the second as absence would let a live
    /// descendant escape the tree walk, and failing on it aborts the operation
    /// for an ordinary transient — which is what gateD12 hit.
    @Test("EIO on a still-resolvable process means exec, and is observed again")
    func execWindowIsObservedAgain() throws {
        typealias Reader = SimulatorMCPCore.DarwinKernelProcessReader
        let resolution = try Reader.resolveArgumentsFailure(
            errno: EIO, pid: 4100, deadlineExpired: false) { false }
        #expect(resolution == .observeAgain)
    }

    @Test("a process still replacing its address space past the deadline fails closed")
    func execWindowFailsClosedPastDeadline() {
        typealias Reader = SimulatorMCPCore.DarwinKernelProcessReader
        do {
            _ = try Reader.resolveArgumentsFailure(
                errno: EIO, pid: 4100, deadlineExpired: true) { false }
            Issue.record("an unreadable live process must not be reported as absent")
        } catch let error as ToolError {
            #expect(error.code == "process_inspection_failed")
            #expect(error.details?["pid"] == .int(4100))
            #expect(!error.fix.isEmpty)
        } catch {
            Issue.record("kernel faults must use the stable ToolError contract: \(error)")
        }
    }

    /// The real reproduction, and unlike the teardown window this one is
    /// reliable: an exec produces thousands of EIO observations.
    @Test("inspecting a process through an exec never aborts")
    func snapshotToleratesExecWindow() throws {
        let reader = SimulatorMCPCore.DarwinProcessIdentityReader()
        var execs = 0
        var inspections = 0
        while execs < 40 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/bash")
            // bash replaces itself with a large, heavily linked binary.
            child.arguments = ["-c", "exec /usr/bin/java -version"]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            execs += 1
            var polls = 0
            while polls < 4000 {
                polls += 1
                do {
                    guard try reader.snapshot(pid: child.processIdentifier) != nil else { break }
                    inspections += 1
                } catch let error as ToolError {
                    child.waitUntilExit()
                    Issue.record(
                        """
                        a process replacing its address space must not abort inspection, \
                        but snapshot threw [\(error.code)]: \(error.message)
                        """)
                    return
                }
            }
            child.waitUntilExit()
        }
        #expect(inspections > 0, "the poll must have inspected live processes")
    }

    @Test("an unrecognised kernel errno still fails closed with the stable contract")
    func unrecognisedErrnoFailsClosed() {
        typealias Reader = SimulatorMCPCore.DarwinKernelProcessReader
        do {
            _ = try Reader.resolveArgumentsFailure(
                errno: EPERM, pid: 4100, deadlineExpired: false) { true }
            Issue.record("an unrecognised errno must not be treated as absence")
        } catch let error as ToolError {
            #expect(error.code == "process_inspection_failed")
            #expect(error.message.contains("errno \(EPERM)"))
            #expect(!error.fix.isEmpty)
        } catch {
            Issue.record("kernel faults must use the stable ToolError contract: \(error)")
        }
    }

    @Test("inspecting a force-killed process never reports a bare kernel fault")
    func snapshotToleratesTeardownWindow() throws {
        let fixture = try MemoryHoldFixture.locate()
        let reader = SimulatorMCPCore.DarwinProcessIdentityReader()

        // Regression guard, not the reproduction. The teardown window is under
        // 100 us wide and an in-process test cannot reliably sample it: issuing
        // the kill deschedules this process, so the child is normally gone
        // before the first inspection starts. Only a tight standalone hot loop
        // samples it, where it reproduces at 6.3%-12.3% of force-kills.
        //
        // What this does guard is the invariant the production poll loops rely
        // on: polling a dying process to absence must never abort with a bare
        // kernel fault.
        var kills = 0
        var teardownsObserved = 0
        while kills < 20 {
            let child = try MemoryHoldFixture.launch(
                fixture, megabytes: 256, selfKillOnStdin: true)
            kills += 1
            child.triggerSelfKill()
            var polls = 0
            while polls < 20000 {
                polls += 1
                do {
                    guard try reader.snapshot(pid: child.pid) != nil else {
                        teardownsObserved += 1
                        break
                    }
                } catch let error as ToolError {
                    child.reap()
                    Issue.record(
                        """
                        a process dying during inspection must not abort the operation, \
                        but snapshot threw [\(error.code)]: \(error.message) \
                        (kill \(kills), poll \(polls))
                        """)
                    return
                }
            }
            child.reap()
        }

        #expect(teardownsObserved == kills, "every killed child must be observed reaching absence")
    }
}

/// Launches the memory-holding fixture and waits for it to report readiness.
/// Readiness is proven by the fixture's own marker, never by a delay.
enum MemoryHoldFixture {
    struct Child {
        let process: Process
        let pid: Int32
        let trigger: Pipe?

        /// Releases the fixture's blocking `read`, after which it raises
        /// SIGKILL on itself.
        func triggerSelfKill() {
            guard let trigger else { return }
            try? trigger.fileHandleForWriting.write(contentsOf: Data([1]))
        }

        func reap() { process.waitUntilExit() }
    }

    private final class BundleLocator {}

    static func locate() throws -> URL {
        // The fixture is built next to the test bundle. swift-testing does not
        // surface the .xctest bundle through Bundle.allBundles, so resolve it
        // from a type in this target and keep the other roots as fallbacks.
        var roots: [URL] = [Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent()]
        roots += Bundle.allBundles
            .filter { $0.bundlePath.hasSuffix(".xctest") }
            .map { $0.bundleURL.deletingLastPathComponent() }
        roots += [Bundle.main.bundleURL, Bundle.main.bundleURL.deletingLastPathComponent()]

        for root in roots {
            let candidate = root.appending(path: "MemoryHoldFixture")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw ToolError(
            code: "fixture_missing",
            message: "The MemoryHoldFixture executable was not found. Searched: \(roots.map(\.path)).",
            fix: "Run the suite through `swift test` so the fixture target is built.")
    }

    static func launch(
        _ executable: URL,
        megabytes: Int,
        selfKillOnStdin: Bool = false
    ) throws -> Child {
        let process = Process()
        process.executableURL = executable
        process.arguments = selfKillOnStdin
            ? [String(megabytes), "--self-kill-on-stdin"] : [String(megabytes)]
        let pipe = Pipe()
        process.standardOutput = pipe
        let trigger = selfKillOnStdin ? Pipe() : nil
        if let trigger { process.standardInput = trigger }
        try process.run()

        var announced = Data()
        while !String(decoding: announced, as: UTF8.self).contains("ready") {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            announced.append(chunk)
        }
        // Readiness is proven by the fixture's own marker. Proceeding without
        // it would inspect a child that has not yet allocated anything, which
        // silently cannot reproduce the window.
        guard String(decoding: announced, as: UTF8.self).contains("ready") else {
            process.terminate()
            process.waitUntilExit()
            throw ToolError(
                code: "fixture_not_ready",
                message: "MemoryHoldFixture exited before announcing readiness (read \(announced.count) bytes).",
                fix: "Inspect the fixture target; the test cannot reproduce the teardown window without it.")
        }
        return Child(process: process, pid: process.processIdentifier, trigger: trigger)
    }
}
