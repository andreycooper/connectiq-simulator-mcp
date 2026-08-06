import Foundation
import Testing

import SimulatorMCPCore

private let integrationEnabled =
    ProcessInfo.processInfo.environment["SIM_INTEGRATION"] == "1"

/// Gate 8.4: capture durability against the real simulator through the
/// installed signed server.
///
/// Ground truth for the defect this closes is
/// `docs/verification/simulator-contracts/capture-short-write.json`: 430 of
/// 468 files in the old shared `/tmp/simulator-mcp/` directory were 4 bytes
/// long -- the PNG signature and nothing else -- while the same bytes reached
/// the MCP response intact. `CapturePublisher` now moves captures to
/// `~/.simulator-mcp/screenshots/`, verifies every publication by reading it
/// back before exposing the path, and prunes to a bounded retention window.
/// This gate drives that machinery for real: past its retention bound, with
/// a caller-supplied `savePath` outside the managed directory in the mix,
/// and checks the old shared directory never grows.
@Suite("Capture durability acceptance", .enabled(if: integrationEnabled), .serialized)
struct CaptureDurabilityIntegrationTests {
    /// Read directly from `CapturePublisher`'s own default parameter
    /// (`Sources/SimulatorMCPCore/Automation/CapturePublisher.swift:33`),
    /// never assumed. The production installed server wires
    /// `ScreenshotService` with an all-default `CapturePublisher()`
    /// (`PublicToolServices.swift`), so this is the bound actually enforced.
    private static let retainCount = 200
    private static let captureCount = retainCount + 5

    @Test(
        "retainCount+5 captures stay within bound, every managed file is a complete PNG, a sequence savePath frame outside the managed directory survives the pruning it triggers, and /tmp/simulator-mcp gains no files",
        .timeLimit(.minutes(20)))
    func captureDurability() async throws {
        let root = repositoryRoot()
        let executable = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/bin/simulator-mcp")
        let developerKey = try #require(
            ProcessInfo.processInfo.environment["SIM_DEVELOPER_KEY"],
            "SIM_DEVELOPER_KEY must name an external Connect IQ developer key")
        #expect(FileManager.default.isReadableFile(atPath: developerKey))
        let fixture = root.appending(path: "Tests/fixtures/testapp", directoryHint: .isDirectory)

        let managedDirectory = CapturePublisher.defaultDirectory
        let legacyDirectory = URL(fileURLWithPath: "/tmp/simulator-mcp")
        let externalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate8.4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalDirectory, withIntermediateDirectories: true)
        let externalSavePath = externalDirectory.appendingPathComponent("external-frame.png")
        defer { try? FileManager.default.removeItem(at: externalDirectory) }
        // Resolved the same way the server's own `canonicalPath` resolves a
        // savePath (expand ~, resolve symlinks, standardize) so the
        // comparison below is against what the tool actually promised, not a
        // client-side guess.
        let expectedExternalPath = URL(fileURLWithPath: externalSavePath.path)
            .resolvingSymlinksInPath().standardizedFileURL.path

        let legacyCountBefore = countEntries(legacyDirectory)
        Log.err("capture_durability_gate: /tmp/simulator-mcp before = \(legacyCountBefore)")

        let client = InstalledServerClient(executableURL: executable)
        try await client.start()

        do {
            try validateTask17ToolAdvertisement(try await client.listTools())
            // Force a clean first launch rather than adopting whatever a
            // previous suite left loaded. This gate's assertions are all
            // about files on disk -- run_app succeeding plus the first
            // screenshot succeeding is sufficient readiness, and it sidesteps
            // the pre-existing same-device-relaunch log-capture defect
            // (docs/verification/simulator-contracts/same-device-relaunch-log-loss.json)
            // entirely rather than depending on get_logs, which is exactly
            // the dependency that defect breaks.
            _ = try await client.callTool("sim_stop", as: SimStopResult.self)
            try await waitForSimulatorStopped(client, deadline: .seconds(30))
            _ = try requireSuccess(
                try await client.callTool("sim_start", as: SimStartResult.self), tool: "sim_start")

            let run = try requireSuccess(
                try await client.callTool(
                    "run_app",
                    arguments: [
                        "projectPath": .string(fixture.path),
                        "device": .string("fenix6xpro"),
                        "developerKey": .string(developerKey),
                        "rebuild": true,
                    ], as: RunAppResult.self),
                tool: "run_app")
            #expect(run.simulatorRestarted == false, "expected a first launch, not a device-switch restart")

            // A sequence savePath frame outside the managed directory, taken
            // before the excess managed captures below so its survival
            // through the pruning they trigger is actually exercised, not
            // just structurally guaranteed by never sharing a directory.
            let sequence = try requireSuccess(
                try await client.callTool(
                    "run_sequence",
                    arguments: [
                        "steps": .array([
                            .object([
                                "kind": .string("screenshot"),
                                "label": .string("external"),
                                "savePath": .string(externalSavePath.path),
                            ])
                        ]),
                        "allowFocus": false,
                    ], as: SequenceResult.self),
                tool: "run_sequence")
            #expect(sequence.steps.map(\.status) == ["completed"])
            #expect(sequence.steps.first?.path == expectedExternalPath)

            let externalCheck = pngCompleteness(at: URL(fileURLWithPath: expectedExternalPath))
            #expect(externalCheck.isCompletePNG, "external savePath frame is not a complete PNG: \(externalCheck)")

            // Drive retainCount + 5 plain (managed) captures -- enough to
            // cross the retention bound, not just approach it.
            for index in 0..<Self.captureCount {
                let shot = try requireSuccess(
                    try await client.callTool("screenshot", as: ScreenshotResult.self),
                    tool: "screenshot")
                #expect(shot.path.hasPrefix(managedDirectory.path))
                if index % 25 == 0 || index == Self.captureCount - 1 {
                    Log.err("capture_durability_gate: managed capture \(index + 1)/\(Self.captureCount)")
                }
            }

            _ = try await client.callTool("sim_stop", as: SimStopResult.self)
        } catch {
            Log.err("capture_durability_gate: server diagnostics on failure:\n\(await client.diagnosticText())")
            _ = try? await client.callTool("sim_stop", as: SimStopResult.self)
            await client.stop()
            throw error
        }
        #expect(await client.stop())

        // 1 & 3: the managed directory stays within its retention bound, and
        // every file remaining in it is a complete PNG -- not just the ones
        // this run happened to write, but everything found on disk.
        let managedEntries = (try? FileManager.default.contentsOfDirectory(
            at: managedDirectory, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        let managedPNGs = managedEntries.filter { $0.pathExtension == "png" }
        Log.err("capture_durability_gate: managed directory has \(managedPNGs.count) PNG file(s) after \(Self.captureCount) captures (retainCount=\(Self.retainCount))")
        #expect(managedPNGs.count <= Self.retainCount)

        var shortFiles: [String] = []
        var incompleteFiles: [String] = []
        for file in managedPNGs {
            let check = pngCompleteness(at: file)
            if check.size < 8 { shortFiles.append("\(file.lastPathComponent) (\(check.size)B)") }
            if !check.isCompletePNG {
                incompleteFiles.append("\(file.lastPathComponent) (\(check.size)B, sig=\(check.hasSignature), iend=\(check.hasIEND))")
            }
        }
        #expect(shortFiles.isEmpty, "files under 8 bytes found: \(shortFiles)")
        #expect(incompleteFiles.isEmpty, "incomplete PNGs found: \(incompleteFiles)")

        // 4: the external savePath frame survived the pruning the excess
        // managed captures above triggered.
        #expect(FileManager.default.fileExists(atPath: expectedExternalPath))
        let externalRecheck = pngCompleteness(at: URL(fileURLWithPath: expectedExternalPath))
        #expect(externalRecheck.isCompletePNG, "external savePath frame did not survive: \(externalRecheck)")

        // 5: the legacy shared directory gained no files.
        let legacyCountAfter = countEntries(legacyDirectory)
        Log.err("capture_durability_gate: /tmp/simulator-mcp after = \(legacyCountAfter)")
        #expect(legacyCountAfter == legacyCountBefore)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // Integration
            .deletingLastPathComponent() // SimulatorMCPCoreTests
            .deletingLastPathComponent() // Tests
    }

    private func countEntries(_ directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
    }
}

/// Independently re-derived PNG completeness check -- deliberately not a call
/// into `CapturePublisher`'s own validation, so this gate proves what is
/// actually on disk rather than trusting the component under test to grade
/// its own homework.
private struct PNGCompletenessCheck: CustomStringConvertible {
    let size: Int
    let hasSignature: Bool
    let hasIEND: Bool
    var isCompletePNG: Bool { hasSignature && hasIEND && size >= 20 }
    var description: String { "size=\(size) signature=\(hasSignature) iend=\(hasIEND)" }
}

private func pngCompleteness(at url: URL) -> PNGCompletenessCheck {
    guard let data = try? Data(contentsOf: url) else {
        return PNGCompletenessCheck(size: -1, hasSignature: false, hasIEND: false)
    }
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    let hasSignature = data.count >= 8 && Array(data.prefix(8)) == signature
    let hasIEND = data.count >= 8 && Array(data.suffix(8).prefix(4)) == Array("IEND".utf8)
    return PNGCompletenessCheck(size: data.count, hasSignature: hasSignature, hasIEND: hasIEND)
}
