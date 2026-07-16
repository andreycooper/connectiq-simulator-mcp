import Foundation

// MARK: - Transcript input

/// One line of monkeydo output, tagged with the pipe it arrived on and a
/// global sequence number. The capture layer interleaves stdout and stderr
/// into a single seq-ordered stream; the parser consumes that order as-is.
public struct TranscriptEvent: Codable, Equatable, Sendable {
    public let seq: Int
    public let stream: LogStream
    public let line: String

    public init(seq: Int, stream: LogStream, line: String) {
        self.seq = seq
        self.stream = stream
        self.line = line
    }
}

// MARK: - Parsed results

/// The closed status vocabulary of one executed test, mapped from the bare
/// `PASS`/`FAIL`/`ERROR` marker lines in captured monkeydo transcripts.
public enum TestStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case error
}

/// One test's parsed outcome. `durationSeconds` is always `nil` today —
/// monkeydo prints no durations — but stays in the model so the wire shape
/// is stable if a future SDK adds them.
public struct PerTestResult: Codable, Equatable, Sendable {
    public let name: String
    public let status: TestStatus
    public let durationSeconds: Double?
    public let message: String?

    public init(name: String, status: TestStatus, durationSeconds: Double?, message: String?) {
        self.name = name
        self.status = status
        self.durationSeconds = durationSeconds
        self.message = message
    }
}

/// The parsed outcome of one `monkeydo … -t` run: the counts from the final
/// summary line plus per-test results in executed order.
public struct TestSummary: Codable, Equatable, Sendable {
    public let passed: Int
    public let failed: Int
    public let errors: Int
    public let overallPassed: Bool
    public let perTest: [PerTestResult]

    public init(passed: Int, failed: Int, errors: Int, overallPassed: Bool, perTest: [PerTestResult]) {
        self.passed = passed
        self.failed = failed
        self.errors = errors
        self.overallPassed = overallPassed
        self.perTest = perTest
    }
}

// MARK: - Parser

/// Parses monkeydo unit-test transcripts. Every pattern below was derived
/// from captured transcripts in
/// `Tests/SimulatorMCPCoreTests/Fixtures/transcripts/` (SDKs 8.4.1 and
/// 9.1.0 produce the identical shape), not from documentation.
///
/// The transcript is authoritative and monkeydo's exit code is not (an SDK
/// regex bug makes it return 1 on passing filtered runs — the captured
/// fixtures prove it), so `parse` never lets the exit code influence the
/// result. A transcript that cannot be fully cross-checked — executed
/// blocks against the RESULTS table against the final summary counts —
/// throws `test_transcript_invalid` rather than half-parsing.
public enum TestTranscriptParser {

    /// The monkeydo arguments that select unit-test mode: bare `-t` runs
    /// every test, `-t <filter>` runs the matching subset.
    public static func testArguments(filter: String?) -> [String] {
        guard let filter else { return ["-t"] }
        return ["-t", filter]
    }

    /// Parses an ordered transcript into a `TestSummary`.
    ///
    /// `exitCode` is diagnostic only and deliberately unused: monkeydo's
    /// exit code is unreliable, so validity is decided entirely by the
    /// transcript's own structure.
    public static func parse(events: [TranscriptEvent], exitCode: Int32?) throws -> TestSummary {
        let lines = events.map { stripAnsi($0.line) }

        guard !lines.isEmpty else {
            throw invalid(
                "The test transcript is empty — monkeydo produced no output.",
                lines: lines)
        }

        let executing = /^Executing test (.+)\.\.\.$/
        // Simulator logger lines (`DEBUG (19:07): probe_pass ran`) are app
        // logging, not failure content; they surface through get_logs.
        let logger = #/^(?:DEBUG|INFO|WARNING|ERROR) \(.*\): /#
        let tableHeader = /^Test:\s+Status:$/
        let ranTests = /^Ran \d+ tests?$/
        let finalSummary = /^(PASSED|FAILED) \(passed=(\d+), failed=(\d+), errors=(\d+)\)$/

        var blocks: [(name: String, status: TestStatus, content: [String])] = []
        var openName: String?
        var openContent: [String] = []
        var tableRows: [(name: String, status: TestStatus)] = []
        var summary: (word: String, passed: Int, failed: Int, errors: Int)?
        var inResults = false

        for line in lines {
            if inResults {
                if let match = line.wholeMatch(of: finalSummary) {
                    summary = (
                        word: String(match.1),
                        passed: Int(match.2) ?? 0,
                        failed: Int(match.3) ?? 0,
                        errors: Int(match.4) ?? 0
                    )
                    continue
                }
                if line == "RESULTS" { continue }
                if line.wholeMatch(of: tableHeader) != nil { continue }
                if line.wholeMatch(of: ranTests) != nil { continue }
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count == 2, let status = statusMarker(String(fields[1])) {
                    tableRows.append((name: String(fields[0]), status: status))
                }
                // Blank lines and anything else in the RESULTS section are
                // ignored; validity is decided by the cross-checks below.
                continue
            }

            if let name = openName {
                // Inside a block only the bare marker closes it; a block
                // whose marker was lost swallows the rest of the transcript
                // and fails the summary or table cross-check below.
                if let status = statusMarker(line) {
                    blocks.append((name: name, status: status, content: openContent))
                    openName = nil
                    openContent = []
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // skip blank content
                } else if line.firstMatch(of: logger) != nil {
                    // skip simulator logger lines
                } else {
                    openContent.append(line)
                }
                continue
            }

            if let match = line.wholeMatch(of: executing) {
                openName = String(match.1)
                continue
            }
            if !line.isEmpty, line.allSatisfy({ $0 == "=" }) {
                inResults = true
                continue
            }
            // Dash separators, blank lines, and preamble noise between
            // blocks are ignored.
        }

        return try crossCheck(blocks: blocks, tableRows: tableRows, summary: summary, lines: lines)
    }

    // MARK: - Cross-checking

    /// Validates executed blocks against the RESULTS table and the final
    /// summary line, then assembles the `TestSummary`. A truncated or torn
    /// transcript must never half-parse, so every relation is checked.
    private static func crossCheck(
        blocks: [(name: String, status: TestStatus, content: [String])],
        tableRows: [(name: String, status: TestStatus)],
        summary: (word: String, passed: Int, failed: Int, errors: Int)?,
        lines: [String]
    ) throws -> TestSummary {
        guard let summary else {
            throw invalid(
                "The transcript ended without a final PASSED/FAILED summary line.",
                lines: lines)
        }

        let blockNames = blocks.map(\.name)
        guard Set(blockNames).count == blockNames.count else {
            throw invalid(
                "The transcript executed the same test name more than once.",
                lines: lines)
        }
        let rowNames = tableRows.map(\.name)
        guard Set(rowNames).count == rowNames.count else {
            throw invalid(
                "The RESULTS table lists the same test name more than once.",
                lines: lines)
        }

        let rowStatus = Dictionary(uniqueKeysWithValues: tableRows.map { ($0.name, $0.status) })
        for block in blocks {
            guard let status = rowStatus[block.name] else {
                throw invalid(
                    "Test \(block.name) was executed but is missing from the RESULTS table.",
                    lines: lines)
            }
            guard status == block.status else {
                throw invalid(
                    "Test \(block.name) has status \(block.status.rawValue) in its executed block but a different status in the RESULTS table.",
                    lines: lines)
            }
        }
        let executedNames = Set(blockNames)
        for row in tableRows where !executedNames.contains(row.name) {
            throw invalid(
                "The RESULTS table lists test \(row.name) but the transcript has no executed block for it.",
                lines: lines)
        }

        let tally = (
            passed: blocks.count(where: { $0.status == .passed }),
            failed: blocks.count(where: { $0.status == .failed }),
            errors: blocks.count(where: { $0.status == .error })
        )
        guard tally == (summary.passed, summary.failed, summary.errors) else {
            throw invalid(
                "The final summary counts (passed=\(summary.passed), failed=\(summary.failed), errors=\(summary.errors)) disagree with the per-test statuses (passed=\(tally.passed), failed=\(tally.failed), errors=\(tally.errors)).",
                lines: lines)
        }

        let countsSayPassed = summary.failed == 0 && summary.errors == 0
        guard (summary.word == "PASSED") == countsSayPassed else {
            throw invalid(
                "The final \(summary.word) verdict disagrees with its own counts (failed=\(summary.failed), errors=\(summary.errors)).",
                lines: lines)
        }

        let perTest = blocks.map { block -> PerTestResult in
            let message: String?
            if block.status == .passed {
                message = nil
            } else {
                let joined = block.content.joined(separator: "\n")
                message = joined.isEmpty ? nil : joined
            }
            return PerTestResult(
                name: block.name,
                status: block.status,
                durationSeconds: nil,
                message: message)
        }

        return TestSummary(
            passed: summary.passed,
            failed: summary.failed,
            errors: summary.errors,
            overallPassed: summary.word == "PASSED",
            perTest: perTest)
    }

    // MARK: - Line helpers

    /// Removes ANSI CSI escape sequences (`ESC [` parameter bytes … final
    /// letter, e.g. `\u{1B}[31m`) so matching and messages are color-free.
    private static func stripAnsi(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        return line.replacing(/\u{1B}\[[0-9;:<=>?]*[a-zA-Z]/, with: "")
    }

    /// Maps a bare marker line (block terminator or RESULTS table status
    /// column) onto a status; anything else is `nil`.
    private static func statusMarker(_ text: String) -> TestStatus? {
        switch text {
        case "PASS": return .passed
        case "FAIL": return .failed
        case "ERROR": return .error
        default: return nil
        }
    }

    /// Builds the invalid-transcript error. Every throw carries the last
    /// stripped transcript lines so a caller can see how the run tore.
    private static func invalid(_ message: String, lines: [String]) -> ToolError {
        ToolError(
            code: "test_transcript_invalid",
            message: message,
            fix:
                "Re-run the tests — the simulator run was likely interrupted or its output truncated. If it recurs, check sim_status and get_logs for a crashed simulator or app.",
            details: ["lastLines": .array(lines.suffix(20).map { .string($0) })]
        )
    }
}
