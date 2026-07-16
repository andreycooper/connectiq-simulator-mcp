import Foundation

/// A project plus the developer key that signs its builds. Only `build`,
/// `run_app`, and `run_tests` resolve one of these — read-only tools use
/// `ProjectDescriptor` alone and never look for a key.
public struct BuildContext: Equatable, Sendable {
    public let project: ProjectDescriptor
    public let developerKey: URL

    /// Explicit key first; otherwise `developer_key.der` then
    /// `developer_key` at the project root and in each parent directory up
    /// through the filesystem root. A candidate must be a regular readable
    /// file — a directory or unreadable entry with a matching name is
    /// skipped, an explicit override that isn't one is an error.
    ///
    /// `searchCeiling` bounds the upward walk (inclusive); it exists so
    /// tests in throwaway directories can't accidentally discover a real
    /// key higher up. Production callers leave it nil (walk to `/`).
    public static func resolve(
        project: ProjectDescriptor,
        developerKeyOverride: String?,
        searchCeiling: URL? = nil
    ) throws -> BuildContext {
        if let developerKeyOverride {
            let key = URL(fileURLWithPath: developerKeyOverride)
                .resolvingSymlinksInPath().standardizedFileURL
            guard isRegularReadableFile(key) else {
                throw ToolError(
                    code: "developer_key_not_found",
                    message: "The developer key \(key.path) is not a readable file.",
                    fix: "Point the developer key parameter at your Connect IQ developer key file (commonly developer_key.der).",
                    details: ["developerKey": .string(key.path)]
                )
            }
            return BuildContext(project: project, developerKey: key)
        }

        let ceiling = (searchCeiling ?? URL(fileURLWithPath: "/"))
            .resolvingSymlinksInPath().standardizedFileURL
        var directory = project.root
        var searched: [String] = []
        while true {
            for candidateName in ["developer_key.der", "developer_key"] {
                let candidate = directory.appending(path: candidateName)
                if isRegularReadableFile(candidate) {
                    return BuildContext(
                        project: project,
                        developerKey: candidate.resolvingSymlinksInPath().standardizedFileURL
                    )
                }
            }
            searched.append(directory.path)
            if directory.path == ceiling.path || directory.path == "/" {
                break
            }
            directory = directory.deletingLastPathComponent()
        }

        throw ToolError(
            code: "developer_key_not_found",
            message:
                "No developer_key.der or developer_key exists at \(project.root.path) or any parent directory.",
            fix: "Place your Connect IQ developer key as developer_key.der at the project root, or pass its path explicitly.",
            details: [
                "projectRoot": .string(project.root.path),
                "searched": .array(searched.map { .string($0) }),
            ]
        )
    }

    private static func isRegularReadableFile(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard
            let type = try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
            type == .typeRegular
        else { return false }
        return fileManager.isReadableFile(atPath: url.path)
    }
}
