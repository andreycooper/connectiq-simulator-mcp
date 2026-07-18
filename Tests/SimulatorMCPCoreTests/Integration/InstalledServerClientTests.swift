import Foundation
import Testing

import SimulatorMCPCore

@Suite("Installed server client", .serialized)
struct InstalledServerClientTests {
    @Test("Task 17 tool advertisement is complete and excludes deferred input")
    func toolAdvertisementContract() throws {
        try validateTask17ToolAdvertisement(Array(task17RequiredToolNames))
        #expect(throws: InstalledServerClientError.self) {
            try validateTask17ToolAdvertisement(["doctor"])
        }
        #expect(throws: InstalledServerClientError.self) {
            try validateTask17ToolAdvertisement(Array(task17RequiredToolNames) + ["press_button"])
        }
    }

    @Test("an explicit executable crosses initialize, tools/list, and tools/call over stdio")
    func explicitExecutableRoundTrip() async throws {
        let executable = repositoryRoot()
            .appending(path: ".build/debug/simulator-mcp")
        let client = InstalledServerClient(executableURL: executable)

        #expect(client.executableURL == executable.standardizedFileURL)

        try await client.start()
        do {
            await #expect(throws: InstalledServerClientError.self) {
                let _: InstalledToolResponse<DoctorResult> = try await client.callTool(
                    "doctor", arguments: ["requestPermissions": false])
            }

            let tools = try await client.listTools()
            try validateTask17ToolAdvertisement(tools)

            let response: InstalledToolResponse<DoctorResult> = try await client.callTool(
                "doctor", arguments: ["requestPermissions": false])
            #expect(response.isError == false)
            #expect(response.envelope.ok)
            #expect(
                response.envelope.result?.executablePath
                    == executable.resolvingSymlinksInPath().path)
            #expect(response.content.contains { content in
                if case .text = content { return true }
                return false
            })
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
    }

    @Test("installed v1 boundary excludes input and reports no input capability")
    func installedV1InputContract() async throws {
        guard ProcessInfo.processInfo.environment["SIM_V1_INSTALLED_CHECK"] == "1" else {
            return
        }
        let executable = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/bin/simulator-mcp")
        let client = InstalledServerClient(executableURL: executable)
        try await client.start()
        defer { Task { await client.stop() } }

        let tools = try await client.listTools()
        let response: InstalledToolResponse<ListDevicesResult> = try await client.callTool(
            "list_devices", as: ListDevicesResult.self)
        let devices = try #require(response.envelope.result?.devices)
        print("INSTALLED_V1_TOOLS " + tools.sorted().joined(separator: ","))
        for device in devices {
            let profile = device.inputProfile ?? "null"
            print("INSTALLED_V1_DEVICE \(device.deviceId) inputSupported=\(device.inputSupported) buttons=\(device.buttons) inputProfile=\(profile)")
        }
        #expect(!tools.contains("press_button"))
        #expect(response.isError == false)
        #expect(devices.allSatisfy {
            !$0.inputSupported && $0.buttons.isEmpty && $0.inputProfile == nil
        })
    }

    @Test("failed initialization leaves no child owned by the client")
    func failedInitializationCleansUp() async throws {
        let client = InstalledServerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"))

        await #expect(throws: (any Error).self) {
            try await client.start()
        }
        #expect(await client.isRunning == false)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // Integration
            .deletingLastPathComponent() // SimulatorMCPCoreTests
            .deletingLastPathComponent() // Tests
    }
}
