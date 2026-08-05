import Foundation
import Testing

@testable import SimulatorMCPCore

/// Gates 7, 9 and 10: a failed sequence still returns its evidence, refusals
/// match `press_button` exactly, and the wall-clock budget is real.
/// `.serialized` is load-bearing, not decoration, and the reason is measured
/// rather than reasoned: `hangingStepHitsTheDeadline` parks a step on a
/// `FakeClock` until `withDeadline` cancels it. Run alone it passes 8/8 in
/// ~1 ms; run unserialized alongside its five siblings it failed 1 run in 5 by
/// hitting the 60 s time limit. Nothing is shared between these tests — each
/// builds its own harness, clock and gate — so the interaction is in task
/// scheduling, and I have not isolated it further. Removing this trait
/// reintroduces the flake.
@Suite("SequenceFailure", .serialized)
struct SequenceFailureTests {

    // MARK: - Gate 7

    @Test("a sequence failing at step 3 of 5 returns the frames before it and one after")
    func failureReturnsFramesAndStepRecord() async throws {
        let harness = FailureHarness(
            pressFailure: ToolError(
                code: "input_delivery_failed",
                message: "The input transport could not deliver the button.",
                fix: "Restart the simulator, verify the selected input profile and Accessibility state, then retry.",
                details: [
                    "button": .string("enter"),
                    "simulatorPid": .int(4_242),
                    "transportStage": .string("eventPost"),
                ]),
            failOnPressNumber: 1)

        let run = try await harness.service().run(RunSequenceToolRequest(
            steps: [
                .screenshot(label: "one"),
                .screenshot(label: "two"),
                .press(button: "enter", holdMs: nil),   // step 2 fails
                .screenshot(label: "never"),
                .press(button: "esc", holdMs: nil),
            ],
            allowFocus: true))

        let failure = try #require(run.failure)
        #expect(failure.code == "input_delivery_failed")
        #expect(failure.details?["failedStepIndex"] == .int(2))
        #expect(failure.details?["completedSteps"] == .int(2))

        // The failing step's own diagnostics survive alongside the sequence
        // keys. 905e76c added these precisely so an intermittent delivery
        // failure is diagnosable; a sequence must not swallow them.
        #expect(failure.details?["button"] == .string("enter"))
        #expect(failure.details?["simulatorPid"] == .int(4_242))
        #expect(failure.details?["transportStage"] == .string("eventPost"))

        // Two frames captured before the failure, plus the terminal one. Three
        // screenshot steps would exceed maximumFrames, which is the cap doing
        // its job rather than a limitation of this test.
        #expect(run.frames.map(\.label) == ["one", "two", "post-failure"])
        #expect(run.result.frameCount == 3)

        // Every step is accounted for: completed, the failure, then skipped.
        #expect(run.result.steps.map(\.status)
            == ["completed", "completed", "failed", "skipped", "skipped"])
        #expect(run.result.steps.map(\.index) == [0, 1, 2, 3, 4])
    }

    @Test("a step-0 failure still returns the terminal frame and names the step")
    func firstStepFailureStillCarriesEvidence() async throws {
        let harness = FailureHarness(
            pressFailure: ToolError(
                code: "focus_required",
                message: "This input transport requires simulator focus; allowFocus=true visibly brings Garmin Simulator forward and leaves it frontmost.",
                fix: "Retry with allowFocus=true if visible Simulator activation and leaving it frontmost are acceptable."),
            failOnPressNumber: 1)

        let run = try await harness.service().run(RunSequenceToolRequest(
            steps: [.press(button: "enter", holdMs: nil), .screenshot(label: "never")],
            allowFocus: false))

        let failure = try #require(run.failure)
        // Gate 9: refusal parity. Byte-identical to a single press_button.
        #expect(failure.code == "focus_required")
        #expect(failure.message.contains("requires simulator focus"))
        #expect(failure.fix.contains("allowFocus=true"))
        #expect(failure.details?["failedStepIndex"] == .int(0))
        #expect(failure.details?["completedSteps"] == .int(0))
        // No frames precede it, but the screen at the moment of failure is
        // still the most diagnostic artifact available.
        #expect(run.frames.map(\.label) == ["post-failure"])
    }

    @Test("a failed terminal capture is dropped, never replacing the real error")
    func terminalCaptureFailureIsSwallowed() async throws {
        let harness = FailureHarness(
            pressFailure: ToolError(
                code: "input_unsupported", message: "Button up is not verified for device x.",
                fix: "Use one of: enter, esc, up, down."),
            failOnPressNumber: 1,
            captureFailsAfterCount: 1)

        let run = try await harness.service().run(RunSequenceToolRequest(
            steps: [.screenshot(label: "one"), .press(button: "up", holdMs: nil)],
            allowFocus: true))

        let failure = try #require(run.failure)
        #expect(failure.code == "input_unsupported", "the real error survives")
        #expect(run.frames.map(\.label) == ["one"], "no terminal frame, and no crash")
        #expect(run.result.steps.map(\.status) == ["completed", "failed"])
    }

    // MARK: - Gate 10

    /// The branch that answers the design's only blocker-severity finding.
    /// Gate 10 alone never reached it: advancing the clock between steps trips
    /// the cheap pre-step guard instead, so a step that *hangs* is the only
    /// thing that exercises `withDeadline`.
    @Test("a step that hangs past the budget is cut off and keeps its frames",
          .timeLimit(.minutes(1)))
    func hangingStepHitsTheDeadline() async throws {
        let clock = FakeClock()
        let harness = FailureHarness(hangOnCaptureNumber: 2, clock: clock)

        async let running = harness.service().run(RunSequenceToolRequest(
            steps: [.screenshot(label: "one"), .screenshot(label: "hangs")],
            allowFocus: false))

        // Let the hanging step start, then run the whole budget out from under
        // it. No real time passes.
        try await harness.waitUntilHanging()
        clock.advance(by: .seconds(121))
        let run = try await running

        let failure = try #require(run.failure)
        #expect(failure.code == "sequence_budget_exhausted")
        #expect(failure.details?["failedStepIndex"] == .int(1))
        #expect(run.result.steps.map(\.status) == ["completed", "failed"])
        // The frame before the hang survives being cut off, and the terminal
        // capture still runs -- on its own budget, not the exhausted one.
        #expect(run.frames.map(\.label) == ["one", "post-failure"])
    }

    @Test("an untranslated platform error becomes a step failure, not a lost run")
    func untranslatedErrorStillReturnsFrames() async throws {
        // CocoaError is what AtomicFile.replace surfaces when /tmp is full or
        // unwritable: not a ToolError, and it used to escape the whole run.
        let harness = FailureHarness(
            captureFailsAfterCount: 1,
            captureFailure: CocoaError(.fileWriteOutOfSpace))

        let run = try await harness.service().run(RunSequenceToolRequest(
            steps: [.screenshot(label: "one"), .screenshot(label: "two")],
            allowFocus: false))

        let failure = try #require(run.failure)
        #expect(failure.code == "internal_error")
        #expect(!failure.fix.isEmpty)
        #expect(failure.details?["failedStepIndex"] == .int(1))
        // The point: the frame captured before it is still returned.
        #expect(run.frames.map(\.label) == ["one"])
        #expect(run.result.steps.map(\.status) == ["completed", "failed"])
    }

    @Test("a sequence that exceeds its wall-clock budget fails and keeps its frames")
    func budgetExhaustionReturnsEvidence() async throws {
        // The clock is advanced between steps, not inside a capture: advancing
        // inside one makes the deadline sleeper become due mid-step, and which
        // task then wins `withDeadline`'s race is scheduling, not the property
        // under test.
        let clock = FakeClock()
        let harness = FailureHarness(advanceAfterCapture: .seconds(70), clock: clock)

        let run = try await harness.service().run(RunSequenceToolRequest(
            steps: [
                .screenshot(label: "one"),
                .screenshot(label: "two"),
                .screenshot(label: "three"),
            ],
            allowFocus: false))

        let failure = try #require(run.failure)
        #expect(failure.code == "sequence_budget_exhausted")
        #expect(!failure.fix.isEmpty)
        // Which mechanism reports exhaustion — the cheap pre-step guard or
        // withDeadline cutting the step off — depends on whether the advance
        // crosses the running step's own deadline, which is scheduling. The
        // property is not: the run stops, says why, and keeps its frames.
        // `hangingStepHitsTheDeadline` pins the withDeadline path exactly.
        #expect(run.frames.map(\.label).first == "one")
        #expect(run.result.steps.first?.status == "completed")
        #expect(run.result.steps.contains { $0.status == "failed" })
    }
}

// MARK: - Harness

private struct FailureHarness: Sendable {
    private let state = FailureState()
    private let pressFailure: ToolError?
    private let failOnPressNumber: Int
    private let captureFailsAfterCount: Int?
    private let captureAdvances: Duration?
    private let clock: FakeClock?

    private let captureFailure: (any Error)?
    private let hangOnCaptureNumber: Int?
    private let hanging = HangGate()

    init(
        pressFailure: ToolError? = nil,
        failOnPressNumber: Int = 0,
        captureFailsAfterCount: Int? = nil,
        captureFailure: (any Error)? = nil,
        advanceAfterCapture: Duration? = nil,
        hangOnCaptureNumber: Int? = nil,
        clock: FakeClock? = nil
    ) {
        self.pressFailure = pressFailure
        self.failOnPressNumber = failOnPressNumber
        self.captureFailsAfterCount = captureFailsAfterCount
        self.captureFailure = captureFailure
        self.captureAdvances = advanceAfterCapture
        self.hangOnCaptureNumber = hangOnCaptureNumber
        self.clock = clock
    }

    func waitUntilHanging() async throws { await hanging.waitUntilEntered() }

    func service() -> SequenceService {
        let state = self.state
        let pressFailure = self.pressFailure
        let failOnPressNumber = self.failOnPressNumber
        let captureFailsAfterCount = self.captureFailsAfterCount
        let captureAdvances = self.captureAdvances
        let clock = self.clock

        let captureFailure = self.captureFailure
        let hangOnCaptureNumber = self.hangOnCaptureNumber
        let hanging = self.hanging
        let capture: @Sendable (OperationContext) async throws -> ScreenshotOutput = { _ in
            let count = state.nextCapture()
            if count == hangOnCaptureNumber {
                // Never returns and never observes cancellation — exactly the
                // step withDeadline has to cut off.
                await hanging.enter()
                // On the injected clock, so cancellation is deterministic and
                // no real time passes: FakeClock resumes a cancelled sleeper
                // through its own cancellation handler.
                try await (clock ?? FakeClock()).sleep(for: .seconds(3_600))
            }
            if let limit = captureFailsAfterCount, count > limit {
                throw captureFailure ?? ToolError(
                    code: "environment_missing",
                    message: "No visible primary simulator window belongs to PID 4242.",
                    fix: "Bring the Connect IQ simulator device window on screen, then retry screenshot.")
            }
            if let advance = captureAdvances, let clock { clock.advance(by: advance) }
            return ScreenshotOutput(
                result: ScreenshotResult(
                    path: "/tmp/simulator-mcp/frame-\(count).png", mimeType: "image/png",
                    width: 454, height: 454, capturedPid: 4_242, appDisplayRect: nil),
                png: Data([0x89, 0x50, 0x4E, 0x47, UInt8(count)]))
        }
        let press: @Sendable (PressButtonToolRequest, OperationContext) async throws ->
            PressButtonResult = { request, _ in
            let count = state.nextPress()
            if let pressFailure, count == failOnPressNumber { throw pressFailure }
            return PressButtonResult(
                button: request.button, pressType: "press", transport: "focused-keys",
                simulatorPid: 4_242)
        }

        if let clock {
            return SequenceService(
                operationRunner: .immediate(context: failureContext()),
                capture: capture, press: press,
                readLogs: { _, _ in throw ToolError(
                    code: "no_current_session", message: "unused", fix: "unused") },
                revalidate: { _ in },
                clock: clock)
        }
        return SequenceService(
            operationRunner: .immediate(context: failureContext()),
            capture: capture, press: press,
            readLogs: { _, _ in throw ToolError(
                code: "no_current_session", message: "unused", fix: "unused") },
            revalidate: { _ in })
    }
}

/// Signals that the hanging step has actually started, so the test advances the
/// clock at a defined point instead of racing it.
private actor HangGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        let resume = waiters
        waiters.removeAll()
        resume.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class FailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var captures = 0
    private var presses = 0

    func nextCapture() -> Int { lock.withLock { captures += 1; return captures } }
    func nextPress() -> Int { lock.withLock { presses += 1; return presses } }
}

private func failureContext() -> OperationContext {
    OperationContext(
        simulatorPid: 4_242,
        sdk: SdkInfo(
            version: SemVer("9.1.0")!, root: URL(fileURLWithPath: "/sdk/9.1.0"),
            source: .installed),
        currentDevice: "fenix6xpro",
        listeningEndpoints: [])
}
