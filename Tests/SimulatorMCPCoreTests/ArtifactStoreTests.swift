import Foundation
import Testing

import SimulatorMCPCore

@Suite("ArtifactStore")
struct ArtifactStoreTests {

    // MARK: - Naming

    @Test("artifact, sidecar, and lock names derive from appName, device, and mode")
    func testArtifactNaming() throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let store = ArtifactStore()

        let app = store.paths(for: try sandbox.makeRequest(mode: .debugApp))
        #expect(app.target.lastPathComponent == "Probe_App-fenix6xpro.prg")
        #expect(app.sidecar.lastPathComponent == "Probe_App-fenix6xpro.prg.meta.json")
        #expect(app.lock.path.hasSuffix("bin/.locks/Probe_App-fenix6xpro.prg.lock"))

        let release = store.paths(for: try sandbox.makeRequest(mode: .releaseApp))
        #expect(release.target.lastPathComponent == "Probe_App-fenix6xpro.prg")

        let tests = store.paths(for: try sandbox.makeRequest(mode: .unitTests))
        #expect(tests.target.lastPathComponent == "Probe_App-fenix6xpro-test.prg")
        #expect(tests.target.deletingLastPathComponent().lastPathComponent == "bin")
    }

    // MARK: - Compatibility key

    @Test("the key is stable for an unchanged request")
    func testKeyStability() throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let store = ArtifactStore()
        let request = try sandbox.makeRequest()

        let first = try store.compatibilityKey(for: request)
        let second = try store.compatibilityKey(for: request)

        #expect(first.key == second.key)
        #expect(!first.key.isEmpty)
    }

    @Test("the key changes with SDK path, SDK version, device, and mode")
    func testKeyChangesWithRequestIdentity() throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let store = ArtifactStore()
        let base = try store.compatibilityKey(for: sandbox.makeRequest()).key

        let otherSdkPath = try store.compatibilityKey(
            for: sandbox.makeRequest(sdkDirectoryName: "connectiq-sdk-mac-9.1.0-other")).key
        #expect(otherSdkPath != base)

        let otherSdkVersion = try store.compatibilityKey(
            for: sandbox.makeRequest(sdkVersion: "8.4.1")).key
        #expect(otherSdkVersion != base)

        let otherDevice = try store.compatibilityKey(
            for: sandbox.makeRequest(device: "venu3fixture")).key
        #expect(otherDevice != base)

        let otherMode = try store.compatibilityKey(for: sandbox.makeRequest(mode: .unitTests)).key
        #expect(otherMode != base)
    }

    @Test("the key changes when jungle, manifest, source, resource, or jungle-named paths change")
    func testKeyChangesWithInputMtimes() throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let store = ArtifactStore()

        for relativePath in [
            "monkey.jungle",
            "manifest.xml",
            "source/CompilerProbe.mc",
            "resources/strings.xml",
            "extra-src/Extra.mc",  // named by barrel.sourcePath in the jungle
        ] {
            let before = try store.compatibilityKey(for: sandbox.makeRequest()).key
            try sandbox.bumpMtime(of: relativePath)
            let after = try store.compatibilityKey(for: sandbox.makeRequest()).key
            #expect(after != before, "\(relativePath) mtime bump must change the key")
        }
    }

    // MARK: - Locking

    @Test("a held artifact lock times out as artifact_lock_timeout")
    func testLockTimeout() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let store = ArtifactStore()
        let paths = store.paths(for: try sandbox.makeRequest())
        try FileManager.default.createDirectory(
            at: paths.lock.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Hold the lock out-of-band.
        let fd = open(paths.lock.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        let start = ContinuousClock.now
        do {
            _ = try await store.withArtifactLock(paths, timeout: .milliseconds(200)) { true }
            Issue.record("expected artifact_lock_timeout")
        } catch let error as ToolError {
            #expect(error.code == "artifact_lock_timeout")
            #expect(!error.fix.isEmpty)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("the lock file is created but never unlinked")
    func testLockFileNeverUnlinked() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let store = ArtifactStore()
        let paths = store.paths(for: try sandbox.makeRequest())

        _ = try await store.withArtifactLock(paths, timeout: .seconds(1)) { true }

        #expect(FileManager.default.fileExists(atPath: paths.lock.path))
    }

    // MARK: - Publication

    @Test("publish renames over an existing target and a reader never sees it missing")
    func testPublishIsAtomicForReaders() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let store = ArtifactStore()
        let request = try sandbox.makeRequest()
        let paths = store.paths(for: request)
        let key = try store.compatibilityKey(for: request)

        // First publication.
        try publishOnce(store: store, paths: paths, request: request, key: key, content: "v0")

        let stop = Stop()
        let readerStarted = ReaderStarted()
        let reader = Task<Int, Never> {
            var observations = 0
            while !stop.value {
                if !FileManager.default.fileExists(atPath: paths.target.path) {
                    await readerStarted.markStarted()
                    return -1  // target vanished: rename semantics violated
                }
                observations += 1
                if observations == 1 {
                    await readerStarted.markStarted()
                }
            }
            return observations
        }

        await readerStarted.waitUntilStarted()
        for round in 1...25 {
            try publishOnce(
                store: store, paths: paths, request: request, key: key, content: "v\(round)")
        }
        stop.set()
        let observations = await reader.value

        #expect(observations > 0, "reader must have actually observed the target")
        #expect(String(decoding: try Data(contentsOf: paths.target), as: UTF8.self) == "v25")
    }

    @Test("reuse requires both a matching key and an exact PRG hash")
    func testReuseRequiresKeyAndHash() async throws {
        let sandbox = try CompileSandbox()
        defer { sandbox.tearDown() }
        let store = ArtifactStore()
        let request = try sandbox.makeRequest()
        let paths = store.paths(for: request)
        let key = try store.compatibilityKey(for: request)

        try publishOnce(store: store, paths: paths, request: request, key: key, content: "genuine")
        #expect(try store.reusableArtifact(paths: paths, key: key) != nil)

        // Simulate the crash window: the PRG was renamed but the sidecar
        // was not (equivalently: PRG bytes do not match the recorded
        // hash). This must be a cache miss, never a false hit.
        try Data("tampered".utf8).write(to: paths.target)
        #expect(try store.reusableArtifact(paths: paths, key: key) == nil)

        // A stale key (input changed) is also a miss even with intact bytes.
        try publishOnce(store: store, paths: paths, request: request, key: key, content: "genuine")
        try sandbox.bumpMtime(of: "source/CompilerProbe.mc")
        let newKey = try store.compatibilityKey(for: request)
        #expect(try store.reusableArtifact(paths: paths, key: newKey) == nil)
    }

    private func publishOnce(
        store: ArtifactStore,
        paths: ArtifactPaths,
        request: BuildRequest,
        key: ArtifactKey,
        content: String
    ) throws {
        let temp = paths.bin.appending(
            path: ".\(paths.target.lastPathComponent).\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(at: paths.bin, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: temp)
        _ = try store.publish(temporaryPrg: temp, paths: paths, request: request, key: key)
    }
}

/// Single-flag stop signal for reader loops.
private final class Stop: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }
}

/// One-shot barrier proving the reader has observed the initial target before
/// the writer starts republishing. Without this handshake the reader task may
/// not be scheduled until after `stop` is set, making the test fail with zero
/// observations even though publication is correct.
private actor ReaderStarted {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        guard !started else { return }
        started = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A complete fake compile setup: project (jungle, manifest, strings,
/// source, an extra jungle-named source tree), a fake SDK layout, and a
/// developer key, all in one throwaway directory.
struct CompileSandbox {
    let root: URL
    private let projectRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "compile-sandbox-\(UUID().uuidString)")
        projectRoot = root.appending(path: "project")
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: projectRoot.appending(path: "source"), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: projectRoot.appending(path: "resources"), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: projectRoot.appending(path: "extra-src"), withIntermediateDirectories: true)

        try """
        project.manifest = manifest.xml
        barrel.sourcePath = extra-src
        """.write(to: projectRoot.appending(path: "monkey.jungle"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <iq:manifest xmlns:iq="http://www.garmin.com/xml/connectiq" version="1">
            <iq:application entry="ProbeApp" id="00000000000000000000000000000003" name="Probe App" type="watch-app">
                <iq:products><iq:product id="fenix6xpro"/></iq:products>
            </iq:application>
        </iq:manifest>
        """.write(to: projectRoot.appending(path: "manifest.xml"), atomically: true, encoding: .utf8)

        try "class ProbeApp {}\n".write(
            to: projectRoot.appending(path: "source/CompilerProbe.mc"),
            atomically: true, encoding: .utf8)
        try "<resources/>\n".write(
            to: projectRoot.appending(path: "resources/strings.xml"),
            atomically: true, encoding: .utf8)
        try "class Extra {}\n".write(
            to: projectRoot.appending(path: "extra-src/Extra.mc"),
            atomically: true, encoding: .utf8)
        try Data([0x30, 0x82]).write(to: root.appending(path: "developer_key.der"))

        try makeSdkLayout(directoryName: "connectiq-sdk-mac-9.1.0-2026-01-01-abcdef123")
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeRequest(
        device: String = "fenix6xpro",
        mode: BuildMode = .debugApp,
        force: Bool = false,
        sdkVersion: String = "9.1.0",
        sdkDirectoryName: String? = nil
    ) throws -> BuildRequest {
        let sdkDirectory = sdkDirectoryName ?? "connectiq-sdk-mac-\(sdkVersion)-2026-01-01-abcdef123"
        try makeSdkLayout(directoryName: sdkDirectory)
        let sdk = SdkInfo(
            version: SemVer(sdkVersion) ?? SemVer(major: 9, minor: 1, patch: 0),
            root: root.appending(path: sdkDirectory).resolvingSymlinksInPath().standardizedFileURL,
            source: .explicit
        )
        let project = try ProjectDescriptor.resolve(
            projectPath: projectRoot.path, jungleOverride: nil)
        let context = try BuildContext.resolve(
            project: project,
            developerKeyOverride: root.appending(path: "developer_key.der").path,
            searchCeiling: root
        )
        return BuildRequest(context: context, sdk: sdk, device: device, mode: mode, force: force)
    }

    /// Pushes the file's modification time forward past filesystem
    /// timestamp granularity so the compatibility key must change.
    func bumpMtime(of relativePath: String, by seconds: TimeInterval = 2) throws {
        let url = projectRoot.appending(path: relativePath)
        let current =
            (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                as? Date) ?? Date()
        try FileManager.default.setAttributes(
            [.modificationDate: current.addingTimeInterval(seconds)], ofItemAtPath: url.path)
    }

    var binDirectory: URL { projectRoot.appending(path: "bin") }

    private func makeSdkLayout(directoryName: String) throws {
        let sdkRoot = root.appending(path: directoryName)
        guard !FileManager.default.fileExists(atPath: sdkRoot.path) else { return }
        try FileManager.default.createDirectory(
            at: sdkRoot.appending(path: "bin/ConnectIQ.app"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: sdkRoot.appending(path: "bin/monkeyc"))
        try Data("#!/bin/sh\n".utf8).write(to: sdkRoot.appending(path: "bin/monkeydo"))
    }
}
