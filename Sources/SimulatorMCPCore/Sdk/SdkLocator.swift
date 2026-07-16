import Foundation

/// Which resolution branch produced an `SdkInfo`.
public enum SdkSource: String, Codable, Equatable, Sendable {
    /// An explicit path parameter on the tool call.
    case explicit
    /// The `CIQ_SDK` environment variable.
    case environment = "env"
    /// The SDK Manager's `current-sdk.cfg`.
    case currentSdkCfg = "current-sdk.cfg"
    /// Newest installed version under `Sdks/` by numeric semver.
    case newestInstalled = "newest-installed"
    /// Inventory listing (`installedSdks()`), not a resolution winner.
    case installed
}

/// One resolved Connect IQ SDK.
public struct SdkInfo: Codable, Equatable, Sendable {
    public let version: SemVer
    public let root: URL
    public let source: SdkSource

    public init(version: SemVer, root: URL, source: SdkSource) {
        self.version = version
        self.root = root
        self.source = source
    }

    public var simulatorApp: URL { root.appending(path: "bin/ConnectIQ.app") }
    public var monkeyc: URL { root.appending(path: "bin/monkeyc") }
    public var monkeydo: URL { root.appending(path: "bin/monkeydo") }
}

/// Resolves the Connect IQ SDK using the locked precedence (see AGENTS.md,
/// verified on this machine): explicit param → `CIQ_SDK` env →
/// `current-sdk.cfg` → newest installed by parsed semver.
///
/// A source that is *present but unusable* (explicit path without monkeyc,
/// `CIQ_SDK` pointing nowhere, cfg naming a missing directory) is an
/// error, never a silent fall-through to the next branch — falling through
/// would mask a misconfiguration behind whichever SDK happens to be
/// installed.
public struct SdkLocator: Sendable {
    private let sdksRoot: URL
    private let currentSdkCfg: URL
    private let environment: [String: String]

    /// Production layout under `~/Library/Application Support/Garmin/ConnectIQ`
    /// (verified on this machine: `Sdks/connectiq-sdk-mac-<semver>-<date>-<hash>`
    /// directories next to `current-sdk.cfg`).
    public init() {
        let connectIQ = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Garmin/ConnectIQ")
        self.init(
            sdksRoot: connectIQ.appending(path: "Sdks"),
            currentSdkCfg: connectIQ.appending(path: "current-sdk.cfg"),
            environment: ProcessInfo.processInfo.environment
        )
    }

    public init(sdksRoot: URL, currentSdkCfg: URL, environment: [String: String]) {
        self.sdksRoot = sdksRoot
        self.currentSdkCfg = currentSdkCfg
        self.environment = environment
    }

    /// Resolves the effective SDK, reporting which branch won.
    public func resolve(explicitPath: String? = nil) throws -> SdkInfo {
        if let explicitPath {
            return try validatedSdk(
                atPath: explicitPath,
                source: .explicit,
                origin: "the explicit sdk path",
                fix: "Pass the root of an installed Connect IQ SDK (it must contain bin/monkeyc, bin/monkeydo, and bin/ConnectIQ.app)."
            )
        }

        if let envPath = environment["CIQ_SDK"] {
            return try validatedSdk(
                atPath: envPath,
                source: .environment,
                origin: "CIQ_SDK",
                fix: "Point CIQ_SDK at the root of an installed Connect IQ SDK, or unset it to use current-sdk.cfg."
            )
        }

        if FileManager.default.fileExists(atPath: currentSdkCfg.path) {
            return try resolveFromCfg()
        }

        return try newestInstalled()
    }

    /// Every valid SDK under `Sdks/`, ascending by version. Skips
    /// directories without a parseable version or a complete layout.
    public func installedSdks() -> [SdkInfo] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: sdksRoot, includingPropertiesForKeys: nil)) ?? []
        return
            entries
            .compactMap { entry -> SdkInfo? in
                guard let version = SemVer(firstIn: entry.lastPathComponent),
                    isValidSdkLayout(canonicalize(entry))
                else { return nil }
                return SdkInfo(version: version, root: canonicalize(entry), source: .installed)
            }
            .sorted { ($0.version, $0.root.path) < ($1.version, $1.root.path) }
    }

    // MARK: - Branches

    private func resolveFromCfg() throws -> SdkInfo {
        let raw: String
        do {
            raw = try String(contentsOf: currentSdkCfg, encoding: .utf8)
        } catch {
            throw ToolError(
                code: "sdk_not_found",
                message:
                    "current-sdk.cfg at \(currentSdkCfg.path) exists but could not be read: \(error.localizedDescription)",
                fix: "Re-select an SDK with the Connect IQ SDK Manager, or remove the file to fall back to the newest installed SDK.",
                details: ["cfg": .string(currentSdkCfg.path)]
            )
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError(
                code: "sdk_not_found",
                message: "current-sdk.cfg at \(currentSdkCfg.path) is empty.",
                fix: "Re-select an SDK with the Connect IQ SDK Manager, or remove the file to fall back to the newest installed SDK.",
                details: ["cfg": .string(currentSdkCfg.path)]
            )
        }

        // The real file holds an absolute path with a trailing slash;
        // tolerate a relative path by resolving against the cfg's own
        // directory.
        let target: URL =
            trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : currentSdkCfg.deletingLastPathComponent().appending(path: trimmed)

        return try validatedSdk(
            atPath: target.path,
            source: .currentSdkCfg,
            origin: "current-sdk.cfg (\(currentSdkCfg.path))",
            fix: "Re-select an SDK with the Connect IQ SDK Manager, or remove current-sdk.cfg to fall back to the newest installed SDK."
        )
    }

    private func newestInstalled() throws -> SdkInfo {
        guard let newest = installedSdks().last else {
            throw ToolError(
                code: "sdk_not_found",
                message: "No Connect IQ SDK is installed under \(sdksRoot.path).",
                fix: "Install an SDK with the Connect IQ SDK Manager, or pass an explicit sdk path.",
                details: ["sdksRoot": .string(sdksRoot.path)]
            )
        }
        return SdkInfo(version: newest.version, root: newest.root, source: .newestInstalled)
    }

    // MARK: - Validation

    private func validatedSdk(
        atPath path: String, source: SdkSource, origin: String, fix: String
    ) throws -> SdkInfo {
        // isDirectory: true keeps the URL's directory flag consistent
        // across input spellings (with/without trailing slash, through a
        // symlink), so equal roots compare equal as URLs.
        let root = canonicalize(URL(fileURLWithPath: path, isDirectory: true))

        guard isValidSdkLayout(root) else {
            throw ToolError(
                code: "sdk_not_found",
                message:
                    "\(origin) names \(root.path), which is not a usable Connect IQ SDK (bin/monkeyc, bin/monkeydo, and bin/ConnectIQ.app must all exist).",
                fix: fix,
                details: ["path": .string(root.path), "source": .string(source.rawValue)]
            )
        }

        guard let version = SemVer(firstIn: root.lastPathComponent) else {
            throw ToolError(
                code: "sdk_not_found",
                message:
                    "\(origin) names \(root.path), whose directory name does not contain a version. SDK Manager installs are named connectiq-sdk-mac-<version>-<date>-<hash>.",
                fix: fix,
                details: ["path": .string(root.path), "source": .string(source.rawValue)]
            )
        }

        return SdkInfo(version: version, root: root, source: source)
    }

    private func isValidSdkLayout(_ root: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return false }
        return fileManager.fileExists(atPath: root.appending(path: "bin/monkeyc").path)
            && fileManager.fileExists(atPath: root.appending(path: "bin/monkeydo").path)
            && fileManager.fileExists(atPath: root.appending(path: "bin/ConnectIQ.app").path)
    }

    private func canonicalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
