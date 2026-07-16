import Foundation
import Testing

import SimulatorMCPCore

/// The parser is written against captured transcripts only (see
/// Fixtures/compiler/<sdk>/): raw monkeyc bytes plus a hand-reviewed
/// expected.json per supported SDK. Both SDKs were probed on this machine
/// with the compilerprobe fixture before any regex existed.
@Suite("CompilerDiagnostics")
struct CompilerDiagnosticsTests {

    @Test("captured transcripts parse to the hand-reviewed diagnostics", arguments: ["8.4.1", "9.1.0"])
    func testCapturedTranscriptParsesExactly(sdkVersion: String) throws {
        let fixtureDir = Bundle.module.resourceURL!
            .appending(path: "Fixtures/compiler")
            .appending(path: sdkVersion)
        let stdout = try Data(contentsOf: fixtureDir.appending(path: "stdout.txt"))
        let stderr = try Data(contentsOf: fixtureDir.appending(path: "stderr.txt"))
        let expected = try JSONDecoder().decode(
            ExpectedTranscript.self,
            from: Data(contentsOf: fixtureDir.appending(path: "expected.json")))

        #expect(stdout.count == expected.stdoutBytes)

        let parsed = Compiler.parseDiagnostics(stdout: stdout, stderr: stderr)

        #expect(parsed.count == expected.diagnostics.count)
        for (index, (actual, wanted)) in zip(parsed, expected.diagnostics).enumerated() {
            #expect(actual.file == wanted.file, "diagnostic \(index) file")
            #expect(actual.line == wanted.line, "diagnostic \(index) line")
            #expect(actual.column == wanted.column, "diagnostic \(index) column")
            #expect(actual.severity.rawValue == wanted.severity, "diagnostic \(index) severity")
            #expect(actual.message == wanted.message, "diagnostic \(index) message")
        }
    }

    @Test("unparsed nonempty compiler lines become info diagnostics, not silence")
    func testUnparsedLinesBecomeInfo() throws {
        let stderr = Data(
            """
            Picked up JAVA_TOOL_OPTIONS: -Dsome.flag=1
            WARNING: fenix6xpro: /p/App.mc:3,1: Local variable 'x' is not used.
            something completely freeform
            """.utf8)

        let parsed = Compiler.parseDiagnostics(stdout: Data(), stderr: stderr)

        #expect(parsed.count == 3)
        #expect(parsed[0].severity == .info)
        #expect(parsed[0].message == "Picked up JAVA_TOOL_OPTIONS: -Dsome.flag=1")
        #expect(parsed[1].severity == .warning)
        #expect(parsed[1].file == "/p/App.mc")
        #expect(parsed[1].line == 3)
        #expect(parsed[1].column == 1)
        #expect(parsed[2].severity == .info)
        #expect(parsed[2].message == "something completely freeform")
    }

    @Test("a located line without a column still parses")
    func testLocatedLineWithoutColumn() throws {
        let stderr = Data("ERROR: fenix6xpro: /p/App.mc:12: Something broke.\n".utf8)

        let parsed = Compiler.parseDiagnostics(stdout: Data(), stderr: stderr)

        #expect(parsed.count == 1)
        #expect(parsed[0].severity == .error)
        #expect(parsed[0].file == "/p/App.mc")
        #expect(parsed[0].line == 12)
        #expect(parsed[0].column == nil)
        #expect(parsed[0].message == "Something broke.")
    }

    private struct ExpectedTranscript: Decodable {
        struct ExpectedDiagnostic: Decodable {
            let file: String?
            let line: Int?
            let column: Int?
            let severity: String
            let message: String
        }
        let exitCode: Int32
        let stdoutBytes: Int
        let diagnostics: [ExpectedDiagnostic]
    }
}
