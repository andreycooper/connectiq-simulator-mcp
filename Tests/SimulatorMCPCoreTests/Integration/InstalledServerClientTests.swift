import Foundation
import Testing

import SimulatorMCPCore

@Suite("Installed server client", .serialized)
struct InstalledServerClientTests {
    @Test("published tool advertisement is complete and rejects extras or duplicates")
    func toolAdvertisementContract() throws {
        try validateTask17ToolAdvertisement(Array(task17RequiredToolNames))
        #expect(task17RequiredToolNames.contains("press_button"))
        #expect(throws: InstalledServerClientError.self) {
            try validateTask17ToolAdvertisement(["doctor"])
        }
        #expect(throws: InstalledServerClientError.self) {
            try validateTask17ToolAdvertisement(Array(task17RequiredToolNames) + ["unexpected"])
        }
        #expect(throws: InstalledServerClientError.self) {
            try validateTask17ToolAdvertisement(Array(task17RequiredToolNames) + ["doctor"])
        }
    }

    @Test("the launch environment carries no tool-surface selector")
    func launchEnvironment() {
        let base = ["PATH": "/usr/bin", "SIM_BUTTON_QUALIFICATION": "unexpected", "KEEP": "yes"]
        let environment = InstalledServerClient.environment(preserving: base)
        // The server publishes one surface; a stray selector in the inherited
        // environment must not be able to change what it serves.
        #expect(environment["SIM_BUTTON_QUALIFICATION"] == nil)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["KEEP"] == "yes")
    }

    @Test("the debug build publishes exactly 13 tools including press_button")
    func qualificationModeRoundTrip() async throws {
        let executable = repositoryRoot().appending(path: ".build/debug/simulator-mcp")
        let events = InstalledClientEventRecorder()
        let client = InstalledServerClient(
            executableURL: executable,
            eventSink: { events.record($0) })
        try await client.start()
        do {
            try validateTask17ToolAdvertisement(try await client.listTools())
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
        let snapshot = events.events
        let writes = snapshot.compactMap { event -> Int? in
            guard case .requestWritten(let id, _, _, _) = event else { return nil }
            return id
        }
        let responses = snapshot.compactMap { event -> Int? in
            guard case .responseReceived(let id, _, _, _) = event else { return nil }
            return id
        }
        #expect(writes == responses)
        guard case .stopCompleted? = snapshot.last else {
            Issue.record("client stop milestone was not last")
            return
        }
        let stopPhases = snapshot.compactMap { event -> String? in
            switch event {
            case .stopStarted: "stopStarted"
            case .stdinClosed: "stdinClosed"
            case .serverExited: "serverExited"
            case .terminateSent: "terminateSent"
            case .stopCompleted: "stopCompleted"
            default: nil
            }
        }
        #expect(stopPhases == ["stopStarted", "stdinClosed", "serverExited", "stopCompleted"])
    }

    @Test("stop drains terminal stderr before completing and preserves its snapshot")
    func finalStderrDrain() async throws {
        let script = """
            IFS= read -r request
            printf '{"jsonrpc":"2.0","id":1,"result":{}}\\n'
            while IFS= read -r notification; do :; done
            printf 'terminal-focused-outcome\\n' >&2
            """
        let events = InstalledClientEventRecorder()
        let client = InstalledServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            eventSink: { events.record($0) })

        try await client.start()
        #expect(await client.diagnosticText().contains("terminal-focused-outcome") == false)
        await client.stop()

        #expect(await client.diagnosticText().contains("terminal-focused-outcome"))
        let snapshot = events.events
        let exited = try #require(snapshot.firstIndex { if case .serverExited = $0 { true } else { false } })
        let completed = try #require(snapshot.firstIndex { if case .stopCompleted = $0 { true } else { false } })
        #expect(exited < completed)
    }

    @Test("incomplete bounded shutdown is observable and retains child ownership")
    func incompleteShutdown() async throws {
        let script = """
            trap '' TERM
            IFS= read -r request
            printf '{"jsonrpc":"2.0","id":1,"result":{}}\\n'
            while IFS= read -r notification; do :; done
            printf 'emergency-retained-child\\n' >&2
            while :; do :; done
            """
        let events = InstalledClientEventRecorder()
        let client = InstalledServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            gracefulStopTimeout: .milliseconds(10),
            terminatedStopTimeout: .milliseconds(10),
            eventSink: { events.record($0) })
        try await client.start()
        let pid = try #require(await client.runningPID)

        #expect(await client.stop() == false)
        #expect(await client.runningPID == pid)
        #expect(events.events.contains { if case .terminateSent = $0 { true } else { false } })
        #expect(events.events.contains { if case .stopCompleted = $0 { true } else { false } } == false)

        #expect(await client.emergencyCleanupRetainedChild())
        #expect(await client.runningPID == nil)
        #expect(await client.diagnosticText().contains("emergency-retained-child"))
        let emergencyPhases = events.events.compactMap { event -> String? in
            switch event {
            case .emergencyCleanupStarted: "started"
            case .emergencySIGKILLSent: "sigkill"
            case .emergencyServerExited: "exited"
            case .emergencyCleanupCompleted: "completed"
            default: nil
            }
        }
        #expect(emergencyPhases == ["started", "sigkill", "exited", "completed"])
        #expect(events.events.contains { if case .stopCompleted = $0 { true } else { false } } == false)
    }

    @Test("published child PID is atomic, exact, and removed after a proven stop")
    func publishesAndRemovesOwnedPID() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(
            path: "simulator-mcp-installed-client-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
            IFS= read -r request
            printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\\n'
            while IFS= read -r notification; do :; done
            """
        let environment = ProcessInfo.processInfo.environment.merging([
            "SIM_BUTTON_QUALIFICATION_CLIENT_PID_FILE": pidFile.path,
        ]) { _, value in value }
        let client = InstalledServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: environment)

        try await client.start()
        let pid = try #require(await client.runningPID)
        let published = try String(contentsOf: pidFile, encoding: .utf8)
        #expect(published == "\(pid)\n")
        #expect(await client.stop())
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
        #expect(await client.runningPID == nil)
    }

    @Test("a replaced PID file is never removed as if it were client-owned")
    func doesNotRemoveReplacedPIDFile() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(
            path: "simulator-mcp-installed-client-replaced-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
            IFS= read -r request
            printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\\n'
            while IFS= read -r notification; do :; done
            """
        let environment = ProcessInfo.processInfo.environment.merging([
            "SIM_BUTTON_QUALIFICATION_CLIENT_PID_FILE": pidFile.path,
        ]) { _, value in value }
        let client = InstalledServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: environment)

        try await client.start()
        try Data("999999\n".utf8).write(to: pidFile)
        // The child has been proven exited, but the replacement is not ours.
        // Closing stdin lets the deterministic fixture finish without a signal.
        // `stop` still owns the cleanup decision and must fail closed.
        // swift-testing does not expose the private stdin handle, so stop drives it.
        // The graceful path closes stdin before checking the PID file.
        //
        // The replacement remains untouched even though cleanup is reported false.
        // The client process itself is no longer retained after the proven exit.
        //
        #expect(await client.stop() == false)
        #expect(try String(contentsOf: pidFile, encoding: .utf8) == "999999\n")
        #expect(await client.runningPID == nil)
        #expect(await client.stop() == false)
        #expect(await client.emergencyCleanupRetainedChild() == false)
        #expect(try String(contentsOf: pidFile, encoding: .utf8) == "999999\n")

        try FileManager.default.removeItem(at: pidFile)
        #expect(await client.emergencyCleanupRetainedChild())
        #expect(await client.stop())
    }

    @Test("PID publication failure cleans the started child before reporting failure")
    func pidPublicationFailureCleansChild() async throws {
        let missingParent = FileManager.default.temporaryDirectory.appending(
            path: "simulator-mcp-installed-client-missing-pid-parent-\(UUID().uuidString)")
        let pidFile = missingParent.appending(path: "child.pid")
        let client = InstalledServerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            environment: ProcessInfo.processInfo.environment.merging([
                "SIM_BUTTON_QUALIFICATION_CLIENT_PID_FILE": pidFile.path,
            ]) { _, value in value })

        await #expect(throws: InstalledServerClientError.self) {
            try await client.start()
        }
        #expect(await client.runningPID == nil)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    @Test("sim_stop MCP error envelope is classified as cleanup tool failure")
    func cleanupErrorEnvelopeClassification() {
        let response = InstalledToolResponse<SimStopResult>(
            content: [],
            envelope: ToolEnvelope(
                ok: false, result: nil,
                error: ToolFailure(
                    code: "cleanup_denied", message: "cleanup failed", fix: "retry cleanup")),
            isError: true)

        let outcome = classifyQualificationSimStop(response)
        guard case .toolFailure(let failure) = outcome else {
            Issue.record("cleanup error envelope was not classified as tool failure")
            return
        }
        #expect(failure.contains("cleanup_denied"))
        #expect(failure.contains("cleanup failed"))
    }

    @Test("frontmost sampler starts before activation phases and remains through cleanup")
    func frontmostSamplerLifecycle() async {
        let attempt = QualificationAttemptRecorder(
            sdk: "test-sdk", button: "up", pressType: "press")
        let sampler = startQualificationFrontmostSampler(
            attempt: attempt, timeout: .seconds(60), frontmostPID: { 7 })

        await attempt.waitUntilRecorded("frontmost_sample")
        attempt.record("observer_activation_requested")
        attempt.record("cleanup_start")
        sampler.cancel()
        _ = await sampler.result

        let phases = attempt.recordedPhases
        let sample = phases.firstIndex { $0.hasPrefix("phase=frontmost_sample ") }
        let activation = phases.firstIndex { $0.hasPrefix("phase=observer_activation_requested ") }
        let cleanup = phases.firstIndex { $0.hasPrefix("phase=cleanup_start ") }
        let final = phases.firstIndex { $0.hasPrefix("phase=frontmost_sampler_final ") }
        #expect(sample != nil && activation != nil && sample! < activation!)
        #expect(cleanup != nil && final != nil && cleanup! < final!)
        #expect(phases[final!].contains("reason=cleanup_completed"))
    }

    @Test("an explicit executable crosses initialize, tools/list, and tools/call over stdio")
    func explicitExecutableRoundTrip() async throws {
        let executable = repositoryRoot()
            .appending(path: ".build/debug/simulator-mcp")
        let events = InstalledClientEventRecorder()
        let client = InstalledServerClient(
            executableURL: executable,
            eventSink: { events.record($0) })

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
            let _: InstalledToolResponse<GetLogsResult> = try await client.callTool(
                "get_logs", arguments: ["sessionId": -1])
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
        let toolBoundaries = events.events.compactMap { event -> String? in
            switch event {
            case .requestWritten(_, _, let tool, _): "write:\(tool ?? "none")"
            case .responseReceived(_, _, let tool, _): "response:\(tool ?? "none")"
            default: nil
            }
        }
        #expect(toolBoundaries.contains("write:doctor"))
        #expect(toolBoundaries.contains("response:doctor"))
        #expect(toolBoundaries.contains(where: { $0.contains("get_logs") }) == false)
    }

    @Test("installed boundary publishes input and reports fenix6xpro capability")
    func installedInputContract() async throws {
        guard ProcessInfo.processInfo.environment["SIM_V1_INSTALLED_CHECK"] == "1" else {
            return
        }
        let executable = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".simulator-mcp/bin/simulator-mcp")
        let client = InstalledServerClient(executableURL: executable)
        try await client.start()
        do {
            let tools = try await client.listTools()
            let response: InstalledToolResponse<ListDevicesResult> = try await client.callTool(
                "list_devices", as: ListDevicesResult.self)
            let devices = try #require(response.envelope.result?.devices)
            print("INSTALLED_V1_TOOLS " + tools.sorted().joined(separator: ","))
            for device in devices {
                let profile = device.inputProfile ?? "null"
                print("INSTALLED_V1_DEVICE \(device.deviceId) inputSupported=\(device.inputSupported) buttons=\(device.buttons) inputProfile=\(profile)")
            }
            #expect(tools.contains("press_button"))
            #expect(response.isError == false)
            let fenix = try #require(devices.first { $0.deviceId == "fenix6xpro" })
            #expect(fenix.inputSupported)
            #expect(fenix.buttons == ["enter", "esc", "up", "down"])
            #expect(fenix.inputProfile == "fenix6xpro-verified/3")
            #expect(devices.filter { $0.deviceId != "fenix6xpro" }.allSatisfy {
                !$0.inputSupported && $0.buttons.isEmpty && $0.inputProfile == nil
            })
            #expect(await client.stop())
        } catch {
            _ = await client.stop()
            throw error
        }
    }

    @Test("failed initialization leaves no child owned by the client")
    func failedInitializationCleansUp() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(
            path: "simulator-mcp-installed-client-failed-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let client = InstalledServerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            environment: ProcessInfo.processInfo.environment.merging([
                "SIM_BUTTON_QUALIFICATION_CLIENT_PID_FILE": pidFile.path,
            ]) { _, value in value })

        await #expect(throws: (any Error).self) {
            try await client.start()
        }
        #expect(await client.isRunning == false)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // Integration
            .deletingLastPathComponent() // SimulatorMCPCoreTests
            .deletingLastPathComponent() // Tests
    }
}

private final class InstalledClientEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [InstalledServerClientEvent] = []
    var events: [InstalledServerClientEvent] {
        lock.lock(); defer { lock.unlock() }; return values
    }
    func record(_ event: InstalledServerClientEvent) {
        lock.lock(); values.append(event); lock.unlock()
    }
}
