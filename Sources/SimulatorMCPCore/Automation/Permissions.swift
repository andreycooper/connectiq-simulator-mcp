// ApplicationServices exposes kAXTrustedCheckOptionPrompt as an imported
// mutable C global even though callers only read the framework-owned CFString.
// Limit pre-concurrency interoperability to this file and keep the value local.
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

public enum SignatureKind: String, Codable, Equatable, Sendable {
    case unsigned
    case adHoc
    case stable
}

public struct PermissionStatus: Codable, Equatable, Sendable {
    public let granted: Bool
    public let prompted: Bool
    public let systemSettingsPath: String
    public let restartRequired: Bool

    public init(
        granted: Bool, prompted: Bool, systemSettingsPath: String,
        restartRequired: Bool
    ) {
        self.granted = granted
        self.prompted = prompted
        self.systemSettingsPath = systemSettingsPath
        self.restartRequired = restartRequired
    }
}

public struct PermissionReport: Equatable, Sendable {
    public let screenRecording: PermissionStatus
    public let accessibility: PermissionStatus

    public init(screenRecording: PermissionStatus, accessibility: PermissionStatus) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}

/// TCC preflight and explicit onboarding prompts. Prompt closures are async
/// solely to give tests a race-free actor seam; the live macOS calls are
/// synchronous and execute directly in the inherited task context.
public struct Permissions: Sendable {
    public static let screenSettingsPath =
        "System Settings > Privacy & Security > Screen & System Audio Recording"
    public static let accessibilitySettingsPath =
        "System Settings > Privacy & Security > Accessibility"

    private let screenPreflight: @Sendable () async -> Bool
    private let screenRequest: @Sendable () async -> Bool
    private let accessibilityPreflight: @Sendable () async -> Bool
    private let accessibilityRequest: @Sendable () async -> Bool

    public init() {
        self.init(
            screenPreflight: { CGPreflightScreenCaptureAccess() },
            screenRequest: { CGRequestScreenCaptureAccess() },
            accessibilityPreflight: { AXIsProcessTrusted() },
            accessibilityRequest: {
                let options = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            })
    }

    public init(
        screenPreflight: @escaping @Sendable () async -> Bool,
        screenRequest: @escaping @Sendable () async -> Bool,
        accessibilityPreflight: @escaping @Sendable () async -> Bool,
        accessibilityRequest: @escaping @Sendable () async -> Bool
    ) {
        self.screenPreflight = screenPreflight
        self.screenRequest = screenRequest
        self.accessibilityPreflight = accessibilityPreflight
        self.accessibilityRequest = accessibilityRequest
    }

    public func inspect(requestPermissions: Bool) async -> PermissionReport {
        let screenPreflightGranted = await screenPreflight()
        let accessibilityPreflightGranted = await accessibilityPreflight()

        let screenPrompted = requestPermissions && !screenPreflightGranted
        if screenPrompted { _ = await screenRequest() }

        let accessibilityPrompted = requestPermissions && !accessibilityPreflightGranted
        if accessibilityPrompted { _ = await accessibilityRequest() }

        return PermissionReport(
            screenRecording: PermissionStatus(
                granted: screenPreflightGranted, prompted: screenPrompted,
                systemSettingsPath: Self.screenSettingsPath,
                restartRequired: !screenPreflightGranted),
            accessibility: PermissionStatus(
                granted: accessibilityPreflightGranted, prompted: accessibilityPrompted,
                systemSettingsPath: Self.accessibilitySettingsPath,
                restartRequired: !accessibilityPreflightGranted))
    }
}

public struct DoctorProbeStatus: Equatable, Sendable {
    public let ok: Bool
    public let observed: String
    public let fix: String?

    public init(ok: Bool, observed: String, fix: String?) {
        self.ok = ok
        self.observed = observed
        self.fix = fix
    }
}

/// Pure diagnosis aggregator. Environment probes translate their own platform
/// failures into observations, so an unhealthy machine remains a successful,
/// structured doctor result rather than preventing doctor from running.
public struct DoctorService: Sendable {
    private let permissions: Permissions
    private let signatureInspector: SignatureInspector
    private let executableURL: @Sendable () -> URL
    private let sdkProbe: @Sendable () async -> DoctorProbeStatus
    private let javaProbe: @Sendable () async -> DoctorProbeStatus
    private let simulatorProbe: @Sendable () async -> DoctorProbeStatus
    private let installedExecutablePath: String

    public init(
        permissions: Permissions,
        signatureInspector: SignatureInspector,
        executableURL: @escaping @Sendable () -> URL,
        sdkProbe: @escaping @Sendable () async -> DoctorProbeStatus,
        javaProbe: @escaping @Sendable () async -> DoctorProbeStatus,
        simulatorProbe: @escaping @Sendable () async -> DoctorProbeStatus,
        installedExecutablePath: String
    ) {
        self.permissions = permissions
        self.signatureInspector = signatureInspector
        self.executableURL = executableURL
        self.sdkProbe = sdkProbe
        self.javaProbe = javaProbe
        self.simulatorProbe = simulatorProbe
        self.installedExecutablePath = installedExecutablePath
    }

    public func inspect(requestPermissions: Bool) async -> DoctorResult {
        let executable = executableURL().resolvingSymlinksInPath().standardizedFileURL
        let signature = signatureInspector.inspect(executableURL: executable)

        async let sdk = sdkProbe()
        async let java = javaProbe()
        async let simulator = simulatorProbe()
        let permissionReport = await permissions.inspect(requestPermissions: requestPermissions)
        let (sdkStatus, javaStatus, simulatorStatus) = await (sdk, java, simulator)

        let screen = permissionCheck(
            name: "screen_recording", status: permissionReport.screenRecording,
            executablePath: signature.executablePath)
        let accessibility = permissionCheck(
            name: "accessibility", status: permissionReport.accessibility,
            executablePath: signature.executablePath)
        let signatureHealthy = signature.kind == .stable
        let signatureCheck = DoctorCheck(
            name: "signature", ok: signatureHealthy,
            observed: signatureObservation(signature),
            fix: signatureHealthy ? nil
                : "Install a release build signed with a persistent code-signing identity; unsigned and ad-hoc builds do not retain TCC grants.")

        let installed = URL(fileURLWithPath: installedExecutablePath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let installHealthy = signature.executablePath == installed
        let installCheck = DoctorCheck(
            name: "install_path", ok: installHealthy,
            observed: signature.executablePath,
            fix: installHealthy ? nil
                : "Install and register the signed server at \(installed), then run doctor through that executable.")

        return DoctorResult(
            executablePath: signature.executablePath,
            signatureKind: signature.kind,
            signingIdentifier: signature.signingIdentifier,
            teamIdentifier: signature.teamIdentifier,
            cdhash: signature.cdhash,
            sdkFound: sdkStatus.ok,
            javaFound: javaStatus.ok,
            simulator: simulatorStatus.ok,
            screenRecording: permissionReport.screenRecording,
            accessibility: permissionReport.accessibility,
            responsibleProcessNote: "macOS may attribute TCC checks to the responsible MCP host process. Enable the exact executable path reported above; Task 17 verifies whether the signed binary or signed host app owns the grants.",
            checks: [
                check(name: "sdk", status: sdkStatus),
                check(name: "java", status: javaStatus),
                check(name: "simulator", status: simulatorStatus),
                screen, accessibility, signatureCheck, installCheck,
            ])
    }

    private func check(name: String, status: DoctorProbeStatus) -> DoctorCheck {
        DoctorCheck(name: name, ok: status.ok, observed: status.observed, fix: status.fix)
    }

    private func permissionCheck(
        name: String, status: PermissionStatus, executablePath: String
    ) -> DoctorCheck {
        let observed = status.granted
            ? "granted\(status.prompted ? " after an explicit request" : "")"
            : "denied\(status.prompted ? " after an explicit request" : "; no prompt requested")"
        let fix = status.restartRequired
            ? "Open \(status.systemSettingsPath), enable the exact executable \(executablePath), then fully restart the MCP host after changing the grant."
            : nil
        return DoctorCheck(name: name, ok: status.granted, observed: observed, fix: fix)
    }

    private func signatureObservation(_ report: SignatureReport) -> String {
        [
            "kind=\(report.kind.rawValue)",
            "identifier=\(report.signingIdentifier ?? "none")",
            "team=\(report.teamIdentifier ?? "none")",
            "cdhash=\(report.cdhash ?? "none")",
            "designatedRequirement=\(report.designatedRequirement ?? "none")",
        ].joined(separator: "; ")
    }
}
