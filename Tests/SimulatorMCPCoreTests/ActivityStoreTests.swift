import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("ActivityStore")
struct ActivityStoreTests {
    @Test("an active operation round-trips through the file")
    func activeRoundTrips() throws {
        let sandbox = try ActivitySandbox()
        defer { sandbox.tearDown() }
        let store = ActivityStore(activityFile: sandbox.activityFile)

        store.publish(operation: "press_button", startedAt: Date(timeIntervalSince1970: 1_785_932_487.5))

        let active = try #require(store.read())
        #expect(active.operation == "press_button")
        #expect(active.startedEpochSeconds == 1_785_932_487.5)
        #expect(active.owner.pid == getpid())
    }

    @Test("clear returns the store to idle")
    func clearReturnsToIdle() throws {
        let sandbox = try ActivitySandbox()
        defer { sandbox.tearDown() }
        let store = ActivityStore(activityFile: sandbox.activityFile)

        store.publish(operation: "screenshot", startedAt: Date())
        store.clear()

        #expect(store.read() == nil)
    }

    @Test("an idle envelope writes an explicit null rather than omitting the key")
    func idleWritesExplicitNull() throws {
        let sandbox = try ActivitySandbox()
        defer { sandbox.tearDown() }
        let store = ActivityStore(activityFile: sandbox.activityFile)

        store.clear()

        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: sandbox.activityFile)) as? [String: Any]
        let object = try #require(json)
        #expect(object["active"] is NSNull)
        #expect(object["schemaVersion"] as? Int == 1)
    }

    @Test("a lower and a higher schemaVersion both read as idle")
    func unsupportedVersionsReadAsIdle() throws {
        for version in [0, 2] {
            let sandbox = try ActivitySandbox()
            defer { sandbox.tearDown() }
            try Data(#"{"schemaVersion":\#(version),"active":null}"#.utf8)
                .write(to: sandbox.activityFile)

            #expect(ActivityStore(activityFile: sandbox.activityFile).read() == nil)
        }
    }

    @Test("corrupt and truncated input read as idle")
    func corruptInputReadsAsIdle() throws {
        for bytes in ["not json at all", #"{"schemaVersion":1,"active":{"opera"#] {
            let sandbox = try ActivitySandbox()
            defer { sandbox.tearDown() }
            try Data(bytes.utf8).write(to: sandbox.activityFile)

            #expect(ActivityStore(activityFile: sandbox.activityFile).read() == nil)
        }
    }

    @Test("a missing file reads as idle")
    func missingFileReadsAsIdle() throws {
        let sandbox = try ActivitySandbox()
        defer { sandbox.tearDown() }

        #expect(ActivityStore(activityFile: sandbox.activityFile).read() == nil)
    }

    @Test("a failing publish logs and does not propagate")
    func failingPublishIsSwallowed() throws {
        let sandbox = try ActivitySandbox()
        defer { sandbox.tearDown() }
        let recorder = MessageRecorder()
        let store = ActivityStore(
            activityFile: sandbox.activityFile,
            log: { recorder.record($0) },
            atomicPublish: { _, _ in
                throw ToolError(code: "internal_error", message: "boom", fix: "none")
            })

        store.publish(operation: "run_app", startedAt: Date())

        #expect(recorder.entries.count == 1)
        #expect(recorder.entries[0].contains("activity"))
        #expect(store.read() == nil)
    }

    @Test("the disabled store never writes and always reads idle")
    func disabledStoreIsInert() throws {
        let sandbox = try ActivitySandbox()
        defer { sandbox.tearDown() }
        let tracker = PublishTracker()
        let observed = try SimulatorMCPCore.DarwinProcessIdentityReader().snapshot(pid: getpid())
        let stableIdentity = try #require(observed).stableIdentity
        let disabledStore = ActivityStore(
            disabled: sandbox.activityFile,
            atomicPublish: { _, _ in tracker.recordCall() },
            selfIdentity: { stableIdentity })

        disabledStore.publish(operation: "sim_start", startedAt: Date())
        disabledStore.clear()

        #expect(tracker.callCount == 0)
        #expect(!FileManager.default.fileExists(atPath: sandbox.activityFile.path))
        #expect(disabledStore.read() == nil)
    }

    @Test("the recorded owner revalidates equal against a live snapshot of this process")
    func recordedOwnerIsSelf() throws {
        let sandbox = try ActivitySandbox()
        defer { sandbox.tearDown() }
        let store = ActivityStore(activityFile: sandbox.activityFile)

        store.publish(operation: "run_sequence", startedAt: Date())

        let active = try #require(store.read())
        // Qualified, and hoisted out of #require: see the Global Constraints.
        let observed = try SimulatorMCPCore.DarwinProcessIdentityReader().snapshot(pid: getpid())
        let live = try #require(observed)
        #expect(active.owner == live.stableIdentity)
        #expect(!active.owner.arguments.isEmpty)
    }
}

private struct ActivitySandbox {
    let directory: URL
    let activityFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "simulator-mcp-activity-tests-\(UUID().uuidString)")
        activityFile = directory.appending(path: "activity.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func tearDown() { try? FileManager.default.removeItem(at: directory) }
}

private final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }
}

private final class PublishTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordCall() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
