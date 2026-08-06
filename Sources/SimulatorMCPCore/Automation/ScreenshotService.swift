import AppKit
import CoreGraphics
import Foundation
import ImageIO
import os
import ScreenCaptureKit
import UniformTypeIdentifiers

public protocol ScreenshotCapturing: Sendable {
    func captureWindow(pid: Int32) async throws -> CapturedPNG
}

public struct CapturedPNG: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let appDisplayRect: PixelRect?

    public init(data: Data, width: Int, height: Int, appDisplayRect: PixelRect?) {
        self.data = data
        self.width = width
        self.height = height
        self.appDisplayRect = appDisplayRect
    }
}

struct WindowCapture: Sendable {
    let png: Data
    let width: Int
    let height: Int
    let windowWidth: Double
    let windowHeight: Double
    let contentTopInset: Double

    init(
        png: Data,
        width: Int,
        height: Int,
        windowWidth: Double,
        windowHeight: Double,
        contentTopInset: Double = 0
    ) {
        self.png = png
        self.width = width
        self.height = height
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.contentTopInset = contentTopInset
    }
}

struct ScreenshotWindow: Equatable, Sendable {
    let id: UInt32
    let pid: Int32
    let layer: Int
    let isVisible: Bool
}

enum ScreenshotWindowSelector {
    static func select(_ windows: [ScreenshotWindow], pid: Int32) throws -> ScreenshotWindow {
        let candidates = windows.filter {
            $0.pid == pid && $0.layer == 0 && $0.isVisible
        }
        guard candidates.count == 1, let selected = candidates.first else {
            throw ToolError(
                code: "environment_missing",
                message: candidates.isEmpty
                    ? "No visible primary simulator window belongs to PID \(pid)."
                    : "Multiple visible primary simulator windows belong to PID \(pid).",
                fix: candidates.isEmpty
                    ? "Bring the Connect IQ simulator device window on screen, then retry screenshot."
                    : "Close extra Connect IQ simulator windows so exactly one device window remains, then retry screenshot.",
                details: [
                    "simulatorPid": .int(Int(pid)),
                    "candidateWindowIds": .array(candidates.map { .int(Int($0.id)) }),
                ])
        }
        return selected
    }
}

struct PNGEncoder: Sendable {
    private let finalize: @Sendable (CGImageDestination) -> Bool

    init(finalize: @escaping @Sendable (CGImageDestination) -> Bool = CGImageDestinationFinalize) {
        self.finalize = finalize
    }

    func encode(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil)
        else {
            throw encodingError("ImageIO could not create a PNG destination.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard finalize(destination) else {
            throw encodingError("ImageIO could not finalize the simulator PNG.")
        }
        return output as Data
    }

    private func encodingError(_ message: String) -> ToolError {
        ToolError(
            code: "internal_error", message: message,
            fix: "Retry screenshot. If it repeats, run doctor and inspect the server stderr log.")
    }
}

struct ScreenCaptureKitCapturer: ScreenshotCapturing {
    private let appDisplayRect: PixelRect?
    private let screenRecordingGranted: @Sendable () -> Bool
    private let capture: @Sendable (Int32) async throws -> WindowCapture
    private let clock: any Clock<Duration>

    init(appDisplayRect: PixelRect?) {
        self.init(
            appDisplayRect: appDisplayRect,
            screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
            capture: Self.liveCapture,
            clock: ContinuousClock())
    }

    init(
        appDisplayRect: PixelRect?,
        screenRecordingGranted: @escaping @Sendable () -> Bool,
        capture: @escaping @Sendable (Int32) async throws -> WindowCapture,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.appDisplayRect = appDisplayRect
        self.screenRecordingGranted = screenRecordingGranted
        self.capture = capture
        self.clock = clock
    }

    func captureWindow(pid: Int32) async throws -> CapturedPNG {
        guard screenRecordingGranted() else {
            throw ToolError(
                code: "screen_recording_denied",
                message: "Screen Recording permission is not granted for the MCP server or its responsible host.",
                fix: Permissions.grantInstructions(
                    settingsPath: Permissions.screenSettingsPath,
                    executablePath: SignatureInspector.currentExecutableURL().path))
        }

        let captured: WindowCapture
        do {
            captured = try await ClockSupport.withDeadline(
                .seconds(30), clock: clock
            ) {
                try await capture(pid)
            }
        } catch is ClockSupport.DeadlineExceeded {
            throw ToolError(
                code: "operation_timeout",
                message: "Simulator screenshot capture did not finish within 30 seconds.",
                fix: "Keep the simulator device window visible, run doctor, then retry screenshot.")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolError {
            throw error
        } catch {
            Log.err("ScreenCaptureKit capture failed: \(String(reflecting: error))")
            throw ToolError(
                code: "internal_error",
                message: "ScreenCaptureKit could not capture the simulator window.",
                fix: "Run doctor, confirm Screen Recording access, then retry screenshot.")
        }

        let scaledRect = try appDisplayRect.map {
            try ScreenshotGeometry.scale(
                $0,
                contentTopInset: captured.contentTopInset,
                windowWidth: captured.windowWidth,
                windowHeight: captured.windowHeight,
                capturedWidth: captured.width,
                capturedHeight: captured.height)
        }
        return CapturedPNG(
            data: captured.png, width: captured.width, height: captured.height,
            appDisplayRect: scaledRect)
    }

    private static func liveCapture(pid: Int32) async throws -> WindowCapture {
        // simulator-mcp is a headless CLI, so no AppKit lifecycle initializes
        // its WindowServer connection. ScreenCaptureKit invokes its completion
        // on an XPC queue, where SCContentFilter otherwise asserts inside
        // SLSGetDisplaysWithRect before CoreGraphics has been initialized.
        let contentTopInset = await MainActor.run {
            _ = CGMainDisplayID()
            return WindowContentGeometry.standardTitledTopInset()
        }

        let gate = CaptureCallbackGate<WindowCapture>()
        return try await gate.wait {
            SCShareableContent.getExcludingDesktopWindows(
                true, onScreenWindowsOnly: true
            ) { content, error in
                gate.startImage {
                    if let error { throw error }
                    guard let content else {
                        throw ToolError(
                            code: "internal_error",
                            message: "ScreenCaptureKit returned no shareable window inventory.",
                            fix: "Run doctor, keep the simulator window visible, then retry screenshot.")
                    }
                    let descriptors = content.windows.map {
                        ScreenshotWindow(
                            id: $0.windowID,
                            pid: $0.owningApplication?.processID ?? -1,
                            layer: $0.windowLayer,
                            isVisible: $0.isOnScreen)
                    }
                    let selected = try ScreenshotWindowSelector.select(descriptors, pid: pid)
                    guard let window = content.windows.first(where: { $0.windowID == selected.id }) else {
                        throw ToolError(
                            code: "internal_error",
                            message: "The selected simulator window disappeared before capture.",
                            fix: "Keep the simulator window open and retry screenshot.")
                    }

                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let info = SCShareableContent.info(for: filter)
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(
                        1, Int(ceil(window.frame.width * CGFloat(info.pointPixelScale))))
                    configuration.height = max(
                        1, Int(ceil(window.frame.height * CGFloat(info.pointPixelScale))))
                    configuration.showsCursor = false
                    configuration.capturesAudio = false
                    configuration.scalesToFit = false
                    let windowWidth = Double(window.frame.width)
                    let windowHeight = Double(window.frame.height)

                    SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: configuration
                    ) { image, error in
                        gate.finishImage {
                            if let error { throw error }
                            guard let image else {
                                throw ToolError(
                                    code: "internal_error",
                                    message: "ScreenCaptureKit returned no simulator image.",
                                    fix: "Keep the simulator window visible and retry screenshot.")
                            }
                            let png = try PNGEncoder().encode(image)
                            return WindowCapture(
                                png: png, width: image.width, height: image.height,
                                windowWidth: windowWidth,
                                windowHeight: windowHeight,
                                contentTopInset: contentTopInset)
                        }
                    }
                }
            }
        }
    }
}

/// ScreenCaptureKit's macOS 14 callback APIs have no cancellation token.
/// The lock orders cancellation with callback-stage registration. Advancing a
/// stage and incrementing `inFlight` is its linearization point; cancellation
/// records a terminal result that blocks later stages, but cannot resume the
/// continuation until already-started synchronous work decrements `inFlight`
/// to zero. External callbacks and PNG encoding run outside the non-reentrant
/// lock, so a framework completion may safely be delivered synchronously.
final class CaptureCallbackGate<Value: Sendable>: Sendable {
    private enum Stage: Sendable {
        case idle
        case inventory
        case image
        case encoding
    }

    private struct State: Sendable {
        var stage: Stage = .idle
        var inFlight = 0
        var continuation: CheckedContinuation<Value, Error>?
        var terminalResult: Result<Value, Error>?
    }

    private struct PendingCompletion: Sendable {
        let continuation: CheckedContinuation<Value, Error>
        let result: Result<Value, Error>

        func resume() {
            continuation.resume(with: result)
        }
    }

    private struct StartDecision: Sendable {
        let shouldStart: Bool
        let pending: PendingCompletion?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait(
        startInventory: @escaping @Sendable () -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let decision = state.withLock { state -> StartDecision in
                    if let result = state.terminalResult {
                        return StartDecision(
                            shouldStart: false,
                            pending: PendingCompletion(
                                continuation: continuation, result: result))
                    }
                    guard state.stage == .idle, state.continuation == nil else {
                        return StartDecision(
                            shouldStart: false,
                            pending: PendingCompletion(
                                continuation: continuation,
                                result: .failure(CancellationError())))
                    }

                    state.continuation = continuation
                    state.stage = .inventory
                    state.inFlight = 1
                    return StartDecision(shouldStart: true, pending: nil)
                }
                decision.pending?.resume()
                guard decision.shouldStart else { return }
                startInventory()
                endWork()
            }
        } onCancel: {
            cancel()
        }
    }

    /// Atomically advances inventory -> image and registers/starts the image
    /// callback before cancellation can finish the operation.
    func startImage(_ start: () throws -> Void) {
        guard beginWork(from: .inventory, to: .image) else { return }
        do {
            try start()
        } catch {
            record(.failure(error))
        }
        endWork()
    }

    /// Atomically claims the one encoding attempt. Cancellation may be recorded
    /// while encoding runs, but the continuation remains owned until encoding
    /// leaves the in-flight stage.
    func finishImage(_ encode: () throws -> Value) {
        guard beginWork(from: .image, to: .encoding) else { return }
        do {
            record(.success(try encode()))
        } catch {
            record(.failure(error))
        }
        endWork()
    }

    private func cancel() {
        let pending = state.withLock { state in
            recordLocked(state: &state, result: .failure(CancellationError()))
        }
        pending?.resume()
    }

    private func beginWork(from expected: Stage, to next: Stage) -> Bool {
        state.withLock { state in
            guard state.terminalResult == nil, state.stage == expected else {
                return false
            }
            state.stage = next
            state.inFlight += 1
            return true
        }
    }

    private func record(_ result: Result<Value, Error>) {
        let pending = state.withLock { state in
            recordLocked(state: &state, result: result)
        }
        pending?.resume()
    }

    private func endWork() {
        let pending = state.withLock { state -> PendingCompletion? in
            precondition(state.inFlight > 0, "unbalanced screenshot callback stage")
            state.inFlight -= 1
            return takeCompletionLocked(state: &state)
        }
        pending?.resume()
    }

    private func recordLocked(
        state: inout State,
        result: Result<Value, Error>
    ) -> PendingCompletion? {
        if state.terminalResult == nil {
            state.terminalResult = result
        }
        return takeCompletionLocked(state: &state)
    }

    private func takeCompletionLocked(state: inout State) -> PendingCompletion? {
        guard state.inFlight == 0,
            let result = state.terminalResult,
            let continuation = state.continuation
        else { return nil }
        state.continuation = nil
        return PendingCompletion(continuation: continuation, result: result)
    }
}

public struct ScreenshotOutput: Sendable {
    public let result: ScreenshotResult
    public let png: Data

    public init(result: ScreenshotResult, png: Data) {
        self.result = result
        self.png = png
    }
}

struct ScreenshotOperationRunner: Sendable {
    typealias Body = @Sendable (OperationContext) async throws -> ScreenshotOutput
    private let runBody: @Sendable (
        SimOperation, OperationRequirement, @escaping Body
    ) async throws -> ScreenshotOutput

    init(controller: SimulatorController) {
        runBody = { operation, requirement, body in
            try await controller.withOperation(
                operation, requirement: requirement, body: body)
        }
    }

    init(
        _ run: @escaping @Sendable (
            SimOperation, OperationRequirement, @escaping Body
        ) async throws -> ScreenshotOutput
    ) {
        runBody = run
    }

    func run(
        _ operation: SimOperation,
        requirement: OperationRequirement,
        body: @escaping Body
    ) async throws -> ScreenshotOutput {
        try await runBody(operation, requirement, body)
    }

    static func immediate(context: OperationContext) -> ScreenshotOperationRunner {
        ScreenshotOperationRunner { _, _, body in try await body(context) }
    }
}

public struct ScreenshotService: Sendable {
    private let operationRunner: ScreenshotOperationRunner
    private let displayRect: @Sendable (String) -> PixelRect?
    private let makeCapturer: @Sendable (PixelRect?) -> any ScreenshotCapturing
    private let deviceReadback: any DeviceObserving
    private let publisher: CapturePublisher

    public init(
        controller: SimulatorController,
        deviceCatalog: DeviceCatalog = DeviceCatalog(),
        deviceReadback: any DeviceObserving = DeviceReadback()
    ) {
        self.init(
            deviceCatalog: deviceCatalog,
            operationRunner: ScreenshotOperationRunner(controller: controller),
            deviceReadback: deviceReadback)
    }

    /// Live wiring with an injected runner, so a composing service can supply a
    /// lease-free runner without hand-copying `displayRect`/`makeCapturer` —
    /// two copies of that wiring would be free to drift apart.
    init(
        deviceCatalog: DeviceCatalog = DeviceCatalog(),
        operationRunner: ScreenshotOperationRunner,
        makeCapturer: (@Sendable (PixelRect?) -> any ScreenshotCapturing)? = nil,
        deviceReadback: any DeviceObserving = DeviceReadback(),
        publisher: CapturePublisher = CapturePublisher()
    ) {
        self.init(
            operationRunner: operationRunner,
            displayRect: { device in
                deviceCatalog.installedDevices().first { $0.deviceId == device }?.displayRect
            },
            makeCapturer: makeCapturer ?? { ScreenCaptureKitCapturer(appDisplayRect: $0) },
            deviceReadback: deviceReadback,
            publisher: publisher)
    }

    init(
        operationRunner: ScreenshotOperationRunner,
        displayRect: @escaping @Sendable (String) -> PixelRect?,
        makeCapturer: @escaping @Sendable (PixelRect?) -> any ScreenshotCapturing,
        deviceReadback: any DeviceObserving = DeviceReadback(),
        publisher: CapturePublisher = CapturePublisher()
    ) {
        self.operationRunner = operationRunner
        self.displayRect = displayRect
        self.makeCapturer = makeCapturer
        self.deviceReadback = deviceReadback
        self.publisher = publisher
    }

    public func capture(savePath: String?) async throws -> ScreenshotOutput {
        try await operationRunner.run(.screenshot, requirement: .currentReady) { context in
            let target = try publisher.resolveTarget(savePath)
            // Unchanged: always keyed by the requested/recorded device, never
            // by the observation below. Deriving it from the observation
            // would null it whenever the readback is unavailable but the
            // capture still succeeds (the readback requires `isVisible` too,
            // which capture does not), losing the rect this always had.
            let logicalDisplayRect = context.currentDevice.flatMap(displayRect)
            let captured = try await makeCapturer(logicalDisplayRect)
                .captureWindow(pid: context.simulatorPid)
            let path = try publisher.publish(captured.data, to: target)

            // Only these three identity fields come from the observation. A
            // capture never claims a device it did not observe.
            let observation = await deviceReadback.observe(simulatorPid: context.simulatorPid)
            let observedDevice: String? = {
                if case .device(let deviceId, _) = observation { return deviceId }
                return nil
            }()
            let observedDisplayName: String? = {
                if case .device(_, let displayName) = observation { return displayName }
                return nil
            }()
            let nativeResolution: DisplaySize? = observedDevice.flatMap(displayRect).map {
                DisplaySize(width: $0.width, height: $0.height)
            }

            return ScreenshotOutput(
                result: ScreenshotResult(
                    path: path.path,
                    mimeType: "image/png",
                    width: captured.width,
                    height: captured.height,
                    capturedPid: context.simulatorPid,
                    device: observedDevice,
                    deviceDisplayName: observedDisplayName,
                    nativeResolution: nativeResolution,
                    appDisplayRect: captured.appDisplayRect.map {
                        DisplayRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    }),
                png: captured.data)
        }
    }
}

@MainActor
enum WindowContentGeometry {
    static func standardTitledTopInset() -> Double {
        let frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let content = NSWindow.contentRect(forFrameRect: frame, styleMask: [.titled])
        return Double(frame.height - content.height)
    }
}

enum ScreenshotGeometry {
    static func scale(
        _ logical: PixelRect,
        contentTopInset: Double = 0,
        windowWidth: Double,
        windowHeight: Double,
        capturedWidth: Int,
        capturedHeight: Int
    ) throws -> PixelRect {
        guard contentTopInset.isFinite, contentTopInset >= 0,
            windowWidth.isFinite, windowHeight.isFinite,
            windowWidth > 0, windowHeight > 0,
            capturedWidth > 0, capturedHeight > 0,
            logical.width > 0, logical.height > 0
        else {
            throw invalidDisplayRect(logical)
        }

        let (logicalRight, rightOverflow) = logical.x.addingReportingOverflow(logical.width)
        let (logicalBottom, bottomOverflow) = logical.y.addingReportingOverflow(logical.height)
        guard !rightOverflow, !bottomOverflow else {
            throw invalidDisplayRect(logical)
        }

        let translatedTop = Double(logical.y) + contentTopInset
        let translatedBottom = Double(logicalBottom) + contentTopInset
        guard translatedTop.isFinite, translatedBottom.isFinite else {
            throw invalidDisplayRect(logical)
        }

        let scaleX = Double(capturedWidth) / windowWidth
        let scaleY = Double(capturedHeight) / windowHeight
        guard scaleX.isFinite, scaleY.isFinite,
            let left = scaledBound(
                Double(logical.x), scale: scaleX, upperBound: capturedWidth, rounding: floor),
            let top = scaledBound(
                translatedTop, scale: scaleY, upperBound: capturedHeight, rounding: floor),
            let right = scaledBound(
                Double(logicalRight), scale: scaleX, upperBound: capturedWidth, rounding: ceil),
            let bottom = scaledBound(
                translatedBottom, scale: scaleY, upperBound: capturedHeight, rounding: ceil)
        else {
            throw invalidDisplayRect(logical)
        }

        guard left < capturedWidth, top < capturedHeight, right > left, bottom > top else {
            throw invalidDisplayRect(logical)
        }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Rounds in floating point, validates the result, and clamps before any
    /// `Double`-to-`Int` conversion. Returning an existing integer bound also
    /// avoids the `Double(Int.max)` representation gap at the upper endpoint.
    private static func scaledBound(
        _ coordinate: Double,
        scale: Double,
        upperBound: Int,
        rounding: (Double) -> Double
    ) -> Int? {
        let product = coordinate * scale
        guard product.isFinite else { return nil }
        let rounded = rounding(product)
        guard rounded.isFinite else { return nil }
        if rounded <= 0 { return 0 }
        if rounded >= Double(upperBound) { return upperBound }
        guard rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }

    private static func invalidDisplayRect(_ rect: PixelRect) -> ToolError {
        ToolError(
            code: "environment_missing",
            message: "The current device display rectangle is outside the captured simulator window.",
            fix: "Reinstall or update the current Connect IQ device profile, run the app again, then retry screenshot.",
            details: [
                "x": .int(rect.x), "y": .int(rect.y),
                "width": .int(rect.width), "height": .int(rect.height),
            ])
    }
}
