import Foundation
import Testing

import SimulatorMCPCore

/// The parser is written against captured monkeydo transcripts only (see
/// Fixtures/transcripts/<sdk>/<run>/): raw sequence-numbered event streams
/// plus hand-reviewed expected.json per supported SDK. Both SDKs were
/// probed on this machine with the transcriptprobe fixture app before any
/// parser code existed. The error-path streams below are derived from the
/// captured events by minimal programmatic edits (a renamed test, an
/// altered count, an injected color code) — wording is never invented.
@Suite("TestTranscriptParser")
struct TestTranscriptParserTests {

    static let sdkVersions = ["8.4.1", "9.1.0"]

    // MARK: - Captured fixtures

    @Test(
        "captured full-suite transcripts parse to the hand-reviewed summary",
        arguments: sdkVersions)
    func testFullSuiteParsesExactly(sdkVersion: String) throws {
        let events = try loadEvents(sdkVersion, "full")
        let meta = try loadMeta(sdkVersion, "full")
        let expected = try loadExpected(sdkVersion, "full")

        let summary = try TestTranscriptParser.parse(events: events, exitCode: meta.exitCode)

        #expect(summary == expected)
        #expect(!summary.overallPassed)
        #expect(summary.perTest.count == 3)
    }

    @Test(
        "captured filtered transcripts parse to a passing summary",
        arguments: sdkVersions)
    func testFilteredRunParsesExactly(sdkVersion: String) throws {
        let events = try loadEvents(sdkVersion, "filtered")
        let meta = try loadMeta(sdkVersion, "filtered")
        let expected = try loadExpected(sdkVersion, "filtered")

        let summary = try TestTranscriptParser.parse(events: events, exitCode: meta.exitCode)

        #expect(summary == expected)
        #expect(summary.overallPassed)
        #expect(summary.perTest.map(\.name) == ["probe_pass"])
    }

    // MARK: - Exit code is diagnostic only

    @Test(
        "monkeydo's broken nonzero exit with a passing transcript still passes",
        arguments: sdkVersions)
    func testNonzeroExitWithPassingTranscriptPasses(sdkVersion: String) throws {
        // The captured filtered runs really did exit 1 on a PASSED
        // transcript (meta.json); assert the workaround explicitly.
        let events = try loadEvents(sdkVersion, "filtered")
        let meta = try loadMeta(sdkVersion, "filtered")
        #expect(meta.exitCode != 0, "the capture itself proves the exit-code bug")

        let summary = try TestTranscriptParser.parse(events: events, exitCode: meta.exitCode)

        #expect(summary.overallPassed)
        #expect(summary.failed == 0 && summary.errors == 0)
    }

    @Test("a zero exit with a failing transcript still fails")
    func testZeroExitWithFailingTranscriptFails() throws {
        let events = try loadEvents("9.1.0", "full")

        let summary = try TestTranscriptParser.parse(events: events, exitCode: 0)

        #expect(!summary.overallPassed)
        #expect(summary.failed == 1 && summary.errors == 1)
    }

    // MARK: - Invalid transcripts

    @Test(
        "a transcript truncated before the final summary is test_transcript_invalid",
        arguments: sdkVersions)
    func testTruncatedTranscriptIsInvalid(sdkVersion: String) throws {
        let events = try loadEvents(sdkVersion, "truncated")
        let expectedCode = try loadExpectedErrorCode(sdkVersion, "truncated")

        do {
            _ = try TestTranscriptParser.parse(events: events, exitCode: 1)
            Issue.record("truncated transcript must not parse")
        } catch let error as ToolError {
            #expect(error.code == expectedCode)
            #expect(!error.fix.isEmpty)
            requireLastLines(error, expectedToContain: "Ran 3 tests")
        }
    }

    @Test("an empty transcript is test_transcript_invalid")
    func testEmptyTranscriptIsInvalid() throws {
        do {
            _ = try TestTranscriptParser.parse(events: [], exitCode: 0)
            Issue.record("an empty transcript must not parse")
        } catch let error as ToolError {
            #expect(error.code == "test_transcript_invalid")
            #expect(!error.fix.isEmpty)
        }
    }

    @Test("a duplicate test name is test_transcript_invalid")
    func testDuplicateTestNameIsInvalid() throws {
        // Rename probe_fail to probe_pass everywhere: two executed blocks
        // and two RESULTS rows now share one name (with disagreeing
        // statuses); only the name was edited, no wording invented.
        let events = try loadEvents("9.1.0", "full").map { event in
            TranscriptEvent(
                seq: event.seq,
                stream: event.stream,
                line: event.line.replacingOccurrences(of: "probe_fail", with: "probe_pass"))
        }

        do {
            _ = try TestTranscriptParser.parse(events: events, exitCode: 1)
            Issue.record("duplicate test names must not parse")
        } catch let error as ToolError {
            #expect(error.code == "test_transcript_invalid")
            requireLastLines(error, expectedToContain: "FAILED (passed=1, failed=1, errors=1)")
        }
    }

    @Test("summary counts disagreeing with per-test statuses is test_transcript_invalid")
    func testCountDisagreementIsInvalid() throws {
        // Only the passed count digit is edited in the captured summary.
        let events = try loadEvents("9.1.0", "full").map { event in
            TranscriptEvent(
                seq: event.seq,
                stream: event.stream,
                line: event.line.replacingOccurrences(
                    of: "FAILED (passed=1, failed=1, errors=1)",
                    with: "FAILED (passed=2, failed=1, errors=1)"))
        }

        do {
            _ = try TestTranscriptParser.parse(events: events, exitCode: 1)
            Issue.record("count disagreement must not parse")
        } catch let error as ToolError {
            #expect(error.code == "test_transcript_invalid")
        }
    }

    @Test("a RESULTS row without its executed block is test_transcript_invalid")
    func testTableRowWithoutExecutedBlockIsInvalid() throws {
        // Drop probe_fail's execution block (separator, marker, log, FAIL)
        // but keep its RESULTS row: a torn transcript must not half-parse.
        let events = try loadEvents("9.1.0", "full").filter { event in
            !(5...8).contains(event.seq)
        }

        do {
            _ = try TestTranscriptParser.parse(events: events, exitCode: 1)
            Issue.record("a torn transcript must not parse")
        } catch let error as ToolError {
            #expect(error.code == "test_transcript_invalid")
        }
    }

    // MARK: - Message handling

    @Test("failure messages are preserved without terminal color codes")
    func testColorCodesAreStripped() throws {
        let events = try loadEvents("9.1.0", "full").map { event in
            TranscriptEvent(
                seq: event.seq,
                stream: event.stream,
                line: event.line.replacingOccurrences(
                    of: "Error: Array Out Of Bounds Error",
                    with: "\u{1B}[31mError: Array Out Of Bounds Error\u{1B}[0m"))
        }
        let expected = try loadExpected("9.1.0", "full")

        let summary = try TestTranscriptParser.parse(events: events, exitCode: 1)

        #expect(summary == expected)
        let errorTest = try #require(summary.perTest.last)
        let message = try #require(errorTest.message)
        #expect(!message.contains("\u{1B}"))
        #expect(message.contains("Error: Array Out Of Bounds Error"))
    }

    // MARK: - monkeydo argument shape

    @Test("no filter uses [\"-t\"]; a filter is passed as [\"-t\", filter]")
    func testMonkeydoTestArguments() {
        #expect(TestTranscriptParser.testArguments(filter: nil) == ["-t"])
        #expect(TestTranscriptParser.testArguments(filter: "probe_pass") == ["-t", "probe_pass"])
    }

    // MARK: - Fixture access

    private func fixtureDirectory(_ sdkVersion: String, _ run: String) -> URL {
        Bundle.module.resourceURL!
            .appending(path: "Fixtures/transcripts")
            .appending(path: sdkVersion)
            .appending(path: run)
    }

    private func loadEvents(_ sdkVersion: String, _ run: String) throws -> [TranscriptEvent] {
        let url = fixtureDirectory(sdkVersion, run).appending(path: "events.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(TranscriptEvent.self, from: Data(line.utf8))
        }
    }

    private struct Meta: Decodable {
        let exitCode: Int32
    }

    private func loadMeta(_ sdkVersion: String, _ run: String) throws -> Meta {
        let url = fixtureDirectory(sdkVersion, run).appending(path: "meta.json")
        return try JSONDecoder().decode(Meta.self, from: Data(contentsOf: url))
    }

    private func loadExpected(_ sdkVersion: String, _ run: String) throws -> TestSummary {
        let url = fixtureDirectory(sdkVersion, run).appending(path: "expected.json")
        return try JSONDecoder().decode(TestSummary.self, from: Data(contentsOf: url))
    }

    private struct ExpectedError: Decodable {
        let expectedErrorCode: String
    }

    private func loadExpectedErrorCode(_ sdkVersion: String, _ run: String) throws -> String {
        let url = fixtureDirectory(sdkVersion, run).appending(path: "expected.json")
        return try JSONDecoder().decode(ExpectedError.self, from: Data(contentsOf: url))
            .expectedErrorCode
    }

    /// Asserts the invalid-transcript error carries the last transcript
    /// lines in details, including `expected`.
    private func requireLastLines(_ error: ToolError, expectedToContain expected: String) {
        guard case .array(let lines)? = error.details?["lastLines"] else {
            Issue.record("test_transcript_invalid must carry details.lastLines")
            return
        }
        #expect(!lines.isEmpty)
        let texts = lines.compactMap { value -> String? in
            if case .string(let text) = value { return text }
            return nil
        }
        let containsExpected = texts.contains(where: { $0.contains(expected) })
        #expect(containsExpected, "lastLines should include the transcript tail")
    }
}
