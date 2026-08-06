import AppKit
import Dispatch
import SimulatorMCPCore

@MainActor
final class MenuApplicationDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var timer: DispatchSourceTimer?
    private var previous: MonitorState?
    private let resolver = MonitorStateResolver()
    private let queue = DispatchQueue(label: "dev.simulator-mcp.menu.poll")
    // Main-thread-only, so no lock is needed. A resolve can take up to 250 ms
    // (the identity probe's own budget) -- exactly the timer's own period --
    // so without this latch a slow resolve leaves the previous one still
    // in-flight when the next tick fires, and the queue backs up faster than
    // it drains with no bound on how far the icon's lag can grow.
    private var resolveInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController()
        startPolling()
    }

    /// A `DispatchSourceTimer` on the main queue rather than a `Timer`.
    /// `NSMenu` tracking runs the run loop in event-tracking mode, and a timer
    /// scheduled in `.default` stops firing while the menu is open — freezing
    /// the readout at exactly the moment it is being read.
    private func startPolling() {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    /// Resolution runs off the main thread: the identity probe can busy-wait on
    /// `sched_yield` for up to 250 ms while a process's address space is being
    /// replaced, which would otherwise freeze the status item for a full poll.
    private func poll() {
        guard !resolveInFlight else { return }
        resolveInFlight = true
        let resolver = self.resolver
        let previous = self.previous
        queue.async {
            let state = resolver.resolve(previous: previous)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resolveInFlight = false
                // `previous` means "the last state we actually resolved".
                // Storing an `.unknown` here would nest it once per failing
                // poll — unbounded at 4 Hz — and bury the real last known state
                // one level deeper each time, which the renderer cannot see past.
                if case .unknown = state {} else { self.previous = state }
                self.controller?.render(state)
            }
        }
    }
}

// Must precede any UI. An unbundled executable defaults to `.prohibited`, and a
// status item created before this call never appears.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = MenuApplicationDelegate()
application.delegate = delegate
application.run()
