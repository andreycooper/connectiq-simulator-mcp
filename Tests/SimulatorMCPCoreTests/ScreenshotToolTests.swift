import Foundation
import MCP
import Testing

import SimulatorMCPCore

@Suite("ScreenshotTool", .serialized)
struct ScreenshotToolTests {
    @Test("screenshot schema accepts only an optional savePath")
    func schema() async throws {
        let recorder = ScreenshotToolRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            let tool = try #require(try await harness.listTools().first { $0.name == "screenshot" })
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else {
                Issue.record("screenshot input schema is not an object")
                return
            }
            #expect(properties.keys.sorted() == ["savePath"])
            #expect(schema["additionalProperties"] == false)
            #expect(schema["required"] == [])
            #expect(tool.outputSchema != nil)
        }
    }

    @Test("JSON is first, image is second, and both describe the same PNG")
    func contentAndDelegation() async throws {
        let recorder = ScreenshotToolRecorder()
        let captured = try await captureStdout {
            try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
                let response = try await harness.call(
                    "screenshot", arguments: ["savePath": "~/shots/../shot.png"],
                    as: ScreenshotResult.self)
                #expect(response.raw.isError == false)
                #expect(response.raw.content.count == 2)
                guard case .text(let json, _, _) = response.raw.content[0],
                    case .image(let base64, let mimeType, _, _) = response.raw.content[1]
                else {
                    Issue.record("screenshot did not return JSON first and image second")
                    return
                }
                #expect(mimeType == "image/png")
                #expect(Data(base64Encoded: base64) == recorder.png)
                #expect(response.envelope.result == recorder.result)
                let structured = try #require(response.raw.structuredContent)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                #expect(json == String(decoding: try encoder.encode(structured), as: UTF8.self))
            }
        }
        #expect(captured.isEmpty)
        #expect(await recorder.requests.count == 1)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(await recorder.requests.first?.savePath == home + "/shot.png")
    }

    @Test("SDK and device overrides are rejected before the screenshot service")
    func noOverrides() async throws {
        let recorder = ScreenshotToolRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            for field in ["sdk", "device"] {
                let response = try await harness.call(
                    "screenshot", arguments: [field: "unexpected"], as: JSONValue.self)
                #expect(response.raw.isError == true)
                #expect(response.envelope.error?.code == "invalid_arguments")
            }
        }
        #expect(await recorder.requests.isEmpty)
    }
}

private actor ScreenshotToolRecorder {
    let png = Data("same-png".utf8)
    let result = ScreenshotResult(
        path: "/tmp/shot.png", mimeType: "image/png", width: 10, height: 20,
        capturedPid: 42,
        device: "fenix6xpro", deviceDisplayName: "fēnix 6X Pro",
        nativeResolution: DisplaySize(width: 280, height: 280),
        appDisplayRect: DisplayRect(x: 2, y: 4, width: 6, height: 8))
    private(set) var requests: [ScreenshotToolRequest] = []

    nonisolated var services: ToolHandlerServices {
        ToolHandlerServices(
            listSdks: { ListSdksResult(sdks: []) },
            listDevices: { _ in ListDevicesResult(devices: []) },
            build: { _ in throw unused() },
            simStart: { _ in throw unused() },
            simStop: { throw unused() },
            simStatus: { throw unused() },
            runApp: { _ in throw unused() },
            runTests: { _ in throw unused() },
            getLogs: { _ in throw unused() },
            doctor: { _ in throw unused() },
            screenshot: { request in await self.record(request) })
    }

    private func record(_ request: ScreenshotToolRequest) -> ScreenshotOutput {
        requests.append(request)
        return ScreenshotOutput(result: result, png: png)
    }
}

private func unused() -> ToolError {
    ToolError(code: "internal_error", message: "Unused service called.", fix: "Fix the test.")
}
