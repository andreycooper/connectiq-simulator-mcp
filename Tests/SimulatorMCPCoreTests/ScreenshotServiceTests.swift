import Foundation
import CoreGraphics
import os
import Testing

@testable import SimulatorMCPCore

@Suite("ScreenshotService")
struct ScreenshotServiceTests {
    @Test("permission denial is actionable and never starts platform capture")
    func permissionDenied() async {
        let calls = CallCount()
        let capturer = ScreenCaptureKitCapturer(
            appDisplayRect: nil,
            screenRecordingGranted: { false },
            capture: { _ in
                await calls.increment()
                return WindowCapture(
                    png: Data([1]), width: 1, height: 1,
                    windowWidth: 1, windowHeight: 1)
            })

        await #expect(throws: ToolError.self) {
            try await capturer.captureWindow(pid: 42)
        }
        #expect(await calls.value == 0)
        do {
            _ = try await capturer.captureWindow(pid: 42)
        } catch let error as ToolError {
            #expect(error.code == "screen_recording_denied")
            #expect(error.fix.contains(Permissions.screenSettingsPath))
            // That the shared instructions are used at all. Their exact content
            // is pinned in PermissionsGrantInstructionsTests with fixed inputs;
            // asserting it here would only re-derive whatever executable is
            // running, which under `swift test` is the test helper.
            #expect(error.fix.contains("Command-Shift-G"))
            #expect(error.fix.contains("remove it with -"))
            #expect(error.fix.contains("restart the MCP host"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("one 30-second monotonic deadline bounds platform capture")
    func captureTimeout() async {
        let clock = FakeClock()
        let capturer = ScreenCaptureKitCapturer(
            appDisplayRect: nil,
            screenRecordingGranted: { true },
            capture: { _ in
                try await clock.sleep(for: .seconds(100))
                return WindowCapture(
                    png: Data([1]), width: 1, height: 1,
                    windowWidth: 1, windowHeight: 1)
            },
            clock: clock)
        let result = Task { () -> String in
            do {
                _ = try await capturer.captureWindow(pid: 42)
                return "success"
            } catch let error as ToolError {
                return error.code
            } catch {
                return "unexpected"
            }
        }
        for _ in 0..<10_000 where clock.pendingSleepCount < 2 { await Task.yield() }
        #expect(clock.pendingSleepCount == 2)
        clock.advance(by: .seconds(30))
        #expect(await result.value == "operation_timeout")
    }

    @Test("cancellation propagates and exits the screenshot operation")
    func cancellation() async throws {
        let temp = try TempScreenshot()
        defer { temp.remove() }
        let clock = FakeClock()
        let events = EventLog()
        let runner = ScreenshotOperationRunner { _, _, body in
            await events.append("operation:start")
            do {
                let value = try await body(operationContext(device: nil))
                await events.append("operation:end")
                return value
            } catch {
                await events.append("operation:end")
                throw error
            }
        }
        let service = ScreenshotService(
            operationRunner: runner,
            displayRect: { _ in nil },
            makeCapturer: { _ in ScreenCaptureKitCapturer(
                appDisplayRect: nil,
                screenRecordingGranted: { true },
                capture: { _ in
                    try await clock.sleep(for: .seconds(100))
                    return WindowCapture(
                        png: Data([1]), width: 1, height: 1,
                        windowWidth: 1, windowHeight: 1)
                },
                clock: clock) },
            deviceReadback: ScriptedReadback([]),
            publisher: CapturePublisher(directory: temp.root))
        let result = Task { () -> Bool in
            do {
                _ = try await service.capture(savePath: nil)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        for _ in 0..<10_000 where clock.pendingSleepCount < 2 { await Task.yield() }
        result.cancel()
        #expect(await result.value == true)
        for _ in 0..<10_000 {
            if await events.values.last == "operation:end" { break }
            await Task.yield()
        }
        #expect(await events.values == ["operation:start", "operation:end"])
    }

    @Test("a retained inventory callback cannot start capture after cancellation")
    func lateInventoryAfterCancellation() async throws {
        let gate = CaptureCallbackGate<Int>()
        let inventoryCallbacks = AsyncStream<RetainedCallback>.makeStream()
        let imageCallbacks = AsyncStream<RetainedCallback>.makeStream()
        let captureStarts = SynchronousCount()
        let encodeStarts = SynchronousCount()
        let completions = SynchronousCount()

        let result = Task { () -> String in
            defer { completions.increment() }
            do {
                _ = try await gate.wait {
                    inventoryCallbacks.continuation.yield {
                        gate.startImage {
                            captureStarts.increment()
                            imageCallbacks.continuation.yield {
                                gate.finishImage {
                                    encodeStarts.increment()
                                    return 1
                                }
                            }
                        }
                    }
                }
                return "success"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected"
            }
        }
        var iterator = inventoryCallbacks.stream.makeAsyncIterator()
        let lateInventory = try #require(await iterator.next())

        result.cancel()
        #expect(await result.value == "cancelled")
        lateInventory()
        lateInventory()

        #expect(captureStarts.value == 0)
        #expect(encodeStarts.value == 0)
        #expect(completions.value == 1)
    }

    @Test("a retained inventory callback cannot start capture after timeout")
    func lateInventoryAfterTimeout() async throws {
        let clock = FakeClock()
        let gate = CaptureCallbackGate<Int>()
        let inventoryCallbacks = AsyncStream<RetainedCallback>.makeStream()
        let captureStarts = SynchronousCount()
        let completions = SynchronousCount()

        let result = Task { () -> String in
            defer { completions.increment() }
            do {
                _ = try await ClockSupport.withDeadline(.seconds(30), clock: clock) {
                    try await gate.wait {
                        inventoryCallbacks.continuation.yield {
                            gate.startImage { captureStarts.increment() }
                        }
                    }
                }
                return "success"
            } catch is ClockSupport.DeadlineExceeded {
                return "timeout"
            } catch {
                return "unexpected"
            }
        }
        var iterator = inventoryCallbacks.stream.makeAsyncIterator()
        let lateInventory = try #require(await iterator.next())
        for _ in 0..<10_000 where clock.pendingSleepCount < 1 { await Task.yield() }
        #expect(clock.pendingSleepCount == 1)

        clock.advance(by: .seconds(30))
        #expect(await result.value == "timeout")
        lateInventory()
        lateInventory()

        #expect(captureStarts.value == 0)
        #expect(completions.value == 1)
    }

    @Test("a retained image callback cannot encode after cancellation")
    func lateImageAfterCancellation() async throws {
        let gate = CaptureCallbackGate<Int>()
        let inventoryCallbacks = AsyncStream<RetainedCallback>.makeStream()
        let imageCallbacks = AsyncStream<RetainedCallback>.makeStream()
        let captureStarts = SynchronousCount()
        let encodeStarts = SynchronousCount()
        let completions = SynchronousCount()

        let result = Task { () -> String in
            defer { completions.increment() }
            do {
                _ = try await gate.wait {
                    inventoryCallbacks.continuation.yield {
                        gate.startImage {
                            captureStarts.increment()
                            imageCallbacks.continuation.yield {
                                gate.finishImage {
                                    encodeStarts.increment()
                                    return 1
                                }
                            }
                        }
                    }
                }
                return "success"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected"
            }
        }
        var inventoryIterator = inventoryCallbacks.stream.makeAsyncIterator()
        let inventory = try #require(await inventoryIterator.next())
        inventory()
        var imageIterator = imageCallbacks.stream.makeAsyncIterator()
        let lateImage = try #require(await imageIterator.next())
        #expect(captureStarts.value == 1)

        result.cancel()
        #expect(await result.value == "cancelled")
        lateImage()
        lateImage()

        #expect(encodeStarts.value == 0)
        #expect(completions.value == 1)
    }

    @Test("synchronous nested capture callbacks do not deadlock the stage gate")
    func synchronousNestedCallbacks() async throws {
        let gate = CaptureCallbackGate<Int>()

        let value = Task {
            try await gate.wait {
                gate.startImage {
                    gate.finishImage { 42 }
                }
            }
        }

        await #expect(try value.value == 42)
    }

    @Test("window selection uses exact PID, visibility, and layer zero")
    func exactWindowSelection() throws {
        let windows = [
            ScreenshotWindow(id: 1, pid: 142, layer: 0, isVisible: true),
            ScreenshotWindow(id: 2, pid: 42, layer: 1, isVisible: true),
            ScreenshotWindow(id: 3, pid: 42, layer: 0, isVisible: false),
            ScreenshotWindow(id: 4, pid: 42, layer: 0, isVisible: true),
        ]
        #expect(try ScreenshotWindowSelector.select(windows, pid: 42).id == 4)
    }

    @Test("zero and multiple primary windows are actionable")
    func ambiguousWindows() {
        #expect(throws: ToolError.self) {
            try ScreenshotWindowSelector.select([], pid: 42)
        }
        #expect(throws: ToolError.self) {
            try ScreenshotWindowSelector.select([
                ScreenshotWindow(id: 1, pid: 42, layer: 0, isVisible: true),
                ScreenshotWindow(id: 2, pid: 42, layer: 0, isVisible: true),
            ], pid: 42)
        }
    }

    @Test("PNG destination finalization failure is actionable")
    func pngEncoderFailure() throws {
        let image = try #require(makeImage())
        let encoder = PNGEncoder(finalize: { _ in false })
        #expect(throws: ToolError.self) { try encoder.encode(image) }
    }

    @Test("one screenshot operation spans capture and atomic publication")
    func operationAndAtomicPublication() async throws {
        let temp = try TempScreenshot()
        defer { temp.remove() }
        let target = temp.root.appending(path: "shot.png")
        try Data("old".utf8).write(to: target)
        let events = EventLog()
        let context = operationContext(device: "fenix6xpro")
        let runner = ScreenshotOperationRunner { operation, requirement, body in
            await events.append("operation:\(operation.rawValue)")
            guard case .currentReady = requirement else {
                throw ToolError(code: "internal_error", message: "wrong requirement", fix: "Fix the test.")
            }
            let value = try await body(context)
            await events.append("operation:end")
            return value
        }
        let capturedData = validPNG(padding: 8)
        let service = ScreenshotService(
            operationRunner: runner,
            displayRect: { device in
                #expect(device == "fenix6xpro")
                return PixelRect(x: 1, y: 2, width: 3, height: 4)
            },
            makeCapturer: { rect in
                #expect(rect == PixelRect(x: 1, y: 2, width: 3, height: 4))
                return FakeCapturer(events: events, png: CapturedPNG(
                    data: capturedData, width: 10, height: 20,
                    appDisplayRect: PixelRect(x: 2, y: 4, width: 6, height: 8)))
            },
            deviceReadback: ScriptedReadback([]),
            publisher: CapturePublisher(directory: temp.root))

        let output = try await service.capture(savePath: target.path)

        // No "publish" event: publication now happens inside CapturePublisher,
        // which has no closure seam to record through — assert on the file it
        // wrote instead, below.
        #expect(await events.values == ["operation:screenshot", "capture", "operation:end"])
        #expect(output.png == capturedData)
        #expect(output.result.path == target.path)
        #expect(output.result.capturedPid == 42)
        #expect(output.result.appDisplayRect == DisplayRect(x: 2, y: 4, width: 6, height: 8))
        #expect(try Data(contentsOf: target) == capturedData)
        // The one case that pins the fallback shut: a real currentDevice
        // ("fenix6xpro") together with a dry readback. A capture must never
        // relabel itself with the *requested* device when the observation
        // fails — that is the exact defect this task exists to prevent (a
        // fenix6xpro frame silently filed as the requested device's
        // evidence). Only captureLeavesIdentityNullWhenUnobserved exercises
        // an unavailable readback elsewhere, and its context has no
        // currentDevice, so a `?? context.currentDevice` fallback there
        // yields nil either way and the assertion would hold vacuously.
        #expect(output.result.device == nil)
        #expect(output.result.deviceDisplayName == nil)
        #expect(output.result.nativeResolution == nil)
    }

    @Test("encoder failure retains an existing destination")
    func encoderFailureRetainsOldFile() async throws {
        let temp = try TempScreenshot()
        defer { temp.remove() }
        let target = temp.root.appending(path: "shot.png")
        let old = Data("old-png".utf8)
        try old.write(to: target)
        let service = ScreenshotService(
            operationRunner: ScreenshotOperationRunner.immediate(
                context: operationContext(device: nil)),
            displayRect: { _ in nil },
            makeCapturer: { _ in ThrowingCapturer() },
            deviceReadback: ScriptedReadback([]),
            publisher: CapturePublisher(directory: temp.root))

        await #expect(throws: ToolError.self) {
            try await service.capture(savePath: target.path)
        }
        #expect(try Data(contentsOf: target) == old)
    }

    @Test("a missing destination parent is rejected before capture")
    func missingParent() async throws {
        let temp = try TempScreenshot()
        defer { temp.remove() }
        let calls = CallCount()
        let service = ScreenshotService(
            operationRunner: ScreenshotOperationRunner.immediate(
                context: operationContext(device: nil)),
            displayRect: { _ in nil },
            makeCapturer: { _ in CountingCapturer(calls: calls) },
            deviceReadback: ScriptedReadback([]),
            publisher: CapturePublisher(directory: temp.root))
        let target = "/tmp/missing-\(UUID().uuidString)/shot.png"
        await #expect(throws: ToolError.self) {
            try await service.capture(savePath: target)
        }
        #expect(await calls.value == 0)
    }

    @Test("the default destination is a UUID PNG under the publisher's managed directory")
    func defaultDestination() async throws {
        let temp = try TempScreenshot()
        defer { temp.remove() }
        let service = ScreenshotService(
            operationRunner: ScreenshotOperationRunner.immediate(
                context: operationContext(device: nil)),
            displayRect: { _ in nil },
            makeCapturer: { _ in StaticCapturer() },
            deviceReadback: ScriptedReadback([]),
            publisher: CapturePublisher(directory: temp.root))

        let output = try await service.capture(savePath: nil)
        let outputURL = URL(fileURLWithPath: output.result.path)

        #expect(outputURL.deletingLastPathComponent().path == temp.root.path)
        #expect(outputURL.pathExtension == "png")
        #expect(UUID(uuidString: outputURL.deletingPathExtension().lastPathComponent) != nil)
        #expect(try Data(contentsOf: outputURL) == output.png)
    }

    @Test("display rectangle scales independently and clamps partial overflow")
    func displayRectScaling() throws {
        let logical = PixelRect(x: 76, y: 141, width: 280, height: 280)

        #expect(try ScreenshotGeometry.scale(
            logical, windowWidth: 500, windowHeight: 500,
            capturedWidth: 500, capturedHeight: 500
        ) == logical)
        #expect(try ScreenshotGeometry.scale(
            logical, windowWidth: 500, windowHeight: 500,
            capturedWidth: 1_000, capturedHeight: 1_000
        ) == PixelRect(x: 152, y: 282, width: 560, height: 560))
        #expect(try ScreenshotGeometry.scale(
            logical, contentTopInset: 32,
            windowWidth: 430, windowHeight: 656,
            capturedWidth: 860, capturedHeight: 1_312
        ) == PixelRect(x: 152, y: 346, width: 560, height: 560))
        #expect(try ScreenshotGeometry.scale(
            PixelRect(x: 450, y: 450, width: 100, height: 100),
            windowWidth: 500, windowHeight: 500,
            capturedWidth: 1_000, capturedHeight: 750
        ) == PixelRect(x: 900, y: 675, width: 100, height: 75))
    }

    @Test("a display rectangle wholly outside the captured window is rejected")
    func displayRectOutsideWindow() {
        #expect(throws: ToolError.self) {
            try ScreenshotGeometry.scale(
                PixelRect(x: 501, y: 0, width: 10, height: 10),
                windowWidth: 500, windowHeight: 500,
                capturedWidth: 1_000, capturedHeight: 1_000)
        }
    }

    @Test("extreme display coordinates return ToolError instead of trapping")
    func extremeDisplayCoordinates() {
        let rectangles = [
            PixelRect(x: Int.max, y: 0, width: 1, height: 1),
            PixelRect(x: Int.min, y: 0, width: 1, height: 1),
            PixelRect(x: 0, y: Int.max, width: 1, height: 1),
            PixelRect(x: 0, y: Int.min, width: 1, height: 1),
        ]

        for rectangle in rectangles {
            #expect(throws: ToolError.self) {
                try ScreenshotGeometry.scale(
                    rectangle,
                    windowWidth: 100,
                    windowHeight: 100,
                    capturedWidth: 100,
                    capturedHeight: 100)
            }
        }
    }

    @Test("overflowing display edges return ToolError instead of trapping")
    func overflowingDisplayEdges() {
        #expect(throws: ToolError.self) {
            try ScreenshotGeometry.scale(
                PixelRect(x: Int.max - 1, y: 0, width: 2, height: 1),
                windowWidth: 100,
                windowHeight: 100,
                capturedWidth: 100,
                capturedHeight: 100)
        }
        #expect(throws: ToolError.self) {
            try ScreenshotGeometry.scale(
                PixelRect(x: 0, y: Int.max - 1, width: 1, height: 2),
                windowWidth: 100,
                windowHeight: 100,
                capturedWidth: 100,
                capturedHeight: 100)
        }
    }

    @Test("extreme scale ratios return ToolError instead of trapping")
    func extremeDisplayScaleRatios() {
        #expect(throws: ToolError.self) {
            try ScreenshotGeometry.scale(
                PixelRect(x: 1, y: 1, width: 1, height: 1),
                windowWidth: Double.leastNonzeroMagnitude,
                windowHeight: Double.leastNonzeroMagnitude,
                capturedWidth: Int.max,
                capturedHeight: Int.max)
        }
    }

    @Test("invalid content top insets are rejected")
    func invalidContentTopInsets() {
        for inset in [-1.0, Double.infinity, Double.nan] {
            #expect(throws: ToolError.self) {
                try ScreenshotGeometry.scale(
                    PixelRect(x: 1, y: 1, width: 1, height: 1),
                    contentTopInset: inset,
                    windowWidth: 100,
                    windowHeight: 100,
                    capturedWidth: 100,
                    capturedHeight: 100)
            }
        }
    }

    @Test("captured PNG allows an unknown app display rectangle")
    func capturedPNGOptionalDisplayRect() throws {
        let capture = CapturedPNG(
            data: Data([1, 2, 3]), width: 2, height: 1, appDisplayRect: nil)
        #expect(capture.appDisplayRect == nil)

        let result = ScreenshotResult(
            path: "/tmp/shot.png", mimeType: "image/png", width: 2, height: 1,
            capturedPid: 42,
            device: nil, deviceDisplayName: nil, nativeResolution: nil,
            appDisplayRect: nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
            as? [String: Any]
        #expect(encoded?.keys.contains("appDisplayRect") == true)
        #expect(encoded?["appDisplayRect"] is NSNull)
        #expect(encoded?.keys.contains("device") == true)
        #expect(encoded?["device"] is NSNull)
        #expect(encoded?.keys.contains("deviceDisplayName") == true)
        #expect(encoded?["deviceDisplayName"] is NSNull)
        #expect(encoded?.keys.contains("nativeResolution") == true)
        #expect(encoded?["nativeResolution"] is NSNull)
    }

    @Test("a capture carries the observed device and its native resolution")
    func captureCarriesDeviceIdentity() async throws {
        let service = screenshotFixture(
            readback: ScriptedReadback([
                .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro")
            ]),
            devices: [
                InstalledDevice(
                    deviceId: "fenix6xpro", displayName: "fēnix 6X Pro", touch: false,
                    physicalKeyIds: [], displayRect: PixelRect(x: 76, y: 141, width: 280, height: 280))
            ])

        let output = try await service.capture(savePath: nil)

        #expect(output.result.device == "fenix6xpro")
        #expect(output.result.deviceDisplayName == "fēnix 6X Pro")
        #expect(output.result.nativeResolution == DisplaySize(width: 280, height: 280))
    }

    @Test("an unobservable device leaves the identity fields null, never guessed")
    func captureLeavesIdentityNullWhenUnobserved() async throws {
        let service = screenshotFixture(
            readback: ScriptedReadback([.unavailable(reason: .screenRecordingDenied)]),
            devices: [])

        let output = try await service.capture(savePath: nil)

        #expect(output.result.device == nil)
        #expect(output.result.deviceDisplayName == nil)
        #expect(output.result.nativeResolution == nil)
    }

    @Test("appDisplayRect stays keyed by the requested device, never the observed one")
    func appDisplayRectIgnoresObservation() async throws {
        // context.currentDevice ("fenix6xpro") and the observed device
        // ("fenix7s") disagree on purpose: appDisplayRect must still resolve
        // from the requested device, and the identity fields must still
        // resolve from the observed one — two independent lookups sharing
        // one `displayRect` closure.
        let devices = [
            InstalledDevice(
                deviceId: "fenix6xpro", displayName: "fēnix 6X Pro", touch: false,
                physicalKeyIds: [], displayRect: PixelRect(x: 76, y: 141, width: 280, height: 280)),
            InstalledDevice(
                deviceId: "fenix7s", displayName: "fēnix 7S", touch: false,
                physicalKeyIds: [], displayRect: PixelRect(x: 10, y: 20, width: 100, height: 100)),
        ]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "shot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = ScreenshotService(
            operationRunner: .immediate(context: operationContext(device: "fenix6xpro")),
            displayRect: { device in devices.first { $0.deviceId == device }?.displayRect },
            makeCapturer: { rect in StubCapturer(appDisplayRect: rect) },
            deviceReadback: ScriptedReadback([
                .device(deviceId: "fenix7s", displayName: "fēnix 7S")
            ]),
            publisher: CapturePublisher(directory: directory))

        let output = try await service.capture(savePath: nil)

        #expect(output.result.device == "fenix7s")
        #expect(output.result.nativeResolution == DisplaySize(width: 100, height: 100))
        // The requested device's rect (fenix6xpro), never the observed
        // device's (fenix7s) — StubCapturer echoes back whatever rect
        // makeCapturer was given, so this pins which lookup fed it.
        #expect(output.result.appDisplayRect == DisplayRect(x: 76, y: 141, width: 280, height: 280))
    }
}

private func screenshotFixture(
    readback: some DeviceObserving, devices: [InstalledDevice]
) -> ScreenshotService {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "shot-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return ScreenshotService(
        operationRunner: .immediate(context: operationContext(device: nil)),
        displayRect: { device in devices.first { $0.deviceId == device }?.displayRect },
        makeCapturer: { rect in StubCapturer(appDisplayRect: rect) },
        deviceReadback: readback,
        publisher: CapturePublisher(directory: directory))
}

private struct StubCapturer: ScreenshotCapturing {
    let appDisplayRect: PixelRect?
    func captureWindow(pid: Int32) async throws -> CapturedPNG {
        CapturedPNG(
            data: validPNG(padding: 8), width: 454, height: 454, appDisplayRect: appDisplayRect)
    }
}

private actor CallCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private typealias RetainedCallback = @Sendable () -> Void

private final class SynchronousCount: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { storage.withLock { $0 } }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}

private actor EventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private struct FakeCapturer: ScreenshotCapturing {
    let events: EventLog
    let png: CapturedPNG
    func captureWindow(pid: Int32) async throws -> CapturedPNG {
        #expect(pid == 42)
        await events.append("capture")
        return png
    }
}

private struct ThrowingCapturer: ScreenshotCapturing {
    func captureWindow(pid: Int32) async throws -> CapturedPNG {
        throw ToolError(
            code: "internal_error", message: "PNG encoding failed.",
            fix: "Retry screenshot. If it repeats, inspect server stderr.")
    }
}

private struct CountingCapturer: ScreenshotCapturing {
    let calls: CallCount
    func captureWindow(pid: Int32) async throws -> CapturedPNG {
        await calls.increment()
        return CapturedPNG(data: validPNG(padding: 8), width: 1, height: 1, appDisplayRect: nil)
    }
}

private struct StaticCapturer: ScreenshotCapturing {
    func captureWindow(pid: Int32) async throws -> CapturedPNG {
        CapturedPNG(data: validPNG(padding: 8), width: 1, height: 1, appDisplayRect: nil)
    }
}

private struct TempScreenshot {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "screenshot-tests-\(UUID().uuidString)")
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func operationContext(device: String?) -> OperationContext {
    OperationContext(
        simulatorPid: 42,
        sdk: SdkInfo(
            version: SemVer(major: 9, minor: 1, patch: 0),
            root: URL(fileURLWithPath: "/tmp/sdk"), source: .explicit),
        currentDevice: device,
        listeningEndpoints: [])
}

private func makeImage() -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytes = [UInt8](repeating: 255, count: 4)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
}
