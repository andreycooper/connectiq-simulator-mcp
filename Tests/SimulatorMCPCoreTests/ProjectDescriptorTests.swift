import Foundation
import Testing

import SimulatorMCPCore

@Suite("ProjectDescriptor")
struct ProjectDescriptorTests {

    // MARK: - Committed fixtures

    @Test("resolves the basic fixture: root jungle, @Strings name, one product")
    func testResolvesBasicFixture() throws {
        let project = try ProjectDescriptor.resolve(
            projectPath: fixtureProject("basic").path, jungleOverride: nil)

        #expect(project.jungle.lastPathComponent == "monkey.jungle")
        #expect(project.manifest.lastPathComponent == "manifest.xml")
        #expect(project.applicationId == "0123456789ABCDEF0123456789ABCDEF")
        // "@Strings.AppName" resolved to "Basic Fixture", then sanitized
        // for artifact paths: the space becomes one underscore.
        #expect(project.appName == "Basic_Fixture")
        #expect(project.manifestDevices == ["fenix6xpro"])
    }

    @Test("descriptor resolution succeeds with no developer key anywhere")
    func testSucceedsWithoutDeveloperKey() throws {
        // The fixture tree contains no developer_key/developer_key.der;
        // read-only descriptor resolution must never look for one.
        _ = try ProjectDescriptor.resolve(
            projectPath: fixtureProject("basic").path, jungleOverride: nil)
    }

    @Test("a jungle override selects a non-root manifest")
    func testJungleOverrideSelectsNonRootManifest() throws {
        let root = fixtureProject("subdir-jungle")
        let project = try ProjectDescriptor.resolve(
            projectPath: root.path,
            jungleOverride: root.appending(path: "config/alt.jungle").path)

        #expect(project.jungle.lastPathComponent == "alt.jungle")
        #expect(project.manifest.path.hasSuffix("meta/manifest.xml"))
        #expect(project.appName == "Alt_Fixture")
        #expect(project.manifestDevices == ["fenix6xpro", "fr965"])
    }

    @Test("a nonexistent manifest assignment is project_invalid naming the jungle")
    func testNonexistentManifestNamesJungle() throws {
        let root = fixtureProject("subdir-jungle")
        do {
            _ = try ProjectDescriptor.resolve(projectPath: root.path, jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
            #expect(error.message.contains("monkey.jungle"))
            #expect(!error.fix.isEmpty)
        }
    }

    // MARK: - Project path validation

    @Test("a nonexistent project path is project_invalid")
    func testNonexistentProjectPath() throws {
        do {
            _ = try ProjectDescriptor.resolve(
                projectPath: "/definitely/not/here/\(UUID().uuidString)", jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a project path that is a file, not a directory, is project_invalid")
    func testProjectPathThatIsAFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "not-a-dir-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try ProjectDescriptor.resolve(projectPath: file.path, jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
        }
    }

    // MARK: - Jungle parsing

    @Test("a jungle with no project.manifest assignment is project_invalid naming the jungle")
    func testMissingManifestAssignment() throws {
        let project = try TempProject(jungle: "# nothing but comments\n")
        defer { project.tearDown() }

        do {
            _ = try ProjectDescriptor.resolve(projectPath: project.root.path, jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
            #expect(error.message.contains("monkey.jungle"))
        }
    }

    @Test("conflicting project.manifest assignments are project_invalid")
    func testConflictingManifestAssignments() throws {
        let project = try TempProject(
            jungle: "project.manifest = manifest.xml\nproject.manifest = other.xml\n")
        defer { project.tearDown() }

        do {
            _ = try ProjectDescriptor.resolve(projectPath: project.root.path, jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
            #expect(error.message.contains("monkey.jungle"))
        }
    }

    @Test("repeated identical assignments are effective, not conflicting")
    func testRepeatedIdenticalAssignmentsAreFine() throws {
        let project = try TempProject(
            jungle: "project.manifest = manifest.xml\nproject.manifest = manifest.xml\n")
        defer { project.tearDown() }

        let descriptor = try ProjectDescriptor.resolve(
            projectPath: project.root.path, jungleOverride: nil)
        #expect(descriptor.manifest.lastPathComponent == "manifest.xml")
    }

    @Test("a variable-expanded manifest assignment is project_invalid")
    func testVariableExpandedManifestAssignment() throws {
        let project = try TempProject(jungle: "project.manifest = $(base)/manifest.xml\n")
        defer { project.tearDown() }

        do {
            _ = try ProjectDescriptor.resolve(projectPath: project.root.path, jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
            #expect(error.message.contains("monkey.jungle"))
        }
    }

    // MARK: - @Strings resolution

    @Test("a missing string id is project_invalid")
    func testMissingStringId() throws {
        let project = try TempProject(
            strings: ["strings.xml": #"<resources><string id="Other">x</string></resources>"#])
        defer { project.tearDown() }

        do {
            _ = try ProjectDescriptor.resolve(projectPath: project.root.path, jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
            #expect(error.message.contains("AppName"))
        }
    }

    @Test("a duplicate string id across resource files is project_invalid")
    func testDuplicateStringId() throws {
        let project = try TempProject(strings: [
            "strings.xml": #"<resources><string id="AppName">One</string></resources>"#,
            "more/extra.xml": #"<resources><string id="AppName">Two</string></resources>"#,
        ])
        defer { project.tearDown() }

        do {
            _ = try ProjectDescriptor.resolve(projectPath: project.root.path, jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
            #expect(error.message.contains("AppName"))
        }
    }

    @Test("the resolved string text is trimmed")
    func testStringTextTrimmed() throws {
        let project = try TempProject(strings: [
            "strings.xml": "<resources><string id=\"AppName\">  Spaced Out \n</string></resources>"
        ])
        defer { project.tearDown() }

        let descriptor = try ProjectDescriptor.resolve(
            projectPath: project.root.path, jungleOverride: nil)
        #expect(descriptor.appName == "Spaced_Out")
    }

    // MARK: - appName sanitization

    @Test("slashes and dot-dot in the name cannot escape the artifact directory")
    func testSanitizesPathEscapes() throws {
        let project = try TempProject(manifestName: "../../evil name")
        defer { project.tearDown() }

        let descriptor = try ProjectDescriptor.resolve(
            projectPath: project.root.path, jungleOverride: nil)

        #expect(descriptor.appName == "_.._evil_name")
        #expect(!descriptor.appName.contains("/"))
        #expect(!descriptor.appName.hasPrefix("."))
    }

    @Test("a name that sanitizes to empty falls back to the application id")
    func testEmptySanitizationFallsBackToApplicationId() throws {
        let project = try TempProject(manifestName: "...")
        defer { project.tearDown() }

        let descriptor = try ProjectDescriptor.resolve(
            projectPath: project.root.path, jungleOverride: nil)

        #expect(descriptor.appName == descriptor.applicationId)
    }

    // MARK: - Device selection

    @Test("an explicit device wins over the manifest")
    func testExplicitDeviceWins() throws {
        let descriptor = try ProjectDescriptor.resolve(
            projectPath: fixtureProject("basic").path, jungleOverride: nil)
        #expect(try descriptor.selectDevice(explicit: "fr965") == "fr965")
    }

    @Test("exactly one manifest product is selected implicitly")
    func testSingleProductSelected() throws {
        let descriptor = try ProjectDescriptor.resolve(
            projectPath: fixtureProject("basic").path, jungleOverride: nil)
        #expect(try descriptor.selectDevice(explicit: nil) == "fenix6xpro")
    }

    @Test("zero manifest products is device_required")
    func testZeroProductsIsDeviceRequired() throws {
        let project = try TempProject(products: [])
        defer { project.tearDown() }
        let descriptor = try ProjectDescriptor.resolve(
            projectPath: project.root.path, jungleOverride: nil)

        do {
            _ = try descriptor.selectDevice(explicit: nil)
            Issue.record("expected device_required")
        } catch let error as ToolError {
            #expect(error.code == "device_required")
        }
    }

    @Test("multiple manifest products is device_required listing the candidates")
    func testMultipleProductsIsDeviceRequired() throws {
        let root = fixtureProject("subdir-jungle")
        let descriptor = try ProjectDescriptor.resolve(
            projectPath: root.path,
            jungleOverride: root.appending(path: "config/alt.jungle").path)

        do {
            _ = try descriptor.selectDevice(explicit: nil)
            Issue.record("expected device_required")
        } catch let error as ToolError {
            #expect(error.code == "device_required")
            #expect(error.details?["available"] == ["fenix6xpro", "fr965"])
        }
    }

    @Test("a manifest without an application element is project_invalid")
    func testManifestWithoutApplication() throws {
        let project = try TempProject(
            manifestXML: #"<iq:manifest xmlns:iq="http://www.garmin.com/xml/connectiq"/>"#)
        defer { project.tearDown() }

        do {
            _ = try ProjectDescriptor.resolve(projectPath: project.root.path, jungleOverride: nil)
            Issue.record("expected project_invalid")
        } catch let error as ToolError {
            #expect(error.code == "project_invalid")
        }
    }
}

// MARK: - Fixture helpers

/// Committed fixture projects copied into the test bundle.
func fixtureProject(_ name: String) -> URL {
    Bundle.module.resourceURL!
        .appending(path: "Fixtures/projects")
        .appending(path: name)
}

/// A throwaway on-disk project for the error-path variants that would
/// bloat the committed fixtures.
private struct TempProject {
    let root: URL

    init(
        jungle: String = "project.manifest = manifest.xml\n",
        manifestName: String = "@Strings.AppName",
        products: [String] = ["fenix6xpro"],
        manifestXML: String? = nil,
        strings: [String: String] = [
            "strings.xml": #"<resources><string id="AppName">Temp App</string></resources>"#
        ]
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "project-descriptor-tests-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        try jungle.write(to: root.appending(path: "monkey.jungle"), atomically: true, encoding: .utf8)

        let productsXML = products.map { #"<iq:product id="\#($0)"/>"# }.joined()
        let manifest =
            manifestXML
            ?? """
            <?xml version="1.0" encoding="UTF-8"?>
            <iq:manifest xmlns:iq="http://www.garmin.com/xml/connectiq" version="1">
                <iq:application entry="TempApp" id="00000000000000000000000000000001" name="\(manifestName)" type="watch-app">
                    <iq:products>\(productsXML)</iq:products>
                </iq:application>
            </iq:manifest>
            """
        try manifest.write(
            to: root.appending(path: "manifest.xml"), atomically: true, encoding: .utf8)

        for (relativePath, contents) in strings {
            let target = root.appending(path: "resources").appending(path: relativePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
