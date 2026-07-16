import Darwin
import Foundation

public struct RuntimeHeader: Codable, Equatable, Sendable {
    public let schemaVersion: Int

    public init(schemaVersion: Int) {
        self.schemaVersion = schemaVersion
    }
}

public struct PersistedMonkeydoOwnership: Codable, Equatable, Sendable {
    public let launcher: StableProcessIdentity
    public let launcherParentPid: Int32
    public let sdkPath: String
    public let prgPath: String
    public let device: String
    public let testFilter: String?
    public let ownerServerInstance: UUID

    public init(
        launcher: StableProcessIdentity,
        launcherParentPid: Int32,
        sdkPath: String,
        prgPath: String,
        device: String,
        testFilter: String?,
        ownerServerInstance: UUID
    ) {
        self.launcher = launcher
        self.launcherParentPid = launcherParentPid
        self.sdkPath = sdkPath
        self.prgPath = prgPath
        self.device = device
        self.testFilter = testFilter
        self.ownerServerInstance = ownerServerInstance
    }
}

public struct RuntimeRecord: Codable, Equatable, Sendable {
    public let simulatorPid: Int32
    public let executablePath: String
    public let sdkPath: String
    public let sdkVersion: String
    public let currentDevice: String?
    public let monkeydoOwnership: PersistedMonkeydoOwnership?

    public init(
        simulatorPid: Int32,
        executablePath: String,
        sdkPath: String,
        sdkVersion: String,
        currentDevice: String?,
        monkeydoOwnership: PersistedMonkeydoOwnership?
    ) {
        self.simulatorPid = simulatorPid
        self.executablePath = executablePath
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
        self.currentDevice = currentDevice
        self.monkeydoOwnership = monkeydoOwnership
    }
}

public struct RuntimeEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let record: RuntimeRecord?

    public init(schemaVersion: Int, record: RuntimeRecord?) {
        self.schemaVersion = schemaVersion
        self.record = record
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, record }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        if let record {
            try container.encode(record, forKey: .record)
        } else {
            try container.encodeNil(forKey: .record)
        }
    }
}

/// Atomically published cross-server runtime hint.
///
/// Callers mutate it only while holding `SimLease`. Reads deliberately return
/// `nil` for missing, corrupt, or unsupported state because consumers must
/// validate PID and executable ownership before trusting any record anyway.
public struct RuntimeStore: Sendable {
    public static let standard = RuntimeStore(
        runtimeFile: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/runtime.json")
    )

    public static let schemaVersion = 2

    public let runtimeFile: URL
    private let log: Log.Sink
    private let atomicPublish: @Sendable (URL, Data) throws -> Void

    public init(runtimeFile: URL, log: @escaping Log.Sink = Log.standardError) {
        self.runtimeFile = runtimeFile
        self.log = log
        self.atomicPublish = { target, data in
            try AtomicFile.replace(at: target, with: data)
            try AtomicFile.syncDirectory(target.deletingLastPathComponent())
        }
    }

    init(
        runtimeFile: URL,
        log: @escaping Log.Sink = Log.standardError,
        atomicPublish: @escaping @Sendable (URL, Data) throws -> Void
    ) {
        self.runtimeFile = runtimeFile
        self.log = log
        self.atomicPublish = atomicPublish
    }

    /// Reads only the current schema after decoding the version header first.
    /// In particular, a valid schema-1 envelope with an obsolete record shape
    /// is diagnosed as unsupported and is never decoded as trusted ownership.
    public func read() -> RuntimeRecord? {
        guard FileManager.default.fileExists(atPath: runtimeFile.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: runtimeFile)
        } catch {
            Log.err(
                "ignored unreadable runtime state at \(runtimeFile.path): \(error.localizedDescription)",
                sink: log)
            return nil
        }

        let header: RuntimeHeader
        do {
            header = try JSONDecoder().decode(RuntimeHeader.self, from: data)
        } catch {
            Log.err(
                "ignored corrupt runtime state at \(runtimeFile.path): \(error.localizedDescription)",
                sink: log)
            return nil
        }
        guard header.schemaVersion == Self.schemaVersion else {
            Log.err(
                "ignored runtime state at \(runtimeFile.path) with unsupported schemaVersion \(header.schemaVersion)",
                sink: log)
            return nil
        }

        do {
            return try JSONDecoder().decode(RuntimeEnvelope.self, from: data).record
        } catch {
            Log.err(
                "ignored corrupt schema 2 runtime state at \(runtimeFile.path): \(error.localizedDescription)",
                sink: log)
            return nil
        }
    }

    public func write(_ record: RuntimeRecord) throws {
        try publish(RuntimeEnvelope(schemaVersion: Self.schemaVersion, record: record))
    }

    public func clear() throws {
        try publish(RuntimeEnvelope(schemaVersion: Self.schemaVersion, record: nil))
    }

    private func publish<Envelope: Encodable>(_ envelope: Envelope) throws {
        let directory = runtimeFile.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ToolError(
                code: "internal_error",
                message: "Could not create runtime state directory \(directory.path): \(error.localizedDescription)",
                fix: "Check that the parent directory is writable, then retry.",
                details: ["directory": .string(directory.path)]
            )
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw SimLease.posixError(
                "chmod", path: directory.path, code: errno,
                fix: "Check ownership of the simulator state directory, then retry.")
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(envelope)
        } catch {
            throw ToolError(
                code: "internal_error",
                message: "Could not encode runtime state: \(error.localizedDescription)",
                fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.",
                details: ["runtimeFile": .string(runtimeFile.path)]
            )
        }

        do {
            try atomicPublish(runtimeFile, data)
        } catch let error as ToolError {
            throw error
        } catch {
            Log.err(
                "runtime state publication failed at \(runtimeFile.path): \(String(reflecting: error))",
                sink: log)
            throw ToolError(
                code: "internal_error",
                message: "Could not atomically publish runtime state.",
                fix: "Check filesystem permissions and available disk space, then retry.",
                details: ["runtimeFile": .string(runtimeFile.path)]
            )
        }
    }
}
