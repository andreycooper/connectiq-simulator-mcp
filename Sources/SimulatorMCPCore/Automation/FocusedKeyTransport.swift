@preconcurrency import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import Carbon
@preconcurrency import CoreGraphics
import Foundation
import os

/// Qualification-only focused CGEvent delivery. All platform effects are
/// injected so lifecycle tests never change focus or post real events.
public struct FocusedKeyTransport: ButtonPressing, Sendable {
    public protocol Event: Sendable { func post() }

    enum Diagnostic: Equatable, Sendable, CustomStringConvertible {
        case roleCaptured(role: String, pid: pid_t)
        case activation(role: String, result: Bool)
        case activationIdentityMismatch(role: String, expectedPID: pid_t, callbackPID: pid_t)
        case frontmost(phase: String, pid: pid_t?, elapsedMilliseconds: Int64, polls: Int, final: Bool)
        case eventBoundary(phase: String, frontmostPID: pid_t?)
        case keyFocus(pid: pid_t, elapsedMilliseconds: Int64)
        case outcome(primary: String)

        var description: String {
            switch self {
            case .roleCaptured(let role, let pid):
                return "role_capture role=\(role) pid=\(pid)"
            case .activation(let role, let result):
                return "activation role=\(role) result=\(result)"
            case .activationIdentityMismatch(let role, let expectedPID, let callbackPID):
                return "activation_identity_mismatch role=\(role) expected_pid=\(expectedPID) callback_pid=\(callbackPID)"
            case .frontmost(let phase, let pid, let elapsed, let polls, let final):
                return "frontmost phase=\(phase) pid=\(pid.map(String.init) ?? "nil") elapsed_ms=\(elapsed) polls=\(polls) final=\(final)"
            case .eventBoundary(let phase, let pid):
                return "event_boundary phase=\(phase) frontmost_pid=\(pid.map(String.init) ?? "nil")"
            case .keyFocus(let pid, let elapsed):
                return "key_focus pid=\(pid) elapsed_ms=\(elapsed)"
            case .outcome(let primary):
                return "outcome primary=\(primary)"
            }
        }
    }

    typealias DiagnosticSink = @Sendable (Diagnostic) -> Void

    public final class KeyboardSource: @unchecked Sendable {
        public let id: String?
        public let enabled: Bool?
        fileprivate let raw: TISInputSource?

        public init(id: String?, enabled: Bool?) {
            self.id = id
            self.enabled = enabled
            raw = nil
        }

        fileprivate init(raw: TISInputSource) {
            id = nil
            enabled = nil
            self.raw = raw
        }
    }

    public struct Application: Equatable, Sendable {
        public let pid: pid_t
        public let bundleURL: URL
        public let executableURL: URL
        public let bundleIdentifier: String
        public let launchDate: Date
        public let isTerminated: Bool

        public init(
            pid: pid_t,
            bundleURL: URL,
            executableURL: URL,
            bundleIdentifier: String,
            launchDate: Date,
            isTerminated: Bool
        ) {
            self.pid = pid
            self.bundleURL = bundleURL
            self.executableURL = executableURL
            self.bundleIdentifier = bundleIdentifier
            self.launchDate = launchDate
            self.isTerminated = isTerminated
        }
    }

    public struct FocusRequestResult: Equatable, Sendable {
        public let callbackPID: pid_t?
        public let errorDescription: String?

        public init(callbackPID: pid_t?, errorDescription: String?) {
            self.callbackPID = callbackPID
            self.errorDescription = errorDescription
        }
    }

    public struct Dependencies: Sendable {
        public let currentInputSource: @Sendable () -> KeyboardSource?
        public let inputSourceID: @Sendable (KeyboardSource) -> String?
        public let inputSourceEnabled: @Sendable (KeyboardSource) -> Bool?
        public let postPermissionGranted: @Sendable () -> Bool
        public let application: @Sendable (pid_t) -> Application?
        public let frontmostPID: @Sendable () -> pid_t?
        public let requestFrontmost: @Sendable (Application) async throws -> FocusRequestResult
        /// Whether the application is the *active* application. Keys posted
        /// to the session tap are delivered to the active application, which
        /// is not always the owner of the frontmost window: a windowless app
        /// can be active while another app still owns the front window.
        public let isActive: @Sendable (pid_t) -> Bool
        /// Whether the application owns key focus, not merely frontmost
        /// order. The window server flips frontmost before the target's
        /// window becomes key; a key posted in that gap is delivered to the
        /// previously focused application and silently lost.
        public let hasKeyFocus: @Sendable (pid_t) -> Bool
        public let makeEvent: @Sendable (UInt16, Bool) -> (any Event)?

        public init(
            currentInputSource: @escaping @Sendable () -> KeyboardSource?,
            inputSourceID: @escaping @Sendable (KeyboardSource) -> String?,
            inputSourceEnabled: @escaping @Sendable (KeyboardSource) -> Bool?,
            postPermissionGranted: @escaping @Sendable () -> Bool,
            application: @escaping @Sendable (pid_t) -> Application?,
            frontmostPID: @escaping @Sendable () -> pid_t?,
            requestFrontmost: @escaping @Sendable (Application) async throws -> FocusRequestResult,
            isActive: @escaping @Sendable (pid_t) -> Bool,
            hasKeyFocus: @escaping @Sendable (pid_t) -> Bool,
            makeEvent: @escaping @Sendable (UInt16, Bool) -> (any Event)?
        ) {
            self.currentInputSource = currentInputSource
            self.inputSourceID = inputSourceID
            self.inputSourceEnabled = inputSourceEnabled
            self.postPermissionGranted = postPermissionGranted
            self.application = application
            self.frontmostPID = frontmostPID
            self.requestFrontmost = requestFrontmost
            self.isActive = isActive
            self.hasKeyFocus = hasKeyFocus
            self.makeEvent = makeEvent
        }

        public static let live = Dependencies(
            currentInputSource: {
                guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
                return KeyboardSource(raw: source)
            },
            inputSourceID: { source in
                if let id = source.id { return id }
                guard let raw = source.raw,
                      let value = TISGetInputSourceProperty(raw, kTISPropertyInputSourceID)
                else { return nil }
                return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
            },
            inputSourceEnabled: { source in
                if let enabled = source.enabled { return enabled }
                guard let raw = source.raw,
                      let value = TISGetInputSourceProperty(raw, kTISPropertyInputSourceIsEnabled)
                else { return nil }
                return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
            },
            postPermissionGranted: { CGPreflightPostEventAccess() },
            application: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid),
                      let bundleURL = app.bundleURL,
                      let executableURL = app.executableURL,
                      let bundleIdentifier = app.bundleIdentifier,
                      let launchDate = app.launchDate
                else { return nil }
                return Application(
                    pid: app.processIdentifier,
                    bundleURL: bundleURL,
                    executableURL: executableURL,
                    bundleIdentifier: bundleIdentifier,
                    launchDate: launchDate,
                    isTerminated: app.isTerminated)
            },
            frontmostPID: { FrontmostApplication.current() },
            requestFrontmost: { application in
                // Setting the accessibility frontmost attribute activates the
                // application in place. The Launch Services open route also
                // brings it forward, but it re-opens the bundle, which moves
                // key focus onto a control inside the simulator window and
                // silently swallows Return.
                let element = AXUIElementCreateApplication(application.pid)
                let error = AXUIElementSetAttributeValue(
                    element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                guard error == .success else {
                    return FocusRequestResult(
                        callbackPID: nil,
                        errorDescription: "AXUIElementSetAttributeValue(AXFrontmost) failed with \(error.rawValue)")
                }
                return FocusRequestResult(callbackPID: application.pid, errorDescription: nil)
            },
            isActive: { pid in
                // Constructed fresh on every call. NSWorkspace's cached
                // application list and its front-application property are
                // refreshed from main-run-loop notifications this server
                // never pumps, so both freeze at process start.
                NSRunningApplication(processIdentifier: pid)?.isActive == true
            },
            hasKeyFocus: { pid in
                let application = AXUIElementCreateApplication(pid)
                var focused: CFTypeRef?
                return AXUIElementCopyAttributeValue(
                    application, kAXFocusedWindowAttribute as CFString, &focused) == .success
                    && focused != nil
            },
            makeEvent: { keyCode, keyDown in
                guard let source = CGEventSource(stateID: .combinedSessionState),
                      let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
                else { return nil }
                return LiveEvent(event)
            })
    }

    /// `kVK_Shift`. The simulator consumes the first key event delivered
    /// after an app launches — reproducibly, and independent of elapsed time,
    /// window focus, or which button is sent. A modifier press absorbs that
    /// event: it reaches the window server like any key, but Connect IQ can
    /// never decode it as a device button, so it is safe to send before every
    /// press rather than tracking which app launch has already been warmed.
    static let warmUpKeyCode: UInt16 = 56

    public let kind: ButtonTransportKind = .focusedKeys
    public let requiresFocusOptIn = true
    private let profile: InputProfile
    private let keyboardLayoutPredicate: KeyboardLayoutPredicate
    private let dependencies: Dependencies
    private let sleep: @Sendable (Duration) async throws -> Void
    private let makeDeadline: @Sendable (Duration) -> ClockDeadline
    private let focusTimeout: Duration
    private let pollInterval: Duration
    private let diagnosticSink: DiagnosticSink
    private let elapsedMilliseconds: @Sendable () -> Int64

    public init(profile: QualifiedInputProfile, dependencies: Dependencies = .live) throws {
        try self.init(
            profile: profile, dependencies: dependencies, clock: ContinuousClock(),
            diagnosticSink: { _ in })
    }

    public init<C: Clock>(
        profile: QualifiedInputProfile,
        dependencies: Dependencies = .live,
        clock: C,
        focusTimeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(10)
    ) throws where C.Duration == Duration {
        try self.init(
            profile: profile, dependencies: dependencies, clock: clock,
            focusTimeout: focusTimeout, pollInterval: pollInterval, diagnosticSink: { _ in })
    }

    init<C: Clock>(
        profile: QualifiedInputProfile,
        dependencies: Dependencies = .live,
        clock: C,
        focusTimeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(10),
        diagnosticSink: @escaping DiagnosticSink
    ) throws where C.Duration == Duration {
        guard profile.profile.transport.kind == .focusedKeys else {
            throw ButtonInputTransportError.eventConstruction("focused profile required")
        }
        self.profile = profile.profile
        keyboardLayoutPredicate = profile.keyboardLayoutPredicate
        self.dependencies = dependencies
        sleep = { try await clock.sleep(for: $0) }
        makeDeadline = { ClockDeadline(clock: clock, timeout: $0) }
        self.focusTimeout = focusTimeout
        self.pollInterval = pollInterval
        self.diagnosticSink = diagnosticSink
        let origin = clock.now
        elapsedMilliseconds = {
            let components = origin.duration(to: clock.now).components
            return components.seconds * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
        }
    }

    public func press(_ request: ButtonPressRequest, context: OperationContext) async throws {
        try keyboardPreflight()
        guard dependencies.postPermissionGranted() else {
            throw ButtonInputTransportError.eventPostingDenied
        }
        guard let simulator = dependencies.application(context.simulatorPid),
              simulator.pid == context.simulatorPid,
              !simulator.isTerminated
        else {
            throw ButtonInputTransportError.workspaceActivation("simulator application unavailable")
        }
        guard let mapping = profile.transport.sdkEntries[context.sdk.version.description]?[request.button],
              case .int(let mappedCode)? = mapping["keyCode"],
              let keyCode = UInt16(exactly: mappedCode)
        else {
            throw ButtonInputTransportError.eventConstruction("validated key mapping unavailable")
        }

        diagnosticSink(.roleCaptured(role: "simulator", pid: simulator.pid))

        var primaryError: (any Error)?
        do {
            try Task.checkCancellation()

            // Construct the cleanup event before the key-down event and before
            // any visible activation. A failed construction cannot steal focus.
            guard let up = dependencies.makeEvent(keyCode, false),
                  let down = dependencies.makeEvent(keyCode, true),
                  let warmUpUp = dependencies.makeEvent(Self.warmUpKeyCode, false),
                  let warmUpDown = dependencies.makeEvent(Self.warmUpKeyCode, true)
            else { throw ButtonInputTransportError.eventConstruction("event construction failed") }

            let simulatorAlreadyFrontmost = isExactFrontmost(simulator)
            if !simulatorAlreadyFrontmost {
                try await requestFrontmost(simulator, role: "simulator")
                try await waitForFrontmost(simulator, phase: "simulator_activation")
            }
            try await waitForKeyFocus(simulator)
            try Task.checkCancellation()
            let downObservation = try requireExactFrontmost(simulator)
            diagnosticSink(.eventBoundary(
                phase: "immediately_before_down", frontmostPID: downObservation.frontmostPID))
            try Task.checkCancellation()
            warmUpDown.post()
            do {
                try await sleep(.milliseconds(profile.core.holdEncoding.minimumPressMs))
            } catch {
                warmUpUp.post()
                throw error
            }
            warmUpUp.post()
            try Task.checkCancellation()
            down.post()

            var upPosted = false
            do {
                // The key must stay down long enough for the simulator's event
                // loop to sample it. An explicit hold already exceeds that
                // floor; a short press would otherwise release in microseconds
                // and never be delivered at all.
                try await sleep(.milliseconds(
                    max(request.holdMs ?? 0, profile.core.holdEncoding.minimumPressMs)))
                try Task.checkCancellation()
                up.post()
                upPosted = true
                try Task.checkCancellation()
                let upObservation = try requireExactFrontmost(simulator)
                try Task.checkCancellation()
                diagnosticSink(.eventBoundary(
                    phase: "after_up", frontmostPID: upObservation.frontmostPID))
            } catch {
                if !upPosted {
                    up.post()
                    upPosted = true
                }
                // A failed post-up proof or cancellation still gets one
                // failure-side boundary observation. Keep it separate from
                // the primary error so cleanup diagnostics cannot mask it.
                diagnosticSink(.eventBoundary(
                    phase: "after_up", frontmostPID: dependencies.frontmostPID()))
                throw error
            }
        } catch {
            primaryError = error
        }

        diagnosticSink(.outcome(primary: primaryError == nil ? "success" : "failure"))

        if let primaryError { throw primaryError }
    }

    private func keyboardPreflight() throws {
        guard let source = dependencies.currentInputSource(),
              let id = dependencies.inputSourceID(source),
              let enabled = dependencies.inputSourceEnabled(source),
              (!keyboardLayoutPredicate.requiresEnabled || enabled),
              id == keyboardLayoutPredicate.inputSourceID
        else { throw ButtonInputTransportError.keyboardLayoutUnsupported }
    }

    private func requestFrontmost(_ application: Application, role: String) async throws {
        try Task.checkCancellation()
        let result = try await dependencies.requestFrontmost(application)
        try Task.checkCancellation()
        diagnosticSink(.activation(
            role: role,
            result: result.callbackPID != nil && result.errorDescription == nil))
        if let callbackPID = result.callbackPID, callbackPID != application.pid {
            diagnosticSink(.activationIdentityMismatch(
                role: role, expectedPID: application.pid, callbackPID: callbackPID))
            throw ButtonInputTransportError.workspaceActivation("frontmost callback identity mismatch")
        }
    }

    private func isExactFrontmost(_ retained: Application) -> Bool {
        exactFrontmostObservation(retained) != nil
    }

    private struct ExactFrontmostObservation: Sendable {
        let application: Application
        let frontmostPID: pid_t
    }

    private func exactFrontmostObservation(_ retained: Application) -> ExactFrontmostObservation? {
        guard let current = dependencies.application(retained.pid) else {
            return nil
        }
        guard isSameApplication(retained, current) else { return nil }
        guard dependencies.isActive(retained.pid) else { return nil }
        let frontmostPID = dependencies.frontmostPID() ?? retained.pid
        return ExactFrontmostObservation(application: current, frontmostPID: frontmostPID)
    }

    private func requireExactFrontmost(_ retained: Application) throws -> ExactFrontmostObservation {
        guard let current = dependencies.application(retained.pid) else {
            throw ButtonInputTransportError.workspaceActivation("retained application unavailable during focus transition")
        }
        guard isSameApplication(retained, current) else {
            throw ButtonInputTransportError.workspaceActivation("retained application identity changed during focus transition")
        }
        guard dependencies.isActive(retained.pid) else {
            throw ButtonInputTransportError.workspaceActivation("simulator is not the active application")
        }
        let frontmostPID = dependencies.frontmostPID() ?? retained.pid
        return ExactFrontmostObservation(application: current, frontmostPID: frontmostPID)
    }

    private func isSameApplication(_ retained: Application, _ current: Application) -> Bool {
        !retained.isTerminated
            && !current.isTerminated
            && retained.pid == current.pid
            && retained.bundleURL == current.bundleURL
            && retained.executableURL == current.executableURL
            && retained.bundleIdentifier == current.bundleIdentifier
            && retained.launchDate == current.launchDate
    }

    /// Frontmost order and key focus are separate transitions. Posting on the
    /// first without the second loses the event to the application that is
    /// still key, which is the long-standing "first keystroke after activation
    /// is swallowed" behavior. This is a probe, never a fixed delay.
    private func waitForKeyFocus(_ retained: Application) async throws {
        let deadline = makeDeadline(focusTimeout)
        while true {
            try Task.checkCancellation()
            if dependencies.hasKeyFocus(retained.pid) {
                diagnosticSink(.keyFocus(pid: retained.pid, elapsedMilliseconds: elapsedMilliseconds()))
                return
            }
            guard !deadline.hasExpired else {
                throw ButtonInputTransportError.workspaceActivation("simulator never took key focus")
            }
            try await deadline.sleepUntilNextPoll(maximumInterval: pollInterval)
        }
    }

    private func waitForFrontmost(_ retained: Application, phase: String) async throws {
        let deadline = makeDeadline(focusTimeout)
        var polls = 0
        var lastObservation: pid_t??
        while true {
            try Task.checkCancellation()
            guard let current = dependencies.application(retained.pid) else {
                throw ButtonInputTransportError.workspaceActivation("retained application unavailable during focus transition")
            }
            guard isSameApplication(retained, current) else {
                throw ButtonInputTransportError.workspaceActivation("retained application identity changed during focus transition")
            }
            let observation = dependencies.frontmostPID()
            polls += 1
            if lastObservation == nil || lastObservation! != observation {
                diagnosticSink(.frontmost(
                    phase: phase, pid: observation, elapsedMilliseconds: elapsedMilliseconds(),
                    polls: polls, final: false))
                lastObservation = .some(observation)
            }
            try Task.checkCancellation()
            if dependencies.isActive(retained.pid) {
                diagnosticSink(.frontmost(
                    phase: phase, pid: observation, elapsedMilliseconds: elapsedMilliseconds(),
                    polls: polls, final: true))
                return
            }
            guard !deadline.hasExpired else {
                diagnosticSink(.frontmost(
                    phase: phase, pid: observation, elapsedMilliseconds: elapsedMilliseconds(),
                    polls: polls, final: true))
                throw ButtonInputTransportError.workspaceActivation("frontmost application poll timed out")
            }
            try await deadline.sleepUntilNextPoll(maximumInterval: pollInterval)
        }
    }
}

private final class LiveEvent: FocusedKeyTransport.Event, @unchecked Sendable {
    private let event: CGEvent
    init(_ event: CGEvent) { self.event = event }
    func post() { event.post(tap: .cgSessionEventTap) }
}
