import Foundation
import Testing

import SimulatorMCPCore

@Suite("BuildContext")
struct BuildContextTests {

    @Test("an explicit developer key override wins over discoverable keys")
    func testExplicitOverrideWins() throws {
        let tree = try KeyTree()
        defer { tree.tearDown() }
        try tree.placeKey(at: "a/b/project/developer_key.der")  // would win a search
        let explicit = try tree.placeKey(at: "elsewhere/my.der")

        let context = try BuildContext.resolve(
            project: tree.project,
            developerKeyOverride: explicit.path,
            searchCeiling: tree.root
        )

        #expect(context.developerKey == explicit.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test("an explicit override that does not exist is developer_key_not_found")
    func testExplicitOverrideMissing() throws {
        let tree = try KeyTree()
        defer { tree.tearDown() }

        do {
            _ = try BuildContext.resolve(
                project: tree.project,
                developerKeyOverride: tree.root.appending(path: "nope.der").path,
                searchCeiling: tree.root
            )
            Issue.record("expected developer_key_not_found")
        } catch let error as ToolError {
            #expect(error.code == "developer_key_not_found")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("an explicit override that is a directory is developer_key_not_found")
    func testExplicitOverrideDirectory() throws {
        let tree = try KeyTree()
        defer { tree.tearDown() }
        let directory = tree.root.appending(path: "keydir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            _ = try BuildContext.resolve(
                project: tree.project,
                developerKeyOverride: directory.path,
                searchCeiling: tree.root
            )
            Issue.record("expected developer_key_not_found")
        } catch let error as ToolError {
            #expect(error.code == "developer_key_not_found")
        }
    }

    @Test("developer_key.der is preferred over developer_key in the same directory")
    func testDerPreferredInSameDirectory() throws {
        let tree = try KeyTree()
        defer { tree.tearDown() }
        _ = try tree.placeKey(at: "a/b/project/developer_key")
        let der = try tree.placeKey(at: "a/b/project/developer_key.der")

        let context = try BuildContext.resolve(
            project: tree.project, developerKeyOverride: nil, searchCeiling: tree.root)

        #expect(context.developerKey == der.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test("the project root is searched before any parent")
    func testProjectRootBeforeParents() throws {
        let tree = try KeyTree()
        defer { tree.tearDown() }
        _ = try tree.placeKey(at: "a/developer_key.der")
        let atRoot = try tree.placeKey(at: "a/b/project/developer_key")

        let context = try BuildContext.resolve(
            project: tree.project, developerKeyOverride: nil, searchCeiling: tree.root)

        #expect(context.developerKey == atRoot.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test("the search ascends through parents until it finds a key")
    func testSearchAscendsParents() throws {
        let tree = try KeyTree()
        defer { tree.tearDown() }
        let atGrandparent = try tree.placeKey(at: "a/developer_key")

        let context = try BuildContext.resolve(
            project: tree.project, developerKeyOverride: nil, searchCeiling: tree.root)

        #expect(context.developerKey == atGrandparent.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test("a directory named developer_key is skipped, not selected")
    func testDirectoryNamedLikeKeyIsSkipped() throws {
        let tree = try KeyTree()
        defer { tree.tearDown() }
        try FileManager.default.createDirectory(
            at: tree.project.root.appending(path: "developer_key.der"),
            withIntermediateDirectories: true)
        let real = try tree.placeKey(at: "a/b/developer_key")

        let context = try BuildContext.resolve(
            project: tree.project, developerKeyOverride: nil, searchCeiling: tree.root)

        #expect(context.developerKey == real.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test("no key anywhere is developer_key_not_found with a concrete fix")
    func testNoKeyAnywhere() throws {
        let tree = try KeyTree()
        defer { tree.tearDown() }

        do {
            _ = try BuildContext.resolve(
                project: tree.project, developerKeyOverride: nil, searchCeiling: tree.root)
            Issue.record("expected developer_key_not_found")
        } catch let error as ToolError {
            #expect(error.code == "developer_key_not_found")
            #expect(!error.fix.isEmpty)
        }
    }
}

/// `<root>/a/b/project/` with a real resolvable project at the bottom, so
/// key placement at any level exercises the upward search.
private struct KeyTree {
    let root: URL
    let project: ProjectDescriptor

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "build-context-tests-\(UUID().uuidString)")
        let projectRoot = root.appending(path: "a/b/project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        try "project.manifest = manifest.xml\n".write(
            to: projectRoot.appending(path: "monkey.jungle"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <iq:manifest xmlns:iq="http://www.garmin.com/xml/connectiq" version="1">
            <iq:application entry="KeyApp" id="00000000000000000000000000000002" name="Key App" type="watch-app">
                <iq:products><iq:product id="fenix6xpro"/></iq:products>
            </iq:application>
        </iq:manifest>
        """.write(to: projectRoot.appending(path: "manifest.xml"), atomically: true, encoding: .utf8)

        project = try ProjectDescriptor.resolve(projectPath: projectRoot.path, jungleOverride: nil)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func placeKey(at relativePath: String) throws -> URL {
        let target = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x30, 0x82]).write(to: target)  // DER-ish leading bytes; contents are irrelevant
        return target
    }
}
