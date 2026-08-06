import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("CapturePublisher")
struct CapturePublisherTests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "capture-publisher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a well-formed capture is published and its bytes round-trip")
    func publishesValidCapture() throws {
        let directory = try temporaryDirectory()
        let publisher = CapturePublisher(directory: directory)
        let data = validPNG(padding: 64)

        let url = try publisher.publish(data, savePath: nil)

        #expect(url.deletingLastPathComponent().path == directory.path)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("data too short to be a PNG is refused and leaves no file")
    func refusesShortData() throws {
        let directory = try temporaryDirectory()
        let publisher = CapturePublisher(directory: directory)

        let error = #expect(throws: ToolError.self) {
            _ = try publisher.publish(Data([0x89, 0x50, 0x4E, 0x47]), savePath: nil)
        }
        #expect(error?.code == "capture_write_short")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("data without a terminating IEND is refused and leaves no file")
    func refusesUnterminatedData() throws {
        let directory = try temporaryDirectory()
        let publisher = CapturePublisher(directory: directory)
        var data = validPNG(padding: 64)
        data.removeLast(4)

        let error = #expect(throws: ToolError.self) {
            _ = try publisher.publish(data, savePath: nil)
        }
        #expect(error?.code == "capture_write_short")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("a failed publication never deletes a caller's existing file")
    func failedPublishLeavesCallerFileIntact() throws {
        let directory = try temporaryDirectory()
        let existing = try temporaryDirectory().appending(path: "mine.png")
        try Data("previous".utf8).write(to: existing)
        let publisher = CapturePublisher(
            directory: directory,
            write: { data, url in try data.prefix(4).write(to: url) })

        _ = #expect(throws: ToolError.self) {
            _ = try publisher.publish(validPNG(padding: 64), savePath: existing.path)
        }
        // Presence alone would pass even if the bytes were destroyed; the
        // truncating write lands on a private staging file beside `existing`
        // (never on `existing` itself), and `AtomicFile.publish` only renames
        // that staging file over the target after its size is verified — so
        // a failed publish must leave both the caller's bytes and the
        // directory listing untouched.
        #expect(try Data(contentsOf: existing) == Data("previous".utf8))
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: existing.deletingLastPathComponent().path) == ["mine.png"])
    }

    @Test("a file that lands shorter than its data is refused")
    func refusesShortWriteOnDisk() throws {
        let directory = try temporaryDirectory()
        // The write hook truncates, standing in for whatever the real path does.
        let publisher = CapturePublisher(
            directory: directory,
            write: { data, url in try data.prefix(4).write(to: url) })

        let error = #expect(throws: ToolError.self) {
            _ = try publisher.publish(validPNG(padding: 64), savePath: nil)
        }
        #expect(error?.code == "capture_write_short")
        // Not `message.contains("4")`: the message also contains "84" (the
        // full image size), so that alone would pass without the observed
        // on-disk size ever appearing. Pin the actual detail instead.
        #expect(error?.details?["observedBytes"] == .int(4))
        // The truncated staging file must not survive the failure — nothing
        // is left behind in the managed directory for a caller to find.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("retention prunes the oldest files beyond the count bound")
    func prunesByCount() throws {
        let directory = try temporaryDirectory()
        let publisher = CapturePublisher(directory: directory, retainCount: 3)
        for _ in 0..<5 { _ = try publisher.publish(validPNG(padding: 8), savePath: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
    }

    @Test("retention prunes files older than the age bound")
    func prunesByAge() throws {
        let directory = try temporaryDirectory()
        // A UUID name, because retention only ever considers files it named.
        let stale = directory.appending(path: "\(UUID().uuidString).png")
        try validPNG(padding: 8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -90_000)], ofItemAtPath: stale.path)

        let publisher = CapturePublisher(directory: directory, retainFor: .seconds(86_400))
        _ = try publisher.publish(validPNG(padding: 8), savePath: nil)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("the just-published file is never pruned")
    func neverPrunesItsOwnPublication() throws {
        let directory = try temporaryDirectory()
        let publisher = CapturePublisher(directory: directory, retainCount: 1)
        let url = try publisher.publish(validPNG(padding: 8), savePath: nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a caller savePath bypasses the managed directory and its retention")
    func callerPathBypassesRetention() throws {
        let directory = try temporaryDirectory()
        let elsewhere = try temporaryDirectory().appending(path: "mine.png")
        let publisher = CapturePublisher(directory: directory, retainCount: 1)

        let url = try publisher.publish(validPNG(padding: 8), savePath: elsewhere.path)
        _ = try publisher.publish(validPNG(padding: 8), savePath: nil)
        _ = try publisher.publish(validPNG(padding: 8), savePath: nil)

        #expect(url.path == elsewhere.path)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test("retention never touches a file it did not create")
    func leavesForeignFilesAlone() throws {
        let directory = try temporaryDirectory()
        let foreign = directory.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: foreign)

        let publisher = CapturePublisher(directory: directory, retainCount: 1)
        _ = try publisher.publish(validPNG(padding: 8), savePath: nil)
        _ = try publisher.publish(validPNG(padding: 8), savePath: nil)

        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("a savePath whose parent does not exist is an argument error")
    func missingParentIsArgumentError() throws {
        let directory = try temporaryDirectory()
        let publisher = CapturePublisher(directory: directory)
        let error = #expect(throws: ToolError.self) {
            _ = try publisher.publish(validPNG(padding: 8), savePath: "/nope/nowhere/x.png")
        }
        #expect(error?.code == "invalid_arguments")
    }
}
