import Foundation
import Testing

import SimulatorMCPCore

@Suite("SdkLocator")
struct SdkLocatorTests {

    // MARK: - Precedence branches

    @Test("an explicit path wins over env, cfg, and installed SDKs")
    func testExplicitPathWins() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let explicit = try sandbox.makeSdk(version: "8.4.1")
        let env = try sandbox.makeSdk(version: "9.1.0")
        let installed = try sandbox.makeInstalledSdk(version: "9.9.9")
        try sandbox.writeCfg(pointingAt: installed)

        let locator = sandbox.locator(environment: ["CIQ_SDK": env.path])
        let info = try locator.resolve(explicitPath: explicit.path)

        #expect(info.source == .explicit)
        #expect(info.root == canonical(explicit))
        #expect(info.version == SemVer("8.4.1"))
    }

    @Test("CIQ_SDK wins when no explicit path is given")
    func testEnvironmentWins() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let env = try sandbox.makeSdk(version: "8.4.1")
        let installed = try sandbox.makeInstalledSdk(version: "9.1.0")
        try sandbox.writeCfg(pointingAt: installed)

        let locator = sandbox.locator(environment: ["CIQ_SDK": env.path])
        let info = try locator.resolve(explicitPath: nil)

        #expect(info.source == .environment)
        #expect(info.root == canonical(env))
    }

    @Test("an absolute current-sdk.cfg (trailing slash and newline) wins over installed")
    func testCfgAbsoluteForm() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let cfgTarget = try sandbox.makeInstalledSdk(version: "8.4.1")
        _ = try sandbox.makeInstalledSdk(version: "9.1.0")
        // The real file on this machine ends with a trailing slash;
        // tolerate a trailing newline too.
        try sandbox.writeCfgRaw(cfgTarget.path + "/\n")

        let info = try sandbox.locator(environment: [:]).resolve(explicitPath: nil)

        #expect(info.source == .currentSdkCfg)
        #expect(info.root == canonical(cfgTarget))
        #expect(info.version == SemVer("8.4.1"))
    }

    @Test("a relative current-sdk.cfg resolves against the cfg's directory")
    func testCfgRelativeForm() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let target = try sandbox.makeInstalledSdk(version: "8.4.1")
        try sandbox.writeCfgRaw("Sdks/\(target.lastPathComponent)\n")

        let info = try sandbox.locator(environment: [:]).resolve(explicitPath: nil)

        #expect(info.source == .currentSdkCfg)
        #expect(info.root == canonical(target))
    }

    @Test("with no explicit, env, or cfg, the newest installed version wins numerically")
    func testNewestInstalledWinsNumerically() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        _ = try sandbox.makeInstalledSdk(version: "9.2.0")
        let newest = try sandbox.makeInstalledSdk(version: "9.10.0")
        _ = try sandbox.makeInstalledSdk(version: "9.9.1")

        let info = try sandbox.locator(environment: [:]).resolve(explicitPath: nil)

        #expect(info.source == .newestInstalled)
        #expect(info.version == SemVer("9.10.0"))
        #expect(info.root == canonical(newest))
    }

    // MARK: - Invalid candidates

    @Test("an explicit path missing monkeyc is sdk_not_found with a fix")
    func testExplicitInvalidCandidate() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let broken = try sandbox.makeSdk(version: "9.1.0", without: "bin/monkeyc")

        do {
            _ = try sandbox.locator(environment: [:]).resolve(explicitPath: broken.path)
            Issue.record("expected sdk_not_found")
        } catch let error as ToolError {
            #expect(error.code == "sdk_not_found")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a set but invalid CIQ_SDK is an error, not a silent fall-through")
    func testEnvironmentInvalidDoesNotFallThrough() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        _ = try sandbox.makeInstalledSdk(version: "9.1.0")  // would win if we fell through

        do {
            _ = try sandbox.locator(environment: ["CIQ_SDK": "/does/not/exist"])
                .resolve(explicitPath: nil)
            Issue.record("expected sdk_not_found")
        } catch let error as ToolError {
            #expect(error.code == "sdk_not_found")
            #expect(error.message.contains("CIQ_SDK"))
        }
    }

    @Test("a cfg pointing at a missing directory is an error, not a silent fall-through")
    func testCfgInvalidDoesNotFallThrough() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        _ = try sandbox.makeInstalledSdk(version: "9.1.0")  // would win if we fell through
        try sandbox.writeCfgRaw("/gone/away/sdk\n")

        do {
            _ = try sandbox.locator(environment: [:]).resolve(explicitPath: nil)
            Issue.record("expected sdk_not_found")
        } catch let error as ToolError {
            #expect(error.code == "sdk_not_found")
            #expect(error.message.contains("current-sdk.cfg"))
        }
    }

    @Test("no installed SDK at all is sdk_not_found")
    func testNothingInstalled() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }

        do {
            _ = try sandbox.locator(environment: [:]).resolve(explicitPath: nil)
            Issue.record("expected sdk_not_found")
        } catch let error as ToolError {
            #expect(error.code == "sdk_not_found")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("newest-installed skips invalid layouts and unversioned directory names")
    func testNewestSkipsInvalidCandidates() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let valid = try sandbox.makeInstalledSdk(version: "8.4.1")
        _ = try sandbox.makeInstalledSdk(version: "9.1.0", without: "bin/ConnectIQ.app")
        try FileManager.default.createDirectory(
            at: sandbox.sdksRoot.appending(path: "not-an-sdk"),
            withIntermediateDirectories: true)

        let info = try sandbox.locator(environment: [:]).resolve(explicitPath: nil)

        #expect(info.version == SemVer("8.4.1"))
        #expect(info.root == canonical(valid))
    }

    // MARK: - Inventory and derived paths

    @Test("installedSdks lists valid SDKs ascending by version")
    func testInstalledSdksSorted() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        _ = try sandbox.makeInstalledSdk(version: "9.10.0")
        _ = try sandbox.makeInstalledSdk(version: "8.4.1")
        _ = try sandbox.makeInstalledSdk(version: "9.2.0", without: "bin/monkeydo")

        let versions = sandbox.locator(environment: [:]).installedSdks().map(\.version)

        #expect(versions == [SemVer("8.4.1"), SemVer("9.10.0")])
    }

    @Test("SdkInfo derives the simulator app and compiler binaries from its root")
    func testSdkInfoDerivedPaths() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let root = try sandbox.makeSdk(version: "9.1.0")

        let info = try sandbox.locator(environment: [:]).resolve(explicitPath: root.path)

        #expect(info.simulatorApp == info.root.appending(path: "bin/ConnectIQ.app"))
        #expect(info.monkeyc == info.root.appending(path: "bin/monkeyc"))
        #expect(info.monkeydo == info.root.appending(path: "bin/monkeydo"))
    }

    @Test("resolution canonicalizes symlinked and slash-decorated input paths")
    func testCanonicalizesInput() throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let root = try sandbox.makeSdk(version: "9.1.0")
        let link = sandbox.root.appending(path: "connectiq-sdk-mac-9.1.0-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        // Trailing slash and a symlinked spelling must both resolve to the
        // same canonical root as the direct path.
        let viaSlash = try sandbox.locator(environment: [:]).resolve(
            explicitPath: root.path + "/")
        let viaLink = try sandbox.locator(environment: [:]).resolve(explicitPath: link.path)

        #expect(viaSlash.root == canonical(root))
        #expect(viaLink.root == canonical(root))
    }
}

/// A throwaway on-disk ConnectIQ-style root:
///
///     <root>/Sdks/connectiq-sdk-mac-<version>-2026-01-01-abcdef123/bin/...
///     <root>/current-sdk.cfg
///     <root>/loose/<version>/...        (SDKs outside Sdks/, for explicit/env)
private struct Sandbox {
    let root: URL
    let sdksRoot: URL
    let cfg: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "sdk-locator-tests-\(UUID().uuidString)")
        sdksRoot = root.appending(path: "Sdks")
        cfg = root.appending(path: "current-sdk.cfg")
        try FileManager.default.createDirectory(at: sdksRoot, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func locator(environment: [String: String]) -> SdkLocator {
        SdkLocator(sdksRoot: sdksRoot, currentSdkCfg: cfg, environment: environment)
    }

    /// A complete (or deliberately broken) SDK tree outside `Sdks/`.
    func makeSdk(version: String, without missing: String? = nil) throws -> URL {
        let dir = root.appending(path: "loose")
            .appending(path: "connectiq-sdk-mac-\(version)-2026-01-01-abcdef123")
        try populateSdk(at: dir, without: missing)
        return dir
    }

    /// A complete (or deliberately broken) SDK tree inside `Sdks/`.
    func makeInstalledSdk(version: String, without missing: String? = nil) throws -> URL {
        let dir = sdksRoot.appending(path: "connectiq-sdk-mac-\(version)-2026-01-01-abcdef123")
        try populateSdk(at: dir, without: missing)
        return dir
    }

    func writeCfg(pointingAt sdk: URL) throws {
        try writeCfgRaw(sdk.path + "/\n")
    }

    func writeCfgRaw(_ contents: String) throws {
        try contents.write(to: cfg, atomically: true, encoding: .utf8)
    }

    private func populateSdk(at dir: URL, without missing: String?) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: dir.appending(path: "bin/ConnectIQ.app"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "bin/monkeyc"))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "bin/monkeydo"))
        if let missing {
            try fileManager.removeItem(at: dir.appending(path: missing))
        }
    }
}

private func canonical(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
}
