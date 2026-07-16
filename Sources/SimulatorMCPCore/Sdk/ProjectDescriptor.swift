import Foundation

/// A resolved Connect IQ project: its jungle, effective manifest, artifact
/// name, application id, and the manifest's product (device) list.
///
/// Resolution is **read-only** and never searches for a developer key —
/// that is `BuildContext.resolve`'s job, and only build/run_app/run_tests
/// call it.
public struct ProjectDescriptor: Equatable, Sendable {
    public let root: URL
    public let jungle: URL
    public let manifest: URL
    /// Artifact-safe app name: every run of characters outside ASCII
    /// letters, digits, dot, underscore, and hyphen becomes one
    /// underscore; leading dots are trimmed; falls back to
    /// `applicationId` when nothing survives. Artifact paths built from
    /// this can never contain a path separator or start with a dot, so
    /// they cannot escape the bin directory.
    public let appName: String
    public let applicationId: String
    /// Product ids from the manifest, in document order.
    public let manifestDevices: [String]

    public static func resolve(
        projectPath: String,
        jungleOverride: String?
    ) throws -> ProjectDescriptor {
        let fileManager = FileManager.default

        let root = URL(fileURLWithPath: projectPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ToolError(
                code: "project_invalid",
                message: "Project path \(projectPath) is not an existing directory.",
                fix: "Pass the root directory of a Connect IQ project (the directory containing monkey.jungle).",
                details: ["projectPath": .string(projectPath)]
            )
        }

        let jungle =
            jungleOverride.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL }
            ?? root.appending(path: "monkey.jungle")
        guard fileManager.fileExists(atPath: jungle.path) else {
            throw ToolError(
                code: "project_invalid",
                message: "Jungle file \(jungle.path) does not exist.",
                fix: "Create a monkey.jungle at the project root or pass the jungle file explicitly.",
                details: ["jungle": .string(jungle.path)]
            )
        }

        let manifest = try effectiveManifest(inJungle: jungle)

        let parsed = try ManifestSummary(contentsOf: manifest)
        let rawName: String
        if parsed.name.hasPrefix("@Strings.") {
            let stringId = String(parsed.name.dropFirst("@Strings.".count))
            rawName = try resolveStringResource(id: stringId, projectRoot: root, manifest: manifest)
        } else {
            rawName = parsed.name
        }

        let sanitized = sanitizeArtifactName(rawName)
        let appName = sanitized.isEmpty ? parsed.applicationId : sanitized

        return ProjectDescriptor(
            root: root,
            jungle: jungle,
            manifest: manifest,
            appName: appName,
            applicationId: parsed.applicationId,
            manifestDevices: parsed.products
        )
    }

    /// Explicit device first; otherwise exactly one manifest product.
    public func selectDevice(explicit: String?) throws -> String {
        if let explicit {
            return explicit
        }
        if manifestDevices.count == 1 {
            return manifestDevices[0]
        }
        throw ToolError(
            code: "device_required",
            message: manifestDevices.isEmpty
                ? "The manifest at \(manifest.path) declares no products, so a device must be given."
                : "The manifest at \(manifest.path) declares \(manifestDevices.count) products, so a device must be given.",
            fix: "Pass a device id explicitly (see list_devices).",
            details: ["available": .array(manifestDevices.map { .string($0) })]
        )
    }

    // MARK: - Jungle parsing

    /// The effective `project.manifest` assignment of `jungle`. This
    /// parser deliberately understands only literal assignments: multiple
    /// *different* values are conflicting, and any `$(…)` value would need
    /// real jungle evaluation — both are project_invalid rather than a
    /// guess.
    private static func effectiveManifest(inJungle jungle: URL) throws -> URL {
        let contents: String
        do {
            contents = try String(contentsOf: jungle, encoding: .utf8)
        } catch {
            throw ToolError(
                code: "project_invalid",
                message: "Jungle file \(jungle.path) could not be read: \(error.localizedDescription)",
                fix: "Make the jungle file readable UTF-8 text.",
                details: ["jungle": .string(jungle.path)]
            )
        }

        var values: [String] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            // Comments run from '#' to end of line.
            let line = rawLine.prefix(while: { $0 != "#" })
            guard let match = line.firstMatch(of: /^\s*project\.manifest\s*=\s*(.+?)\s*$/) else {
                continue
            }
            var value = String(match.1)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !values.contains(value) {
                values.append(value)
            }
        }

        guard let value = values.first, values.count == 1 else {
            let problem =
                values.isEmpty
                ? "contains no project.manifest assignment"
                : "contains conflicting project.manifest assignments (\(values.joined(separator: ", ")))"
            throw ToolError(
                code: "project_invalid",
                message: "\(jungle.path) \(problem).",
                fix: "Give the jungle exactly one literal project.manifest assignment, e.g. `project.manifest = manifest.xml`.",
                details: ["jungle": .string(jungle.path)]
            )
        }

        guard !value.contains("$(") else {
            throw ToolError(
                code: "project_invalid",
                message:
                    "\(jungle.path) assigns project.manifest through a variable (\(value)), which this server does not evaluate.",
                fix: "Replace the variable with a literal manifest path in the jungle, or pass a different jungle file.",
                details: ["jungle": .string(jungle.path)]
            )
        }

        let manifest =
            value.hasPrefix("/")
            ? URL(fileURLWithPath: value)
            : jungle.deletingLastPathComponent().appending(path: value)
        let canonical = manifest.resolvingSymlinksInPath().standardizedFileURL

        guard FileManager.default.fileExists(atPath: canonical.path) else {
            throw ToolError(
                code: "project_invalid",
                message: "\(jungle.path) assigns project.manifest = \(value), but \(canonical.path) does not exist.",
                fix: "Fix the project.manifest path in that jungle or create the manifest file.",
                details: ["jungle": .string(jungle.path), "manifest": .string(canonical.path)]
            )
        }
        return canonical
    }

    // MARK: - Resource string resolution

    /// Finds the single `<string id="…">` below `<project>/resources`,
    /// scanning XML files in sorted canonical-path order. Zero or multiple
    /// matches are project_invalid — an ambiguous app name must not be
    /// guessed.
    private static func resolveStringResource(
        id: String, projectRoot: URL, manifest: URL
    ) throws -> String {
        let resources = projectRoot.appending(path: "resources")
        let fileManager = FileManager.default

        var xmlFiles: [URL] = []
        if let enumerator = fileManager.enumerator(
            at: resources, includingPropertiesForKeys: nil)
        {
            for case let url as URL in enumerator
            where url.pathExtension.lowercased() == "xml" {
                xmlFiles.append(url.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        xmlFiles.sort { $0.path < $1.path }

        var matches: [(file: URL, text: String)] = []
        for file in xmlFiles {
            guard let document = try? XMLDocument(contentsOf: file) else { continue }
            for element in elements(withLocalName: "string", in: document.rootElement())
            where element.attribute(forName: "id")?.stringValue == id {
                let text = (element.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                matches.append((file, text))
            }
        }

        guard matches.count == 1 else {
            let problem =
                matches.isEmpty
                ? "No string resource with id \"\(id)\" exists below \(resources.path)"
                : "String id \"\(id)\" is defined \(matches.count) times below \(resources.path) (\(matches.map(\.file.lastPathComponent).joined(separator: ", ")))"
            throw ToolError(
                code: "project_invalid",
                message: "\(problem), but the manifest at \(manifest.path) names @Strings.\(id).",
                fix: "Define the string id exactly once in the project's resources, or use a literal name in the manifest.",
                details: ["stringId": .string(id), "resources": .string(resources.path)]
            )
        }
        return matches[0].text
    }

    // MARK: - Manifest parsing

    private struct ManifestSummary {
        let applicationId: String
        let name: String
        let products: [String]

        init(contentsOf manifest: URL) throws {
            let document: XMLDocument
            do {
                document = try XMLDocument(contentsOf: manifest)
            } catch {
                throw ToolError(
                    code: "project_invalid",
                    message: "Manifest \(manifest.path) is not parseable XML: \(error.localizedDescription)",
                    fix: "Repair the manifest XML (compare against a generated manifest from the SDK samples).",
                    details: ["manifest": .string(manifest.path)]
                )
            }

            let applications = elements(withLocalName: "application", in: document.rootElement())
            guard let application = applications.first, applications.count == 1 else {
                throw ToolError(
                    code: "project_invalid",
                    message:
                        "Manifest \(manifest.path) must contain exactly one iq:application element, found \(applications.count).",
                    fix: "Point the jungle at an application manifest (barrel manifests cannot be run in the simulator).",
                    details: ["manifest": .string(manifest.path)]
                )
            }

            guard let id = application.attribute(forName: "id")?.stringValue, !id.isEmpty else {
                throw ToolError(
                    code: "project_invalid",
                    message: "The iq:application element in \(manifest.path) has no id attribute.",
                    fix: "Add the application id attribute (the SDK generates one when creating a project).",
                    details: ["manifest": .string(manifest.path)]
                )
            }

            guard let name = application.attribute(forName: "name")?.stringValue, !name.isEmpty
            else {
                throw ToolError(
                    code: "project_invalid",
                    message: "The iq:application element in \(manifest.path) has no name attribute.",
                    fix: "Add a name attribute (a literal or @Strings.<id> reference).",
                    details: ["manifest": .string(manifest.path)]
                )
            }

            self.applicationId = id
            self.name = name
            self.products = elements(withLocalName: "product", in: application)
                .compactMap { $0.attribute(forName: "id")?.stringValue }
        }
    }

    /// Depth-first descendants of `root` (inclusive) whose local name
    /// matches, ignoring XML namespaces (`iq:product` matches "product").
    private static func elements(withLocalName localName: String, in root: XMLElement?) -> [XMLElement] {
        guard let root else { return [] }
        var found: [XMLElement] = []
        if root.localName == localName {
            found.append(root)
        }
        for child in root.children ?? [] {
            if let element = child as? XMLElement {
                found += elements(withLocalName: localName, in: element)
            }
        }
        return found
    }

    // MARK: - Artifact name sanitization

    private static func sanitizeArtifactName(_ raw: String) -> String {
        var sanitized = ""
        var inBadRun = false
        for character in raw {
            let isAllowed =
                character.isASCII
                && (character.isLetter || character.isNumber || character == "."
                    || character == "_" || character == "-")
            if isAllowed {
                sanitized.append(character)
                inBadRun = false
            } else if !inBadRun {
                sanitized.append("_")
                inBadRun = true
            }
        }
        while sanitized.hasPrefix(".") {
            sanitized.removeFirst()
        }
        return sanitized
    }
}
