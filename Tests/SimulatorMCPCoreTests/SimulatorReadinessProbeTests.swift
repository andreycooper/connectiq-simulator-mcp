import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("SimulatorReadinessProbe")
struct SimulatorReadinessProbeTests {
    @Test("lsof parser keeps loopback and wildcard TCP listeners")
    func parsesEligibleListeners() throws {
        let output = """
            p4242
            f11
            n127.0.0.1:1234
            f12
            n[::1]:2345
            f13
            n*:3456
            f14
            n10.0.0.4:4567
            """

        let endpoints = try SimulatorReadinessProbe.parseLsofListeners(Data(output.utf8))

        #expect(endpoints == [
            TCPEndpoint(address: "127.0.0.1", port: 1234, family: "ipv4"),
            TCPEndpoint(address: "::1", port: 2345, family: "ipv6"),
            TCPEndpoint(address: "*", port: 3456, family: "ipv4"),
        ])
    }

    @Test("malformed lsof output is an actionable probe failure")
    func rejectsMalformedLsofOutput() throws {
        do {
            _ = try SimulatorReadinessProbe.parseLsofListeners(Data("p1\nnlocalhost:not-a-port\n".utf8))
            Issue.record("invalid port must fail")
        } catch let error as ToolError {
            #expect(error.code == "simulator_probe_failed")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("readiness requires the same identity and endpoints twice")
    func requiresStableConsecutiveObservations() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let identity = SimulatorProcessIdentity(
            pid: 4242,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
        let calls = LockedCounter()
        let runner = FakeProcessRunner { invocation in
            #expect(invocation.executable.path == "/usr/sbin/lsof")
            #expect(invocation.arguments == [
                "-nP", "-a", "-p", "4242", "-iTCP", "-sTCP:LISTEN", "-Fpn",
            ])
            let port = calls.incrementAndGet() == 1 ? 1234 : 2345
            return (0, Data("p4242\nf11\nn127.0.0.1:\(port)\n".utf8), Data())
        }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            identityLookup: { _ in identity })

        let task = Task {
            try await probe.waitUntilReady(pid: 4242, requested: sdk, timeout: .seconds(2))
        }
        let result = try await task.value

        #expect(calls.value >= 3)
        #expect(result.listeningEndpoints == [
            TCPEndpoint(address: "127.0.0.1", port: 2345, family: "ipv4")
        ])
    }

    @Test("a missing process fails immediately instead of timing out")
    func processExitFailsImmediately() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let runner = FakeProcessRunner { _ in
            Issue.record("lsof must not run for an exited process")
            return (0, Data(), Data())
        }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            identityLookup: { _ in nil })

        do {
            _ = try await probe.waitUntilReady(pid: 9, requested: sdk, timeout: .seconds(30))
            Issue.record("exited process must fail")
        } catch let error as ToolError {
            #expect(error.code == "simulator_exited")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("no listener at the deadline reports requested SDK and last probe")
    func noListenerTimesOutActionably() async throws {
        let sdk = sampleSDK(version: "8.4.1")
        let identity = SimulatorProcessIdentity(
            pid: 77,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
        let runner = FakeProcessRunner { _ in (0, Data("p77\n".utf8), Data()) }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            identityLookup: { _ in identity })

        do {
            _ = try await probe.waitUntilReady(pid: 77, requested: sdk, timeout: .zero)
            Issue.record("zero-deadline listener absence must fail")
        } catch let error as ToolError {
            #expect(error.code == "simulator_ready_timeout")
            #expect(error.details?["sdkPath"] == .string(sdk.root.path))
            #expect(error.details?["lastProbe"] != nil)
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a wildcard-only listener is not readiness evidence")
    func wildcardOnlyDoesNotBecomeReady() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let identity = SimulatorProcessIdentity(
            pid: 88,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
        let runner = FakeProcessRunner { _ in
            (0, Data("p88\nf11\nn*:1234\n".utf8), Data())
        }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            identityLookup: { _ in identity })

        do {
            _ = try await probe.waitUntilReady(pid: 88, requested: sdk, timeout: .milliseconds(250))
            Issue.record("wildcard-only listener must not establish readiness")
        } catch let error as ToolError {
            #expect(error.code == "simulator_ready_timeout")
        }
    }

    @Test("a changed PID during probing is rejected as unstable identity")
    func rejectsUnstablePID() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let wrongIdentity = SimulatorProcessIdentity(
            pid: 99,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
        let runner = FakeProcessRunner { _ in
            Issue.record("lsof must not run after identity changes")
            return (0, Data(), Data())
        }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            identityLookup: { _ in wrongIdentity })

        do {
            _ = try await probe.waitUntilReady(pid: 88, requested: sdk)
            Issue.record("changed process identity must fail")
        } catch let error as ToolError {
            #expect(error.code == "simulator_process_changed")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("identity changing across one lsof sample is rejected")
    func rejectsIdentityChangeAcrossSample() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let first = SimulatorProcessIdentity(
            pid: 101,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
        let changed = SimulatorProcessIdentity(
            pid: 101,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator-changed").path,
            sdk: sdk)
        let sequence = IdentitySequence([first, changed])
        let runner = FakeProcessRunner { _ in
            (0, Data("p101\nf11\nn127.0.0.1:1234\n".utf8), Data())
        }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            identityLookup: { _ in sequence.next() })

        do {
            _ = try await probe.waitUntilReady(pid: 101, requested: sdk)
            Issue.record("changed identity must fail before a stable observation")
        } catch let error as ToolError {
            #expect(error.code == "simulator_process_changed")
        }
    }

    @Test("stable readiness requires a full 100 monotonic milliseconds")
    func stableProofRequiresFullInterval() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let identity = SimulatorProcessIdentity(
            pid: 102,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
        let clock = FakeClock()
        let runner = FakeProcessRunner { _ in
            (0, Data("p102\nf11\nn127.0.0.1:1234\n".utf8), Data())
        }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            clock: clock,
            identityLookup: { _ in identity })
        let task = Task {
            try await probe.waitUntilReady(pid: 102, requested: sdk, timeout: .seconds(1))
        }
        #expect(await waitUntilProbe { clock.pendingSleepCount == 1 })

        clock.advance(by: .milliseconds(99))
        await Task.yield()
        #expect(clock.pendingSleepCount == 1, "99 ms must not complete the stable proof")

        clock.advance(by: .milliseconds(1))
        let observation = try await task.value
        #expect(observation.identity == identity)
    }

    @Test("a matching observation at the overall deadline times out instead of succeeding late")
    func matchingObservationAtDeadlineFails() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let identity = SimulatorProcessIdentity(
            pid: 103,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
        let clock = FakeClock()
        let runner = FakeProcessRunner { _ in
            (0, Data("p103\nf11\nn127.0.0.1:1234\n".utf8), Data())
        }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            clock: clock,
            identityLookup: { _ in identity })
        let task = Task {
            try await probe.waitUntilReady(
                pid: 103, requested: sdk, timeout: .milliseconds(99))
        }
        #expect(await waitUntilProbe { clock.pendingSleepCount == 1 })
        clock.advance(by: .milliseconds(99))

        do {
            _ = try await task.value
            Issue.record("an observation at the expired overall deadline must not succeed")
        } catch let error as ToolError {
            #expect(error.code == "simulator_ready_timeout")
        }
    }

    @Test("an observation that itself overruns the deadline is rejected")
    func suspendedObservationCannotSucceedLate() async throws {
        let sdk = sampleSDK(version: "9.1.0")
        let identity = SimulatorProcessIdentity(
            pid: 104,
            executablePath: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
            sdk: sdk)
        let clock = FakeClock()
        let gate = ProbeGate()
        let runner = FakeProcessRunner { _ in
            await gate.enter()
            await gate.waitForRelease()
            return (0, Data("p104\nf11\nn127.0.0.1:1234\n".utf8), Data())
        }
        let probe = SimulatorReadinessProbe(
            processRunner: runner,
            clock: clock,
            identityLookup: { _ in identity })
        let task = Task {
            try await probe.waitUntilReady(
                pid: 104, requested: sdk, timeout: .milliseconds(50))
        }
        await gate.waitUntilEntered()
        clock.advance(by: .milliseconds(100))
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("an observation completed after the overall deadline must fail")
        } catch let error as ToolError {
            #expect(error.code == "simulator_ready_timeout")
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func incrementAndGet() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class IdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SimulatorProcessIdentity]

    init(_ values: [SimulatorProcessIdentity]) { self.values = values }

    func next() -> SimulatorProcessIdentity? {
        lock.withLock {
            guard !values.isEmpty else { return nil }
            return values.removeFirst()
        }
    }
}

private actor ProbeGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

func sampleSDK(version: String) -> SdkInfo {
    SdkInfo(
        version: SemVer(version)!,
        root: URL(fileURLWithPath: "/tmp/connectiq-sdk-mac-\(version)", isDirectory: true),
        source: .explicit)
}

private func waitUntilProbe(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if predicate() { return true }
        await Task.yield()
    }
    return false
}
