import CoreGraphics
import Foundation
import Testing

@testable import SimulatorMCPCore

/// `NSWorkspace.frontmostApplication` is maintained from notifications
/// delivered on the main run loop. This server never pumps one, so that value
/// freezes at whatever was frontmost when the process started and every focus
/// proof built on it fails against a simulator that really is frontmost.
/// The replacement asks the window server directly on every call.
@Suite("Frontmost application")
struct FrontmostApplicationTests {
    private func window(layer: Int, pid: Int) -> [String: Any] {
        [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid]
    }

    @Test("the owner of the front normal-layer window is frontmost")
    func frontNormalWindowWins() {
        let windows = [window(layer: 0, pid: 4242), window(layer: 0, pid: 99)]
        #expect(FrontmostApplication.pid(inFrontOf: windows) == 4242)
    }

    @Test("menu bars, docks and overlays above the normal layer are skipped")
    func nonNormalLayersSkipped() {
        let windows = [
            window(layer: 25, pid: 11),
            window(layer: 24, pid: 12),
            window(layer: 0, pid: 4242),
        ]
        #expect(FrontmostApplication.pid(inFrontOf: windows) == 4242)
    }

    @Test("no normal-layer window means no frontmost application")
    func noNormalWindow() {
        #expect(FrontmostApplication.pid(inFrontOf: [window(layer: 25, pid: 11)]) == nil)
        #expect(FrontmostApplication.pid(inFrontOf: []) == nil)
    }

    @Test("entries missing a layer or owner are ignored rather than guessed")
    func malformedEntriesIgnored() {
        let windows: [[String: Any]] = [
            [kCGWindowOwnerPID as String: 7],
            [kCGWindowLayer as String: 0],
            window(layer: 0, pid: 4242),
        ]
        #expect(FrontmostApplication.pid(inFrontOf: windows) == 4242)
    }

    @Test("a non-positive owner pid is never reported as frontmost")
    func nonPositiveOwnerRejected() {
        #expect(FrontmostApplication.pid(inFrontOf: [window(layer: 0, pid: 0)]) == nil)
        #expect(FrontmostApplication.pid(inFrontOf: [window(layer: 0, pid: -3)]) == nil)
    }

    @Test("production never observes focus through the run-loop-cached workspace property")
    func productionUsesLiveObservation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // The controller no longer observes focus at all: activated start was
        // withdrawn, so only the input transport may.
        let controller = try String(
            contentsOf: root.appending(path: "Sources/SimulatorMCPCore/Sim/SimulatorController.swift"),
            encoding: .utf8)
        #expect(!controller.contains("frontmostApplication"))
        #expect(!controller.contains("FrontmostApplication"))

        let transport = try String(
            contentsOf: root.appending(
                path: "Sources/SimulatorMCPCore/Automation/FocusedKeyTransport.swift"),
            encoding: .utf8)
        #expect(
            !transport.contains("frontmostApplication"),
            "the transport reads the stale run-loop-cached frontmost application")
        #expect(transport.contains("FrontmostApplication.current()"))
        #expect(transport.contains("NSRunningApplication(processIdentifier: pid)?.isActive"))
    }

    @Test("activation raises the simulator without re-opening it through Launch Services")
    func activationUsesAccessibility() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(
                path: "Sources/SimulatorMCPCore/Automation/FocusedKeyTransport.swift"),
            encoding: .utf8)
        // Launch Services `openApplication` re-opens the bundle, which moves
        // key focus inside the simulator window and swallows Return. Setting
        // the accessibility frontmost attribute activates the app without
        // disturbing which control inside it is focused.
        #expect(source.contains("kAXFrontmostAttribute"))
        #expect(!source.contains("openApplication"))
        #expect(!source.contains("OpenConfiguration"))
    }
}
