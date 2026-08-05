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
            steps: [.screenshot(label: "initial")], allowFocus: false))

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

    @Test("steps run in declared order and each reports its own index")
    func stepsRunInOrder() async throws {
        let recorder = SequenceRecorder()
        await recorder.enqueuePage(lines: [], state: "running")     // pre-lease probe
        await recorder.enqueuePage(lines: [], state: "running")     // in-lease baseline
        await recorder.enqueuePage(lines: ["MENU_OPENED"], state: "running")
        let service = recorder.service()

        let run = try await service.run(RunSequenceToolRequest(
            steps: [
                .screenshot(label: "initial"),
                .press(button: "enter", holdMs: nil),
                .waitForLog(contains: "MENU_OPENED", timeoutMs: 5_000),
                .screenshot(label: "menu"),
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
}

// MARK: - Test double

/// Records every call the service makes through its injected seams and serves
/// scripted `get_logs` pages.
private actor SequenceRecorder {
    static let framePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])

    private(set) var presses: [PressButtonToolRequest] = []
    private(set) var logTokens: [String?] = []
    private(set) var order: [String] = []
    private var pages: [(lines: [String], state: String)] = []
    private var pageIndex = 0

    func enqueuePage(lines: [String], state: String) {
        pages.append((lines, state))
    }

    private func recordCapture() { order.append("capture") }

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
            capture: { _ in
                await self.recordCapture()
                return ScreenshotOutput(
                    result: ScreenshotResult(
                        path: "/tmp/simulator-mcp/frame.png",
                        mimeType: "image/png",
                        width: 454,
                        height: 454,
                        capturedPid: 4_242,
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
