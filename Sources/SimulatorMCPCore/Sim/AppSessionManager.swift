import Foundation

public enum SessionState: String, Codable, Equatable, Sendable {
    case running
    case exited
    case replaced
}

public enum TerminationReason: String, Codable, Equatable, Sendable {
    case normal
    case crashDetected
    case killed
}

public struct PendingSession: Sendable {
    public let proposedId: UInt64
    public let owned: OwnedMonkeydoProcess

    fileprivate let nonce: UUID

    fileprivate init(proposedId: UInt64, owned: OwnedMonkeydoProcess, nonce: UUID) {
        self.proposedId = proposedId
        self.owned = owned
        self.nonce = nonce
    }
}

/// Owns the one published monkeydo session and its in-flight replacement.
///
/// `ProcessRunning` invokes stream callbacks synchronously from its pipe
/// consumers. Those callbacks write into a lock-backed `SessionEventBuffer`;
/// the child wait cannot complete until both pipe consumers have drained, so
/// exit classification always observes every complete line without relying on
/// actor-task scheduling. The actor remains the sole owner of publication,
/// replacement, termination, and cursor state.
public actor AppSessionManager: SimulatorSessionStopping {
    private struct SessionRecord: Sendable {
        let id: UInt64
        let nonce: UUID
        var owned: OwnedMonkeydoProcess
        let buffer: SessionEventBuffer
        var state: SessionState
        var terminationReason: TerminationReason?
        var exitCode: Int32?
        var explicitTermination: TerminationReason?
        var exitApplied: Bool
        var waitTask: Task<Void, Never>?
        var device: String?
        var prgPath: URL?
        var sdk: SdkInfo?
    }

    private struct Cursor: Codable, Sendable {
        let version: Int
        let instanceId: String
        let sessionId: UInt64
        let seq: UInt64
    }

    private static let cursorVersion = 1
    private static let tombstoneCapacity = 32
    private static let monotonicOrigin = ContinuousClock.now

    private let lifecycle: any MonkeydoProcessLifecycling
    private let instanceID: UUID
    private let timestampNanos: @Sendable () -> Int64
    private let initialLogSequence: UInt64
    private let diagnosticSink: Log.Sink

    private var nextSessionID: UInt64
    private var launchInProgress = false
    private var cleanupInProgress = false
    private var pending: SessionRecord?
    private var current: SessionRecord?
    private var tombstones: [UInt64: UInt64] = [:]
    private var tombstoneOrder: [UInt64] = []

    public init(
        lifecycle: any MonkeydoProcessLifecycling = MonkeydoProcessLifecycle(),
        instanceID: UUID = UUID(),
        timestampNanos: (@Sendable () -> Int64)? = nil,
        initialSessionID: UInt64 = 1,
        initialLogSequence: UInt64 = 1,
        diagnosticSink: @escaping Log.Sink = Log.standardError
    ) {
        self.lifecycle = lifecycle
        self.instanceID = instanceID
        self.timestampNanos = timestampNanos ?? Self.currentMonotonicNanos
        self.initialLogSequence = max(1, initialLogSequence)
        self.nextSessionID = initialSessionID
        self.diagnosticSink = diagnosticSink
    }

    public func beginPending(_ command: MonkeydoCommand) async throws -> PendingSession {
        guard pending == nil, !launchInProgress, !cleanupInProgress else {
            throw ToolError(
                code: "invalid_arguments",
                message: "An app launch or cleanup is already in progress.",
                fix: "Wait for the pending launch cleanup to finish, then retry run_app.")
        }
        guard current?.state != .running else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The current app session is still running.",
                fix: "Call prepareCurrentForReplacement() and await cleanup before starting the replacement.")
        }
        guard nextSessionID <= UInt64(Int.max),
            !nextSessionID.addingReportingOverflow(1).overflow
        else {
            throw ToolError(
                code: "session_id_exhausted",
                message: "The app session ID counter is exhausted.",
                fix: "Restart simulator-mcp to create a fresh server instance and session counter.")
        }

        let proposedID = nextSessionID
        nextSessionID += 1
        launchInProgress = true
        defer { launchInProgress = false }

        let nonce = UUID()
        let buffer = SessionEventBuffer(
            timestampNanos: timestampNanos, initialSequence: initialLogSequence)
        let owned: OwnedMonkeydoProcess
        do {
            owned = try await lifecycle.launchApp(
                command,
                onStdout: { data in buffer.append(data, stream: .stdout) },
                onStderr: { data in buffer.append(data, stream: .stderr) })
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolError {
            throw error
        } catch {
            Log.err(
                "AppSessionManager failed to launch \(command.sdk.monkeydo.path): \(error)",
                sink: diagnosticSink)
            throw ToolError(
                code: "app_launch_failed",
                message: "The simulator app child could not be started.",
                fix: "Verify the selected SDK and PRG path, then retry run_app.",
                details: ["executable": .string(command.sdk.monkeydo.path)])
        }
        var record = SessionRecord(
            id: proposedID,
            nonce: nonce,
            owned: owned,
            buffer: buffer,
            state: .running,
            terminationReason: nil,
            exitCode: nil,
            explicitTermination: nil,
            exitApplied: false,
            waitTask: nil,
            device: nil,
            prgPath: nil,
            sdk: nil)
        pending = record

        let observer = Task { [weak self, owned, buffer, diagnosticSink] in
            do {
                let output = try await owned.output()
                buffer.finishLines()
                await self?.childExited(sessionId: proposedID, output: output)
            } catch {
                buffer.finishLines()
                if !(error is CancellationError) {
                    Log.err(
                        "AppSessionManager wait failed for session \(proposedID): \(error)",
                        sink: diagnosticSink)
                }
                await self?.childExited(
                    sessionId: proposedID,
                    output: ProcessOutput(exitCode: -1, stdout: Data(), stderr: Data()))
            }
        }
        record.waitTask = observer
        pending = record
        let handle = PendingSession(proposedId: proposedID, owned: owned, nonce: nonce)
        if Task.isCancelled {
            _ = try await abortCapturingTail(handle)
            throw CancellationError()
        }
        return handle
    }

    /// `acceptedGroup` is the launcher group the connection probe verified at
    /// accept time. Cleanup needs it to identify a process that is ours but no
    /// longer reachable by parentage — a child reparented to PID 1 when the
    /// launcher died. Empty means cleanup can anchor nothing and refuses, which
    /// is the pre-existing behaviour.
    public func commit(
        _ pendingSession: PendingSession,
        device: String,
        prgPath: URL,
        sdk: SdkInfo,
        acceptedGroup: [StableProcessIdentity] = []
    ) async throws -> UInt64 {
        guard !device.isEmpty else {
            throw ToolError(
                code: "invalid_arguments", message: "The app device is empty.",
                fix: "Pass the verified Connect IQ device profile used for this launch.")
        }
        guard let candidate = pending,
            candidate.id == pendingSession.proposedId,
            candidate.nonce == pendingSession.nonce
        else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The pending app session is no longer active.",
                fix: "Start a new pending app launch and commit that returned handle.")
        }

        guard current?.state != .running else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The current app session was not prepared for replacement.",
                fix: "Call prepareCurrentForReplacement() and await cleanup before committing the candidate.")
        }

        guard var committed = pending,
            committed.id == pendingSession.proposedId,
            committed.nonce == pendingSession.nonce
        else {
            throw ToolError(
                code: "invalid_arguments",
                message: "The pending app session changed before commit.",
                fix: "Retry run_app so it can create and verify a new pending launch.")
        }

        if let old = current {
            old.buffer.discard()
            appendTombstone(old: old.id, newer: committed.id)
        }

        committed.device = device
        committed.prgPath = prgPath
        committed.sdk = sdk
        committed.owned = committed.owned.adoptingAcceptedGroup(acceptedGroup)
        pending = nil
        current = committed
        return committed.id
    }

    public func abort(_ pendingSession: PendingSession) async throws {
        _ = try await abortCapturingTail(pendingSession)
    }

    /// Aborts a pending launch while preserving a bounded diagnostic tail for
    /// the coordinator's retry/final-error reporting. The pending session is
    /// still never published through get_logs.
    func abortCapturingTail(
        _ pendingSession: PendingSession,
        limit: Int = 40
    ) async throws -> [String] {
        guard var candidate = pending,
            candidate.id == pendingSession.proposedId,
            candidate.nonce == pendingSession.nonce
        else { return [] }

        // Publish the transition before the first suspension: neither commit
        // nor another beginPending can observe this candidate as available.
        pending = nil
        cleanupInProgress = true

        if candidate.state == .running {
            candidate.explicitTermination = .killed
        }
        do {
            // Even an exited Bash wrapper can leave an owned descendant.
            // Lifecycle cleanup is therefore also the absence proof for the
            // natural-exit path; observer completion alone is insufficient.
            try await terminateAndAwaitCleanup(
                owned: candidate.owned, observer: candidate.waitTask)
        } catch {
            pending = candidate
            cleanupInProgress = false
            throw error
        }
        candidate.buffer.finishLines()
        let tail = candidate.buffer.snapshot().lines.suffix(max(0, limit)).map(\.text)
        cleanupInProgress = false
        return tail
    }

    public func prepareCurrentForReplacement() async throws {
        try await terminateCurrent(reason: .killed)
    }

    public func terminateCurrent(reason _: TerminationReason) async throws {
        guard var session = current else { return }
        if session.state == .running {
            session.explicitTermination = .killed
            current = session
        }
        try await terminateAndAwaitCleanup(owned: session.owned, observer: session.waitTask)
    }

    public func stopForSimulatorShutdown() async throws {
        try await terminateCurrent(reason: .killed)
    }

    public func logs(
        sessionId: UInt64? = nil,
        sinceToken: String? = nil,
        limit: Int
    ) throws -> GetLogsResult {
        guard (1...2_000).contains(limit) else {
            throw ToolError(
                code: "invalid_arguments",
                message: "Log limit \(limit) is outside the supported range 1...2000.",
                fix: "Pass a log limit between 1 and 2000.",
                details: ["limit": .int(limit)])
        }

        let cursor = try sinceToken.map(decodeCursor)
        if let cursor, cursor.instanceId.lowercased() != instanceID.uuidString.lowercased() {
            throw invalidToken("The token belongs to a different server instance.")
        }
        if let sessionId, let cursor, sessionId != cursor.sessionId {
            throw invalidToken("The explicit session ID does not match the token session ID.")
        }

        let requestedID = sessionId ?? cursor?.sessionId ?? current?.id
        guard let requestedID else {
            throw ToolError(
                code: "no_current_session",
                message: "No app session has been published by this server instance.",
                fix: "Call run_app successfully, then retry get_logs.")
        }
        guard let session = current, requestedID == session.id else {
            if let newer = tombstones[requestedID] {
                throw staleSession(requestedID, newer: newer)
            }
            if let current, requestedID < current.id {
                throw staleSession(requestedID, newer: current.id)
            }
            throw invalidToken("The token names an unknown app session.")
        }

        let snapshot = session.buffer.snapshot()
        guard !snapshot.sequenceExhausted else {
            throw ToolError(
                code: "log_sequence_exhausted",
                message: "The current app session exhausted its UInt64 log sequence space.",
                fix: "Run the app again to create a fresh session and log sequence.")
        }
        let since = cursor?.seq ?? 0
        guard since <= snapshot.lastSequence else {
            throw invalidToken("The token sequence is newer than the named session.")
        }
        let selected = snapshot.lines.lazy.filter { $0.seq > since }.prefix(limit)
        let lines = try selected.map { line -> LogLine in
            guard let seq = Int(exactly: line.seq) else {
                throw ToolError(
                    code: "session_id_exhausted",
                    message: "The log sequence cannot be represented on the public wire contract.",
                    fix: "Restart simulator-mcp to begin a fresh bounded session.")
            }
            return LogLine(
                seq: seq,
                monotonicNanos: line.monotonicNanos,
                stream: line.stream,
                text: line.text,
                crash: line.crash)
        }
        let lastReturned = lines.last.map { UInt64($0.seq) } ?? since
        guard let wireID = Int(exactly: session.id) else {
            throw ToolError(
                code: "session_id_exhausted",
                message: "The app session ID cannot be represented on the public wire contract.",
                fix: "Restart simulator-mcp to create a fresh session counter.")
        }
        return GetLogsResult(
            sessionId: wireID,
            state: session.state.rawValue,
            terminationReason: session.terminationReason?.rawValue,
            exitCode: session.exitCode,
            crashDetected: snapshot.crashDetected,
            droppedLines: snapshot.droppedLines,
            lines: lines,
            nextToken: encodeCursor(sessionID: session.id, seq: lastReturned),
            latestToken: encodeCursor(sessionID: session.id, seq: snapshot.lastSequence))
    }

    // MARK: - Child lifecycle

    private func childExited(sessionId: UInt64, output: ProcessOutput) {
        if var candidate = pending, candidate.id == sessionId, !candidate.exitApplied {
            applyExit(&candidate, output: output)
            pending = candidate
            return
        }
        if var session = current, session.id == sessionId, !session.exitApplied {
            applyExit(&session, output: output)
            current = session
        }
    }

    private func applyExit(_ session: inout SessionRecord, output: ProcessOutput) {
        session.buffer.finishLines()
        let crashDetected = session.buffer.snapshot().crashDetected
        session.state = .exited
        session.exitCode = output.exitCode
        if crashDetected {
            session.terminationReason = .crashDetected
        } else if let explicit = session.explicitTermination {
            session.terminationReason = explicit
        } else if output.exitCode == 0 {
            session.terminationReason = .normal
        } else {
            session.terminationReason = .killed
        }
        session.exitApplied = true
    }

    private func appendTombstone(old: UInt64, newer: UInt64) {
        tombstones[old] = newer
        tombstoneOrder.append(old)
        while tombstoneOrder.count > Self.tombstoneCapacity {
            let evicted = tombstoneOrder.removeFirst()
            tombstones.removeValue(forKey: evicted)
        }
    }

    /// The lifecycle owns the cancellation-resistant TERM/KILL sequence and
    /// shares the process's single drain with the natural-exit observer.
    private func terminateAndAwaitCleanup(
        owned: OwnedMonkeydoProcess,
        observer: Task<Void, Never>?
    ) async throws {
        try await lifecycle.terminate(owned, grace: .seconds(5))
        await observer?.value
    }

    // MARK: - Strict cursors

    private func encodeCursor(sessionID: UInt64, seq: UInt64) -> String {
        let json =
            "{\"instanceId\":\"\(instanceID.uuidString.lowercased())\","
            + "\"seq\":\(seq),\"sessionId\":\(sessionID),\"version\":\(Self.cursorVersion)}"
        return Self.base64URLEncode(Data(json.utf8))
    }

    private func decodeCursor(_ token: String) throws -> Cursor {
        guard !token.isEmpty,
            token.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }),
            let data = Self.base64URLDecode(token),
            Self.base64URLEncode(data) == token,
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys) == Set(["version", "instanceId", "sessionId", "seq"]),
            let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
            cursor.version == Self.cursorVersion,
            UUID(uuidString: cursor.instanceId) != nil
        else {
            throw invalidToken("The token is malformed or uses an unsupported version.")
        }
        return cursor
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ token: String) -> Data? {
        guard token.count % 4 != 1 else { return nil }
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64, options: [])
    }

    private func invalidToken(_ reason: String) -> ToolError {
        ToolError(
            code: "invalid_log_token",
            message: "The log cursor is invalid: \(reason)",
            fix: "Use the nextToken returned by get_logs for the same current session.")
    }

    private func staleSession(_ sessionID: UInt64, newer: UInt64) -> ToolError {
        ToolError(
            code: "stale_session",
            message: "App session \(sessionID) was replaced by session \(newer).",
            fix: "Call get_logs without the old token to read the current session.",
            details: [
                "sessionId": .int(Int(sessionID)),
                "newerSessionId": .int(Int(newer)),
            ])
    }

    private static func currentMonotonicNanos() -> Int64 {
        let components = monotonicOrigin.duration(to: ContinuousClock.now).components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let (whole, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !multiplyOverflow else { return Int64.max }
        let (total, addOverflow) = whole.addingReportingOverflow(nanos)
        guard !addOverflow, total <= UInt64(Int64.max) else { return Int64.max }
        return Int64(total)
    }

    // Deterministic test synchronization and direct duplicate-callback proof.
    func waitForCurrentExitForTesting() async {
        await current?.waitTask?.value
    }

    func waitForPendingExitForTesting() async {
        await pending?.waitTask?.value
    }

    func childExitedForTesting(sessionId: UInt64, output: ProcessOutput) {
        childExited(sessionId: sessionId, output: output)
    }

    var tombstoneCountForTesting: Int { tombstones.count }
    var logSequencesForTesting: [UInt64] {
        (current ?? pending)?.buffer.snapshot().lines.map(\.seq) ?? []
    }
}

private final class SessionEventBuffer: @unchecked Sendable {
    struct Entry: Sendable {
        let seq: UInt64
        let monotonicNanos: Int64
        let stream: LogStream
        let text: String
        let crash: Bool
    }

    struct Snapshot: Sendable {
        let lines: [Entry]
        let droppedLines: Int
        let crashDetected: Bool
        let lastSequence: UInt64
        let sequenceExhausted: Bool
    }

    private static let capacity = 10_000
    private static let crashPatterns: [NSRegularExpression] = [
        #"^\s*Stack(?:\s+Trace)?\s*:"#,
        #"Unhandled\s+Exception"#,
        #"Fatal\s+Error"#,
        #"^\s*Error\s*:"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let excludedPatterns: [NSRegularExpression] = [
        #"^\s*ERROR\s*:\s*[^:]+:\s*.*\.mc(?::|,)"#,
        #"^\s*(?:compiler|tests?|test results?)\s+(?:summary|results?)\s*:"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private let lock = NSLock()
    private let timestampNanos: @Sendable () -> Int64
    private var slots: [Entry?] = Array(repeating: nil, count: capacity)
    private var head = 0
    private var count = 0
    private var partial: [LogStream: Data] = [.stdout: Data(), .stderr: Data()]
    private var partialStartedAt: [LogStream: UInt64] = [:]
    private var nextPartialOrder: UInt64 = 1
    private var nextSequence: UInt64?
    private var lastSequence: UInt64
    private var lastTimestamp: Int64 = 0
    private var droppedLines = 0
    private var crashDetected = false

    init(timestampNanos: @escaping @Sendable () -> Int64, initialSequence: UInt64) {
        self.timestampNanos = timestampNanos
        self.nextSequence = initialSequence
        self.lastSequence = initialSequence - 1
    }

    func append(_ data: Data, stream: LogStream) {
        lock.withLock {
            var bytes = partial[stream] ?? Data()
            if bytes.isEmpty, !data.isEmpty {
                markPartialStart(stream)
            }
            bytes.append(data)
            while let newline = bytes.firstIndex(of: 0x0A) {
                var line = Data(bytes[..<newline])
                if line.last == 0x0D { line.removeLast() }
                appendCompleteLine(String(decoding: line, as: UTF8.self), stream: stream)
                bytes.removeSubrange(...newline)
                partialStartedAt[stream] = nil
                if !bytes.isEmpty { markPartialStart(stream) }
            }
            partial[stream] = bytes
        }
    }

    func finishLines() {
        lock.withLock {
            let trailing = [LogStream.stdout, .stderr].compactMap { stream -> (LogStream, Data, UInt64)? in
                guard let data = partial[stream], !data.isEmpty else { return nil }
                return (stream, data, partialStartedAt[stream] ?? UInt64.max)
            }.sorted { $0.2 < $1.2 }
            for (stream, data, _) in trailing {
                appendCompleteLine(String(decoding: data, as: UTF8.self), stream: stream)
                partial[stream] = Data()
                partialStartedAt[stream] = nil
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            let ordered = (0..<count).compactMap { offset in
                slots[(head + offset) % Self.capacity]
            }
            return Snapshot(
                lines: ordered,
                droppedLines: droppedLines,
                crashDetected: crashDetected,
                lastSequence: lastSequence,
                sequenceExhausted: nextSequence == nil)
        }
    }

    func discard() {
        lock.withLock {
            slots = Array(repeating: nil, count: Self.capacity)
            head = 0
            count = 0
            partial.removeAll(keepingCapacity: false)
            partialStartedAt.removeAll(keepingCapacity: false)
        }
    }

    private func appendCompleteLine(_ text: String, stream: LogStream) {
        guard let sequence = nextSequence else { return }
        lastSequence = sequence
        if sequence == UInt64.max {
            nextSequence = nil
        } else {
            nextSequence = sequence + 1
        }
        let crash = Self.isCrash(text)
        crashDetected = crashDetected || crash
        let timestamp = max(lastTimestamp, timestampNanos())
        lastTimestamp = timestamp
        let entry = Entry(
            seq: sequence,
            monotonicNanos: timestamp,
            stream: stream,
            text: text,
            crash: crash)
        if count < Self.capacity {
            slots[(head + count) % Self.capacity] = entry
            count += 1
        } else {
            slots[head] = entry
            head = (head + 1) % Self.capacity
            droppedLines += 1
        }
    }

    private func markPartialStart(_ stream: LogStream) {
        partialStartedAt[stream] = nextPartialOrder
        if nextPartialOrder < UInt64.max { nextPartialOrder += 1 }
    }

    private static func isCrash(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard !excludedPatterns.contains(where: { $0.firstMatch(in: line, range: range) != nil })
        else { return false }
        return crashPatterns.contains(where: { $0.firstMatch(in: line, range: range) != nil })
    }
}
