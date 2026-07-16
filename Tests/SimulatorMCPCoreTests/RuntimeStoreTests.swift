import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("RuntimeStore")
struct RuntimeStoreTests {
    @Test("schema 2 round-trips complete stable monkeydo ownership")
    func schema2OwnershipRoundTrip() throws {
        let sandbox = try RuntimeSandbox()
        defer { sandbox.tearDown() }
        let store = RuntimeStore(runtimeFile: sandbox.runtimeFile)
        let ownership = PersistedMonkeydoOwnership(
            launcher: StableProcessIdentity(
                pid: 4321,
                processGroupId: 4321,
                start: ProcessStartIdentity(seconds: 1_700_000_000, microseconds: 42),
                executablePath: "/bin/bash",
                arguments: ["/bin/bash", "/SDK/bin/monkeydo", "/tmp/App.prg", "fenix6xpro"]),
            launcherParentPid: 4000,
            sdkPath: "/SDK",
            prgPath: "/tmp/App.prg",
            device: "fenix6xpro",
            testFilter: nil,
            ownerServerInstance: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let record = RuntimeRecord(
            simulatorPid: 1234,
            executablePath: "/SDK/bin/ConnectIQ.app/Contents/MacOS/simulator",
            sdkPath: "/SDK",
            sdkVersion: "9.1.0",
            currentDevice: "fenix6xpro",
            monkeydoOwnership: ownership)

        try store.write(record)

        #expect(store.read() == record)
        let header = try JSONDecoder().decode(
            RuntimeHeader.self, from: Data(contentsOf: sandbox.runtimeFile))
        #expect(header.schemaVersion == 2)
    }

    @Test("schema 1 is diagnosed as unsupported before its record shape is decoded")
    func schema1IsUnsupportedNotCorrupt() throws {
        let sandbox = try RuntimeSandbox()
        defer { sandbox.tearDown() }
        let messages = MessageRecorder()
        let store = RuntimeStore(runtimeFile: sandbox.runtimeFile, log: messages.record)
        try Data("{\"schemaVersion\":1,\"record\":{\"legacy\":true}}".utf8)
            .write(to: sandbox.runtimeFile)

        #expect(store.read() == nil)
        #expect(messages.entries.count == 1)
        #expect(messages.entries[0].contains("unsupported schemaVersion 1"))
        #expect(!messages.entries[0].contains("corrupt"))
    }

    @Test("schema 2 record without monkeydo ownership round-trips")
    func testRoundTrip() throws {
        let sandbox = try RuntimeSandbox()
        defer { sandbox.tearDown() }
        let store = RuntimeStore(runtimeFile: sandbox.runtimeFile)
        let record = sampleRecord(device: "fenix6xpro", monkeydoPid: 4321)

        try store.write(record)

        #expect(store.read() == record)
        let envelope = try JSONDecoder().decode(
            RuntimeEnvelope.self, from: Data(contentsOf: sandbox.runtimeFile))
        #expect(envelope == RuntimeEnvelope(schemaVersion: 2, record: record))
    }

    @Test("clear atomically writes an explicit null record and never unlinks runtime.json")
    func testClearWritesNullWithoutUnlinking() throws {
        let sandbox = try RuntimeSandbox()
        defer { sandbox.tearDown() }
        let store = RuntimeStore(runtimeFile: sandbox.runtimeFile)
        try store.write(sampleRecord())

        try store.clear()

        #expect(FileManager.default.fileExists(atPath: sandbox.runtimeFile.path))
        #expect(store.read() == nil)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: sandbox.runtimeFile))
                as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object.keys.contains("record"))
        #expect(object["record"] is NSNull)
    }

    @Test("corrupt and unsupported runtime envelopes are ignored with stderr diagnostics")
    func testCorruptRuntimeIgnoredWithDiagnostic() throws {
        let sandbox = try RuntimeSandbox()
        defer { sandbox.tearDown() }
        let messages = MessageRecorder()
        let store = RuntimeStore(runtimeFile: sandbox.runtimeFile, log: messages.record)

        try Data("{torn".utf8).write(to: sandbox.runtimeFile)
        #expect(store.read() == nil)

        let unsupported = RuntimeEnvelope(schemaVersion: 99, record: sampleRecord())
        try JSONEncoder().encode(unsupported).write(to: sandbox.runtimeFile)
        #expect(store.read() == nil)

        let entries = messages.entries
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.contains("runtime.json") })
        #expect(entries[0].contains("ignored corrupt runtime state"))
        #expect(entries[1].contains("unsupported schemaVersion"))
    }

    @Test("concurrent atomic readers never decode partial JSON")
    func testAtomicReaderNeverSeesPartialJSON() async throws {
        let sandbox = try RuntimeSandbox()
        defer { sandbox.tearDown() }
        let messages = MessageRecorder()
        let store = RuntimeStore(runtimeFile: sandbox.runtimeFile, log: messages.record)
        try store.write(sampleRecord(device: "seed"))
        let stop = AtomicFlag()
        let observations = ObservationCounter()

        let reader = Task {
            while !stop.value {
                if store.read() != nil { observations.increment() }
                await Task.yield()
            }
        }

        for index in 0..<500 {
            try store.write(sampleRecord(device: "device-\(index)", monkeydoPid: Int32(index)))
            await Task.yield()
        }
        stop.set()
        await reader.value

        #expect(observations.value > 0)
        #expect(messages.entries.isEmpty, "atomic rename must never expose partial JSON")
        #expect(store.read()?.currentDevice == "device-499")
    }

    @Test("raw atomic publication failures become stable internal_error")
    func testRawPublicationFailureIsTranslated() throws {
        let sandbox = try RuntimeSandbox()
        defer { sandbox.tearDown() }
        let messages = MessageRecorder()
        let rawError = RawPublicationError(marker: "private-publication-failure")
        let reflected = String(reflecting: rawError)
        let store = RuntimeStore(
            runtimeFile: sandbox.runtimeFile,
            log: messages.record,
            atomicPublish: { _, _ in throw rawError })

        do {
            try store.write(sampleRecord())
            Issue.record("raw publication failure must be translated")
        } catch let error as ToolError {
            #expect(error.code == "internal_error")
            #expect(!error.message.isEmpty)
            #expect(!error.fix.isEmpty)
            #expect(error.details?["runtimeFile"] == .string(sandbox.runtimeFile.path))
            #expect(error.details?["underlyingError"] == nil)
            #expect(!error.message.contains(reflected))
        }
        #expect(messages.entries.count == 1)
        #expect(messages.entries.first?.contains(reflected) == true)
    }
}

private struct RawPublicationError: Error {
    let marker: String
}

private func sampleRecord(
    device: String? = nil,
    monkeydoPid: Int32? = nil
) -> RuntimeRecord {
    let ownership = monkeydoPid.map { pid in
        PersistedMonkeydoOwnership(
            launcher: StableProcessIdentity(
                pid: pid, processGroupId: pid,
                start: ProcessStartIdentity(seconds: 1, microseconds: UInt64(pid)),
                executablePath: "/bin/bash",
                arguments: ["/bin/bash", "/Users/test/connectiq-sdk-mac-9.1.0/bin/monkeydo",
                    "/tmp/app.prg", "fenix6xpro"]),
            launcherParentPid: 100,
            sdkPath: "/Users/test/connectiq-sdk-mac-9.1.0",
            prgPath: "/tmp/app.prg",
            device: device ?? "fenix6xpro",
            testFilter: nil,
            ownerServerInstance: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    }
    return RuntimeRecord(
        simulatorPid: 1234,
        executablePath: "/Applications/ConnectIQ.app/Contents/MacOS/simulator",
        sdkPath: "/Users/test/connectiq-sdk-mac-9.1.0",
        sdkVersion: "9.1.0",
        currentDevice: device,
        monkeydoOwnership: ownership)
}

private struct RuntimeSandbox {
    let directory: URL
    let runtimeFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "simulator-mcp-runtime-tests-\(UUID().uuidString)")
        runtimeFile = directory.appending(path: "runtime.json")
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

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }
}

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
