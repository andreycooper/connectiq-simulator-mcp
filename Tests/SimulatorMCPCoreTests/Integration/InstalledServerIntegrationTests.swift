import CoreGraphics
import Foundation
import ImageIO
import MCP
import Testing

import SimulatorMCPCore

private let integrationEnabled =
    ProcessInfo.processInfo.environment["SIM_INTEGRATION"] == "1"

@Suite(.enabled(if: integrationEnabled), .serialized)
struct InstalledServerIntegrationTests {
    @Test("installed signed server drives the deterministic fixture only through MCP")
    func installedBoundary() async throws {
        let root = repositoryRoot()
        let attribution = try TCCAttribution.load(
            root.appending(path: "docs/verification/simulator-contracts/tcc-attribution.json"))
        let executable = try attribution.selectedExecutable()
        let developerKey = try #require(
            ProcessInfo.processInfo.environment["SIM_DEVELOPER_KEY"],
            "SIM_DEVELOPER_KEY must name an external Connect IQ developer key")
        #expect(FileManager.default.isReadableFile(atPath: developerKey))

        let fixture = root.appending(path: "Tests/fixtures/testapp", directoryHint: .isDirectory)
        let client = InstalledServerClient(executableURL: executable)
        try await client.start()

        do {
            try validateTask17ToolAdvertisement(try await client.listTools())
            let doctor = try requireSuccess(
                try await client.callTool("doctor", as: DoctorResult.self), tool: "doctor")
            #expect(doctor.signatureKind == .stable)
            #expect(doctor.screenRecording.granted)
            #expect(doctor.accessibility.granted)
            #expect(doctor.executablePath == executable.resolvingSymlinksInPath().path)

            let devices = try requireSuccess(
                try await client.callTool("list_devices", as: ListDevicesResult.self),
                tool: "list_devices")
            #expect(!devices.devices.isEmpty)
            for device in devices.devices {
                #expect(device.inputSupported == false)
                #expect(device.buttons.isEmpty)
                #expect(device.inputProfile == nil)
            }

            let started = try requireSuccess(
                try await client.callTool("sim_start", as: SimStartResult.self),
                tool: "sim_start")
            #expect(started.status.state == .ready)

            let tests = try requireSuccess(
                try await client.callTool(
                    "run_tests",
                    arguments: [
                        "projectPath": .string(fixture.path),
                        "device": "fenix6xpro",
                        "developerKey": .string(developerKey),
                    ],
                    as: RunTestsResult.self),
                tool: "run_tests")
            #expect(tests.overallPassed)
            #expect(tests.passed == 2)
            #expect(tests.failed == 0)
            #expect(tests.errors == 0)
            #expect(tests.perTest.map(\.name).sorted() == [
                "fixture_math_passes", "fixture_page_wraps",
            ])
            #expect(tests.perTest.allSatisfy { $0.status == "passed" })

            let app = try requireSuccess(
                try await client.callTool(
                    "run_app",
                    arguments: [
                        "projectPath": .string(fixture.path),
                        "device": "fenix6xpro",
                        "developerKey": .string(developerKey),
                        "rebuild": true,
                    ],
                    as: RunAppResult.self),
                tool: "run_app")
            #expect(app.sessionId > 0)
            #expect(app.device == "fenix6xpro")
            #expect(!app.sdkPath.isEmpty)
            #expect(!app.sdkVersion.isEmpty)
            try await waitForMarker("FIXTURE_STARTED", sessionID: app.sessionId, client: client)

            let screenshotResponse: InstalledToolResponse<ScreenshotResult> =
                try await client.callTool("screenshot")
            let screenshot = try requireSuccess(screenshotResponse, tool: "screenshot")
            let png = try screenshotPNG(screenshotResponse.content)
            try assertRedFixturePatch(png: png, screenshot: screenshot)

            let gps = try requireSuccess(
                try await client.callTool(
                    "set_gps_position", arguments: ["lat": 48.1351, "lon": 11.5820],
                    as: SetGpsPositionResult.self),
                tool: "set_gps_position")
            #expect(gps.latitude == 48.1351)
            #expect(gps.longitude == 11.5820)
            try await waitForMarker(
                "FIXTURE_GPS 48.1351 11.5820", sessionID: app.sessionId, client: client)

            let stopped = try requireSuccess(
                try await client.callTool("sim_stop", as: SimStopResult.self), tool: "sim_stop")
            #expect(stopped.status.state == .notRunning)
            let ended = try requireSuccess(
                try await client.callTool(
                    "get_logs", arguments: ["sessionId": .int(app.sessionId)],
                    as: GetLogsResult.self),
                tool: "get_logs")
            #expect(ended.state == "exited")
        } catch {
            _ = try? await client.callTool("sim_stop", as: SimStopResult.self)
            await client.stop()
            throw error
        }
        await client.stop()
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // Integration
            .deletingLastPathComponent() // SimulatorMCPCoreTests
            .deletingLastPathComponent() // Tests
    }

    private func waitForMarker(
        _ marker: String,
        sessionID: Int,
        client: InstalledServerClient
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var token: String?
        while ContinuousClock.now < deadline {
            var arguments: [String: JSONValue] = ["sessionId": .int(sessionID), "limit": 500]
            if let token { arguments["sinceToken"] = .string(token) }
            let logs = try requireSuccess(
                try await client.callTool(
                    "get_logs", arguments: arguments, as: GetLogsResult.self),
                tool: "get_logs")
            if logs.lines.contains(where: { $0.text == marker }) { return }
            token = logs.nextToken
            try await Task.sleep(for: .milliseconds(25))
        }
        throw InstalledIntegrationError("Timed out waiting for exact log marker \(marker).")
    }

    private func screenshotPNG(_ content: [Tool.Content]) throws -> Data {
        for item in content {
            if case .image(let base64, let mimeType, _, _) = item {
                guard mimeType == "image/png", let data = Data(base64Encoded: base64) else {
                    throw InstalledIntegrationError("Screenshot image content is not valid image/png data.")
                }
                return data
            }
        }
        throw InstalledIntegrationError("Screenshot response contains no MCP image content.")
    }

    private func assertRedFixturePatch(png: Data, screenshot: ScreenshotResult) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw InstalledIntegrationError("ImageIO could not decode the screenshot PNG.")
        }
        let rect = try #require(screenshot.appDisplayRect)
        let displayWidth = 280.0
        let displayHeight = 280.0
        let fixturePatchOrigin = 48.0
        let fixturePatchInset = 4.0
        let fixturePatchSize = 64.0
        let patch = CGRect(
            x: Double(rect.x) + (fixturePatchOrigin + fixturePatchInset)
                * Double(rect.width) / displayWidth,
            y: Double(rect.y) + (fixturePatchOrigin + fixturePatchInset)
                * Double(rect.height) / displayHeight,
            width: (fixturePatchSize - 2 * fixturePatchInset)
                * Double(rect.width) / displayWidth,
            height: (fixturePatchSize - 2 * fixturePatchInset)
                * Double(rect.height) / displayHeight)
        let fullPatch = CGRect(
            x: Double(rect.x) + fixturePatchOrigin * Double(rect.width) / displayWidth,
            y: Double(rect.y) + fixturePatchOrigin * Double(rect.height) / displayHeight,
            width: fixturePatchSize * Double(rect.width) / displayWidth,
            height: fixturePatchSize * Double(rect.height) / displayHeight)
        let displayBounds = CGRect(
            x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        guard displayBounds.contains(fullPatch),
            patch.minX >= 0, patch.minY >= 0,
            patch.maxX <= Double(image.width), patch.maxY <= Double(image.height)
        else {
            throw InstalledIntegrationError(
                "The scaled fixture patch is outside screenshot.appDisplayRect or image bounds.")
        }

        let (redPixels, sampledPixels) = try ScreenshotPixelSampler.redPixelCounts(
            image: image, patch: patch)
        guard sampledPixels > 0,
            Double(redPixels) / Double(sampledPixels) >= 0.90
        else {
            let ratio = sampledPixels == 0 ? 0 : Double(redPixels) / Double(sampledPixels)
            throw InstalledIntegrationError(
                "The app-owned patch is not at least 90% red within RGB tolerance 12 "
                    + "(ratio=\(ratio), displayRect=\(rect), samplePatch=\(patch), "
                    + "image=\(image.width)x\(image.height)).")
        }
    }
}

@Suite("Installed screenshot pixel evidence")
struct InstalledScreenshotPixelEvidenceTests {
    @Test("top-left screenshot coordinates sample the top image row")
    func topLeftCoordinates() throws {
        let pixels: [UInt8] = [
            255, 0, 0, 255, 255, 0, 0, 255,
            0, 0, 255, 255, 0, 0, 255, 255,
        ]
        let provider = try #require(
            CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))

        let counts = try ScreenshotPixelSampler.redPixelCounts(
            image: image, patch: CGRect(x: 0, y: 0, width: 2, height: 1))

        #expect(counts.red == 2)
        #expect(counts.total == 2)
    }
}

private enum ScreenshotPixelSampler {
    static func redPixelCounts(image: CGImage, patch: CGRect) throws -> (red: Int, total: Int) {
        let bytesPerRow = image.width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                let context = CGContext(
                    data: base, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else {
            throw InstalledIntegrationError("Could not render the screenshot into RGBA pixels.")
        }

        let minX = max(0, Int(patch.minX.rounded(.up)))
        let maxX = min(image.width, Int(patch.maxX.rounded(.down)))
        let minY = max(0, Int(patch.minY.rounded(.up)))
        let maxY = min(image.height, Int(patch.maxY.rounded(.down)))
        var redPixels = 0
        var sampledPixels = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * 4
                sampledPixels += 1
                if abs(Int(rgba[offset]) - 255) <= 12,
                    Int(rgba[offset + 1]) <= 12,
                    Int(rgba[offset + 2]) <= 12
                {
                    redPixels += 1
                }
            }
        }
        return (redPixels, sampledPixels)
    }
}

private struct TCCAttribution: Decodable {
    let deploymentMode: String
    let executablePath: String
    let responsibleProcess: ResponsibleProcessEvidence
    let signature: SignatureEvidence
    let installedClientDoctor: DoctorEvidence
    let actualMCPHostDoctor: DoctorEvidence

    static func load(_ url: URL) throws -> TCCAttribution {
        try JSONDecoder().decode(TCCAttribution.self, from: Data(contentsOf: url))
    }

    func selectedExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected: URL
        switch deploymentMode {
        case "stableBinary":
            expected = home.appending(path: ".simulator-mcp/bin/simulator-mcp")
        case "signedHostApp":
            expected = home.appending(
                path: ".simulator-mcp/SimulatorMCPHost.app/Contents/MacOS/simulator-mcp-host")
        default:
            throw InstalledIntegrationError(
                "tcc-attribution.json has unsupported deploymentMode \(deploymentMode).")
        }
        guard URL(fileURLWithPath: executablePath).standardizedFileURL == expected.standardizedFileURL else {
            throw InstalledIntegrationError(
                "tcc-attribution.json executablePath does not match deploymentMode \(deploymentMode).")
        }
        guard !responsibleProcess.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            responsibleProcess.pid > 0
        else {
            throw InstalledIntegrationError(
                "tcc-attribution.json requires a concrete responsible-process name and positive PID.")
        }
        guard !signature.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !signature.signingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw InstalledIntegrationError(
                "tcc-attribution.json requires a concrete signature identity and signing identifier.")
        }
        try validateDoctor(installedClientDoctor, source: "installedClientDoctor", expected: expected)
        try validateDoctor(actualMCPHostDoctor, source: "actualMCPHostDoctor", expected: expected)
        return expected
    }

    private func validateDoctor(_ doctor: DoctorEvidence, source: String, expected: URL) throws {
        guard doctor.requestPermissions == false,
            URL(fileURLWithPath: doctor.executablePath).standardizedFileURL == expected.standardizedFileURL,
            doctor.signatureKind == "stable",
            doctor.signingIdentifier == signature.signingIdentifier,
            doctor.screenRecordingGranted,
            doctor.accessibilityGranted
        else {
            throw InstalledIntegrationError(
                "tcc-attribution.json \(source) must record doctor(false) for the selected stable executable with both grants.")
        }
    }
}

private struct ResponsibleProcessEvidence: Decodable {
    let name: String
    let pid: Int
}

private struct SignatureEvidence: Decodable {
    let identity: String
    let signingIdentifier: String
}

private struct DoctorEvidence: Decodable {
    let requestPermissions: Bool
    let executablePath: String
    let signatureKind: String
    let signingIdentifier: String
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool
}

@Suite("TCC attribution evidence")
struct TCCAttributionTests {
    @Test("incomplete evidence cannot unlock installed integration")
    func rejectsIncompleteEvidence() throws {
        let url = try writeJSON([
            "deploymentMode": "stableBinary",
            "executablePath": stableBinary.path,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            _ = try TCCAttribution.load(url)
        }
    }

    @Test("both installed-client and actual-host doctor calls must prove both grants")
    func rejectsDeniedDoctorEvidence() throws {
        var evidence = completeEvidence()
        var installed = try #require(evidence["installedClientDoctor"] as? [String: Any])
        installed["screenRecordingGranted"] = false
        evidence["installedClientDoctor"] = installed
        let url = try writeJSON(evidence)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            _ = try TCCAttribution.load(url).selectedExecutable()
        }
    }

    @Test("complete matching evidence selects the supported executable")
    func acceptsCompleteEvidence() throws {
        let url = try writeJSON(completeEvidence())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try TCCAttribution.load(url).selectedExecutable() == stableBinary)
    }

    private var stableBinary: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/bin/simulator-mcp")
            .standardizedFileURL
    }

    private func completeEvidence() -> [String: Any] {
        let doctor: [String: Any] = [
            "requestPermissions": false,
            "executablePath": stableBinary.path,
            "signatureKind": "stable",
            "signingIdentifier": "simulator-mcp-local",
            "screenRecordingGranted": true,
            "accessibilityGranted": true,
        ]
        return [
            "deploymentMode": "stableBinary",
            "executablePath": stableBinary.path,
            "responsibleProcess": ["name": "claude", "pid": 1234],
            "signature": [
                "identity": "simulator-mcp-local",
                "signingIdentifier": "simulator-mcp-local",
            ],
            "installedClientDoctor": doctor,
            "actualMCPHostDoctor": doctor,
        ]
    }

    private func writeJSON(_ object: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tcc-attribution-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)
        return url
    }
}

private struct InstalledIntegrationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func requireSuccess<Result: Codable & Sendable>(
    _ response: InstalledToolResponse<Result>,
    tool: String
) throws -> Result {
    guard response.isError == false, response.envelope.ok,
        let result = response.envelope.result
    else {
        let failure = response.envelope.error
        let code = failure?.code ?? "unknown"
        let message = failure?.message ?? "missing message"
        let fix = failure?.fix ?? "missing fix"
        let details = failure?.details.map { " Details: \($0)" } ?? ""
        throw InstalledIntegrationError(
            "\(tool) failed [\(code)]: \(message). Fix: \(fix)\(details)")
    }
    return result
}
