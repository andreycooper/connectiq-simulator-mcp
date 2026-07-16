import Foundation

/// Live service composition behind Task 11's thin MCP handlers. Resolution,
/// compilation, lifecycle policy, run orchestration, and session reads stay in
/// the service layer; handlers only decode one request and call one closure.
extension ToolHandlerServices {
    public static func live() -> ToolHandlerServices {
        let locator = SdkLocator()
        let catalog = DeviceCatalog()
        let processRunner = Subprocess()
        let compiler = Compiler(runner: processRunner)
        let monkeydoLifecycle = MonkeydoProcessLifecycle(processRunner: processRunner)
        let sessions = AppSessionManager(lifecycle: monkeydoLifecycle)
        let controller = SimulatorController(
            queue: AsyncFIFO(), lease: .standard, runtimeStore: .standard,
            processRunner: processRunner, sessionStopper: sessions,
            monkeydoLifecycle: monkeydoLifecycle)
        let coordinator = RunCoordinator(
            controller: controller, compiler: compiler, sessionManager: sessions,
            processRunner: processRunner, lifecycle: monkeydoLifecycle)
        let doctor = DoctorService(
            permissions: Permissions(), signatureInspector: SignatureInspector(),
            executableURL: SignatureInspector.currentExecutableURL,
            sdkProbe: { liveSdkProbe(locator: locator) },
            javaProbe: { await liveJavaProbe(processRunner: processRunner) },
            simulatorProbe: { await liveSimulatorProbe(controller: controller) },
            installedExecutablePath: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".simulator-mcp/bin/simulator-mcp").path)
        let screenshot = ScreenshotService(controller: controller, deviceCatalog: catalog)
        let gpsPosition = GpsPositionService(controller: controller)

        return ToolHandlerServices(
            listSdks: {
                ListSdksResult(installed: locator.installedSdks(), active: try locator.resolve())
            },
            listDevices: { request in
                _ = try locator.resolve(explicitPath: request.sdk)
                if request.projectPath == nil, request.jungle != nil {
                    throw ToolError(
                        code: "invalid_arguments",
                        message: "jungle requires projectPath for list_devices.",
                        fix: "Pass projectPath with jungle, or omit jungle to list all installed devices.")
                }
                let descriptor = try request.projectPath.map {
                    try ProjectDescriptor.resolve(projectPath: $0, jungleOverride: request.jungle)
                }
                let devices = descriptor.map {
                    catalog.installedDevices(intersecting: $0.manifestDevices)
                } ?? catalog.installedDevices()
                return ListDevicesResult(devices: devices.map {
                    DeviceSummary(
                        deviceId: $0.deviceId, displayName: $0.displayName, touch: $0.touch,
                        buttons: [], inputSupported: false, inputProfile: nil)
                })
            },
            build: { request in
                let resolved = try resolveBuild(
                    request.projectPath, request.jungle, request.developerKey, request.sdk,
                    request.device, locator: locator)
                let outcome = try await compiler.build(BuildRequest(
                    context: resolved.context, sdk: resolved.sdk, device: resolved.device,
                    mode: request.mode, force: true))
                return mapBuild(outcome, sdk: resolved.sdk)
            },
            simStart: { request in
                let sdk = try locator.resolve(explicitPath: request.sdk)
                _ = try await controller.withOperation(
                    .simStart, requirement: .start(requested: sdk)) { _ in () }
                return SimStartResult(status: try await controller.status())
            },
            simStop: {
                _ = try await controller.withOperation(.simStop, requirement: .stop) { _ in () }
                return SimStopResult(status: try await controller.status())
            },
            simStatus: { try await controller.status() },
            runApp: { request in
                let resolved = try resolveBuild(
                    request.projectPath, request.jungle, request.developerKey, request.sdk,
                    request.device, locator: locator)
                return try await coordinator.runApp(RunAppRequest(
                    project: resolved.context.project, buildContext: resolved.context,
                    sdk: resolved.sdk, device: resolved.device, rebuild: request.rebuild))
            },
            runTests: { request in
                let resolved = try resolveBuild(
                    request.projectPath, request.jungle, request.developerKey, request.sdk,
                    request.device, locator: locator)
                return try await coordinator.runTests(RunTestsRequest(
                    project: resolved.context.project, buildContext: resolved.context,
                    sdk: resolved.sdk, device: resolved.device, testFilter: request.testFilter))
            },
            getLogs: { request in
                try await sessions.logs(
                    sessionId: request.sessionId, sinceToken: request.sinceToken,
                    limit: request.limit)
            },
            doctor: { request in
                await doctor.inspect(requestPermissions: request.requestPermissions)
            },
            screenshot: { request in
                try await screenshot.capture(savePath: request.savePath)
            },
            setGpsPosition: { request in
                try await gpsPosition.setPosition(request)
            })
    }
}

private func liveSdkProbe(locator: SdkLocator) -> DoctorProbeStatus {
    do {
        let sdk = try locator.resolve()
        return DoctorProbeStatus(
            ok: true,
            observed: "Connect IQ SDK \(sdk.version) at \(sdk.root.path) (\(sdk.source.rawValue))",
            fix: nil)
    } catch let error as ToolError {
        return DoctorProbeStatus(ok: false, observed: error.message, fix: error.fix)
    } catch {
        return DoctorProbeStatus(
            ok: false, observed: "Connect IQ SDK inspection failed.",
            fix: "Install an SDK with Connect IQ SDK Manager, then run doctor again.")
    }
}

private func liveJavaProbe(processRunner: any ProcessRunning) async -> DoctorProbeStatus {
    do {
        let child = try await processRunner.start(
            executable: URL(fileURLWithPath: "/usr/bin/java"), arguments: ["-version"],
            environment: nil, workingDirectory: nil, timeout: .seconds(5),
            onStdout: nil, onStderr: nil)
        let output = try await child.wait()
        let text = String(
            decoding: output.stdout + output.stderr, as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.exitCode == 0, let major = javaMajorVersion(text), major >= 17 else {
            return DoctorProbeStatus(
                ok: false,
                observed: text.isEmpty ? "Java was not available." : text,
                fix: "Install Java 17 or newer, make it the active java executable, then run doctor again.")
        }
        return DoctorProbeStatus(ok: true, observed: text, fix: nil)
    } catch let error as ToolError {
        return DoctorProbeStatus(
            ok: false, observed: error.message,
            fix: "Install Java 17 or newer, make it the active java executable, then run doctor again.")
    } catch {
        return DoctorProbeStatus(
            ok: false, observed: "Java version inspection failed.",
            fix: "Install Java 17 or newer, make it the active java executable, then run doctor again.")
    }
}

private func javaMajorVersion(_ output: String) -> Int? {
    guard let marker = output.range(of: "version", options: .caseInsensitive) else { return nil }
    let suffix = output[marker.upperBound...]
    guard let token = suffix.split(whereSeparator: \Character.isWhitespace).first else { return nil }
    let version = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    let components = version.split(separator: ".")
    guard let first = components.first.flatMap({ Int($0) }) else { return nil }
    return first == 1 && components.count > 1 ? Int(components[1]) : first
}

private func liveSimulatorProbe(controller: SimulatorController) async -> DoctorProbeStatus {
    do {
        let status = try await controller.status()
        let running = status.pid != nil
        let sdk = status.sdkVersion.map { ", SDK \($0)" } ?? ""
        return DoctorProbeStatus(
            ok: running,
            observed: "state=\(status.state.rawValue)\(sdk)",
            fix: running ? nil : "Call sim_start to launch the Connect IQ simulator, then run doctor again.")
    } catch let error as ToolError {
        return DoctorProbeStatus(ok: false, observed: error.message, fix: error.fix)
    } catch {
        return DoctorProbeStatus(
            ok: false, observed: "Simulator inspection failed.",
            fix: "Quit duplicate simulator processes, then run doctor again.")
    }
}

private struct ResolvedPublicBuild: Sendable {
    let context: BuildContext
    let sdk: SdkInfo
    let device: String
}

private func resolveBuild(
    _ projectPath: String, _ jungle: String?, _ developerKey: String?,
    _ sdkPath: String?, _ device: String?, locator: SdkLocator
) throws -> ResolvedPublicBuild {
    let project = try ProjectDescriptor.resolve(projectPath: projectPath, jungleOverride: jungle)
    let context = try BuildContext.resolve(project: project, developerKeyOverride: developerKey)
    return ResolvedPublicBuild(
        context: context, sdk: try locator.resolve(explicitPath: sdkPath),
        device: try project.selectDevice(explicit: device))
}

private func mapBuild(_ outcome: BuildOutcome, sdk: SdkInfo) -> BuildResult {
    BuildResult(
        succeeded: outcome.succeeded, prgPath: outcome.prgPath?.path,
        rebuilt: outcome.rebuilt, artifactKey: outcome.artifactKey, sdk: sdk.root.path,
        device: outcome.device, mode: outcome.mode,
        diagnostics: outcome.diagnostics.map {
            Diagnostic(
                file: $0.file, line: $0.line, column: $0.column,
                severity: $0.severity.rawValue, message: $0.message)
        })
}
