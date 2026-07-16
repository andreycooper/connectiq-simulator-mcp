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
