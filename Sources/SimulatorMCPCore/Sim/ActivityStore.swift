import Darwin
import Foundation

public struct ActivityHeader: Codable, Equatable, Sendable {
    public let schemaVersion: Int

    public init(schemaVersion: Int) {
        self.schemaVersion = schemaVersion
    }
}

/// The operation a lease holder is currently running.
///
/// `owner` is the holder's own identity, not a bare pid: a monitor revalidates
/// it before believing the record, so a hard-killed holder cannot leave a
/// phantom behind and a reused pid cannot impersonate one.
public struct ActiveOperation: Codable, Equatable, Sendable {
    public let operation: String
    public let owner: StableProcessIdentity
    public let startedEpochSeconds: Double

    public init(operation: String, owner: StableProcessIdentity, startedEpochSeconds: Double) {
        self.operation = operation
        self.owner = owner
        self.startedEpochSeconds = startedEpochSeconds
    }
}

public struct ActivityEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let active: ActiveOperation?

    public init(schemaVersion: Int, active: ActiveOperation?) {
        self.schemaVersion = schemaVersion
        self.active = active
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, active }

    /// Hand-written so an idle envelope writes `"active": null` rather than
    /// omitting the key. The synthesized encoder uses `encodeIfPresent` for
    /// optionals; `RuntimeEnvelope` carries the same override for the same
    /// reason, and the on-disk shape is documented in the design spec.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        if let active {
            try container.encode(active, forKey: .active)
        } else {
            try container.encodeNil(forKey: .active)
        }
    }
}

/// Atomically published "what is happening right now" hint.
///
/// This is a convenience signal, never a correctness mechanism — the simulator
/// lease is. Every write is therefore best-effort and non-throwing: a failed
/// hint must never turn a successful tool call into a failure.
///
/// Writes are synchronous. Not because an `async` write would be cancelled —
/// Swift cancellation is cooperative and `AtomicFile.replace` never checks for
/// it — but because the work is a bounded sub-millisecond syscall with no async
/// API, because a synchronous call cannot be cancelled by construction, and
/// because an unstructured `Task` could land a detached `clear` after the next
/// operation's `publish` and erase a live record.
///
/// Must stay a `Sendable` struct. `SimulatorController` holds it in a `let` and
/// calls it from the `@Sendable` closure passed to `AsyncFIFO.withLock`, which
/// does not inherit actor isolation. An actor or class would force `await` and
/// reintroduce suspension points inside the lease-held critical section.
public struct ActivityStore: Sendable {
    public static let standard = ActivityStore(
        activityFile: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/activity.json")
    )

    /// An inert store. The default for `SimulatorController`'s test-only
    /// initializers, so existing suites neither write to a real home directory
    /// nor need updating. Production goes through the public initializer, which
    /// defaults to `.standard`.
    public static let disabled = ActivityStore(disabled: URL(fileURLWithPath: "/dev/null"))

    public static let schemaVersion = 1

    public let activityFile: URL
    private let enabled: Bool
    private let log: Log.Sink
    private let atomicPublish: @Sendable (URL, Data) throws -> Void
    private let selfIdentity: @Sendable () throws -> StableProcessIdentity?

    public init(activityFile: URL, log: @escaping Log.Sink = Log.standardError) {
        self.activityFile = activityFile
        self.enabled = true
        self.log = log
        self.atomicPublish = { target, data in
            try AtomicFile.replace(at: target, with: data)
            try AtomicFile.syncDirectory(target.deletingLastPathComponent())
        }
        self.selfIdentity = { try DarwinProcessIdentityReader().snapshot(pid: getpid())?.stableIdentity }
    }

    init(
        activityFile: URL,
        log: @escaping Log.Sink = Log.standardError,
        atomicPublish: @escaping @Sendable (URL, Data) throws -> Void,
        selfIdentity: @escaping @Sendable () throws -> StableProcessIdentity? = {
            try DarwinProcessIdentityReader().snapshot(pid: getpid())?.stableIdentity
        }
    ) {
        self.activityFile = activityFile
        self.enabled = true
        self.log = log
        self.atomicPublish = atomicPublish
        self.selfIdentity = selfIdentity
    }

    /// Creates an inert store at a specific path. Used internally for
    /// test-only disabled instances.
    init(
        disabled activityFile: URL,
        atomicPublish: @escaping @Sendable (URL, Data) throws -> Void = { _, _ in },
        selfIdentity: @escaping @Sendable () throws -> StableProcessIdentity? = { nil }
    ) {
        self.activityFile = activityFile
        self.enabled = false
        self.log = Log.standardError
        self.atomicPublish = atomicPublish
        self.selfIdentity = selfIdentity
    }

    /// Reads the current activity. Missing, corrupt, and unsupported-version
    /// files all read as idle: a monitor revalidates the owner before trusting
    /// any record anyway, so there is nothing an error would let it do better.
    public func read() -> ActiveOperation? {
        guard enabled else { return nil }
        guard FileManager.default.fileExists(atPath: activityFile.path) else { return nil }
        guard let data = try? Data(contentsOf: activityFile) else { return nil }
        guard let header = try? JSONDecoder().decode(ActivityHeader.self, from: data),
              header.schemaVersion == Self.schemaVersion
        else { return nil }
        return try? JSONDecoder().decode(ActivityEnvelope.self, from: data).active
    }

    public func publish(operation: String, startedAt: Date) {
        guard enabled else { return }
        do {
            guard let owner = try selfIdentity() else {
                Log.err(
                    "activity publish skipped: this process could not identify itself", sink: log)
                return
            }
            try write(
                ActivityEnvelope(
                    schemaVersion: Self.schemaVersion,
                    active: ActiveOperation(
                        operation: operation,
                        owner: owner,
                        startedEpochSeconds: startedAt.timeIntervalSince1970)))
        } catch {
            Log.err(
                "activity publish failed at \(activityFile.path): \(error.localizedDescription)",
                sink: log)
        }
    }

    public func clear() {
        guard enabled else { return }
        do {
            try write(ActivityEnvelope(schemaVersion: Self.schemaVersion, active: nil))
        } catch {
            Log.err(
                "activity clear failed at \(activityFile.path): \(error.localizedDescription)",
                sink: log)
        }
    }

    private func write(_ envelope: ActivityEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicPublish(activityFile, try encoder.encode(envelope))
    }
}
