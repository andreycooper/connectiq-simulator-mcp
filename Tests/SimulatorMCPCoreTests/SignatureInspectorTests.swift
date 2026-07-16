import Foundation
import Testing

import SimulatorMCPCore

@Suite("SignatureInspector")
struct SignatureInspectorTests {
    @Test("stable fixture retains the full designated identity")
    func stableFixture() {
        let inspector = SignatureInspector { _ in
            SignatureMetadata(
                signed: true, adHoc: false, signingIdentifier: "com.example.simulator-mcp",
                teamIdentifier: "TEAM123", cdhash: Data([0x01, 0xab, 0xff]),
                designatedRequirement: "identifier \"com.example.simulator-mcp\" and anchor apple generic")
        }

        let report = inspector.inspect(executableURL: URL(fileURLWithPath: "/installed/simulator-mcp"))

        #expect(report.executablePath == "/installed/simulator-mcp")
        #expect(report.kind == .stable)
        #expect(report.signingIdentifier == "com.example.simulator-mcp")
        #expect(report.teamIdentifier == "TEAM123")
        #expect(report.cdhash == "01abff")
        #expect(report.designatedRequirement ==
            "identifier \"com.example.simulator-mcp\" and anchor apple generic")
    }

    @Test("ad-hoc and unsigned fixtures are classified as unhealthy identities")
    func unhealthyFixtures() {
        let url = URL(fileURLWithPath: "/tmp/simulator-mcp")
        let adHoc = SignatureInspector { _ in
            SignatureMetadata(signed: true, adHoc: true, signingIdentifier: "simulator-mcp")
        }.inspect(executableURL: url)
        let unsigned = SignatureInspector { _ in
            SignatureMetadata(signed: false, adHoc: false)
        }.inspect(executableURL: url)

        #expect(adHoc.kind == .adHoc)
        #expect(unsigned.kind == .unsigned)
    }

    @Test("missing optional Security fields never crash or become stable")
    func missingFields() {
        let report = SignatureInspector { _ in
            SignatureMetadata(signed: true, adHoc: false)
        }.inspect(executableURL: URL(fileURLWithPath: "/tmp/simulator-mcp"))

        #expect(report.kind == .adHoc)
        #expect(report.signingIdentifier == nil)
        #expect(report.teamIdentifier == nil)
        #expect(report.cdhash == nil)
        #expect(report.designatedRequirement == nil)
    }

    @Test("live Security inspection reports the actual current executable path")
    func liveInspectionUsesActualExecutable() {
        let executable = SignatureInspector.currentExecutableURL()
        let report = SignatureInspector().inspect(executableURL: executable)

        #expect(report.executablePath == executable.path)
    }
}
