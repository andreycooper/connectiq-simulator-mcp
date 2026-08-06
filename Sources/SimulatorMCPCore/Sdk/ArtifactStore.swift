import CryptoKit
import Foundation

/// The four filesystem locations one build target owns: the `bin`
/// directory, the published PRG, its sidecar metadata, and its artifact
/// lock file.
public struct ArtifactPaths: Equatable, Sendable {
    public let bin: URL
    public let target: URL
    public let sidecar: URL
    public let lock: URL

    public init(bin: URL, target: URL, sidecar: URL, lock: URL) {
        self.bin = bin
        self.target = target
        self.sidecar = sidecar
        self.lock = lock
    }
}

/// The compatibility identity of one build request: a digest over
/// everything that must be unchanged for a published PRG to be reusable,
/// plus the newest input mtime that fed into it.
public struct ArtifactKey: Equatable, Sendable {
    public let key: String
    public let newestInputMtimeNanos: Int64

    public init(key: String, newestInputMtimeNanos: Int64) {
        self.key = key
        self.newestInputMtimeNanos = newestInputMtimeNanos
    }
}

/// Metadata published next to every PRG. Reuse requires both the recorded
/// `artifactKey` to match the current request's key and the PRG's current
/// bytes to hash to `prgSha256` — a rename that landed without its sidecar
/// (or vice versa) is a cache miss, never a false hit.
public struct ArtifactSidecar: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let artifactKey: String
    public let sdkPath: String
    public let sdkVersion: String
    public let device: String
    public let mode: BuildMode
    public let prgSha256: String
    public let newestInputMtimeNanos: Int64

    public init(
        schemaVersion: Int,
        artifactKey: String,
        sdkPath: String,
        sdkVersion: String,
        device: String,
        mode: BuildMode,
        prgSha256: String,
        newestInputMtimeNanos: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.artifactKey = artifactKey
        self.sdkPath = sdkPath
        self.sdkVersion = sdkVersion
        self.device = device
        self.mode = mode
        self.prgSha256 = prgSha256
        self.newestInputMtimeNanos = newestInputMtimeNanos
    }
}

/// Owns artifact naming, compatibility keys, per-target locking, reuse
/// checks, and durable publication of built PRGs.
public struct ArtifactStore: Sendable {
    /// The current `ArtifactSidecar.schemaVersion`.
    public static let sidecarSchemaVersion = 1

    private static let lockPollInterval: Duration = .milliseconds(25)

    private let clock: any Clock<Duration>

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    // MARK: - Naming

    /// `bin/<appName>-<device>.prg` (unit-test builds append `-test`
    /// before `.prg`), sidecar beside it as `<prg>.meta.json`, lock at
    /// `bin/.locks/<prg>.lock`. `appName` is already artifact-safe (see
    /// `ProjectDescriptor.appName`), so these can never escape `bin`.
    public func paths(for request: BuildRequest) -> ArtifactPaths {
        let project = request.context.project
        let bin = project.root.appending(path: "bin")
        let suffix = request.mode == .unitTests ? "-test" : ""
        let prgName = "\(project.appName)-\(request.device)\(suffix).prg"
        return ArtifactPaths(
            bin: bin,
            target: bin.appending(path: prgName),
            sidecar: bin.appending(path: prgName + ".meta.json"),
            lock: bin.appending(path: ".locks").appending(path: prgName + ".lock")
        )
    }

    // MARK: - Compatibility key

    /// SHA-256 over the sorted-keys JSON of everything that identifies a
    /// build: canonical jungle and manifest paths, device, mode, SDK path
    /// and version, and the newest mtime across every build input (jungle,
    /// manifest, `source/`, `resources*` directories, and any literal
    /// `*.sourcePath` / `*.resourcePath` entries the jungle names).
    public func compatibilityKey(for request: BuildRequest) throws -> ArtifactKey {
        let project = request.context.project
        let newest = try newestInputMtimeNanos(for: project)

        struct KeyMaterial: Codable {
            let junglePath: String
            let manifestPath: String
            let device: String
            let mode: String
            let sdkPath: String
            let sdkVersion: String
            let newestInputMtimeNanos: Int64
        }
        let material = KeyMaterial(
            junglePath: project.jungle.path,
            manifestPath: project.manifest.path,
            device: request.device,
            mode: request.mode.rawValue,
            sdkPath: request.sdk.root.path,
            sdkVersion: request.sdk.version.description,
            newestInputMtimeNanos: newest
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded: Data
        do {
            encoded = try encoder.encode(material)
        } catch {
            throw ToolError(
                code: "internal_error",
                message: "Could not encode the compatibility key material: \(error.localizedDescription)",
                fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.",
                details: ["jungle": .string(project.jungle.path)]
            )
        }
        return ArtifactKey(key: sha256Hex(of: encoded), newestInputMtimeNanos: newest)
    }

    /// The newest `st_mtimespec` (in nanoseconds) across every build input.
    private func newestInputMtimeNanos(for project: ProjectDescriptor) throws -> Int64 {
        var inputs: [URL] = [project.jungle, project.manifest]
        inputs.append(project.root.appending(path: "source"))

        let fileManager = FileManager.default
        if let siblings = try? fileManager.contentsOfDirectory(
            at: project.root, includingPropertiesForKeys: nil)
        {
            for sibling in siblings where sibling.lastPathComponent.hasPrefix("resources") {
                inputs.append(sibling)
            }
        }
        inputs.append(contentsOf: try jungleDeclaredPaths(project: project))

        var newest: Int64 = 0
        for input in inputs {
            scanMtimes(at: input, newest: &newest)
        }
        return newest
    }

    /// Records `url`'s own mtime and, if it is a directory, the mtime of
    /// every descendant. Missing entries are skipped — the mtime scan
    /// widens the key, it never fails resolution the project already passed.
    private func scanMtimes(at url: URL, newest: inout Int64) {
        guard let own = mtimeNanos(atPath: url.path) else { return }
        newest = max(newest, own)

        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil)
        else { return }
        for case let descendant as URL in enumerator {
            if let nanos = mtimeNanos(atPath: descendant.path) {
                newest = max(newest, nanos)
            }
        }
    }

    /// Darwin `stat`'s `st_mtimespec` as nanoseconds. `FileManager`'s
    /// `.modificationDate` round-trips through `Double` and loses
    /// resolution; the raw timespec does not.
    private func mtimeNanos(atPath path: String) -> Int64? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Int64(status.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(status.st_mtimespec.tv_nsec)
    }

    /// Existing literal paths named by `*.sourcePath` / `*.resourcePath`
    /// jungle assignments, split on `;`, unquoted, resolved against the
    /// project root. Values containing `$(` would need real jungle
    /// evaluation and are skipped — the standard `source/` and `resources*`
    /// scans still cover the common layouts they usually expand to.
    private func jungleDeclaredPaths(project: ProjectDescriptor) throws -> [URL] {
        let contents: String
        do {
            contents = try String(contentsOf: project.jungle, encoding: .utf8)
        } catch {
            throw ToolError(
                code: "project_invalid",
                message: "Jungle file \(project.jungle.path) could not be read: \(error.localizedDescription)",
                fix: "Make the jungle file readable UTF-8 text.",
                details: ["jungle": .string(project.jungle.path)]
            )
        }

        var found: [URL] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            // Comments run from '#' to end of line.
            let line = rawLine.prefix(while: { $0 != "#" })
            guard
                let match = line.firstMatch(
                    of: /^\s*\S+\.(?:sourcePath|resourcePath)\s*=\s*(.+?)\s*$/)
            else { continue }

            for rawValue in match.1.split(separator: ";") {
                var value = rawValue.trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                guard !value.isEmpty, !value.contains("$(") else { continue }
                let url =
                    value.hasPrefix("/")
                    ? URL(fileURLWithPath: value)
                    : project.root.appending(path: value)
                if FileManager.default.fileExists(atPath: url.path) {
                    found.append(url)
                }
            }
        }
        return found
    }

    // MARK: - Locking

    /// Runs `body` while holding an exclusive `flock` on the target's lock
    /// file, polling non-blockingly every 25ms on the injected clock until
    /// `timeout` elapses. The lock file is created if missing and is
    /// **never unlinked** (see AGENTS.md — unlinking can split the lock);
    /// a dead holder releases `flock` automatically.
    public func withArtifactLock<T: Sendable>(
        _ paths: ArtifactPaths,
        timeout: Duration,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let locksDirectory = paths.lock.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: locksDirectory, withIntermediateDirectories: true)
        } catch {
            throw ToolError(
                code: "internal_error",
                message:
                    "Could not create the lock directory \(locksDirectory.path): \(error.localizedDescription)",
                fix: "Check that the project's bin directory is writable, then retry.",
                details: ["locksDirectory": .string(locksDirectory.path)]
            )
        }

        let fd = open(paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw ToolError(
                code: "internal_error",
                message:
                    "open(\(paths.lock.path)) failed: \(String(cString: strerror(errno)))",
                fix: "Check that the project's bin directory is writable, then retry.",
                details: ["lock": .string(paths.lock.path)]
            )
        }

        do {
            try await acquireFlock(fd: fd, lockPath: paths.lock.path, timeout: timeout)
        } catch {
            close(fd)
            throw error
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try await body()
    }

    private func acquireFlock(fd: Int32, lockPath: String, timeout: Duration) async throws {
        var elapsed: Duration = .zero
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return
            }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw ToolError(
                    code: "internal_error",
                    message: "flock(\(lockPath)) failed: \(String(cString: strerror(code)))",
                    fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.",
                    details: ["lock": .string(lockPath)]
                )
            }
            guard elapsed < timeout else {
                throw ToolError(
                    code: "artifact_lock_timeout",
                    message:
                        "Another build of the same target still holds the artifact lock at \(lockPath) after \(timeout).",
                    fix:
                        "Wait for the concurrent build of this target to finish and retry; if no build is running, find and terminate the hung monkeyc process holding the lock (do not delete the lock file).",
                    details: ["lock": .string(lockPath)]
                )
            }
            try await clock.sleep(for: Self.lockPollInterval)
            elapsed += Self.lockPollInterval
        }
    }

    // MARK: - Reuse

    /// The published artifact, if — and only if — the sidecar decodes, its
    /// recorded key matches `key`, and the PRG's current bytes hash to the
    /// recorded `prgSha256`. Every read or decode failure is a cache miss,
    /// never an error: the worst outcome of a damaged cache is a rebuild.
    public func reusableArtifact(paths: ArtifactPaths, key: ArtifactKey) throws -> ArtifactSidecar? {
        guard
            let sidecarData = try? Data(contentsOf: paths.sidecar),
            let sidecar = try? JSONDecoder().decode(ArtifactSidecar.self, from: sidecarData),
            sidecar.artifactKey == key.key,
            let prgData = try? Data(contentsOf: paths.target),
            sha256Hex(of: prgData) == sidecar.prgSha256
        else { return nil }
        return sidecar
    }

    /// Why no artifact was reusable: `keyChanged` only when a decodable
    /// sidecar exists and its recorded key differs. Everything else — no
    /// sidecar, unreadable sidecar, missing or altered PRG — is a cacheMiss,
    /// because nothing establishes that a key ever matched.
    func rebuildReason(paths: ArtifactPaths, key: ArtifactKey) -> RebuildReason {
        guard
            let sidecarData = try? Data(contentsOf: paths.sidecar),
            let sidecar = try? JSONDecoder().decode(ArtifactSidecar.self, from: sidecarData)
        else { return .cacheMiss }
        return sidecar.artifactKey == key.key ? .cacheMiss : .keyChanged
    }

    // MARK: - Publication

    /// Validates the compiler's temporary output, renames it durably over
    /// the target (PRG first, then sidecar, then a directory fsync), and
    /// returns the published PRG's SHA-256 hex digest.
    @discardableResult
    public func publish(
        temporaryPrg: URL,
        paths: ArtifactPaths,
        request: BuildRequest,
        key: ArtifactKey
    ) throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryPrg.path)
        guard let attributes, attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ToolError(
                code: "internal_error",
                message:
                    "monkeyc reported success, but its output \(temporaryPrg.path) is not an existing regular file.",
                fix:
                    "Rebuild with force. If it repeats, run monkeyc manually against the project to inspect what it writes.",
                details: ["temporary": .string(temporaryPrg.path)]
            )
        }
        guard let size = attributes[.size] as? Int64, size > 0 else {
            throw ToolError(
                code: "internal_error",
                message:
                    "monkeyc reported success, but its output \(temporaryPrg.path) is empty.",
                fix:
                    "Rebuild with force. If it repeats, run monkeyc manually against the project to inspect what it writes.",
                details: ["temporary": .string(temporaryPrg.path)]
            )
        }

        try AtomicFile.publish(temporary: temporaryPrg, over: paths.target)

        let published: Data
        do {
            published = try Data(contentsOf: paths.target)
        } catch {
            throw ToolError(
                code: "internal_error",
                message:
                    "The just-published PRG at \(paths.target.path) could not be read back: \(error.localizedDescription)",
                fix: "Rebuild with force. If it repeats, inspect the project's bin directory.",
                details: ["target": .string(paths.target.path)]
            )
        }
        let hash = sha256Hex(of: published)

        let sidecar = ArtifactSidecar(
            schemaVersion: Self.sidecarSchemaVersion,
            artifactKey: key.key,
            sdkPath: request.sdk.root.path,
            sdkVersion: request.sdk.version.description,
            device: request.device,
            mode: request.mode,
            prgSha256: hash,
            newestInputMtimeNanos: key.newestInputMtimeNanos
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sidecarData: Data
        do {
            sidecarData = try encoder.encode(sidecar)
        } catch {
            throw ToolError(
                code: "internal_error",
                message: "Could not encode the artifact sidecar: \(error.localizedDescription)",
                fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.",
                details: ["sidecar": .string(paths.sidecar.path)]
            )
        }
        try AtomicFile.replace(at: paths.sidecar, with: sidecarData)
        try AtomicFile.syncDirectory(paths.bin)
        return hash
    }

    // MARK: - Hashing

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
