import Foundation

@testable import SimulatorMCPCore

/// Pops one scripted observation per call, so a test can say "loaded as
/// fenix6xpro before launch, fenix7s after" in one line. Runs dry as
/// `.unavailable(reason: .noSimulatorWindow)`.
actor ScriptedReadback: DeviceObserving {
    private var script: [DeviceObservation]
    private(set) var calls = 0
    /// Every `simulatorPid` this double was actually called with, in order.
    /// The observation hinges entirely on this argument — `DeviceReadback`
    /// filters windows by it — so a caller passing the wrong pid (or `0`)
    /// would still get a scripted answer from this double and look correct.
    /// Recorded so a test can assert on it rather than trust the caller.
    private(set) var observedPids: [pid_t] = []

    init(_ script: [DeviceObservation]) { self.script = script }

    func observe(simulatorPid: pid_t) async -> DeviceObservation {
        calls += 1
        observedPids.append(simulatorPid)
        return script.isEmpty ? .unavailable(reason: .noSimulatorWindow) : script.removeFirst()
    }
}
