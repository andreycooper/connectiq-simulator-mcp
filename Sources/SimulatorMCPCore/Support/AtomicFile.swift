import Foundation

/// Durable-publication primitives: fsync + Darwin `rename(2)`. A target
/// published through these helpers is never unlinked first, so a
/// concurrent reader always sees either the old bytes or the new bytes —
/// never a missing file.
public enum AtomicFile {

    /// fsyncs `temporary`'s bytes to disk, then renames it over `target`.
    /// The temporary must live on the same filesystem as the target
    /// (callers create it in the target's own directory).
    public static func publish(temporary: URL, over target: URL) throws {
        let fd = open(temporary.path, O_RDONLY)
        guard fd >= 0 else {
            throw posixError("open", path: temporary.path)
        }
        let syncResult = fsync(fd)
        close(fd)
        guard syncResult == 0 else {
            throw posixError("fsync", path: temporary.path)
        }

        guard rename(temporary.path, target.path) == 0 else {
            throw posixError("rename", path: target.path)
        }
    }

    /// Writes `data` to a unique dot-temp beside `target`, fsyncs, and
    /// renames it over `target`.
    public static func replace(at target: URL, with data: Data) throws {
        let temporary = target.deletingLastPathComponent()
            .appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            try publish(temporary: temporary, over: target)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// fsyncs a directory so completed renames inside it are durable.
    public static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else {
            throw posixError("open", path: directory.path)
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw posixError("fsync", path: directory.path)
        }
    }

    private static func posixError(_ call: String, path: String) -> ToolError {
        let message = String(cString: strerror(errno))
        return ToolError(
            code: "internal_error",
            message: "\(call)(\(path)) failed: \(message)",
            fix: "Run doctor, then retry. If it repeats, inspect the server stderr log.",
            details: ["path": .string(path), "call": .string(call)]
        )
    }
}
