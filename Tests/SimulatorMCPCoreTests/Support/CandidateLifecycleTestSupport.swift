import Foundation
import SimulatorMCPCore

enum CandidateLifecycleEvent: Equatable, Sendable {
    case preInstallValidation
    case backup
    case verifyBackupDigest
    case installCandidate
    case verifyCandidate
    case runCandidateGate
    case candidateSucceeded
    case restoreExecutableAndResources
    case verifyRestoredDigest
    case verifyAllDeviceCapability
}

enum CandidateLifecycleFailurePoint: Sendable {
    case none
    case preInstall
    case candidateVerification
    case candidateGate
}

enum CandidateLifecycleTestError: Error {
    case preInstallFailed
    case invalidBackupDigest
    case candidateVerificationFailed
    case candidateGateFailed
}

/// Actor-backed fake for the Task 0 lifecycle contract. It models executable
/// and adjacent resource-bundle payloads as one transaction without touching a
/// live installation; Task 3 supplies the real signed installer/client.
actor CandidateLifecycleTestSupport {
    private(set) var events: [CandidateLifecycleEvent] = []
    private(set) var backupRetained = false
    private(set) var restoredToolNames: [String] = []
    private(set) var allDevicesFailClosed = false
    private(set) var installedResourcePresent: Bool
    private let initialDigestValid: Bool
    private let restoreDigestValid: Bool
    private let originalResourcePresent: Bool
    private var digestVerificationCount = 0

    init(
        initialDigestValid: Bool = true,
        restoreDigestValid: Bool = true,
        originalResourcePresent: Bool = false
    ) {
        self.initialDigestValid = initialDigestValid
        self.restoreDigestValid = restoreDigestValid
        self.originalResourcePresent = originalResourcePresent
        installedResourcePresent = originalResourcePresent
    }

    func runCandidate(failurePoint: CandidateLifecycleFailurePoint = .none) throws {
        events.append(.preInstallValidation)
        guard failurePoint != .preInstall else { throw CandidateLifecycleTestError.preInstallFailed }
        events.append(.backup)
        backupRetained = true
        try verifyBackupDigest()
        events.append(.installCandidate)
        installedResourcePresent = true
        events.append(.verifyCandidate)
        if failurePoint == .candidateVerification {
            try restore()
            throw CandidateLifecycleTestError.candidateVerificationFailed
        }
        events.append(.runCandidateGate)
        if failurePoint == .candidateGate {
            try restore()
            throw CandidateLifecycleTestError.candidateGateFailed
        }
        events.append(.candidateSucceeded)
    }

    private func restore() throws {
        try verifyBackupDigest()
        events.append(.restoreExecutableAndResources)
        // The adjacent SwiftPM bundle is one rollback payload with the binary:
        // restore a prior bundle, or remove the candidate-only bundle.
        installedResourcePresent = originalResourcePresent
        events.append(.verifyRestoredDigest)
        restoredToolNames = [
            "build", "doctor", "get_logs", "list_devices", "list_sdks", "run_app",
            "run_tests", "screenshot", "set_gps_position", "sim_start", "sim_status", "sim_stop",
        ]
        allDevicesFailClosed = true
        events.append(.verifyAllDeviceCapability)
    }

    private func verifyBackupDigest() throws {
        events.append(.verifyBackupDigest)
        digestVerificationCount += 1
        let valid = digestVerificationCount == 1 ? initialDigestValid : restoreDigestValid
        guard valid else { throw CandidateLifecycleTestError.invalidBackupDigest }
    }
}
