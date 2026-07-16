import Foundation
import Testing

import SimulatorMCPCore

private let signatureExecutable =
    ProcessInfo.processInfo.environment["SIM_SIGNATURE_EXECUTABLE"]

@Suite(
    "Installed signature verification",
    .enabled(if: signatureExecutable != nil),
    .serialized)
struct InstalledSignatureVerificationTests {
    @Test("the selected executable has SignatureInspector stable identity")
    func stableIdentity() throws {
        let path = try #require(signatureExecutable)
        let report = SignatureInspector().inspect(
            executableURL: URL(fileURLWithPath: path))

        #expect(report.kind == .stable)
        #expect(report.signingIdentifier?.isEmpty == false)
        #expect(report.designatedRequirement?.isEmpty == false)
    }
}
