import Darwin
import Foundation
import MCP

import SimulatorMCPCore

struct InstalledToolResponse<Result: Codable & Sendable>: Sendable {
    let content: [Tool.Content]
    let envelope: ToolEnvelope<Result>
    let isError: Bool
}

enum InstalledServerClientError: Error, CustomStringConvertible {
    case notStarted
    case alreadyStarted
    case executableMissing(String)
    case pipeConfiguration(Int32)
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
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var didListTools = false

    init(executableURL: URL) {
        self.executableURL = executableURL.standardizedFileURL
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() async throws {
        guard process == nil else { throw InstalledServerClientError.alreadyStarted }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw InstalledServerClientError.executableMissing(executableURL.path)
        }

        let child = Process()
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        child.executableURL = executableURL
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errorPipe

        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw InstalledServerClientError.pipeConfiguration(errno)
        }

        let diagnosticBuffer = diagnostics
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { diagnosticBuffer.append(data) }
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

        do {
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
            await stop()
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
        diagnostics.text()
    }

    func stop() async {
        guard let process else { return }

        stdinHandle?.closeFile()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning, ContinuousClock.now < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        stderrHandle?.readabilityHandler = nil
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        self.process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        didListTools = false
    }

    private func nextID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func notify(method: String, params: [String: Any]) throws {
        try writeJSON(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        try writeJSON([
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])

        while true {
            let response = try readJSONLine()
            guard response["id"] != nil else { continue }
            let actualID = (response["id"] as? NSNumber)?.intValue
            guard actualID == id else {
                throw InstalledServerClientError.mismatchedResponse(expected: id, actual: actualID)
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
}

let task17RequiredToolNames: Set<String> = [
    "doctor", "list_sdks", "list_devices", "build", "sim_start", "sim_stop",
    "sim_status", "run_app", "run_tests", "get_logs", "screenshot", "set_gps_position",
]

func validateTask17ToolAdvertisement(_ toolNames: [String]) throws {
    let advertised = Set(toolNames)
    let missing = task17RequiredToolNames.subtracting(advertised).sorted()
    let forbidden = advertised.intersection(["press_button"]).sorted()
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

    func text() -> String {
        lock.lock()
        let snapshot = bytes
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}
