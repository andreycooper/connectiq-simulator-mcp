import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("Task 7 live GUI menu evidence", .serialized)
struct Task7LiveMenuEvidenceTests {
    @Test("capture menu and shortcut attributes through serialized AX operation")
    func capture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sdkPath = environment["SIM_TASK7_SDK_PATH"],
            let outputPath = environment["SIM_TASK7_EVIDENCE_OUTPUT"]
        else { return }

        let sdk = try SdkLocator().resolve(explicitPath: sdkPath)
        let runner = Subprocess()
        let controller = SimulatorController(
            // live-readback: this gate runs only when SIM_TASK7_* are set,
            // against the real simulator — see
            // DeviceVerificationTests.unitTestsNeverReachTheWindowServer.
            queue: AsyncFIFO(), lease: .standard, runtimeStore: .standard,
            processRunner: runner, sessionStopper: NoSimulatorSessionStopper())
        let accessibility = LiveAXAccess()
        let captured = EvidenceBox()

        do {
            try await controller.withOperation(
                .simStart, requirement: .start(requested: sdk)) { context in
                    guard await accessibility.accessibilityTrusted() else {
                        throw ToolError(
                            code: "accessibility_denied",
                            message: "Accessibility permission is required for Task 7 AX evidence.",
                            fix: "Grant Accessibility to the installed stable simulator-mcp executable and retry.")
                    }
                    let application = try await accessibility.application(pid: context.simulatorPid)
                    try await accessibility.setMessagingTimeout(1, for: application)
                    let menuBar = try await requireElement(
                        attribute: "AXMenuBar", from: application, accessibility: accessibility)
                    let tree = try await captureMenuTreeRoot(menuBar, accessibility: accessibility)
                    await captured.set(Task7MenuEvidence(
                        schemaVersion: 1,
                        sdkVersion: sdk.version.description,
                        sdkRoot: sdk.root.path,
                        simulatorExecutable: sdk.simulatorApp.appending(path: "Contents/MacOS/simulator").path,
                        simulatorPid: context.simulatorPid,
                        serializedOperation: "SimulatorController.withOperation(\(SimOperation.simStart.rawValue))",
                        accessibilityTrusted: true,
                        rootAttribute: "AXMenuBar",
                        nodes: tree))
                }
            try await controller.withOperation(.simStop, requirement: .stop) { _ in () }
        } catch {
            _ = try? await controller.withOperation(.simStop, requirement: .stop) { _ in () }
            throw error
        }

        guard let evidence = await captured.value() else { throw EvidenceError.missing }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.replace(at: URL(fileURLWithPath: outputPath), with: encoder.encode(evidence))
    }
}

private struct Task7MenuEvidence: Codable, Sendable {
    let schemaVersion: Int
    let sdkVersion: String
    let sdkRoot: String
    let simulatorExecutable: String
    let simulatorPid: Int32
    let serializedOperation: String
    let accessibilityTrusted: Bool
    let rootAttribute: String
    let nodes: [Task7MenuNode]
}

private struct Task7MenuNode: Codable, Sendable {
    let role: String?
    let title: String?
    let attributes: [String: String]
    let children: [Task7MenuNode]
}

private enum EvidenceError: Error { case missing }

private actor EvidenceBox {
    private var stored: Task7MenuEvidence?
    func set(_ value: Task7MenuEvidence) { stored = value }
    func value() -> Task7MenuEvidence? { stored }
}

private func requireElement(
    attribute: String,
    from element: AXElementID,
    accessibility: LiveAXAccess
) async throws -> AXElementID {
    guard case .element(let value) = try await accessibility.copyAttribute(attribute, of: element)
    else { throw EvidenceError.missing }
    return value
}

private func captureMenuTree(
    _ element: AXElementID,
    accessibility: LiveAXAccess,
    depth: Int = 0,
    visited: inout Set<AXElementID>
) async throws -> Task7MenuNode {
    guard depth < 12, visited.insert(element).inserted else {
        return Task7MenuNode(role: nil, title: nil, attributes: ["truncated": "true"], children: [])
    }
    let names = [
        "AXRole", "AXTitle", "AXMenuItemCmdChar", "AXMenuItemCmdVirtualKey",
        "AXMenuItemCmdModifiers", "AXMenuItemMarkChar", "AXEnabled", "AXHelp",
        "AXDescription", "AXIdentifier"
    ]
    var values: [String: String] = [:]
    for name in names {
        let value = try await accessibility.copyAttribute(name, of: element)
        switch value {
        case .string(let string): values[name] = string
        case .bool(let bool): values[name] = String(bool)
        case .missing: values[name] = "<absent>"
        case .unsupportedType(let type): values[name] = "<unsupported:\(type)>"
        case .element, .elements: values[name] = "<non-scalar>"
        }
    }
    let children = try await accessibility.copyChildren(of: element)
    var childNodes: [Task7MenuNode] = []
    for child in children {
        childNodes.append(try await captureMenuTree(
            child, accessibility: accessibility, depth: depth + 1, visited: &visited))
    }
    return Task7MenuNode(
        role: values["AXRole"], title: values["AXTitle"], attributes: values, children: childNodes)
}

private extension Task7LiveMenuEvidenceTests {
    func captureMenuTreeRoot(_ element: AXElementID, accessibility: LiveAXAccess) async throws -> [Task7MenuNode] {
        var visited = Set<AXElementID>()
        return [try await captureMenuTree(element, accessibility: accessibility, visited: &visited)]
    }
}
