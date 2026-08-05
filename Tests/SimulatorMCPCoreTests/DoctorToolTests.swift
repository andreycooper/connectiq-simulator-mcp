import Foundation
import MCP
import Testing

import SimulatorMCPCore

@Suite("DoctorTool")
struct DoctorToolTests {
    @Test("doctor reports every check and exact denied-permission fixes")
    func deniedPermissionFixes() async throws {
        let executable = URL(fileURLWithPath: "/actual/bin/simulator-mcp")
        let service = makeDoctor(
            executable: executable,
            signature: SignatureMetadata(signed: false, adHoc: false),
            permissions: Permissions(
                screenPreflight: { false }, screenRequest: { false },
                accessibilityPreflight: { false }, accessibilityRequest: { false }))

        let result = await service.inspect(requestPermissions: false)

        #expect(result.executablePath == executable.path)
        #expect(result.signatureKind == .unsigned)
        #expect(result.screenRecording.granted == false)
        #expect(result.screenRecording.prompted == false)
        #expect(result.screenRecording.restartRequired == true)
        #expect(result.accessibility.granted == false)
        #expect(result.accessibility.prompted == false)
        #expect(result.accessibility.restartRequired == true)
        #expect(result.checks.map(\.name) == [
            "sdk", "java", "simulator", "screen_recording", "accessibility",
            "signature", "install_path",
        ])
        // Pinned by content rather than by one long literal: these are the
        // facts a reader needs, and an assertion that says which ones survives
        // rewording while still failing if any of them is dropped.
        for (name, settings) in [
            ("screen_recording", Permissions.screenSettingsPath),
            ("accessibility", Permissions.accessibilitySettingsPath),
        ] {
            let fix = try #require(result.checks.first { $0.name == name }?.fix)
            #expect(fix.contains(settings), "names the exact settings pane")
            #expect(fix.contains("/actual/bin"), "names the directory to reveal")
            #expect(fix.contains("simulator-mcp"), "names the executable to enable")
            #expect(fix.contains("Command-Shift-G"), "says how to reach a hidden folder")
            #expect(fix.contains("remove it"), "says a stale entry must be re-added")
            #expect(fix.contains("restart the MCP host"), "says the host must restart")
        }
        #expect(result.checks.allSatisfy { !$0.observed.isEmpty })
    }

    @Test("ad-hoc and unsigned signatures make only the signature identity unhealthy")
    func unhealthySignatures() async {
        for fixture: SignatureMetadata in [
            .init(signed: true, adHoc: true, signingIdentifier: "simulator-mcp"),
            .init(signed: false, adHoc: false),
        ] {
            let result = await makeDoctor(signature: fixture).inspect(requestPermissions: false)
            #expect(result.signatureKind != .stable)
            #expect(result.checks.first { $0.name == "signature" }?.ok == false)
            #expect(result.checks.first { $0.name == "signature" }?.fix?.isEmpty == false)
        }
    }

    @Test("public doctor handler defaults prompts off and delegates once")
    func handlerDefaultsAndDelegates() async throws {
        let recorder = DoctorRequestRecorder()
        let services = stubServices(doctor: { request in
            await recorder.record(request)
            return await makeDoctor().inspect(requestPermissions: request.requestPermissions)
        })
        try await withMCPHarness(handlers: ToolHandlers.configured(services)) { harness in
            let response = try await harness.call("doctor", as: DoctorResult.self)
            #expect(response.raw.isError == false)
            #expect(response.envelope.result?.executablePath == "/installed/simulator-mcp")
        }
        #expect(await recorder.requests == [.init(requestPermissions: false)])
    }

    @Test("public doctor handler opts into prompts explicitly and rejects unknown fields")
    func handlerExplicitPromptAndStrictSchema() async throws {
        let recorder = DoctorRequestRecorder()
        let services = stubServices(doctor: { request in
            await recorder.record(request)
            return await makeDoctor().inspect(requestPermissions: request.requestPermissions)
        })
        try await withMCPHarness(handlers: ToolHandlers.configured(services)) { harness in
            _ = try await harness.call(
                "doctor", arguments: ["requestPermissions": true], as: DoctorResult.self)
            let invalid = try await harness.call(
                "doctor", arguments: ["unexpected": true], as: JSONValue.self)
            #expect(invalid.raw.isError == true)
            #expect(invalid.envelope.error?.code == "invalid_arguments")
        }
        #expect(await recorder.requests == [.init(requestPermissions: true)])
    }
}

private func makeDoctor(
    executable: URL = URL(fileURLWithPath: "/installed/simulator-mcp"),
    signature: SignatureMetadata = .init(
        signed: true, adHoc: false, signingIdentifier: "simulator-mcp-local",
        designatedRequirement: "identifier simulator-mcp-local"),
    permissions: Permissions = Permissions(
        screenPreflight: { true }, screenRequest: { true },
        accessibilityPreflight: { true }, accessibilityRequest: { true })
) -> DoctorService {
    DoctorService(
        permissions: permissions,
        signatureInspector: SignatureInspector { _ in signature },
        executableURL: { executable },
        sdkProbe: { .init(ok: true, observed: "Connect IQ SDK 9.1.0 at /sdk", fix: nil) },
        javaProbe: { .init(ok: true, observed: "Java 17.0.12", fix: nil) },
        simulatorProbe: { .init(ok: true, observed: "ready, SDK 9.1.0", fix: nil) },
        installedExecutablePath: "/installed/simulator-mcp")
}

private func stubServices(
    doctor: @escaping @Sendable (DoctorToolRequest) async throws -> DoctorResult
) -> ToolHandlerServices {
    ToolHandlerServices(
        listSdks: { .init(sdks: []) },
        listDevices: { _ in .init(devices: []) },
        build: { _ in throw StubError.unused },
        simStart: { _ in throw StubError.unused },
        simStop: { throw StubError.unused },
        simStatus: { throw StubError.unused },
        runApp: { _ in throw StubError.unused },
        runTests: { _ in throw StubError.unused },
        getLogs: { _ in throw StubError.unused },
        doctor: doctor)
}

private actor DoctorRequestRecorder {
    private(set) var requests: [DoctorToolRequest] = []
    func record(_ request: DoctorToolRequest) { requests.append(request) }
}

private enum StubError: Error { case unused }
