import Foundation
import Testing

@testable import SimulatorMCPCore

/// Attribution is diagnostic only. It must name the inspection path and the
/// tree under inspection without altering the error contract or control flow.
///
/// This exists because gateD5 reported a bare PID and nothing else, leaving the
/// failing process unidentifiable after the run.
@Suite("Inspection site attribution")
struct InspectionSiteTests {
    @Test("a tagged failure keeps its code, message and fix, and gains its site")
    func taggedFailurePreservesContract() {
        let original = ToolError(
            code: "process_inspection_failed",
            message: "sysctl(KERN_PROCARGS2) failed for PID 816 with errno 5.",
            fix: "Retry the operation.",
            details: ["pid": .int(816)])

        do {
            try taggingInspectionSite(
                "probe.captureTree",
                details: ["launcherPid": .int(4100), "launcherPgid": .int(4100)]
            ) { throw original }
            Issue.record("the wrapper must not swallow the failure")
        } catch let error as ToolError {
            #expect(error.code == original.code)
            #expect(error.message == original.message)
            #expect(error.fix == original.fix)
            #expect(error.details?["pid"] == .int(816))
            #expect(error.details?["inspectionSite"] == .string("probe.captureTree"))
            #expect(error.details?["launcherPid"] == .int(4100))
            #expect(error.details?["launcherPgid"] == .int(4100))
        } catch {
            Issue.record("the wrapper must preserve the ToolError contract: \(error)")
        }
    }

    @Test("attribution never overwrites detail the failure already carried")
    func attributionDoesNotOverwriteExistingDetail() {
        let original = ToolError(
            code: "process_inspection_failed",
            message: "boom",
            fix: "retry",
            details: ["pid": .int(816), "launcherPid": .int(999)])

        do {
            try taggingInspectionSite("cleanup.captureGroup", details: ["launcherPid": .int(4100)]) {
                throw original
            }
            Issue.record("the wrapper must not swallow the failure")
        } catch let error as ToolError {
            #expect(error.details?["launcherPid"] == .int(999))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("nested attribution keeps the innermost, most specific site")
    func nestedAttributionKeepsInnermostSite() {
        do {
            try taggingInspectionSite("cleanup.outer", details: ["launcherPid": .int(1)]) {
                try taggingInspectionSite("cleanup.captureGroup", details: ["launcherPgid": .int(7)]) {
                    throw ToolError(
                        code: "process_inspection_failed", message: "boom", fix: "retry")
                }
            }
            Issue.record("the wrapper must not swallow the failure")
        } catch let error as ToolError {
            #expect(error.details?["inspectionSite"] == .string("cleanup.captureGroup"))
            // Outer context is still additive where it does not conflict.
            #expect(error.details?["launcherPgid"] == .int(7))
            #expect(error.details?["launcherPid"] == .int(1))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("a successful inspection is returned untouched")
    func successPassesThrough() throws {
        let value = try taggingInspectionSite("probe.captureTree") { 42 }
        #expect(value == 42)
    }

    @Test("a process inspection failure records whether the PID was still alive")
    func inspectionErrorRecordsLiveness() {
        // Our own process is unambiguously alive.
        let live = SimulatorMCPCore.DarwinKernelProcessReader.inspectionError(
            "probe", pid: getpid())
        #expect(live.details?["pidAlive"] == .bool(true))

        // A PID far above the allocator is unambiguously not.
        let dead = SimulatorMCPCore.DarwinKernelProcessReader.inspectionError(
            "probe", pid: 99_998)
        #expect(dead.details?["pidAlive"] == .bool(false))
    }
}
