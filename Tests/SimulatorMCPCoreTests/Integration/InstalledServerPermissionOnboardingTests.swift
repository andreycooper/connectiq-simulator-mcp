import Foundation
import Testing

import SimulatorMCPCore

private let onboardingEnabled =
    ProcessInfo.processInfo.environment["SIM_TCC_ONBOARD"] == "1"
private let preflightEnabled =
    ProcessInfo.processInfo.environment["SIM_TCC_PREFLIGHT"] == "1"

@Suite(.enabled(if: onboardingEnabled), .serialized)
struct InstalledServerPermissionOnboardingTests {
    @Test("installed doctor requests permissions without invoking simulator tools")
    func requestPermissions() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = environment["SIM_TCC_EXECUTABLE"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".simulator-mcp/bin/simulator-mcp")
        let client = InstalledServerClient(executableURL: executable)

        try await client.start()
        do {
            try validateTask17ToolAdvertisement(try await client.listTools())
            let response: InstalledToolResponse<DoctorResult> = try await client.callTool(
                "doctor", arguments: ["requestPermissions": true])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(response.envelope), as: UTF8.self))

            let doctor = try #require(response.envelope.result)
            #expect(response.isError == false)
            #expect(doctor.executablePath == executable.resolvingSymlinksInPath().path)
            #expect(doctor.signatureKind == .stable)
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
    }
}

@Suite(.enabled(if: preflightEnabled), .serialized)
struct InstalledServerPermissionPreflightTests {
    @Test("installed doctor verifies permissions without prompting or attribution input")
    func verifyPermissions() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = environment["SIM_TCC_EXECUTABLE"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".simulator-mcp/bin/simulator-mcp")
        let client = InstalledServerClient(executableURL: executable)

        try await client.start()
        do {
            try validateTask17ToolAdvertisement(try await client.listTools())
            let response: InstalledToolResponse<DoctorResult> = try await client.callTool(
                "doctor", arguments: ["requestPermissions": false])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(response.envelope), as: UTF8.self))

            let doctor = try #require(response.envelope.result)
            #expect(response.isError == false)
            #expect(doctor.executablePath == executable.resolvingSymlinksInPath().path)
            #expect(doctor.signatureKind == .stable)
            #expect(doctor.screenRecording.prompted == false)
            #expect(doctor.accessibility.prompted == false)
            #expect(doctor.screenRecording.granted)
            #expect(doctor.accessibility.granted)
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
    }
}
