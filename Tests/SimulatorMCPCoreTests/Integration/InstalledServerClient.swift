import Darwin
import Foundation
import MCP

import SimulatorMCPCore

struct InstalledToolResponse<Result: Codable & Sendable>: Sendable {
    let content: [Tool.Content]
    let envelope: ToolEnvelope<Result>
    let isError: Bool
}

enum InstalledServerClientEvent: Equatable, Sendable {
    case requestWritten(id: Int, method: String, tool: String?, monotonicNanos: UInt64)
    case responseReceived(id: Int, method: String, tool: String?, monotonicNanos: UInt64)
    case stopStarted(monotonicNanos: UInt64)
    case stdinClosed(monotonicNanos: UInt64)
    case serverExited(monotonicNanos: UInt64)
    case terminateSent(monotonicNanos: UInt64)
    case stopCompleted(monotonicNanos: UInt64)
    case emergencyCleanupStarted(monotonicNanos: UInt64)
    case emergencySIGKILLSent(monotonicNanos: UInt64)
    case emergencyServerExited(monotonicNanos: UInt64)
    case emergencyCleanupCompleted(monotonicNanos: UInt64)
}

enum InstalledServerClientError: Error, CustomStringConvertible {
    case notStarted
    case alreadyStarted
    case executableMissing(String)
    case pipeConfiguration(Int32)
    case pidPublicationFailed(String)
    case pidCleanupFailed(String)
    case toolListRequired
    case invalidToolAdvertisement(missing: [String], forbidden: [String])
    case serverClosed(stderr: String)
    case malformedResponse(String)
    case mismatchedResponse(expected: Int, actual: Int?)
    case remote(code: Int?, message: String, data: String?)

    var description: String {
        switch self {
        case .notStarted:
            return "The installed server client has not been started."
        case .alreadyStarted:
            return "The installed server client is already running."
        case .executableMissing(let path):
            return "The installed server executable does not exist at \(path)."
        case .pipeConfiguration(let code):
            return "Could not disable SIGPIPE for installed-server stdin (errno \(code))."
        case .pidPublicationFailed(let reason):
            return "Could not publish the installed-server child PID atomically: \(reason)"
        case .pidCleanupFailed(let reason):
            return "Could not prove cleanup of the installed-server child PID file: \(reason)"
        case .toolListRequired:
            return "Call tools/list and validate the installed server's advertised tools before calling a tool."
        case .invalidToolAdvertisement(let missing, let forbidden):
            return "Installed tools/list failed the Task 17 contract; missing=\(missing), forbidden=\(forbidden)."
        case .serverClosed(let stderr):
            return "The installed server closed stdout before replying. stderr: \(stderr)"
        case .malformedResponse(let reason):
            return "The installed server returned malformed JSON-RPC: \(reason)"
        case .mismatchedResponse(let expected, let actual):
            let actualText = actual.map(String.init) ?? "nil"
            return "Expected JSON-RPC response id \(expected), got \(actualText)."
        case .remote(let code, let message, let data):
            let suffix = data.map { " data=\($0)" } ?? ""
            let codeText = code.map(String.init) ?? "unknown"
            return "JSON-RPC error \(codeText): \(message)\(suffix)"
        }
    }
}

/// Test-only client for the installed public stdio boundary.
///
/// `Foundation.Process` intentionally lives under `Tests/`; production process
/// creation remains confined to `Support/Subprocess.swift`. Requests are
/// serialized by this actor, stdout is parsed only as newline-delimited
/// JSON-RPC, and stderr is drained independently into a bounded buffer.
actor InstalledServerClient {
    nonisolated let executableURL: URL

    private let diagnostics = InstalledServerDiagnosticBuffer(capacity: 64 * 1024)
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var processExitBarrier: InstalledServerProcessExitBarrier?
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var didListTools = false
    private let eventSink: @Sendable (InstalledServerClientEvent) -> Void
    private let arguments: [String]
    private let baseEnvironment: [String: String]
    private let pidFile: URL?
    private var publishedPID: pid_t?
    private var pidCleanupUncertain = false
    private let gracefulStopTimeout: Duration
    private let terminatedStopTimeout: Duration
    private let emergencyCleanupTimeout: Duration
    private var finalDiagnosticSnapshot = ""

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gracefulStopTimeout: Duration = .seconds(5),
        terminatedStopTimeout: Duration = .seconds(1),
        emergencyCleanupTimeout: Duration = .seconds(2),
        eventSink: @escaping @Sendable (InstalledServerClientEvent) -> Void = { _ in }
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.arguments = arguments
        baseEnvironment = environment
        if let path = environment["SIM_BUTTON_QUALIFICATION_CLIENT_PID_FILE"], !path.isEmpty {
            pidFile = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            pidFile = nil
        }
        self.gracefulStopTimeout = gracefulStopTimeout
        self.terminatedStopTimeout = terminatedStopTimeout
        self.emergencyCleanupTimeout = emergencyCleanupTimeout
        self.eventSink = eventSink
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() async throws {
        guard process == nil else { throw InstalledServerClientError.alreadyStarted }
        guard !pidCleanupUncertain else {
            throw InstalledServerClientError.pidCleanupFailed(
                "the previous child PID file cleanup is still uncertain")
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw InstalledServerClientError.executableMissing(executableURL.path)
        }

        let child = Process()
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        child.environment = Self.environment(
            preserving: baseEnvironment)
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errorPipe
        let exitBarrier = InstalledServerProcessExitBarrier()
        child.terminationHandler = { _ in exitBarrier.complete() }

        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw InstalledServerClientError.pipeConfiguration(errno)
        }

        let diagnosticBuffer = diagnostics
        diagnosticBuffer.reset()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { diagnosticBuffer.complete() } else { diagnosticBuffer.append(data) }
        }

        do {
            try child.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        process = child
        stdinHandle = input.fileHandleForWriting
        stdoutHandle = output.fileHandleForReading
        stderrHandle = errorPipe.fileHandleForReading
        processExitBarrier = exitBarrier

        do {
            try publishOwnedPID(child.processIdentifier)
            let initializeID = nextID()
            _ = try request(
                id: initializeID,
                method: "initialize",
                params: [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": ["name": "simulator-mcp-installed-tests", "version": "0.1.0"],
                ])
            try notify(method: "notifications/initialized", params: [:])
        } catch {
            let cleanupProven = await stop()
            if !cleanupProven {
                throw InstalledServerClientError.pidCleanupFailed(
                    "the child did not complete bounded cleanup or its published PID file was not owned")
            }
            throw error
        }
    }

    func listTools() throws -> [String] {
        let result = try request(id: nextID(), method: "tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else {
            throw InstalledServerClientError.malformedResponse("tools/list result has no tools array")
        }
        let names = try tools.map { tool in
            guard let name = tool["name"] as? String else {
                throw InstalledServerClientError.malformedResponse("tools/list contains a tool without a name")
            }
            return name
        }
        didListTools = true
        return names
    }

    func callTool<Result: Codable & Sendable>(
        _ name: String,
        arguments: [String: JSONValue] = [:],
        as: Result.Type = Result.self
    ) throws -> InstalledToolResponse<Result> {
        guard didListTools else { throw InstalledServerClientError.toolListRequired }
        let encodedArguments = try Self.jsonObject(arguments)
        let result = try request(
            id: nextID(), method: "tools/call",
            params: ["name": name, "arguments": encodedArguments])
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let raw = try JSONDecoder().decode(CallTool.Result.self, from: data)
        guard let structured = raw.structuredContent else {
            throw InstalledServerClientError.malformedResponse(
                "tools/call result has no structuredContent")
        }
        let structuredData = try JSONEncoder().encode(structured)
        let envelope = try JSONDecoder().decode(ToolEnvelope<Result>.self, from: structuredData)
        return InstalledToolResponse(
            content: raw.content, envelope: envelope, isError: raw.isError ?? false)
    }

    func diagnosticText() -> String {
        process == nil ? finalDiagnosticSnapshot : diagnostics.text()
    }

    @discardableResult
    func stop() async -> Bool {
        guard let process else {
            return resolvePIDCleanupUncertainty()
        }
        eventSink(.stopStarted(monotonicNanos: DispatchTime.now().uptimeNanoseconds))

        stdinHandle?.closeFile()
        eventSink(.stdinClosed(monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        var exited = await processExitBarrier?.wait(timeout: gracefulStopTimeout) ?? !process.isRunning
        if !exited {
            process.terminate()
            eventSink(.terminateSent(monotonicNanos: DispatchTime.now().uptimeNanoseconds))
            exited = await processExitBarrier?.wait(timeout: terminatedStopTimeout) ?? !process.isRunning
        }

        guard exited else {
            // Fail closed: retain the pipe, handler, and process ownership rather
            // than claiming a completed stop without an EOF/drain barrier.
            finalDiagnosticSnapshot = diagnostics.text()
            return false
        }
        eventSink(.serverExited(monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        await diagnostics.waitUntilComplete()
        guard releaseExitedProcess() else { return false }
        eventSink(.stopCompleted(monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        return true
    }

    @discardableResult
    func emergencyCleanupRetainedChild() async -> Bool {
        guard let process else {
            return resolvePIDCleanupUncertainty()
        }
        eventSink(.emergencyCleanupStarted(monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        if process.isRunning {
            guard kill(process.processIdentifier, SIGKILL) == 0 else { return false }
            eventSink(.emergencySIGKILLSent(monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        }
        let exited = await processExitBarrier?.wait(timeout: emergencyCleanupTimeout) ?? !process.isRunning
        guard exited else { return false }
        eventSink(.emergencyServerExited(monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        await diagnostics.waitUntilComplete()
        guard releaseExitedProcess() else { return false }
        eventSink(.emergencyCleanupCompleted(monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        return true
    }

    var runningPID: pid_t? { process?.processIdentifier }

    private func publishOwnedPID(_ pid: pid_t) throws {
        guard let pidFile else { return }
        let parent = pidFile.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw InstalledServerClientError.pidPublicationFailed(
                "the PID-file parent does not exist: \(parent.path)")
        }

        do {
            try Data("\(pid)\n".utf8).write(to: pidFile, options: [.atomic])
        } catch {
            throw InstalledServerClientError.pidPublicationFailed(
                "writing \(pidFile.path) failed: \(error.localizedDescription)")
        }
        publishedPID = pid
    }

    private func removePublishedPIDIfOwned() -> Bool {
        guard let pidFile, let publishedPID else { return true }

        guard FileManager.default.fileExists(atPath: pidFile.path) else {
            self.publishedPID = nil
            pidCleanupUncertain = false
            return true
        }
        do {
            let contents = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard contents == String(publishedPID) else {
                pidCleanupUncertain = true
                return false
            }
            try FileManager.default.removeItem(at: pidFile)
            guard !FileManager.default.fileExists(atPath: pidFile.path) else {
                pidCleanupUncertain = true
                return false
            }
            self.publishedPID = nil
            pidCleanupUncertain = false
            return true
        } catch {
            pidCleanupUncertain = true
            return false
        }
    }

    private func resolvePIDCleanupUncertainty() -> Bool {
        guard pidCleanupUncertain else { return true }
        return removePublishedPIDIfOwned() && !pidCleanupUncertain
    }

    private func releaseExitedProcess() -> Bool {
        let pidCleanupProven = removePublishedPIDIfOwned()
        if !pidCleanupProven { pidCleanupUncertain = true }
        finalDiagnosticSnapshot = diagnostics.text()
        stderrHandle?.readabilityHandler = nil
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        processExitBarrier = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        didListTools = false
        return pidCleanupProven
    }

    private func nextID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func notify(method: String, params: [String: Any]) throws {
        try writeJSON(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        let tool = method == "tools/call" ? params["name"] as? String : nil
        try writeJSON([
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        if tool != "get_logs" {
            eventSink(.requestWritten(
                id: id, method: method, tool: tool,
                monotonicNanos: DispatchTime.now().uptimeNanoseconds))
        }

        while true {
            let response = try readJSONLine()
            guard response["id"] != nil else { continue }
            let actualID = (response["id"] as? NSNumber)?.intValue
            guard actualID == id else {
                throw InstalledServerClientError.mismatchedResponse(expected: id, actual: actualID)
            }
            if tool != "get_logs" {
                eventSink(.responseReceived(
                    id: id, method: method, tool: tool,
                    monotonicNanos: DispatchTime.now().uptimeNanoseconds))
            }
            if let error = response["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue
                let message = error["message"] as? String ?? "Unknown JSON-RPC error"
                let data = error["data"].map { String(describing: $0) }
                throw InstalledServerClientError.remote(code: code, message: message, data: data)
            }
            guard let result = response["result"] as? [String: Any] else {
                throw InstalledServerClientError.malformedResponse("response has no object result")
            }
            return result
        }
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard let stdinHandle else { throw InstalledServerClientError.notStarted }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    private func readJSONLine() throws -> [String: Any] {
        guard let stdoutHandle else { throw InstalledServerClientError.notStarted }
        while true {
            if let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = stdoutBuffer[..<newline]
                stdoutBuffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw InstalledServerClientError.malformedResponse("response line is not an object")
                }
                return object
            }

            let chunk = stdoutHandle.availableData
            guard !chunk.isEmpty else {
                throw InstalledServerClientError.serverClosed(stderr: diagnostics.text())
            }
            stdoutBuffer.append(chunk)
        }
    }

    private static func jsonObject(_ value: some Encodable) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// The server publishes exactly one tool surface, so the launch
    /// environment carries no selector that could swap it.
    nonisolated static func environment(
        preserving base: [String: String]
    ) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "SIM_BUTTON_QUALIFICATION")
        return environment
    }
}

private final class InstalledServerProcessExitBarrier: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timer: DispatchSourceTimer
    }

    private let lock = NSLock()
    private var completed = false
    private var waiters: [UUID: Waiter] = [:]

    func complete() {
        lock.lock()
        completed = true
        let snapshot = waiters.values
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        snapshot.forEach {
            $0.timer.cancel()
            $0.continuation.resume(returning: true)
        }
    }

    func wait(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.setEventHandler { [weak self] in self?.timeOut(id: id) }
            lock.lock()
            if completed {
                lock.unlock()
                timer.cancel()
                timer.resume()
                continuation.resume(returning: true)
                return
            }
            waiters[id] = Waiter(continuation: continuation, timer: timer)
            lock.unlock()
            let components = timeout.components
            let nanoseconds = components.seconds * 1_000_000_000
                + Int64(components.attoseconds / 1_000_000_000)
            timer.schedule(deadline: .now() + .nanoseconds(Int(nanoseconds)))
            timer.resume()
        }
    }

    private func timeOut(id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.continuation.resume(returning: false)
    }
}

let task17RequiredToolNames: Set<String> = [
    "doctor", "list_sdks", "list_devices", "build", "sim_start", "sim_stop",
    "sim_status", "run_app", "run_tests", "get_logs", "screenshot", "set_gps_position",
    "press_button", "run_sequence",
]

func validateTask17ToolAdvertisement(_ toolNames: [String]) throws {
    let advertised = Set(toolNames)
    let missing = task17RequiredToolNames.subtracting(advertised).sorted()
    let duplicates = Dictionary(grouping: toolNames, by: { $0 })
        .filter { $0.value.count > 1 }.map(\.key)
    let forbidden = (advertised.subtracting(task17RequiredToolNames) + duplicates).sorted()
    guard missing.isEmpty, forbidden.isEmpty else {
        throw InstalledServerClientError.invalidToolAdvertisement(
            missing: missing, forbidden: forbidden)
    }
}



/// Safety invariant: every byte mutation and snapshot is protected by `lock`;
/// no reference to mutable storage escapes. This test-only bridge is required
/// because `FileHandle.readabilityHandler` is callback-based. Remove it when
/// Foundation provides an async, Sendable pipe-drain API usable on macOS 14.
private final class InstalledServerDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var bytes = Data()
    private var completed = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ data: Data) {
        lock.lock()
        bytes.append(data)
        if bytes.count > capacity {
            bytes.removeFirst(bytes.count - capacity)
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        bytes.removeAll(keepingCapacity: false)
        completed = false
        completionWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func complete() {
        lock.lock()
        completed = true
        let waiters = completionWaiters
        completionWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitUntilComplete() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
            } else {
                completionWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func text() -> String {
        lock.lock()
        let snapshot = bytes
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}
