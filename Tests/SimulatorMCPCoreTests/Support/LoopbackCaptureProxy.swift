import Foundation
import Network
import SimulatorMCPCore

final class LoopbackCaptureProxy: @unchecked Sendable {
    private let listener: NWListener
    private let target: NWEndpoint.Host
    private let targetPort: NWEndpoint.Port
    private let transcriptURL: URL
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var accepted = false
    private var stopping = false
    private var rejectedSecondClient = false
    private var terminal = false
    private var terminalError: Error?
    private var completedDirections = 0
    private var inFlight = 0
    private var terminalWaiters: [CheckedContinuation<Void, Error>] = []
    private var listenerCallbacks = 0
    private var listenerCancelled = false
    private var listenerStarted = false
    private var listenerWaiters: [CheckedContinuation<Void, Never>] = []
    private var listenerHold: ProxyTestGate?
    private var stopBarrier: ProxyTestGate?
    private var rejectionGate: ProxyTestGate?

    private init(endpoint: TCPEndpoint, transcriptURL: URL) throws {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw ProxyError.invalidEndpoint }
        self.target = NWEndpoint.Host(endpoint.address)
        self.targetPort = port
        self.transcriptURL = transcriptURL
        self.listener = try NWListener(using: .tcp, on: .any)
        listener.parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: .any)
    }

    convenience init(context: OperationContext, transcriptURL: URL) throws {
        let endpoints = context.listeningEndpoints.filter {
            ($0.family == "ipv4" && $0.address == "127.0.0.1")
                || ($0.family == "ipv6" && $0.address == "::1")
                || $0.address == "localhost"
        }
        guard endpoints.count == 1, let endpoint = endpoints.first else {
            throw ToolError(code: "simulator_not_ready",
                message: "The capture proxy requires exactly one validated loopback listener.",
                fix: "Run the proxy inside withSerializedProbe and provide its OperationContext.")
        }
        try self.init(endpoint: endpoint, transcriptURL: transcriptURL)
    }

    var localPort: UInt16? { listener.port?.rawValue }
    var didRejectSecondClient: Bool { lock.withLock { rejectedSecondClient } }

    /// Deterministic test hook: models a receive/send unit whose completion is
    /// deliberately delayed until the returned closure is invoked.
    func holdWorkForTesting() -> @Sendable () -> Void {
        guard let unit = beginWork() else { return {} }
        return { unit.complete() }
    }

    func injectTerminalErrorForTesting() {
        finish(ProxyError.transcriptWriteFailed)
    }

    func holdNextListenerCallbackForTesting() -> ProxyTestGate {
        let gate = ProxyTestGate()
        lock.withLock { listenerHold = gate }
        return gate
    }

    func observeStopBarrierForTesting() -> ProxyTestGate {
        let gate = ProxyTestGate()
        lock.withLock { stopBarrier = gate }
        return gate
    }

    func observeSecondClientRejectionForTesting() -> ProxyTestGate {
        let gate = ProxyTestGate()
        lock.withLock { rejectionGate = gate }
        return gate
    }

    func start() async throws {
        let gate = ContinuationGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resume(continuation)
                case .failed(let error): gate.resume(continuation, throwing: error)
                case .cancelled:
                    self.markListenerCancelled()
                    gate.resume(continuation, throwing: ProxyError.cancelled)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.beginListenerCallback()
                self.lock.withLock { self.listenerHold }?.blockUntilReleased()
                self.accept(connection)
                self.endListenerCallback()
            }
            self.lock.withLock { self.listenerStarted = true }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() async throws {
        let result = lock.withLock { () -> ([NWConnection], Error?) in
            stopping = true
            let active = connections
            connections.removeAll()
            if !terminal {
                terminal = true
            }
            return (active, terminalError)
        }
        if !lock.withLock({ listenerStarted }) { markListenerCancelled() }
        listener.cancel()
        result.0.forEach { $0.cancel() }
        lock.withLock { stopBarrier }?.signalStarted()
        try await awaitTerminalBarrier()
        await awaitListenerBarrier()
        if let error = result.1 { throw error }
    }

    private func beginListenerCallback() { lock.withLock { listenerCallbacks += 1 } }
    private func endListenerCallback() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            listenerCallbacks -= 1
            guard listenerCallbacks == 0 && listenerCancelled else { return [] }
            let result = listenerWaiters
            listenerWaiters.removeAll()
            return result
        }
        waiters.forEach { $0.resume() }
    }
    private func markListenerCancelled() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            listenerCancelled = true
            guard listenerCallbacks == 0 else { return [] }
            let result = listenerWaiters
            listenerWaiters.removeAll()
            return result
        }
        waiters.forEach { $0.resume() }
    }
    private func awaitListenerBarrier() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let immediate = lock.withLock {
                if listenerCancelled && listenerCallbacks == 0 { return true }
                listenerWaiters.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    private func accept(_ client: NWConnection) {
        guard lock.withLock({
            guard !accepted, !stopping else { return false }
            accepted = true
            let server = NWConnection(host: target, port: targetPort, using: .tcp)
            connections += [client, server]
            configure(client: client, server: server)
            server.start(queue: .global(qos: .userInitiated))
            client.start(queue: .global(qos: .userInitiated))
            return true
        }) else {
            let gate = lock.withLock { () -> ProxyTestGate? in
                rejectedSecondClient = true
                return rejectionGate
            }
            gate?.signalStarted()
            client.start(queue: .global(qos: .userInitiated))
            client.cancel()
            return
        }
    }

    private func configure(client: NWConnection, server: NWConnection) {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.forward(from: client, to: server, direction: "client->server")
            case .failed(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        server.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.forward(from: server, to: client, direction: "server->client")
            case .failed(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
    }

    private func forward(from source: NWConnection, to destination: NWConnection, direction: String) {
        guard let unit = beginWork() else { return }
        let owner = self
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if self.isTerminal() { unit.complete(); return }
            if let data, !data.isEmpty {
                do {
                    guard try self.record(direction: direction, data: data) else {
                        unit.complete()
                        return
                    }
                } catch {
                    self.finish(ProxyError.transcriptWriteFailed)
                    unit.complete()
                    return
                }
                guard let sendUnit = owner.beginWork() else { unit.complete(); return }
                destination.send(content: data, completion: .contentProcessed { error in
                    if let error { owner.finish(error) }
                    sendUnit.complete()
                    if !isComplete {
                        unit.complete()
                        owner.forward(from: source, to: destination, direction: direction)
                    }
                })
            }
            if let error { self.finish(error); unit.complete() }
            else if isComplete {
                guard let sendUnit = owner.beginWork() else { unit.complete(); return }
                destination.send(content: nil, completion: .contentProcessed { error in
                    if let error { owner.finish(error) }
                    else { owner.completeDirection() }
                    sendUnit.complete()
                    unit.complete()
                })
            }
            else if data == nil { unit.complete() }
        }
    }

    private func beginWork() -> WorkUnit? {
        lock.withLock {
            guard !terminal else { return nil }
            inFlight += 1
            return WorkUnit(owner: self)
        }
    }

    fileprivate func completeWork() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            precondition(inFlight > 0, "proxy work completion without a matching unit")
            inFlight -= 1
            guard terminal && inFlight == 0 else { return [] }
            let result = terminalWaiters
            terminalWaiters.removeAll()
            return result
        }
        resume(waiters)
    }

    private func resume(_ waiters: [CheckedContinuation<Void, Error>]) {
        for waiter in waiters {
            if let error = terminalError { waiter.resume(throwing: error) }
            else { waiter.resume() }
        }
    }

    private func isTerminal() -> Bool { lock.withLock { terminal } }

    private func awaitTerminalBarrier() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let immediate = lock.withLock { () -> Bool in
                if terminal && inFlight == 0 { return true }
                terminalWaiters.append(continuation)
                return false
            }
            if immediate {
                if let error = terminalError { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func completeDirection() {
        let complete = lock.withLock {
            completedDirections += 1
            return completedDirections >= 2
        }
        if complete { finish(nil) }
    }

    private func finish(_ error: Error?) {
        let result = lock.withLock { () -> [NWConnection] in
            guard !terminal else { return [] }
            terminal = true
            terminalError = error
            let active = connections
            connections.removeAll()
            return active
        }
        result.forEach { $0.cancel() }
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard terminal && inFlight == 0 else { return [] }
            let result = terminalWaiters
            terminalWaiters.removeAll()
            return result
        }
        resume(waiters)
    }

    private func record(direction: String, data: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return false }
        var existing = (try? Data(contentsOf: transcriptURL)) ?? Data()
        existing.append(Data("\(direction) \(data.count)\n".utf8))
        existing.append(data)
        try existing.write(to: transcriptURL, options: .atomic)
        return true
    }
}

enum ProxyError: Error { case invalidEndpoint, cancelled, transcriptWriteFailed }

final class ProxyTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signalStarted() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            started = true
            let result = waiters
            waiters.removeAll()
            return result
        }
        continuations.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if started { return true }
                waiters.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    func blockUntilReleased() {
        signalStarted()
        releaseSemaphore.wait()
    }

    func release() { releaseSemaphore.signal() }
}

private final class WorkUnit: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private weak var owner: LoopbackCaptureProxy?

    init(owner: LoopbackCaptureProxy) { self.owner = owner }

    func complete() {
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldComplete { owner?.completeWork() }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func resume(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation.resume()
    }

    func resume(_ continuation: CheckedContinuation<Void, Error>, throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation.resume(throwing: error)
    }
}
