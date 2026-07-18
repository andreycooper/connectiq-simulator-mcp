import Foundation
import Network
import Testing
@testable import SimulatorMCPCore

@Suite("Loopback capture proxy")
struct LoopbackCaptureProxyTests {
    @Test("delayed nonterminal send completion is a stop barrier")
    func delayedSendStopBarrier() async throws {
        let proxy = try testProxy()
        let release = proxy.holdWorkForTesting()
        let done = BoolBox()
        let stopping = Task {
            try await proxy.stop()
            done.set(true)
        }
        await Task.yield()
        #expect(done.value == false)
        release()
        try await stopping.value
        #expect(done.value == true)
    }

    @Test("terminal proxy errors propagate through stop")
    func terminalErrorPropagation() async throws {
        let proxy = try testProxy()
        proxy.injectTerminalErrorForTesting()
        do {
            try await proxy.stop()
            Issue.record("terminal proxy error must propagate through stop")
        } catch ProxyError.transcriptWriteFailed {
            // expected
        }
    }

    @Test("accept and stop race completes without hanging")
    func acceptStopRace() async throws {
        let proxy = try testProxy()
        try await proxy.start()
        let callback = proxy.holdNextListenerCallbackForTesting()
        let barrier = proxy.observeStopBarrierForTesting()
        let port = try #require(proxy.localPort)
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        client.start(queue: .global(qos: .userInitiated))
        await callback.waitUntilStarted()
        let stopped = BoolBox()
        let stopping = Task {
            try await proxy.stop()
            stopped.set(true)
        }
        await barrier.waitUntilStarted()
        let deadline = ContinuousClock.now + .milliseconds(20)
        while !stopped.value && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!stopped.value)
        callback.release()
        try await stopping.value
        client.cancel()
        #expect(stopped.value)
        #expect(proxy.didRejectSecondClient)
    }

    @Test("forwards both directions and records both terminal byte streams")
    func forwardsAndCaptures() async throws {
        let target = try NWListener(using: .tcp, on: .any)
        let targetReady = ReadyGate()
        let serverPayload = Data("from-client".utf8)
        let clientPayload = Data("from-server".utf8)
        let serverReceived = DataBox()
        let clientReceived = DataBox()

        target.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                        if let data { serverReceived.set(data) }
                        connection.send(content: clientPayload, completion: .contentProcessed { _ in })
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        target.stateUpdateHandler = { state in
            if case .ready = state { targetReady.signal() }
        }
        target.start(queue: .global(qos: .userInitiated))
        await targetReady.wait()
        let targetPort = try #require(target.port?.rawValue)

        let transcriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "button-proxy-\(UUID().uuidString).bin")
        let proxy = try LoopbackCaptureProxy(context: OperationContext(
            simulatorPid: 1, sdk: SdkInfo(version: SemVer(major: 9, minor: 1, patch: 0),
                root: URL(fileURLWithPath: "/tmp/sdk"), source: .explicit), currentDevice: nil,
            listeningEndpoints: [TCPEndpoint(address: "127.0.0.1", port: targetPort, family: "ipv4")]),
            transcriptURL: transcriptURL)
        try await proxy.start()
        let proxyPort = try #require(proxy.localPort)
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        let clientReady = ReadyGate()
        client.stateUpdateHandler = { state in if case .ready = state { clientReady.signal() } }
        client.start(queue: .global(qos: .userInitiated))
        await clientReady.wait()
        let rejection = proxy.observeSecondClientRejectionForTesting()
        let second = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        second.stateUpdateHandler = { state in
            _ = state
        }
        second.start(queue: .global(qos: .userInitiated))
        await rejection.waitUntilStarted()
        #expect(proxy.didRejectSecondClient, "a second client must be rejected")
        client.send(content: serverPayload, isComplete: true, completion: .contentProcessed { _ in })
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
            if let data { clientReceived.set(data) }
        }

        #expect(await serverReceived.wait() == serverPayload)
        #expect(await clientReceived.wait() == clientPayload)
        let beforeStop = try Data(contentsOf: transcriptURL)
        try await proxy.stop()
        second.cancel()
        client.cancel()
        target.cancel()
        let transcript = try Data(contentsOf: transcriptURL)
        #expect(transcript.contains(serverPayload))
        #expect(transcript.contains(clientPayload))
        #expect(transcript == beforeStop)
        try? FileManager.default.removeItem(at: transcriptURL)
    }
}

private func testProxy() throws -> LoopbackCaptureProxy {
    try LoopbackCaptureProxy(context: OperationContext(
        simulatorPid: 1,
        sdk: SdkInfo(version: SemVer(major: 9, minor: 1, patch: 0),
            root: URL(fileURLWithPath: "/tmp/sdk"), source: .explicit),
        currentDevice: nil,
        listeningEndpoints: [TCPEndpoint(address: "127.0.0.1", port: 4312, family: "ipv4")]),
        transcriptURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "proxy-test-\(UUID().uuidString).transcript"))
}

private final class ReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { lock.withLock { signalled = true; let values = waiters; waiters.removeAll(); values.forEach { $0.resume() } } }
    func wait() async { await withCheckedContinuation { c in lock.withLock { if signalled { c.resume() } else { waiters.append(c) } } } }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var waiters: [CheckedContinuation<Data, Never>] = []
    func set(_ value: Data) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Data, Never>] in
            self.value = value
            let result = waiters
            waiters.removeAll()
            return result
        }
        continuations.forEach { $0.resume(returning: value) }
    }
    var data: Data? { lock.withLock { value } }
    func wait() async -> Data {
        await withCheckedContinuation { continuation in
            let current: Data? = lock.withLock {
                if let value { return value }
                waiters.append(continuation)
                return nil
            }
            if let current { continuation.resume(returning: current) }
        }
    }
}

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set(_ value: Bool) { lock.withLock { stored = value } }
    var value: Bool { lock.withLock { stored } }
}
