import Foundation
import MCP
import Testing

@testable import SimulatorMCPCore

@Suite("SetGpsPositionTool", .serialized)
struct SetGpsPositionToolTests {
    @Test("one serialized simulator operation spans the complete GPS automation")
    func oneOperation() async throws {
        let events = GpsOperationEvents()
        let context = OperationContext(
            simulatorPid: 42,
            sdk: SdkInfo(
                version: SemVer(major: 9, minor: 1, patch: 0),
                root: URL(fileURLWithPath: "/sdk-9.1.0"), source: .explicit),
            currentDevice: "fenix6xpro", listeningEndpoints: [])
        let runner = GpsPositionOperationRunner { operation, requirement, body in
            await events.append("operation:\(operation.rawValue):\(requirement.isCurrentReady)")
            let result = try await body(context)
            await events.append("operation:end")
            return result
        }
        let service = GpsPositionService(
            operationRunner: runner,
            automate: { latitude, longitude, observed in
                await events.append("automation:\(observed.simulatorPid):\(observed.sdk.version)")
                return SetGpsPositionResult(
                    latitude: latitude, longitude: longitude,
                    simulatorPid: observed.simulatorPid)
            })

        let result = try await service.setPosition(
            SetGpsPositionToolRequest(latitude: 48.1351, longitude: 11.582))

        #expect(result.simulatorPid == 42)
        #expect(await events.values == [
            "operation:set_gps_position:true", "automation:42:9.1.0", "operation:end",
        ])
    }

    @Test("invalid coordinates fail before the simulator operation")
    func validationBeforeOperation() async {
        let events = GpsOperationEvents()
        let runner = GpsPositionOperationRunner { _, _, _ in
            await events.append("operation")
            throw gpsUnused()
        }
        let service = GpsPositionService(operationRunner: runner) { _, _, _ in
            throw gpsUnused()
        }
        await #expect(throws: ToolError.self) {
            _ = try await service.setPosition(
                SetGpsPositionToolRequest(latitude: .nan, longitude: 0))
        }
        #expect(await events.values.isEmpty)
    }

    @Test("public schema requires two numeric coordinates and rejects overrides")
    func schema() async throws {
        let recorder = GpsToolRecorder()
        try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
            let tool = try #require(try await harness.listTools().first { $0.name == "set_gps_position" })
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { Issue.record("set_gps_position schema is not an object"); return }
            #expect(properties.keys.sorted() == ["lat", "lon"])
            #expect(schema["required"] == ["lat", "lon"])
            #expect(schema["additionalProperties"] == false)
            #expect(tool.outputSchema != nil)

            for arguments: [String: Value] in [
                ["lat": 1, "lon": 2, "sdk": "unexpected"],
                ["lat": "1", "lon": 2],
                ["lat": 1],
            ] {
                let response = try await harness.call(
                    "set_gps_position", arguments: arguments, as: JSONValue.self)
                #expect(response.raw.isError == true)
                #expect(response.envelope.error?.code == "invalid_arguments")
            }
        }
        #expect(await recorder.requests.isEmpty)
    }

    @Test("public call delegates exactly once and returns typed coordinates without stdout")
    func delegation() async throws {
        let recorder = GpsToolRecorder()
        let captured = try await captureStdout {
            try await withMCPHarness(handlers: ToolHandlers.configured(recorder.services)) { harness in
                let response = try await harness.call(
                    "set_gps_position", arguments: ["lat": 48.1351, "lon": 11.582],
                    as: SetGpsPositionResult.self)
                #expect(response.raw.isError == false)
                #expect(response.envelope.result == recorder.result)
                #expect(response.raw.content.count == 1)
            }
        }
        #expect(captured.isEmpty)
        #expect(await recorder.requests == [.init(latitude: 48.1351, longitude: 11.582)])
    }
}

private actor GpsOperationEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private extension OperationRequirement {
    var isCurrentReady: Bool {
        if case .currentReady = self { return true }
        return false
    }
}

private actor GpsToolRecorder {
    let result = SetGpsPositionResult(latitude: 48.1351, longitude: 11.582, simulatorPid: 42)
    private(set) var requests: [SetGpsPositionToolRequest] = []

    nonisolated var services: ToolHandlerServices {
        ToolHandlerServices(
            listSdks: { ListSdksResult(sdks: []) },
            listDevices: { _ in ListDevicesResult(devices: []) },
            build: { _ in throw gpsUnused() },
            simStart: { _ in throw gpsUnused() },
            simStop: { throw gpsUnused() },
            simStatus: { throw gpsUnused() },
            runApp: { _ in throw gpsUnused() },
            runTests: { _ in throw gpsUnused() },
            getLogs: { _ in throw gpsUnused() },
            doctor: { _ in throw gpsUnused() },
            setGpsPosition: { request in await self.record(request) })
    }

    private func record(_ request: SetGpsPositionToolRequest) -> SetGpsPositionResult {
        requests.append(request)
        return result
    }
}

private func gpsUnused() -> ToolError {
    ToolError(code: "internal_error", message: "Unused service called.", fix: "Fix the test.")
}
