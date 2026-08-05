import Foundation

/// One scripted step. The wire form is a flat `kind`-tagged object (nothing
/// validates `inputSchema`, so the decoder is the contract — see the v3
/// design); this is the decoded form, where an illegal combination of fields
/// cannot be represented at all.
public enum SequenceStep: Equatable, Sendable {
    case press(button: String, holdMs: Int?)
    case screenshot(label: String)
    case waitForLog(contains: String, timeoutMs: Int)

    public var kind: String {
        switch self {
        case .press: return "press"
        case .screenshot: return "screenshot"
        case .waitForLog: return "waitForLog"
        }
    }

    /// Declared wait, used by the pre-lease budget check. A press or a
    /// screenshot declares nothing: their ceilings live in the transports.
    var declaredTimeoutMs: Int {
        if case .waitForLog(_, let timeoutMs) = self { return timeoutMs }
        return 0
    }
}

public struct RunSequenceToolRequest: Equatable, Sendable {
    public let steps: [SequenceStep]
    public let allowFocus: Bool

    public init(steps: [SequenceStep], allowFocus: Bool) {
        self.steps = steps
        self.allowFocus = allowFocus
    }
}

/// A captured frame. The bytes leave as an `image` content block; the label
/// and step index let the model correlate them with the structured outcomes.
public struct SequenceFrame: Equatable, Sendable {
    public let stepIndex: Int
    public let label: String
    public let png: Data

    public init(stepIndex: Int, label: String, png: Data) {
        self.stepIndex = stepIndex
        self.label = label
        self.png = png
    }
}

/// The service returns this even when a step failed, so the handler can encode
/// `failure(error, additionalContent: frames)`. A thrown `ToolError` is
/// reserved for faults decided before any step runs, where there are no frames
/// to lose.
public struct SequenceRun: Sendable {
    public let result: SequenceResult
    public let frames: [SequenceFrame]
    public let failure: ToolError?

    public init(result: SequenceResult, frames: [SequenceFrame], failure: ToolError?) {
        self.result = result
        self.frames = frames
        self.failure = failure
    }
}

/// Same injectable seam as `ScreenshotOperationRunner` and
/// `ButtonOperationRunner`: production takes the one lease, tests forward a
/// context directly.
public struct SequenceOperationRunner: Sendable {
    public typealias Body = @Sendable (OperationContext) async throws -> SequenceRun
    private let runBody: @Sendable (
        SimOperation, OperationRequirement, @escaping Body
    ) async throws -> SequenceRun

    public init(controller: SimulatorController) {
        runBody = { try await controller.withOperation($0, requirement: $1, body: $2) }
    }

    public init(
        _ run: @escaping @Sendable (
            SimOperation, OperationRequirement, @escaping Body
        ) async throws -> SequenceRun
    ) {
        runBody = run
    }

    func run(
        _ operation: SimOperation,
        requirement: OperationRequirement,
        body: @escaping Body
    ) async throws -> SequenceRun {
        try await runBody(operation, requirement, body)
    }

    static func immediate(context: OperationContext) -> SequenceOperationRunner {
        SequenceOperationRunner { _, _, body in try await body(context) }
    }
}

/// Runs a scripted interaction under a single lease.
///
/// Composition detail that is load-bearing: the screenshot and press closures
/// must reach services built with *lease-free* runners
/// (`ScreenshotOperationRunner.immediate`, `ButtonOperationRunner.init(_:)`).
/// Calling the public service closures instead would nest `withOperation`
/// inside `withOperation`; `AsyncFIFO` is not reentrant, so that self-blocks
/// for 30 s and then fails `simulator_busy`.
public struct SequenceService: Sendable {
    /// Wall-clock bound on the sequence's *steps*, applied per step against
    /// the remaining budget. The declared-timeout sum bounds almost nothing —
    /// a press carries 10 s + holdMs, a capture 30 s, a readiness re-check up
    /// to 15 s, and `withOperation` puts no deadline on its body at all.
    ///
    /// Not a hard bound on wall-clock, and the difference is worth stating:
    /// `ClockSupport.withDeadline` cancels its loser **cooperatively**, so a
    /// step that never observes cancellation runs to its own ceiling before
    /// the deadline can be reported. The post-failure capture is bounded
    /// separately by `terminalCaptureBudget`.
    static let totalBudget: Duration = .seconds(120)
    /// The diagnostic capture after a failed step. Separate from the step
    /// budget because it runs once that budget is already spent, and smaller
    /// than the capturer's own 30 s ceiling so a wedged capture cannot keep the
    /// lease and the keyboard for another half minute after the run has already
    /// failed. Advisory, like every `withDeadline`: it bounds when the wait is
    /// reported, not when a stuck capture stops.
    static let terminalCaptureBudget: Duration = .seconds(10)
    static let maximumSteps = 20
    /// Frames per sequence. Derived from measurement, not estimate: Gate 11
    /// captured fenix6xpro windows at **973 KB** each, an order of magnitude
    /// above the "hundred kilobytes" the design first assumed. Every frame is
    /// base64'd into one JSON-RPC response, so the worst case is (cap + the
    /// post-failure frame) x 973 KB x 4/3:
    ///
    ///     cap 6 -> 9.1 MB   cap 3 -> 5.2 MB   cap 2 -> 3.9 MB
    ///
    /// Three keeps a before/middle/after filmstrip while holding the response
    /// near 5 MB. Cropping captures to `appDisplayRect` would buy back most of
    /// this and is the real fix if more frames are ever wanted; it changes the
    /// screenshot tool's own output, so it is not folded in here.
    static let maximumFrames = 3
    static let maximumDeclaredWaitMs = 20_000
    static let pollInterval: Duration = .milliseconds(50)
    static let pollPageLimit = 500

    private let operationRunner: SequenceOperationRunner
    private let capture: @Sendable (OperationContext) async throws -> ScreenshotOutput
    private let press:
        @Sendable (PressButtonToolRequest, OperationContext) async throws -> PressButtonResult
    private let readLogs: @Sendable (String?, Int) async throws -> GetLogsResult
    private let revalidate: @Sendable (OperationContext) async throws -> Void
    private let clock: any Clock<Duration>
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline
    /// Milliseconds since this service was constructed. An `any Clock<Duration>`
    /// hides its `Instant`, so elapsed time is captured in a closure built by
    /// the generic initializer — the same shape `FocusedKeyTransport` uses.
    private let elapsedMs: @Sendable () -> Int

    public init<C: Clock>(
        operationRunner: SequenceOperationRunner,
        capture: @escaping @Sendable (OperationContext) async throws -> ScreenshotOutput,
        press: @escaping @Sendable (PressButtonToolRequest, OperationContext) async throws ->
            PressButtonResult,
        readLogs: @escaping @Sendable (String?, Int) async throws -> GetLogsResult,
        revalidate: @escaping @Sendable (OperationContext) async throws -> Void,
        clock: C = ContinuousClock()
    ) where C.Duration == Duration {
        self.operationRunner = operationRunner
        self.capture = capture
        self.press = press
        self.readLogs = readLogs
        self.revalidate = revalidate
        self.clock = clock
        self.makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        let origin = clock.now
        self.elapsedMs = {
            let parts = origin.duration(to: clock.now).components
            return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        }
    }

    // MARK: - Entry

    public func run(_ request: RunSequenceToolRequest) async throws -> SequenceRun {
        try Self.validateBeforeLease(request)
        let needsSession = request.steps.contains { if case .waitForLog = $0 { return true }
            return false }
        // Cheap refusal before anyone waits on the lease: a sequence that can
        // never observe a marker must not block another client for 30 s first.
        if needsSession { _ = try await requireOwnedRunningSession() }

        return try await operationRunner.run(.runSequence, requirement: .currentReady) { context in
            try await execute(request, needsSession: needsSession, context: context)
        }
    }

    // MARK: - Pre-lease validation

    static func validateBeforeLease(_ request: RunSequenceToolRequest) throws {
        guard !request.steps.isEmpty else {
            throw ToolError(
                code: "invalid_arguments",
                message: "A sequence needs at least one step.",
                fix: "Pass one or more steps, each with a kind of press, screenshot or waitForLog.")
        }
        guard request.steps.count <= maximumSteps else {
            throw ToolError(
                code: "invalid_arguments",
                message: "A sequence may contain at most \(maximumSteps) steps; this one has \(request.steps.count).",
                fix: "Split the interaction into separate run_sequence calls of \(maximumSteps) steps or fewer.",
                details: ["steps": .int(request.steps.count)])
        }
        let frames = request.steps.filter { if case .screenshot = $0 { return true }
            return false }.count
        guard frames <= maximumFrames else {
            throw ToolError(
                code: "invalid_arguments",
                message: "A sequence may capture at most \(maximumFrames) frames; this one captures \(frames).",
                fix: "Remove screenshot steps so at most \(maximumFrames) remain — every frame is returned inline in one response.",
                details: ["screenshotSteps": .int(frames)])
        }
        let declared = request.steps.reduce(0) { $0 + $1.declaredTimeoutMs }
        guard declared <= maximumDeclaredWaitMs else {
            throw ToolError(
                code: "invalid_arguments",
                message: "Declared waits total \(declared) ms, above the \(maximumDeclaredWaitMs) ms a sequence may wait.",
                fix: "Lower the timeoutMs values so their total is \(maximumDeclaredWaitMs) ms or less; a sequence holds the simulator lease for its whole run.",
                details: ["declaredWaitMs": .int(declared)])
        }
    }

    /// The pre-lease ownership probe. `get_logs` takes no lease, so this is
    /// free — and it is the only place that can distinguish "this server never
    /// launched an app" from "the app is gone".
    @discardableResult
    private func requireOwnedRunningSession() async throws -> GetLogsResult {
        let page: GetLogsResult
        do {
            page = try await readLogs(nil, 1)
        } catch let error as ToolError where error.code == "no_current_session" {
            // The shipped fix says "Call run_app successfully", which would
            // restart the app and destroy the state the sequence exists to
            // exercise. Say something true for a sequence instead.
            throw ToolError(
                code: "sequence_session_unavailable",
                message: "No app session belonging to this server is running, so waitForLog cannot observe a marker.",
                fix: "Run the app through this same server with run_app, or remove the waitForLog steps and script only press and screenshot.")
        }
        guard page.state == "running" else {
            throw ToolError(
                code: "sequence_session_unavailable",
                message: "The app session for this server is \(page.state), so waitForLog cannot observe a marker.",
                fix: "Run the app again with run_app, or remove the waitForLog steps and script only press and screenshot.",
                details: [
                    "state": .string(page.state),
                    "crashDetected": .bool(page.crashDetected),
                ])
        }
        return page
    }

    // MARK: - Execution

    private struct StepProduct: Sendable {
        let outcome: SequenceStepOutcome
        let frame: SequenceFrame?
        let cursor: String?
        let carried: [LogLine]
    }

    private func execute(
        _ request: RunSequenceToolRequest,
        needsSession: Bool,
        context: OperationContext
    ) async throws -> SequenceRun {
        var outcomes: [SequenceStepOutcome] = []
        var frames: [SequenceFrame] = []
        var sessionId: Int?
        var cursor: String?
        var carried: [LogLine] = []
        let budget = makeDeadline(Self.totalBudget)

        if needsSession {
            // Re-asserted inside the lease: only run_app can replace a session
            // and it must hold this lease to do it, so this read is the
            // authoritative one, and its latestToken is the baseline no
            // pre-existing marker can satisfy.
            let baseline = try await requireOwnedRunningSession()
            sessionId = baseline.sessionId
            cursor = baseline.latestToken
        }

        for (index, step) in request.steps.enumerated() {
            do {
                let remaining = budget.remaining
                guard !budget.hasExpired, remaining > .zero else {
                    throw Self.budgetExhausted()
                }
                // Bound to immutable locals: the deadline closure is escaping
                // and @Sendable, so it cannot capture the loop's running state.
                let startCursor = cursor
                let startCarried = carried
                let product = try await ClockSupport.withDeadline(remaining, clock: clock) {
                    try await self.perform(
                        step, index: index, allowFocus: request.allowFocus,
                        context: context, cursor: startCursor, carried: startCarried)
                }
                outcomes.append(product.outcome)
                if let frame = product.frame { frames.append(frame) }
                cursor = product.cursor
                carried = product.carried
            } catch is CancellationError {
                // A cancelled call has no response to carry frames in, so
                // there is nothing to preserve. Unwind and let withOperation
                // release the lease.
                throw CancellationError()
            } catch {
                // Every other error is a step failure, including one no layer
                // below translated. Returning rather than throwing is what
                // keeps the frames: a thrown error reaches ToolRegistry, which
                // builds its own failure envelope with no content at all.
                return await failed(
                    step, at: index, of: request.steps, because: error,
                    outcomes: outcomes, frames: frames, sessionId: sessionId, context: context)
            }
        }

        return SequenceRun(
            result: SequenceResult(
                sessionId: sessionId, steps: outcomes, frameCount: frames.count),
            frames: frames,
            failure: nil)
    }

    private func perform(
        _ step: SequenceStep,
        index: Int,
        allowFocus: Bool,
        context: OperationContext,
        cursor: String?,
        carried: [LogLine]
    ) async throws -> StepProduct {
        switch step {
        case .screenshot(let label):
            let output = try await capture(context)
            return StepProduct(
                outcome: SequenceStepOutcome(
                    index: index, kind: step.kind, status: "completed", label: label,
                    path: output.result.path, width: output.result.width,
                    height: output.result.height),
                frame: SequenceFrame(stepIndex: index, label: label, png: output.png),
                cursor: cursor,
                carried: carried)

        case .press(let button, let holdMs):
            // The transport's identity comparison is intra-press: it retains
            // its snapshot at the top of the call, so it cannot catch a pid
            // reused between steps. Only the readiness probe ties a pid back
            // to a Connect IQ executable.
            try await revalidateBeforePress(context)
            let result = try await press(
                PressButtonToolRequest(button: button, holdMs: holdMs, allowFocus: allowFocus),
                context)
            return StepProduct(
                outcome: SequenceStepOutcome(
                    index: index, kind: step.kind, status: "completed",
                    button: result.button, pressType: result.pressType,
                    transport: result.transport),
                frame: nil,
                cursor: cursor,
                carried: carried)

        case .waitForLog(let contains, let timeoutMs):
            return try await waitForLog(
                contains: contains, timeoutMs: timeoutMs, index: index,
                cursor: cursor, carried: carried)
        }
    }

    private func revalidateBeforePress(_ context: OperationContext) async throws {
        do {
            try await revalidate(context)
        } catch let error as ToolError {
            // Those errors are phrased for sim_start/run_app and for a
            // monkeydo retry that this caller never issued. A fix must be
            // concrete for the operation that failed.
            throw ToolError(
                code: "sequence_simulator_changed",
                message: "The simulator stopped matching the one this sequence started against.",
                fix: "Check sim_status, run the app again if it exited, then rerun the sequence.",
                details: [
                    "cause": .string(error.code),
                    // sdk_mismatch names which SDK it found; dropping that
                    // repeats the diagnostic loss 905e76c was written to fix.
                    "causeMessage": .string(error.message),
                ])
        }
    }

    private func waitForLog(
        contains needle: String,
        timeoutMs: Int,
        index: Int,
        cursor: String?,
        carried: [LogLine]
    ) async throws -> StepProduct {
        let startedAt = elapsedMs()
        var scanned = 0
        var token = cursor
        let deadline = makeDeadline(.milliseconds(timeoutMs))

        // Lines retained from the page that satisfied an earlier wait. They sit
        // between that match and `cursor`, so nothing else will ever return
        // them.
        if let hit = carried.firstIndex(where: { $0.text.contains(needle) }) {
            scanned += hit + 1
            return StepProduct(
                outcome: Self.waitOutcome(
                    index: index, waitedMs: elapsedMs() - startedAt, scanned: scanned),
                frame: nil,
                cursor: cursor,
                carried: Array(carried.dropFirst(hit + 1)))
        }
        scanned += carried.count

        while true {
            let page = try await readLogs(token, Self.pollPageLimit)
            // Scan before the state check: a marker flushed by the child's own
            // exit still satisfies the wait.
            if let hit = page.lines.firstIndex(where: { $0.text.contains(needle) }) {
                scanned += hit + 1
                return StepProduct(
                    outcome: Self.waitOutcome(
                        index: index, waitedMs: elapsedMs() - startedAt, scanned: scanned),
                    frame: nil,
                    cursor: page.nextToken,
                    carried: Array(page.lines.dropFirst(hit + 1)))
            }
            scanned += page.lines.count
            // Advance on every poll. `logs` returns prefix(limit) from the
            // oldest unread line, so a cursor left in place cannot see past
            // one page however long it waits.
            token = page.nextToken
            guard page.state == "running" else {
                throw ToolError(
                    code: "sequence_app_exited",
                    message: "The app \(page.state) while waiting for '\(needle)'.",
                    fix: "Read get_logs for the crash output, fix the app, then run it again before rerunning the sequence.",
                    details: [
                        "contains": .string(needle),
                        "state": .string(page.state),
                        "crashDetected": .bool(page.crashDetected),
                        "exitCode": page.exitCode.map { JSONValue.int(Int($0)) } ?? .null,
                        "terminationReason": page.terminationReason.map(JSONValue.string) ?? .null,
                    ])
            }
            guard !deadline.hasExpired else {
                throw ToolError(
                    code: "sequence_marker_timeout",
                    message: "'\(needle)' did not appear within \(timeoutMs) ms (\(scanned) lines scanned).",
                    fix: "Confirm the app prints that marker with a trailing newline — an unterminated line is not yet a log line — or raise timeoutMs.",
                    details: [
                        "contains": .string(needle),
                        "timeoutMs": .int(timeoutMs),
                        "linesScanned": .int(scanned),
                        "waitedMs": .int(max(0, elapsedMs() - startedAt)),
                    ])
            }
            try await deadline.sleepUntilNextPoll(maximumInterval: Self.pollInterval)
        }
    }

    /// Builds the returned run for a failed step: the failure itself, every
    /// later step marked skipped, and the screen at the moment it failed.
    private func failed(
        _ step: SequenceStep,
        at index: Int,
        of steps: [SequenceStep],
        because error: any Error,
        outcomes: [SequenceStepOutcome],
        frames: [SequenceFrame],
        sessionId: Int?,
        context: OperationContext
    ) async -> SequenceRun {
        var outcomes = outcomes
        var frames = frames
        outcomes.append(Self.failedOutcome(step, index: index))
        outcomes.append(contentsOf: steps.enumerated()
            .dropFirst(index + 1)
            .map { Self.skippedOutcome($1, index: $0) })
        if let terminal = await terminalFrame(index: index, context: context) {
            frames.append(terminal)
        }
        return SequenceRun(
            result: SequenceResult(
                sessionId: sessionId, steps: outcomes, frameCount: frames.count),
            frames: frames,
            failure: Self.sequenceFailure(
                Self.translate(error), index: index, outcomes: outcomes))
    }

    /// Raw platform errors are translated at this boundary, never interpolated
    /// into a public message. An untranslated error reaching here is a defect
    /// in a layer below, so it is logged in full to stderr and reported with a
    /// stable code.
    private static func translate(_ error: any Error) -> ToolError {
        if let toolError = error as? ToolError { return toolError }
        if error is ClockSupport.DeadlineExceeded { return budgetExhausted() }
        Log.err("run_sequence step failed with an untranslated \(type(of: error)): "
            + String(reflecting: error))
        return ToolError(
            code: "internal_error",
            message: "A sequence step failed unexpectedly.",
            fix: "Run doctor, then retry the sequence. If it repeats, inspect the server stderr log.")
    }

    /// The screen at the moment of failure is the most diagnostic artifact, and
    /// the lease is still held. Bounded separately from the step budget, which
    /// is already spent by the time this runs, and a failed diagnostic capture
    /// must never replace the real error — so this swallows its own failure.
    private func terminalFrame(index: Int, context: OperationContext) async -> SequenceFrame? {
        do {
            let output = try await ClockSupport.withDeadline(
                Self.terminalCaptureBudget, clock: clock
            ) {
                try await capture(context)
            }
            return SequenceFrame(stepIndex: index, label: "post-failure", png: output.png)
        } catch {
            Log.err("run_sequence terminal capture failed: \(String(reflecting: error))")
            return nil
        }
    }

    // MARK: - Outcomes and errors

    private static func waitOutcome(index: Int, waitedMs: Int, scanned: Int) -> SequenceStepOutcome {
        SequenceStepOutcome(
            index: index, kind: "waitForLog", status: "completed",
            waitedMs: max(0, waitedMs), linesScanned: scanned)
    }

    private static func failedOutcome(_ step: SequenceStep, index: Int) -> SequenceStepOutcome {
        SequenceStepOutcome(index: index, kind: step.kind, status: "failed", label: step.label)
    }

    private static func skippedOutcome(_ step: SequenceStep, index: Int) -> SequenceStepOutcome {
        SequenceStepOutcome(index: index, kind: step.kind, status: "skipped", label: step.label)
    }

    /// Rendered from the constant so the message cannot drift from the bound,
    /// without interpolating a `Duration` (which prints "120.0 seconds").
    private static var budgetSeconds: Int {
        Int(totalBudget.components.seconds)
    }

    private static func budgetExhausted() -> ToolError {
        ToolError(
            code: "sequence_budget_exhausted",
            message: "The sequence exceeded its \(budgetSeconds) second budget.",
            fix: "Shorten the sequence or lower its timeoutMs values, then rerun it.")
    }

    /// Sequence keys are added to the step error's own details, never over
    /// them: a failing press carries button, simulatorPid and transportStage,
    /// and losing those inside a sequence would undo the diagnosis those
    /// details exist for.
    private static func sequenceFailure(
        _ error: ToolError, index: Int, outcomes: [SequenceStepOutcome]
    ) -> ToolError {
        var details = error.details ?? [:]
        details["failedStepIndex"] = .int(index)
        details["completedSteps"] = .int(outcomes.filter { $0.status == "completed" }.count)
        if let encoded = try? JSONEncoder().encode(outcomes),
            let value = try? JSONDecoder().decode(JSONValue.self, from: encoded) {
            details["steps"] = value
        }
        return ToolError(
            code: error.code, message: error.message, fix: error.fix, details: details)
    }
}

extension SequenceStep {
    /// Only a screenshot carries a caller-supplied label, and a failed or
    /// skipped step still reports the one it was asked for.
    var label: String? {
        if case .screenshot(let label) = self { return label }
        return nil
    }
}

extension SequenceService {
    /// The production composition. This factory owns the single decision that
    /// must never regress: both inner services are rebuilt per operation with
    /// **lease-free** runners that forward the context the sequence already
    /// holds. Handing either of them a controller-backed runner would nest
    /// `withOperation` inside `withOperation`, and `AsyncFIFO` is not
    /// reentrant — a 30 s stall ending in `simulator_busy`.
    ///
    /// Only the capturer and the button transports are injectable, so a test
    /// exercises this exact wiring rather than a copy of it.
    static func live(
        controller: SimulatorController,
        sessions: AppSessionManager,
        buttonDevices: [(profile: InputProfile, transports: [any ButtonPressing])],
        deviceCatalog: DeviceCatalog = DeviceCatalog(),
        makeCapturer: (@Sendable (PixelRect?) -> any ScreenshotCapturing)? = nil
    ) -> SequenceService {
        SequenceService(
            operationRunner: SequenceOperationRunner(controller: controller),
            capture: { context in
                try await ScreenshotService(
                    deviceCatalog: deviceCatalog,
                    operationRunner: .immediate(context: context),
                    makeCapturer: makeCapturer
                ).capture(savePath: nil)
            },
            press: { request, context in
                try await ButtonInputService(
                    devices: buttonDevices,
                    operationRunner: ButtonOperationRunner { _, _, body in
                        try await body(context)
                    }
                ).press(request)
            },
            readLogs: { token, limit in
                try await sessions.logs(sinceToken: token, limit: limit)
            },
            revalidate: { context in
                try await controller.revalidateReady(context, inside: .runSequence)
            })
    }
}
