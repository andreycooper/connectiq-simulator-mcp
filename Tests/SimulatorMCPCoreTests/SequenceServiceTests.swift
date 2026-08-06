import Foundation
import Testing

@testable import SimulatorMCPCore

/// Gate 1 of the v3 design: each step kind fails before its implementation and
/// passes after. The assertions are behavioural — a step kind is "implemented"
/// when it produces its own outcome columns, not when the call returns.
@Suite("SequenceService")
struct SequenceServiceTests {

    @Test("a screenshot step captures a labelled frame and reports its geometry")
    func screenshotStep() async throws {
        let recorder = SequenceRecorder()
        let service = recorder.service()

        let run = try await service.run(RunSequenceToolRequest(
            steps: [.screenshot(label: "initial", savePath: nil)], allowFocus: false))

        #expect(run.failure == nil)
        #expect(run.result.steps.count == 1)
        let outcome = try #require(run.result.steps.first)
        #expect(outcome.index == 0)
        #expect(outcome.kind == "screenshot")
        #expect(outcome.status == "completed")
        #expect(outcome.label == "initial")
        #expect(outcome.path == "/tmp/simulator-mcp/frame.png")
        #expect(outcome.width == 454)
        #expect(outcome.height == 454)
        #expect(outcome.device == "fenix6xpro")
        #expect(outcome.deviceDisplayName == "fēnix 6X Pro")
        #expect(outcome.nativeResolution == DisplaySize(width: 280, height: 280))

        #expect(run.result.frameCount == 1)
        #expect(run.frames.map(\.label) == ["initial"])
        #expect(run.frames.map(\.stepIndex) == [0])
        #expect(run.frames.first?.png == SequenceRecorder.framePNG)
    }

    @Test("a press step delivers the verified button and reports the transport")
    func pressStep() async throws {
        let recorder = SequenceRecorder()
        let service = recorder.service()

        let run = try await service.run(RunSequenceToolRequest(
            steps: [.press(button: "enter", holdMs: 1_000)], allowFocus: true))

        #expect(run.failure == nil)
        let outcome = try #require(run.result.steps.first)
        #expect(outcome.kind == "press")
        #expect(outcome.status == "completed")
        #expect(outcome.button == "enter")
        #expect(outcome.pressType == "hold")
        #expect(outcome.transport == "focused-keys")

        // allowFocus reaches the transport unchanged: a sequence must not
        // widen consent beyond what the caller declared.
        #expect(await recorder.presses == [
            PressButtonToolRequest(button: "enter", holdMs: 1_000, allowFocus: true)
        ])
    }

    @Test("a waitForLog step observes a marker emitted after the baseline")
    func waitForLogStep() async throws {
        let recorder = SequenceRecorder()
        await recorder.enqueuePage(lines: [], state: "running")     // pre-lease probe
        await recorder.enqueuePage(lines: [], state: "running")     // in-lease baseline
        await recorder.enqueuePage(lines: ["boot"], state: "running")
        await recorder.enqueuePage(lines: ["MENU_OPENED"], state: "running")
        let service = recorder.service()

        let run = try await service.run(RunSequenceToolRequest(
            steps: [.waitForLog(contains: "MENU_OPENED", timeoutMs: 5_000)],
            allowFocus: false))

        #expect(run.failure == nil)
        let outcome = try #require(run.result.steps.first)
        #expect(outcome.kind == "waitForLog")
        #expect(outcome.status == "completed")
        #expect(outcome.linesScanned == 2)
        #expect(outcome.waitedMs != nil)

        // Ownership is probed before the lease and re-asserted inside it; the
        // baseline is that second read's latestToken, and every poll advances
        // on the page it just read rather than re-reading from the baseline.
        #expect(await recorder.logTokens == [nil, nil, "latest-1", "next-3"])
        #expect(run.result.sessionId == 7)
    }

    @Test("a screenshot step's savePath reaches the capture closure")
    func screenshotStepThreadsSavePath() async throws {
        let recorder = SequenceRecorder()
        let service = recorder.service()

        let run = try await service.run(RunSequenceToolRequest(
            steps: [.screenshot(label: "initial", savePath: "/tmp/simulator-mcp/explicit.png")],
            allowFocus: false))

        #expect(run.failure == nil)
        #expect(await recorder.capturedSavePaths == ["/tmp/simulator-mcp/explicit.png"])
    }

    @Test("a screenshot step without savePath passes nil to the capture closure")
    func screenshotStepDefaultsToNilSavePath() async throws {
        let recorder = SequenceRecorder()
        let service = recorder.service()

        let run = try await service.run(RunSequenceToolRequest(
            steps: [.screenshot(label: "initial", savePath: nil)], allowFocus: false))

        #expect(run.failure == nil)
        #expect(await recorder.capturedSavePaths == [nil])
    }

    @Test("a screenshot step writes to its savePath")
    func screenshotStepHonoursSavePath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "frame.png")

        let service = publishingSequenceService(managedDirectory: directory.appending(path: "managed"))

        let run = try await service.run(RunSequenceToolRequest(
            steps: [.screenshot(label: "page1", savePath: target.path)], allowFocus: false))

        #expect(run.failure == nil)
        #expect(run.result.steps.first?.path == target.path)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("a screenshot step without savePath still lands in the managed directory")
    func screenshotStepDefaultsToManagedDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "seq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = publishingSequenceService(managedDirectory: directory)

        let run = try await service.run(RunSequenceToolRequest(
            steps: [.screenshot(label: "page1", savePath: nil)], allowFocus: false))

        #expect(run.failure == nil)
        let path = try #require(run.result.steps.first?.path)
        #expect(path.hasSuffix(".png"))
        #expect(path.hasPrefix(directory.path))
    }

    @Test("steps run in declared order and each reports its own index")
    func stepsRunInOrder() async throws {
        let recorder = SequenceRecorder()
        await recorder.enqueuePage(lines: [], state: "running")     // pre-lease probe
        await recorder.enqueuePage(lines: [], state: "running")     // in-lease baseline
        await recorder.enqueuePage(lines: ["MENU_OPENED"], state: "running")
        let service = recorder.service()

        let run = try await service.run(RunSequenceToolRequest(
            steps: [
                .screenshot(label: "initial", savePath: nil),
                .press(button: "enter", holdMs: nil),
                .waitForLog(contains: "MENU_OPENED", timeoutMs: 5_000),
                .screenshot(label: "menu", savePath: nil),
            ],
            allowFocus: true))

        #expect(run.failure == nil)
        #expect(run.result.steps.map(\.kind)
            == ["screenshot", "press", "waitForLog", "screenshot"])
        #expect(run.result.steps.map(\.index) == [0, 1, 2, 3])
        #expect(run.result.steps.allSatisfy { $0.status == "completed" })
        #expect(await recorder.order
            == ["logs", "logs", "capture", "press", "logs", "capture"])
        #expect(run.frames.map(\.label) == ["initial", "menu"])
        #expect(run.result.frameCount == 2)

        // A press with no holdMs is a press, not a hold.
        #expect(run.result.steps.dropFirst().first?.pressType == "press")
    }

    /// Success criterion §9.6: a sequence frame must carry the same device
    /// identity a direct `screenshot` call would report in the same state —
    /// otherwise the field exists on `ScreenshotResult` but is silently
    /// dropped for the step outcomes most likely to be compared across
    /// devices. Two independently constructed `ScreenshotService`s share one
    /// `displayRect` closure and one scripted observation, so this is a
    /// same-state comparison, not a coincidence of two hard-coded strings.
    @Test("a sequence frame carries the same device as a direct screenshot in the same state")
    func sequenceFrameMatchesDirectScreenshotDevice() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The observed device ("fenix7s") deliberately differs from
        // `sequenceTestContext()`'s `currentDevice` ("fenix6xpro"): if a
        // sequence outcome ever fell back to the requested device instead of
        // the observed one, this is the only test that would notice — the
        // two previously matched, so a fallback would have passed silently.
        let devices = [
            InstalledDevice(
                deviceId: "fenix6xpro", displayName: "fēnix 6X Pro", touch: false,
                physicalKeyIds: [], displayRect: PixelRect(x: 76, y: 141, width: 280, height: 280)),
            InstalledDevice(
                deviceId: "fenix7s", displayName: "fēnix 7S", touch: false,
                physicalKeyIds: [], displayRect: PixelRect(x: 10, y: 20, width: 100, height: 100)),
        ]
        let displayRect: @Sendable (String) -> PixelRect? = { device in
            devices.first { $0.deviceId == device }?.displayRect
        }
        let observation = DeviceObservation.device(deviceId: "fenix7s", displayName: "fēnix 7S")
        let context = sequenceTestContext()

        let direct = ScreenshotService(
            operationRunner: .immediate(context: context),
            displayRect: displayRect,
            makeCapturer: { _ in PublishingStubCapturer() },
            deviceReadback: ScriptedReadback([observation]),
            publisher: CapturePublisher(directory: directory.appending(path: "direct")))
        let directOutput = try await direct.capture(savePath: nil)

        let sequenceService = SequenceService(
            operationRunner: .immediate(context: context),
            capture: { context, savePath in
                try await ScreenshotService(
                    operationRunner: .immediate(context: context),
                    displayRect: displayRect,
                    makeCapturer: { _ in PublishingStubCapturer() },
                    deviceReadback: ScriptedReadback([observation]),
                    publisher: CapturePublisher(directory: directory.appending(path: "managed"))
                ).capture(savePath: savePath)
            },
            press: { request, _ in
                PressButtonResult(
                    button: request.button, pressType: "press", transport: "focused-keys",
                    simulatorPid: 4_242)
            },
            readLogs: { _, _ in
                throw ToolError(code: "no_current_session", message: "unused", fix: "unused")
            },
            revalidate: { _ in })

        let run = try await sequenceService.run(RunSequenceToolRequest(
            steps: [.screenshot(label: "page1", savePath: nil)], allowFocus: false))

        #expect(run.failure == nil)
        let outcome = try #require(run.result.steps.first)
        #expect(outcome.device == "fenix7s")
        #expect(outcome.device == directOutput.result.device)
        #expect(outcome.deviceDisplayName == directOutput.result.deviceDisplayName)
        #expect(outcome.nativeResolution == directOutput.result.nativeResolution)
    }
}

// MARK: - Test double

/// Records every call the service makes through its injected seams and serves
/// scripted `get_logs` pages.
private actor SequenceRecorder {
    static let framePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])

    private(set) var presses: [PressButtonToolRequest] = []
    private(set) var logTokens: [String?] = []
    private(set) var order: [String] = []
    private(set) var capturedSavePaths: [String?] = []
    private var pages: [(lines: [String], state: String)] = []
    private var pageIndex = 0

    func enqueuePage(lines: [String], state: String) {
        pages.append((lines, state))
    }

    private func recordCapture(savePath: String?) {
        order.append("capture")
        capturedSavePaths.append(savePath)
    }

    private func recordPress(_ request: PressButtonToolRequest) {
        order.append("press")
        presses.append(request)
    }

    private func nextPage(sinceToken: String?) -> GetLogsResult {
        order.append("logs")
        logTokens.append(sinceToken)
        let page = pageIndex < pages.count ? pages[pageIndex] : (lines: [], state: "running")
        pageIndex += 1
        let index = pageIndex
        return GetLogsResult(
            sessionId: 7,
            state: page.state,
            terminationReason: nil,
            exitCode: nil,
            crashDetected: false,
            droppedLines: 0,
            lines: page.lines.enumerated().map { offset, text in
                LogLine(
                    seq: index * 100 + offset, monotonicNanos: Int64(index * 1_000),
                    stream: .stdout, text: text, crash: false)
            },
            nextToken: "next-\(index)",
            latestToken: "latest-\(index - 1)")
    }

    nonisolated func service() -> SequenceService {
        SequenceService(
            operationRunner: .immediate(context: sequenceTestContext()),
            capture: { _, savePath in
                await self.recordCapture(savePath: savePath)
                return ScreenshotOutput(
                    result: ScreenshotResult(
                        path: "/tmp/simulator-mcp/frame.png",
                        mimeType: "image/png",
                        width: 454,
                        height: 454,
                        capturedPid: 4_242,
                        device: "fenix6xpro",
                        deviceDisplayName: "fēnix 6X Pro",
                        nativeResolution: DisplaySize(width: 280, height: 280),
                        appDisplayRect: nil),
                    png: Self.framePNG)
            },
            press: { request, _ in
                await self.recordPress(request)
                return PressButtonResult(
                    button: request.button,
                    pressType: (request.holdMs ?? 0) >= 300 ? "hold" : "press",
                    transport: "focused-keys",
                    simulatorPid: 4_242)
            },
            readLogs: { token, _ in await self.nextPage(sinceToken: token) },
            revalidate: { _ in },
            clock: ContinuousClock())
    }
}

private func sequenceTestContext() -> OperationContext {
    OperationContext(
        simulatorPid: 4_242,
        sdk: SdkInfo(
            version: SemVer("9.1.0")!,
            root: URL(fileURLWithPath: "/sdk/9.1.0"),
            source: .installed),
        currentDevice: "fenix6xpro",
        listeningEndpoints: [])
}

/// A `SequenceService` whose capture closure is wired exactly like
/// `SequenceService.live`'s — a real `ScreenshotService` over a real
/// `CapturePublisher` — minus the `SimulatorController`/lease machinery that
/// `SequenceLeaseTests` already exercises. This is what lets these tests
/// assert on an actual file landing on disk rather than on a stubbed path
/// string.
private func publishingSequenceService(managedDirectory: URL) -> SequenceService {
    SequenceService(
        operationRunner: .immediate(context: sequenceTestContext()),
        capture: { context, savePath in
            try await ScreenshotService(
                deviceCatalog: DeviceCatalog(),
                operationRunner: .immediate(context: context),
                makeCapturer: { _ in PublishingStubCapturer() },
                deviceReadback: ScriptedReadback([]),
                publisher: CapturePublisher(directory: managedDirectory)
            ).capture(savePath: savePath)
        },
        press: { request, _ in
            PressButtonResult(
                button: request.button, pressType: "press", transport: "focused-keys",
                simulatorPid: 4_242)
        },
        readLogs: { _, _ in
            throw ToolError(code: "no_current_session", message: "unused", fix: "unused")
        },
        revalidate: { _ in })
}

private struct PublishingStubCapturer: ScreenshotCapturing {
    func captureWindow(pid: Int32) async throws -> CapturedPNG {
        CapturedPNG(data: validPNG(padding: 8), width: 454, height: 454, appDisplayRect: nil)
    }
}
