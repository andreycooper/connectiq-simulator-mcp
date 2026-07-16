import Foundation

/// Everything one build needs: the resolved project + developer key, the
/// resolved SDK, the target device, the build mode, and whether to bypass
/// artifact reuse.
public struct BuildRequest: Sendable {
    public let context: BuildContext
    public let sdk: SdkInfo
    public let device: String
    public let mode: BuildMode
    public let force: Bool

    public init(context: BuildContext, sdk: SdkInfo, device: String, mode: BuildMode, force: Bool) {
        self.context = context
        self.sdk = sdk
        self.device = device
        self.mode = mode
        self.force = force
    }
}

/// One parsed monkeyc diagnostic. Lines that carry a `file:line[,column]`
/// location fill all fields; location-less ERROR/WARNING lines fill only
/// severity and message; any other nonempty compiler output becomes an
/// `.info` diagnostic rather than being silently dropped.
public struct BuildDiagnostic: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case error
        case warning
        case info
    }

    public let file: String?
    public let line: Int?
    public let column: Int?
    public let severity: Severity
    public let message: String

    public init(file: String?, line: Int?, column: Int?, severity: Severity, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }
}

/// The result of one `Compiler.build`. Ordinary compile failures are an
/// outcome (`succeeded: false` with diagnostics), never a throw — only
/// launch failures, timeouts, and internal errors throw.
public struct BuildOutcome: Equatable, Sendable {
    public let succeeded: Bool
    public let prgPath: URL?
    public let rebuilt: Bool
    public let artifactKey: String
    public let device: String
    public let mode: BuildMode
    public let diagnostics: [BuildDiagnostic]

    public init(
        succeeded: Bool,
        prgPath: URL?,
        rebuilt: Bool,
        artifactKey: String,
        device: String,
        mode: BuildMode,
        diagnostics: [BuildDiagnostic]
    ) {
        self.succeeded = succeeded
        self.prgPath = prgPath
        self.rebuilt = rebuilt
        self.artifactKey = artifactKey
        self.device = device
        self.mode = mode
        self.diagnostics = diagnostics
    }
}

extension BuildMode {
    /// Maps the tool-call flags onto a mode. `release` and `unitTests`
    /// together are contradictory (monkeyc's `-r` and `-t` select different
    /// artifacts) and are rejected at argument decoding.
    public init(release: Bool, unitTests: Bool) throws {
        switch (release, unitTests) {
        case (true, true):
            throw ToolError(
                code: "invalid_arguments",
                message: "release and unitTests cannot both be true.",
                fix: "Pass at most one of release/unitTests."
            )
        case (false, true):
            self = .unitTests
        case (true, false):
            self = .releaseApp
        case (false, false):
            self = .debugApp
        }
    }
}

/// Runs monkeyc and manages the resulting artifacts through `ArtifactStore`:
/// per-target flock, compatibility-key reuse, atomic publication. The
/// compiler writes to a dot-temp in `bin/` and only a validated, non-empty
/// output is ever renamed over the published PRG, so a failed build leaves
/// the previous PRG and sidecar byte-identical.
public protocol BuildCompiling: Sendable {
    func build(_ request: BuildRequest) async throws -> BuildOutcome
}

public struct Compiler: BuildCompiling, Sendable {
    private let runner: any ProcessRunning
    private let store: ArtifactStore
    private let buildTimeout: Duration
    private let lockTimeout: Duration

    public init(
        runner: any ProcessRunning = Subprocess(),
        store: ArtifactStore = ArtifactStore(),
        buildTimeout: Duration = .seconds(120),
        lockTimeout: Duration = .seconds(30)
    ) {
        self.runner = runner
        self.store = store
        self.buildTimeout = buildTimeout
        self.lockTimeout = lockTimeout
    }

    public func build(_ request: BuildRequest) async throws -> BuildOutcome {
        let paths = store.paths(for: request)
        do {
            try FileManager.default.createDirectory(
                at: paths.bin, withIntermediateDirectories: true)
        } catch {
            throw ToolError(
                code: "internal_error",
                message:
                    "Could not create the artifact directory \(paths.bin.path): \(error.localizedDescription)",
                fix: "Check that the project directory is writable, then retry.",
                details: ["bin": .string(paths.bin.path)]
            )
        }

        let store = self.store
        let runner = self.runner
        let buildTimeout = self.buildTimeout
        return try await store.withArtifactLock(paths, timeout: lockTimeout) {
            () async throws -> BuildOutcome in
            // The key is computed inside the lock so a concurrent build of
            // the same target that just published is observed here as a
            // reusable artifact instead of being rebuilt or clobbered.
            let key = try store.compatibilityKey(for: request)

            if !request.force, try store.reusableArtifact(paths: paths, key: key) != nil {
                return BuildOutcome(
                    succeeded: true,
                    prgPath: paths.target,
                    rebuilt: false,
                    artifactKey: key.key,
                    device: request.device,
                    mode: request.mode,
                    diagnostics: []
                )
            }

            let temporary = paths.bin.appending(
                path: ".\(paths.target.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }

            var arguments = [
                "-f", request.context.project.jungle.path,
                "-o", temporary.path,
                "-d", request.device,
                "-y", request.context.developerKey.path,
                "-w",
            ]
            switch request.mode {
            case .debugApp:
                break
            case .releaseApp:
                arguments.append("-r")
            case .unitTests:
                arguments.append("-t")
            }

            let process = try await runner.start(
                executable: request.sdk.monkeyc,
                arguments: arguments,
                environment: nil,
                workingDirectory: request.context.project.root,
                timeout: buildTimeout,
                onStdout: nil,
                onStderr: nil
            )
            let output = try await process.wait()

            guard output.exitCode == 0 else {
                var diagnostics = Compiler.parseDiagnostics(
                    stdout: output.stdout, stderr: output.stderr)
                if !diagnostics.contains(where: { $0.severity == .error }) {
                    let stderrText = String(decoding: output.stderr, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail =
                        stderrText.isEmpty
                        ? "it produced no stderr output" : "stderr: \(stderrText)"
                    diagnostics.append(
                        BuildDiagnostic(
                            file: nil,
                            line: nil,
                            column: nil,
                            severity: .error,
                            message:
                                "monkeyc exited with code \(output.exitCode) and no parseable error; \(detail)"
                        ))
                }
                return BuildOutcome(
                    succeeded: false,
                    prgPath: nil,
                    rebuilt: false,
                    artifactKey: key.key,
                    device: request.device,
                    mode: request.mode,
                    diagnostics: diagnostics
                )
            }

            _ = try store.publish(
                temporaryPrg: temporary, paths: paths, request: request, key: key)
            return BuildOutcome(
                succeeded: true,
                prgPath: paths.target,
                rebuilt: true,
                artifactKey: key.key,
                device: request.device,
                mode: request.mode,
                diagnostics: Compiler.parseDiagnostics(
                    stdout: output.stdout, stderr: output.stderr)
            )
        }
    }

    // MARK: - Diagnostics parsing

    /// Parses monkeyc output into diagnostics, stderr lines before stdout
    /// lines. The two patterns were derived from the captured transcripts
    /// in `Tests/SimulatorMCPCoreTests/Fixtures/compiler/` (both supported
    /// SDKs), not from documentation. The `(\S+)` after the severity is the
    /// device name monkeyc echoes on every line; it is not stored.
    public static func parseDiagnostics(stdout: Data, stderr: Data) -> [BuildDiagnostic] {
        let located = /^(ERROR|WARNING): (\S+): (.+?):(\d+)(?:,(\d+))?: (.+)$/
        let plain = /^(ERROR|WARNING): (\S+): (.+)$/

        var diagnostics: [BuildDiagnostic] = []
        for data in [stderr, stdout] {
            let text = String(decoding: data, as: UTF8.self)
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var line = rawLine
                if line.hasSuffix("\r") {
                    line = line.dropLast()
                }
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                if let match = line.firstMatch(of: located) {
                    diagnostics.append(
                        BuildDiagnostic(
                            file: String(match.3),
                            line: Int(match.4),
                            column: match.5.flatMap { Int($0) },
                            severity: match.1 == "ERROR" ? .error : .warning,
                            message: String(match.6)
                        ))
                } else if let match = line.firstMatch(of: plain) {
                    diagnostics.append(
                        BuildDiagnostic(
                            file: nil,
                            line: nil,
                            column: nil,
                            severity: match.1 == "ERROR" ? .error : .warning,
                            message: String(match.3)
                        ))
                } else {
                    diagnostics.append(
                        BuildDiagnostic(
                            file: nil,
                            line: nil,
                            column: nil,
                            severity: .info,
                            message: String(line)
                        ))
                }
            }
        }
        return diagnostics
    }
}
