import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("MonkeydoConnectionProbe")
struct MonkeydoConnectionProbeTests {
    @Test("negative elapsed launch time is rejected before probing")
    func negativeElapsedIsInvalid() async {
        let fixture = ownedProbeFixture()
        let runner = matchingShellRunner()
        let probe = MonkeydoConnectionProbe(
            processRunner: runner,
            identityReader: fixture.reader,
            clock: FakeClock(),
            serverPID: 500)

        do {
            _ = try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1),
                elapsedBeforeProbe: .milliseconds(-1))
            Issue.record("negative prior elapsed time must be rejected")
        } catch let error as ToolError {
            #expect(error.code == "invalid_arguments")
            #expect(!error.fix.isEmpty)
        } catch {
            Issue.record("invalid elapsed time must use ToolError: \(error)")
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test("lsof parser preserves the local and remote endpoint tuple")
    func parsesConnectionPairs() throws {
        let result = try MonkeydoConnectionProbe.parseEstablishedConnectionPairs(
            Data("p4242\nn127.0.0.1:52100->127.0.0.1:1234\n".utf8),
            expectedPID: 4242)

        #expect(result == [TCPConnection(
            local: TCPEndpoint(address: "127.0.0.1", port: 52100, family: "ipv4"),
            remote: TCPEndpoint(address: "127.0.0.1", port: 1234, family: "ipv4"))])
    }

    @Test("lsof parser returns the remote side of established IPv4 and IPv6 connections")
    func parsesRemoteEndpoints() throws {
        let data = Data("""
            p4242
            f8
            n127.0.0.1:52100->127.0.0.1:1234
            f9
            n[::1]:52101->[::1]:2345
            """.utf8)

        let result = try MonkeydoConnectionProbe.parseEstablishedConnections(data, expectedPID: 4242)

        #expect(result == [
            TCPEndpoint(address: "127.0.0.1", port: 1234, family: "ipv4"),
            TCPEndpoint(address: "::1", port: 2345, family: "ipv6"),
        ])
    }

    @Test("lsof reporting another PID is rejected")
    func rejectsAnotherPID() throws {
        do {
            _ = try MonkeydoConnectionProbe.parseEstablishedConnections(
                Data("p99\nn127.0.0.1:5000->127.0.0.1:1234\n".utf8),
                expectedPID: 4242)
            Issue.record("a reused PID must not become connection evidence")
        } catch let error as ToolError {
            #expect(error.code == "monkeydo_probe_failed")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("connection evidence without a PID is rejected")
    func rejectsConnectionWithoutPID() throws {
        do {
            _ = try MonkeydoConnectionProbe.parseEstablishedConnections(
                Data("n127.0.0.1:5000->127.0.0.1:1234\n".utf8),
                expectedPID: 4242)
            Issue.record("connection evidence must be bound to the requested PID")
        } catch let error as ToolError {
            #expect(error.code == "monkeydo_probe_failed")
        }
    }

    @Test("acceptance follows the exact launcher Java shell chain and revalidates the socket")
    func acceptsExactOwnedConnectionAfterFreshRevalidation() async throws {
        let sdk = SdkInfo(
            version: SemVer(major: 9, minor: 1, patch: 0),
            root: URL(fileURLWithPath: "/SDK With Spaces"),
            source: .explicit)
        let prg = URL(fileURLWithPath: "/tmp/App With Spaces.prg")
        let launcher = probeSnapshot(
            pid: 100, parent: 500, group: 100, executable: "/bin/bash",
            arguments: ["/bin/bash", sdk.monkeydo.path, prg.path, "fenix6xpro"])
        let java = probeSnapshot(
            pid: 101, parent: 100, group: 100, executable: "/JDK/bin/java",
            arguments: [
                "/usr/bin/java", "-classpath", sdk.root.appending(path: "bin/monkeybrains.jar").path,
                "com.garmin.monkeybrains.monkeydodeux.MonkeyDoDeux",
                "-f", prg.path, "-d", "fenix6xpro", "-s", sdk.root.appending(path: "bin/shell").path,
            ])
        let shell = probeSnapshot(
            pid: 102, parent: 101, group: 100,
            executable: sdk.root.appending(path: "bin/shell").path,
            arguments: [
                sdk.root.appending(path: "bin/shell").path,
                "--transport=tcp", "--transport_args=127.0.0.1:1234",
            ])
        let server = probeSnapshot(
            pid: 500, parent: 1, group: 500, executable: "/usr/local/bin/simulator-mcp",
            arguments: ["/usr/local/bin/simulator-mcp"])
        let reader = ProbeIdentityReader(
            snapshots: [100: launcher, 101: java, 102: shell, 500: server],
            children: [100: [101], 101: [102]],
            groups: [100: [100, 101, 102]])
        let runner = FakeProcessRunner { invocation in
            #expect(invocation.arguments == [
                "-nP", "-a", "-p", "102", "-iTCP", "-sTCP:ESTABLISHED", "-Fpn",
            ])
            return (0, Data("p102\nn127.0.0.1:52100->127.0.0.1:1234\n".utf8), Data())
        }
        let process = ProbeOwnedRunningProcess(pid: 100)
        let owned = OwnedMonkeydoProcess(
            process: process,
            launcher: launcher,
            command: MonkeydoCommand(
                sdk: sdk, prgPath: prg, device: "fenix6xpro", testFilter: nil))
        let probe = MonkeydoConnectionProbe(
            processRunner: runner,
            identityReader: reader,
            clock: FakeClock(),
            serverPID: 500)

        let verified = try await probe.waitUntilConnected(
            owned: owned,
            listeningEndpoints: [TCPEndpoint(address: "*", port: 1234, family: "ipv4")],
            timeout: .seconds(1),
            elapsedBeforeProbe: .seconds(2))

        #expect(runner.invocations.count == 2, "socket evidence must be queried fresh twice")
        #expect(verified.launcher == launcher)
        #expect(verified.connectionOwner == shell)
        #expect(verified.parentChain == [shell, java, launcher])
        #expect(verified.launcherGroupMembers == [launcher, java, shell])
        #expect(verified.serverProcess == server)
        #expect(verified.launcherGroupFullyAnchored)
        #expect(verified.postSocketRevalidationVerified)
        #expect(verified.localEndpoint.port == 52100)
        #expect(verified.matchedSimulatorListener.address == "*")
        #expect(verified.elapsedMonotonicMilliseconds == 2_000)
    }

    @Test("an unrelated transient helper may exit while the exact connection chain stays stable")
    func transientHelperExitDoesNotInvalidateExactChain() async throws {
        let fixture = ownedProbeFixture()
        let java = try #require(fixture.reader.snapshots[101])
        let helper = probeSnapshot(
            pid: 103, parent: java.pid, group: 100,
            executable: "/JDK/lib/jspawnhelper", arguments: ["13:16"])
        var snapshots = fixture.reader.snapshots
        snapshots[helper.pid] = helper
        let reader = SequencedProbeIdentityReader(
            snapshots: snapshots,
            sequences: [:],
            children: fixture.reader.children,
            childSequences: [101: [[102, 103], [102]]],
            groups: fixture.reader.groups)
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(),
            identityReader: reader,
            clock: FakeClock(),
            serverPID: 500)

        let verified = try await probe.waitUntilConnected(
            owned: fixture.owned,
            listeningEndpoints: fixture.listeners,
            timeout: .seconds(1))

        #expect(verified.parentChain.map(\.pid) == [102, 101, 100])
        #expect(verified.launcherGroupFullyAnchored)
        #expect(verified.postSocketRevalidationVerified)
    }

    @Test("a stale first socket sample polls and accepts only a later fresh tuple")
    func staleSocketSamplePollsForFreshEvidence() async throws {
        let fixture = ownedProbeFixture()
        let sequence = ConnectionOutputSequence([
            "p102\nn127.0.0.1:52100->127.0.0.1:1234\n",
            "p102\n",
            "p102\nn127.0.0.1:52200->127.0.0.1:1234\n",
            "p102\nn127.0.0.1:52200->127.0.0.1:1234\n",
        ])
        let runner = FakeProcessRunner { _ in
            (0, Data(sequence.next().utf8), Data())
        }
        let clock = FakeClock()
        let probe = MonkeydoConnectionProbe(
            processRunner: runner,
            identityReader: fixture.reader,
            clock: clock,
            serverPID: 500)

        let task = Task {
            try await ClockSupport.withDeadline(.seconds(1), clock: clock) {
                try await probe.waitUntilConnected(
                    owned: fixture.owned,
                    listeningEndpoints: fixture.listeners,
                    timeout: .seconds(1))
            }
        }
        await clock.waitUntilPendingSleepCount(2)
        clock.advance(by: .milliseconds(100))
        let verified = try await task.value

        #expect(runner.invocations.count == 4)
        #expect(verified.localEndpoint.port == 52200)
        #expect(clock.pendingSleepCount == 0)
    }

    /// A process leaves its process group when it is REAPED, not when it dies.
    /// Measured against the kernel: a killed, unreaped process stays listed
    /// in both the child list and the group list while
    /// being uninspectable. So an uninspectable member is an ordinary zombie,
    /// and the probe — which signals nothing — must not abort on one.
    @Test("a zombie descendant does not abort the probe")
    func zombieDescendantDoesNotAbortTheProbe() async throws {
        let fixture = ownedProbeFixture()
        var children = fixture.reader.children
        children[100] = [101, 999]
        let reader = ProbeIdentityReader(
            snapshots: fixture.reader.snapshots,
            children: children,
            groups: [100: [100, 101, 102, 999]])
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(), identityReader: reader,
            clock: FakeClock(), serverPID: 500)

        let verified = try await probe.waitUntilConnected(
            owned: fixture.owned,
            listeningEndpoints: fixture.listeners,
            timeout: .seconds(1))
        #expect(verified.localEndpoint.port == 52100)
        #expect(verified.remoteEndpoint.port == 1234)
    }

    /// The guard the inverted test was providing: tolerating a vanished child
    /// must not tolerate a live one that is not ours.
    @Test("a listed child that is inspectable but not ours still fails closed")
    func foreignListedChildFailsClosed() async {
        let fixture = ownedProbeFixture()
        var snapshots = fixture.reader.snapshots
        // Inspectable, alive, in our group — but its parent is not the launcher.
        snapshots[998] = probeSnapshot(
            pid: 998, parent: 1, group: 100, executable: "/usr/bin/foreign",
            arguments: ["/usr/bin/foreign"])
        var children = fixture.reader.children
        children[100] = [101, 998]
        let reader = ProbeIdentityReader(
            snapshots: snapshots, children: children,
            groups: [100: [100, 101, 102, 998]])
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(), identityReader: reader,
            clock: FakeClock(), serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
    }

    @Test("a zombie launcher-group member does not abort the probe")
    func zombieGroupMemberDoesNotAbortTheProbe() async throws {
        let fixture = ownedProbeFixture()
        let reader = ProbeIdentityReader(
            snapshots: fixture.reader.snapshots,
            children: fixture.reader.children,
            groups: [100: [100, 101, 102, 999]])
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(), identityReader: reader,
            clock: FakeClock(), serverPID: 500)

        let verified = try await probe.waitUntilConnected(
            owned: fixture.owned,
            listeningEndpoints: fixture.listeners,
            timeout: .seconds(1))
        #expect(verified.localEndpoint.port == 52100)
        #expect(verified.remoteEndpoint.port == 1234)
    }

    /// The guard the inverted test was providing: a live group member that is
    /// not in our tree is a foreign process, which is exactly what the
    /// anchoring requirement exists to catch.
    @Test("a live launcher-group member outside the owned tree still fails closed")
    func foreignGroupMemberFailsClosed() async {
        let fixture = ownedProbeFixture()
        var snapshots = fixture.reader.snapshots
        snapshots[997] = probeSnapshot(
            pid: 997, parent: 1, group: 100, executable: "/usr/bin/foreign",
            arguments: ["/usr/bin/foreign"])
        let reader = ProbeIdentityReader(
            snapshots: snapshots,
            children: fixture.reader.children,
            groups: [100: [100, 101, 102, 997]])
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(), identityReader: reader,
            clock: FakeClock(), serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
    }

    /// The tree is captured before the group, so a descendant reaped in between
    /// is legitimately in one and not the other. Exact dictionary equality
    /// cannot express that, and failed on it.
    @Test("a descendant reaped between the tree and group captures does not abort")
    func descendantReapedBetweenCapturesDoesNotAbort() async throws {
        let fixture = ownedProbeFixture()
        let helper = probeSnapshot(
            pid: 103, parent: 100, group: 100, executable: "/bin/dirname",
            arguments: ["/bin/dirname", "/SDK With Spaces/bin/monkeydo"])
        var children = fixture.reader.children
        children[100] = [101, 103]
        // Inspectable for both tree captures, then gone: 103 is absent from the
        // group listing because it was reaped before the group was captured.
        let reader = SequencedProbeIdentityReader(
            snapshots: fixture.reader.snapshots,
            sequences: [103: [helper, helper]],
            children: children,
            groups: [100: [100, 101, 102]])
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(), identityReader: reader,
            clock: FakeClock(), serverPID: 500)

        let verified = try await probe.waitUntilConnected(
            owned: fixture.owned,
            listeningEndpoints: fixture.listeners,
            timeout: .seconds(1))
        #expect(verified.localEndpoint.port == 52100)
        #expect(verified.remoteEndpoint.port == 1234)
    }

    /// ...but a descendant that left the group while still ALIVE is fatal.
    @Test("a descendant that leaves the launcher group while alive fails closed")
    func liveDescendantOutsideGroupFailsClosed() async {
        let fixture = ownedProbeFixture()
        var snapshots = fixture.reader.snapshots
        snapshots[103] = probeSnapshot(
            pid: 103, parent: 100, group: 100, executable: "/bin/dirname",
            arguments: ["/bin/dirname", "/SDK With Spaces/bin/monkeydo"])
        var children = fixture.reader.children
        children[100] = [101, 103]
        let reader = ProbeIdentityReader(
            snapshots: snapshots, children: children,
            groups: [100: [100, 101, 102]])
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(), identityReader: reader,
            clock: FakeClock(), serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
    }

    @Test("duplicate launcher-group PIDs fail closed after fresh socket proof")
    func duplicateGroupPIDFailsClosed() async {
        let fixture = ownedProbeFixture()
        let reader = ProbeIdentityReader(
            snapshots: fixture.reader.snapshots,
            children: fixture.reader.children,
            groups: [100: [100, 101, 102, 102]])
        let runner = matchingShellRunner()
        let probe = MonkeydoConnectionProbe(
            processRunner: runner, identityReader: reader, clock: FakeClock(), serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
        #expect(runner.invocations.count == 2)
    }

    @Test("a launcher descendant missing from the final group fails closed")
    func missingFinalGroupMemberFailsClosed() async {
        let fixture = ownedProbeFixture()
        let reader = ProbeIdentityReader(
            snapshots: fixture.reader.snapshots,
            children: fixture.reader.children,
            groups: [100: [100, 101]])
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(),
            identityReader: reader,
            clock: FakeClock(),
            serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
    }

    @Test("an extra final group member outside the launcher tree fails closed")
    func extraFinalGroupMemberFailsClosed() async {
        let fixture = ownedProbeFixture()
        let helper = probeSnapshot(
            pid: 103, parent: 1, group: 100,
            executable: "/JDK/lib/jspawnhelper", arguments: ["13:16"])
        var snapshots = fixture.reader.snapshots
        snapshots[helper.pid] = helper
        let reader = ProbeIdentityReader(
            snapshots: snapshots,
            children: fixture.reader.children,
            groups: [100: [100, 101, 102, 103]])
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(),
            identityReader: reader,
            clock: FakeClock(),
            serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
    }

    @Test("a launcher group shared with the MCP server fails closed")
    func serverGroupCollisionFailsClosed() async {
        let fixture = ownedProbeFixture()
        let server = try! #require(fixture.reader.snapshots[500])
        let collidingServer = ProcessIdentitySnapshot(
            pid: server.pid,
            parentPid: server.parentPid,
            processGroupId: 100,
            start: server.start,
            executablePath: server.executablePath,
            arguments: server.arguments)
        var snapshots = fixture.reader.snapshots
        snapshots[server.pid] = collidingServer
        let reader = ProbeIdentityReader(
            snapshots: snapshots,
            children: fixture.reader.children,
            groups: fixture.reader.groups)
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(),
            identityReader: reader,
            clock: FakeClock(),
            serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
    }

    @Test("group identity changes during final acceptance fail closed")
    func changedFinalGroupIdentityFailsClosed() async {
        let fixture = ownedProbeFixture()
        let shell = try! #require(fixture.reader.snapshots[102])
        let changedShell = ProcessIdentitySnapshot(
            pid: shell.pid,
            parentPid: shell.parentPid,
            processGroupId: shell.processGroupId,
            start: ProcessStartIdentity(seconds: shell.start.seconds + 1, microseconds: 0),
            executablePath: shell.executablePath,
            arguments: shell.arguments)
        let reader = SequencedProbeIdentityReader(
            snapshots: fixture.reader.snapshots,
            sequences: [102: [shell, shell, changedShell]],
            children: fixture.reader.children,
            groups: fixture.reader.groups)
        let runner = matchingShellRunner()
        let probe = MonkeydoConnectionProbe(
            processRunner: runner, identityReader: reader, clock: FakeClock(), serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
        #expect(runner.invocations.count == 2)
    }

    @Test("changed connection owner failure reports both identity samples")
    func changedConnectionOwnerReportsIdentitySamples() async {
        let fixture = ownedProbeFixture()
        let shell = try! #require(fixture.reader.snapshots[102])
        let changedShell = ProcessIdentitySnapshot(
            pid: shell.pid,
            parentPid: shell.parentPid,
            processGroupId: shell.processGroupId,
            start: ProcessStartIdentity(seconds: shell.start.seconds + 1, microseconds: 0),
            executablePath: shell.executablePath,
            arguments: shell.arguments)
        let reader = SequencedProbeIdentityReader(
            snapshots: fixture.reader.snapshots,
            sequences: [102: [shell, changedShell]],
            children: fixture.reader.children,
            groups: fixture.reader.groups)
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(),
            identityReader: reader,
            clock: FakeClock(),
            serverPID: 500)

        do {
            _ = try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
            Issue.record("a changed connection owner must fail closed")
        } catch let error as ToolError {
            #expect(error.code == "monkeydo_probe_failed")
            #expect(
                error.details?["observedCandidate"]
                    == .string("pid=102,parent=101,start=1700000000.102"))
            #expect(error.details?["finalCandidates"] == .array([
                .string("pid=102,parent=101,start=1700000001.0")
            ]))
            #expect(error.details?["finalDescendants"] == .array([
                .string("pid=101,parent=100,start=1700000000.101"),
                .string("pid=102,parent=101,start=1700000001.0"),
            ]))
        } catch {
            Issue.record("probe failures must use ToolError: \(error)")
        }
    }

    @Test("Java parent identity changes during final acceptance fail closed")
    func changedJavaIdentityFailsClosed() async {
        let fixture = ownedProbeFixture()
        let java = try! #require(fixture.reader.snapshots[101])
        let changedJava = ProcessIdentitySnapshot(
            pid: java.pid,
            parentPid: java.parentPid,
            processGroupId: java.processGroupId,
            start: ProcessStartIdentity(seconds: java.start.seconds + 1, microseconds: 0),
            executablePath: java.executablePath,
            arguments: java.arguments)
        let reader = SequencedProbeIdentityReader(
            snapshots: fixture.reader.snapshots,
            sequences: [101: [java, changedJava]],
            children: fixture.reader.children,
            groups: fixture.reader.groups)
        let probe = MonkeydoConnectionProbe(
            processRunner: matchingShellRunner(),
            identityReader: reader,
            clock: FakeClock(),
            serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
    }

    @Test("multiple matching sockets are fatal rather than chosen arbitrarily")
    func multipleMatchingSocketsFailClosed() async {
        let fixture = ownedProbeFixture()
        let runner = FakeProcessRunner { _ in
            (0, Data("""
                p102
                n127.0.0.1:52100->127.0.0.1:1234
                n127.0.0.1:52101->127.0.0.1:1234
                """.utf8), Data())
        }
        let probe = MonkeydoConnectionProbe(
            processRunner: runner,
            identityReader: fixture.reader,
            clock: FakeClock(),
            serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
        #expect(runner.invocations.count == 1)
    }

    @Test("unrelated exact-looking Java children are rejected as ambiguous")
    func multipleExactJavaChildrenFailClosed() async {
        let fixture = ownedProbeFixture()
        let java = try! #require(fixture.reader.snapshots[101])
        let secondJava = ProcessIdentitySnapshot(
            pid: 104,
            parentPid: java.parentPid,
            processGroupId: java.processGroupId,
            start: ProcessStartIdentity(seconds: java.start.seconds, microseconds: 104),
            executablePath: java.executablePath,
            arguments: java.arguments)
        var snapshots = fixture.reader.snapshots
        snapshots[104] = secondJava
        var children = fixture.reader.children
        children[100] = [101, 104]
        let runner = matchingShellRunner()
        let probe = MonkeydoConnectionProbe(
            processRunner: runner,
            identityReader: ProbeIdentityReader(
                snapshots: snapshots, children: children, groups: fixture.reader.groups),
            clock: FakeClock(),
            serverPID: 500)

        await expectProbeFailure {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .seconds(1))
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test("wrong Java argv never becomes a connection owner and times out")
    func wrongJavaArgumentsTimeOutWithoutLsof() async {
        let fixture = ownedProbeFixture()
        let java = try! #require(fixture.reader.snapshots[101])
        var snapshots = fixture.reader.snapshots
        snapshots[101] = ProcessIdentitySnapshot(
            pid: java.pid,
            parentPid: java.parentPid,
            processGroupId: java.processGroupId,
            start: java.start,
            executablePath: java.executablePath,
            arguments: java.arguments + ["--deceptive-suffix"])
        let runner = matchingShellRunner()
        let probe = MonkeydoConnectionProbe(
            processRunner: runner,
            identityReader: ProbeIdentityReader(
                snapshots: snapshots,
                children: fixture.reader.children,
                groups: fixture.reader.groups),
            clock: ContinuousClock(),
            serverPID: 500)

        await expectProbeError("app_launch_timeout") {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .milliseconds(5))
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test("an unrelated established endpoint is never accepted")
    func unrelatedEndpointTimesOut() async {
        let fixture = ownedProbeFixture()
        let runner = FakeProcessRunner { _ in
            (0, Data("p102\nn127.0.0.1:52100->127.0.0.1:9999\n".utf8), Data())
        }
        let probe = MonkeydoConnectionProbe(
            processRunner: runner,
            identityReader: fixture.reader,
            clock: ContinuousClock(),
            serverPID: 500)

        await expectProbeError("app_launch_timeout") {
            try await probe.waitUntilConnected(
                owned: fixture.owned,
                listeningEndpoints: fixture.listeners,
                timeout: .milliseconds(5))
        }
        #expect(!runner.invocations.isEmpty)
    }
}

private func probeSnapshot(
    pid: Int32,
    parent: Int32,
    group: Int32,
    executable: String,
    arguments: [String]
) -> ProcessIdentitySnapshot {
    ProcessIdentitySnapshot(
        pid: pid,
        parentPid: parent,
        processGroupId: group,
        start: ProcessStartIdentity(seconds: 1_700_000_000, microseconds: UInt64(pid)),
        executablePath: executable,
        arguments: arguments)
}

private struct ProbeIdentityReader: SimulatorMCPCore.ProcessIdentityReading, Sendable {
    let snapshots: [Int32: ProcessIdentitySnapshot]
    let children: [Int32: [Int32]]
    let groups: [Int32: [Int32]]

    func snapshot(pid: Int32) throws -> ProcessIdentitySnapshot? { snapshots[pid] }
    func childPIDs(parentPid: Int32) throws -> [Int32] { children[parentPid] ?? [] }
    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        groups[processGroupId] ?? []
    }
}

private final class SequencedProbeIdentityReader: SimulatorMCPCore.ProcessIdentityReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let snapshots: [Int32: ProcessIdentitySnapshot]
    private var sequences: [Int32: [ProcessIdentitySnapshot]]
    private let children: [Int32: [Int32]]
    private var childSequences: [Int32: [[Int32]]]
    private let groups: [Int32: [Int32]]

    init(
        snapshots: [Int32: ProcessIdentitySnapshot],
        sequences: [Int32: [ProcessIdentitySnapshot]],
        children: [Int32: [Int32]],
        childSequences: [Int32: [[Int32]]] = [:],
        groups: [Int32: [Int32]]
    ) {
        self.snapshots = snapshots
        self.sequences = sequences
        self.children = children
        self.childSequences = childSequences
        self.groups = groups
    }

    func snapshot(pid: Int32) throws -> ProcessIdentitySnapshot? {
        lock.withLock {
            guard var values = sequences[pid], !values.isEmpty else { return snapshots[pid] }
            let value = values.removeFirst()
            sequences[pid] = values
            return value
        }
    }

    func childPIDs(parentPid: Int32) throws -> [Int32] {
        lock.withLock {
            guard var values = childSequences[parentPid], !values.isEmpty else {
                return children[parentPid] ?? []
            }
            let value = values.removeFirst()
            childSequences[parentPid] = values
            return value
        }
    }
    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        groups[processGroupId] ?? []
    }
}

private actor ProbeOwnedRunningProcess: RunningProcess {
    nonisolated let pid: Int32
    init(pid: Int32) { self.pid = pid }
    func wait() async throws -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdout: Data(), stderr: Data())
    }
    func terminate(grace _: Duration) async {}
}

private struct OwnedProbeFixture {
    let reader: ProbeIdentityReader
    let owned: OwnedMonkeydoProcess
    let listeners: Set<TCPEndpoint>
}

private func ownedProbeFixture() -> OwnedProbeFixture {
    let sdk = SdkInfo(
        version: SemVer(major: 9, minor: 1, patch: 0),
        root: URL(fileURLWithPath: "/SDK With Spaces"),
        source: .explicit)
    let prg = URL(fileURLWithPath: "/tmp/App With Spaces.prg")
    let launcher = probeSnapshot(
        pid: 100, parent: 500, group: 100, executable: "/bin/bash",
        arguments: ["/bin/bash", sdk.monkeydo.path, prg.path, "fenix6xpro"])
    let java = probeSnapshot(
        pid: 101, parent: 100, group: 100, executable: "/JDK/bin/java",
        arguments: [
            "/usr/bin/java", "-classpath", sdk.root.appending(path: "bin/monkeybrains.jar").path,
            "com.garmin.monkeybrains.monkeydodeux.MonkeyDoDeux",
            "-f", prg.path, "-d", "fenix6xpro", "-s", sdk.root.appending(path: "bin/shell").path,
        ])
    let shell = probeSnapshot(
        pid: 102, parent: 101, group: 100,
        executable: sdk.root.appending(path: "bin/shell").path,
        arguments: [
            sdk.root.appending(path: "bin/shell").path,
            "--transport=tcp", "--transport_args=127.0.0.1:1234",
        ])
    let server = probeSnapshot(
        pid: 500, parent: 1, group: 500, executable: "/usr/local/bin/simulator-mcp",
        arguments: ["/usr/local/bin/simulator-mcp"])
    return OwnedProbeFixture(
        reader: ProbeIdentityReader(
            snapshots: [100: launcher, 101: java, 102: shell, 500: server],
            children: [100: [101], 101: [102]],
            groups: [100: [100, 101, 102]]),
        owned: OwnedMonkeydoProcess(
            process: ProbeOwnedRunningProcess(pid: 100),
            launcher: launcher,
            command: MonkeydoCommand(
                sdk: sdk, prgPath: prg, device: "fenix6xpro", testFilter: nil)),
        listeners: [TCPEndpoint(address: "*", port: 1234, family: "ipv4")])
}

private final class ConnectionOutputSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]

    init(_ outputs: [String]) { self.outputs = outputs }

    func next() -> String {
        lock.withLock { outputs.isEmpty ? "p102\n" : outputs.removeFirst() }
    }
}

private func matchingShellRunner() -> FakeProcessRunner {
    FakeProcessRunner { _ in
        (0, Data("p102\nn127.0.0.1:52100->127.0.0.1:1234\n".utf8), Data())
    }
}

private func expectProbeFailure(
    _ operation: () async throws -> VerifiedMonkeydoConnection
) async {
    do {
        _ = try await operation()
        Issue.record("incomplete or ambiguous evidence must fail closed")
    } catch let error as ToolError {
        #expect(error.code == "monkeydo_probe_failed")
        #expect(!error.message.isEmpty)
        #expect(!error.fix.isEmpty)
    } catch {
        Issue.record("probe failures must use ToolError: \(error)")
    }
}

private func expectProbeError(
    _ code: String,
    _ operation: () async throws -> VerifiedMonkeydoConnection
) async {
    do {
        _ = try await operation()
        Issue.record("expected probe error \(code)")
    } catch let error as ToolError {
        #expect(error.code == code)
        #expect(!error.fix.isEmpty)
    } catch {
        Issue.record("probe failures must use ToolError: \(error)")
    }
}
