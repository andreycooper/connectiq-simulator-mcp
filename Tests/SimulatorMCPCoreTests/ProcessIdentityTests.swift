import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("Process identity")
struct ProcessIdentityTests {
    @Test("stable launcher identity excludes a changing parent PID but preserves exact argv")
    func stableIdentityExcludesParentPID() {
        let start = ProcessStartIdentity(seconds: 1_721_234_567, microseconds: 42)
        let original = ProcessIdentitySnapshot(
            pid: 4100,
            parentPid: 4000,
            processGroupId: 4100,
            start: start,
            executablePath: "/bin/bash",
            arguments: ["/bin/bash", "/SDK With Spaces/bin/monkeydo", "/tmp/App.prg", "fenix6xpro"])
        let reparented = ProcessIdentitySnapshot(
            pid: 4100,
            parentPid: 1,
            processGroupId: 4100,
            start: start,
            executablePath: "/bin/bash",
            arguments: ["/bin/bash", "/SDK With Spaces/bin/monkeydo", "/tmp/App.prg", "fenix6xpro"])

        #expect(original != reparented)
        #expect(original.stableIdentity == reparented.stableIdentity)
        #expect(original.stableIdentity.arguments[1] == "/SDK With Spaces/bin/monkeydo")
    }

    @Test("KERN_PROCARGS2 decoding preserves exact positional arguments")
    func procArgumentsPreserveStructure() throws {
        let arguments = [
            "/bin/bash",
            "/SDK With Spaces/bin/monkeydo",
            "/tmp/App With Spaces.prg",
            "fenix6xpro",
            "-t",
            "Suite Name.test case",
        ]

        let decoded = try SimulatorMCPCore.DarwinProcessIdentityReader.parseProcArguments(
            procArgumentsData(executable: "/bin/bash", arguments: arguments))

        #expect(decoded == arguments)
    }

    @Test("malformed successful KERN_PROCARGS2 data fails closed", arguments: [
        Data(),
        Data([0, 0, 0, 0]),
        procArgumentsData(executable: "/bin/bash", arguments: ["/bin/bash"], argc: 2),
    ])
    func malformedProcArgumentsFailClosed(_ data: Data) {
        do {
            _ = try SimulatorMCPCore.DarwinProcessIdentityReader.parseProcArguments(data)
            Issue.record("malformed kernel data must not produce a partial argv")
        } catch let error as ToolError {
            #expect(error.code == "process_inspection_failed")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
        } catch {
            Issue.record("kernel parse errors must use the stable ToolError contract: \(error)")
        }
    }

    @Test("snapshot fails closed when BSD identity changes around path and argv capture")
    func snapshotRejectsIdentityRace() throws {
        let before = kernelIdentity(parentPid: 4000, startMicroseconds: 10)
        let reused = kernelIdentity(parentPid: 4000, startMicroseconds: 11)
        let reader = SimulatorMCPCore.DarwinProcessIdentityReader(
            kernel: IdentityKernel(identities: [before, reused]))

        do {
            _ = try reader.snapshot(pid: 4100)
            Issue.record("a mixed snapshot must not be returned")
        } catch let error as ToolError {
            #expect(error.code == "process_inspection_failed")
            #expect(error.details?["pid"] == .int(4100))
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a process that vanishes during snapshot capture returns nil")
    func snapshotReturnsNilForVanishedProcess() throws {
        let reader = SimulatorMCPCore.DarwinProcessIdentityReader(
            kernel: IdentityKernel(identities: [kernelIdentity(), nil]))

        #expect(try reader.snapshot(pid: 4100) == nil)
    }

    @Test("live reader captures the current process with structured argv")
    func liveReaderCapturesCurrentProcess() throws {
        let captured = try SimulatorMCPCore.DarwinProcessIdentityReader().snapshot(pid: getpid())
        let snapshot = try #require(captured)

        #expect(snapshot.pid == getpid())
        #expect(snapshot.start.seconds > 0)
        #expect(!snapshot.executablePath.isEmpty)
        #expect(!snapshot.arguments.isEmpty)
        #expect(snapshot.stableIdentity.pid == snapshot.pid)
    }
}

private func procArgumentsData(
    executable: String,
    arguments: [String],
    argc: Int32? = nil
) -> Data {
    var count = argc ?? Int32(arguments.count)
    var data = withUnsafeBytes(of: &count) { Data($0) }
    data.append(contentsOf: executable.utf8)
    data.append(0)
    data.append(0)
    for argument in arguments {
        data.append(contentsOf: argument.utf8)
        data.append(0)
    }
    return data
}

private func kernelIdentity(
    parentPid: Int32 = 4000,
    startMicroseconds: UInt64 = 10
) -> SimulatorMCPCore.KernelBSDIdentity {
    SimulatorMCPCore.KernelBSDIdentity(
        pid: 4100,
        parentPid: parentPid,
        processGroupId: 4100,
        start: ProcessStartIdentity(seconds: 1_721_234_567, microseconds: startMicroseconds))
}

private final class IdentityKernel: SimulatorMCPCore.KernelProcessReading, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [SimulatorMCPCore.KernelBSDIdentity?]

    init(identities: [SimulatorMCPCore.KernelBSDIdentity?]) {
        self.identities = identities
    }

    func bsdIdentity(pid _: Int32) throws -> SimulatorMCPCore.KernelBSDIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identities.isEmpty ? nil : identities.removeFirst()
    }

    func executablePath(pid _: Int32) throws -> String? { "/bin/bash" }

    func arguments(pid _: Int32) throws -> [String]? {
        ["/bin/bash", "/SDK With Spaces/bin/monkeydo", "/tmp/App.prg", "fenix6xpro"]
    }

    func childPIDs(parentPid _: Int32) throws -> [Int32] { [] }

    func processGroupPIDs(processGroupId _: Int32) throws -> [Int32] { [] }
}
