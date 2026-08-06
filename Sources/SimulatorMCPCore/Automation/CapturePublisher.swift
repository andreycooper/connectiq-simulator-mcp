import Foundation

/// Places capture bytes on disk and proves they arrived whole.
///
/// The default directory moved out of `/tmp/simulator-mcp/` because that
/// directory is world-writable, shared, and managed by the OS. Captures now
/// live beside the rest of the server's state.
///
/// Every publication is verified: 430 of 468 files in the old directory were
/// created 4 bytes long — the PNG signature and nothing else — while the same
/// bytes reached the MCP response intact
/// (`docs/verification/simulator-contracts/capture-short-write.json`). The
/// mechanism is recorded there; this type makes the outcome impossible either
/// way, by refusing to report a path it has not read back at full length.
public struct CapturePublisher: Sendable {
    /// Signature (8) + IEND chunk (12). Anything shorter cannot be a PNG.
    private static let minimumPNGBytes = 20
    private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let iendMarker = Data("IEND".utf8)

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/screenshots")
    }

    private let directory: URL
    private let retainCount: Int
    private let retainFor: Duration
    private let write: @Sendable (Data, URL) throws -> Void

    public init(
        directory: URL = CapturePublisher.defaultDirectory,
        retainCount: Int = 200,
        retainFor: Duration = .seconds(86_400),
        write: @escaping @Sendable (Data, URL) throws -> Void = {
            try AtomicFile.replace(at: $1, with: $0)
        }
    ) {
        self.directory = directory
        self.retainCount = retainCount
        self.retainFor = retainFor
        self.write = write
    }

    /// A resolved destination and whether this publisher owns it. `managed`
    /// travels with the target rather than being re-derived, because "is this
    /// path inside our directory" is the wrong question: a caller may pass a
    /// savePath that happens to point there, and spec §5.4 says a caller's
    /// path is never garbage-collected and never unlinked on failure.
    public struct CaptureTarget: Equatable, Sendable {
        public let url: URL
        public let managed: Bool
    }

    /// Split from `publish` because path validation must precede the caller's
    /// capture: `ScreenshotService.capture` resolves the target before it
    /// invokes the capturer, and `ScreenshotServiceTests.missingParent`
    /// asserts a bad savePath costs no capture at all.
    public func resolveTarget(_ savePath: String?) throws -> CaptureTarget {
        CaptureTarget(url: try resolveURL(savePath), managed: savePath == nil)
    }

    /// Bytes never reach `target.url` directly. They land in a private
    /// staging file beside it, are read back and measured, and only a
    /// staging file whose on-disk size matches the in-memory `Data` is
    /// promoted onto the target — with one atomic rename
    /// (`AtomicFile.publish`), never a direct overwrite. This is what keeps
    /// a short write from ever reaching an existing file: `target.url` is
    /// touched exactly once, and only after its replacement is already
    /// known-good. A caller's pre-existing file at that path is therefore
    /// never partially overwritten, regardless of what `write` does to the
    /// staging path it is actually given.
    @discardableResult
    public func publish(_ data: Data, to target: CaptureTarget) throws -> URL {
        try validateFraming(data)
        let staging = stagingURL(besides: target.url)
        do {
            try write(data, staging)
            try verifyStagedSize(data, at: staging)
            try AtomicFile.publish(temporary: staging, over: target.url)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        if target.managed { prune(keeping: target.url) }
        return target.url
    }

    /// Convenience composing the two, for callers that capture nothing.
    @discardableResult
    public func publish(_ data: Data, savePath: String?) throws -> URL {
        try publish(data, to: try resolveTarget(savePath))
    }

    // MARK: - Verification

    private func validateFraming(_ data: Data) throws {
        guard data.count >= Self.minimumPNGBytes,
            data.prefix(Self.signature.count) == Self.signature,
            data.suffix(8).prefix(4) == Self.iendMarker
        else {
            throw shortWrite(
                "The captured image is not a complete PNG (\(data.count) bytes).",
                observed: data.count)
        }
    }

    /// A hidden, uniquely-named sibling of `target` — same directory, so the
    /// later `rename(2)` inside `AtomicFile.publish` stays on one filesystem.
    private func stagingURL(besides target: URL) -> URL {
        target.deletingLastPathComponent()
            .appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).partial")
    }

    private func verifyStagedSize(_ data: Data, at staging: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: staging.path))?[.size]
            as? Int
        guard let size, size == data.count else {
            throw shortWrite(
                "The capture was written to disk as \(size.map(String.init) ?? "unreadable") bytes but the image is \(data.count) bytes.",
                observed: size ?? 0)
        }
    }

    private func shortWrite(_ message: String, observed: Int) -> ToolError {
        ToolError(
            code: "capture_write_short",
            message: message,
            fix: "Retry screenshot. If it repeats, run doctor and inspect the server stderr log.",
            details: ["observedBytes": .int(observed)])
    }

    // MARK: - Placement

    private func resolveURL(_ savePath: String?) throws -> URL {
        guard let savePath else {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                Log.err("capture directory creation failed: \(String(reflecting: error))")
                throw ToolError(
                    code: "internal_error",
                    message: "Could not create the capture directory at \(directory.path).",
                    fix: "Ensure ~/.simulator-mcp is writable, then retry screenshot.")
            }
            return directory.appending(path: "\(UUID().uuidString).png")
        }

        let target = URL(fileURLWithPath: (savePath as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ToolError(
                code: "invalid_arguments",
                message: "Capture destination parent directory does not exist: \(parent.path).",
                fix: "Create the parent directory, then retry with that savePath.",
                details: ["parent": .string(parent.path)])
        }
        return target
    }

    // MARK: - Retention

    /// Best-effort: a failed prune is logged and dropped. Losing a capture is
    /// worse than keeping one too long, so anything unreadable is left alone,
    /// as is anything this publisher did not name.
    private func prune(keeping current: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)
        else { return }

        let managed = entries
            .filter { $0.pathExtension == "png" && UUID(uuidString: $0.deletingPathExtension()
                .lastPathComponent) != nil }
            .filter { $0.standardizedFileURL != current.standardizedFileURL }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: Set(keys))
                    .contentModificationDate
                else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }

        let cutoff = Date(timeIntervalSinceNow: -Double(retainFor.components.seconds))
        for (index, entry) in managed.enumerated() {
            let overCount = index >= max(0, retainCount - 1)
            let tooOld = entry.1 < cutoff
            guard overCount || tooOld else { continue }
            do {
                try FileManager.default.removeItem(at: entry.0)
            } catch {
                Log.err("capture retention could not remove \(entry.0.path): \(error)")
            }
        }
    }
}
