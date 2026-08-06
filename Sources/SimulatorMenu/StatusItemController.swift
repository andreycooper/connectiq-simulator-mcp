import AppKit
import SimulatorMCPCore

/// Renders a `MonitorState` into the status item and its menu.
///
/// Holds no logic of its own: every decision lives in `MonitorStateResolver`,
/// which is unit-tested in the library. This type only maps a state to pixels.
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let activityItem = NSMenuItem()
    private let simulatorItem = NSMenuItem()
    private let sdkItem = NSMenuItem()
    private let deviceItem = NSMenuItem()
    private let revealItem: NSMenuItem

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        revealItem = NSMenuItem(
            title: "Reveal ~/.simulator-mcp", action: #selector(reveal), keyEquivalent: "")

        for entry in [activityItem, simulatorItem, sdkItem, deviceItem] {
            entry.isEnabled = false
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        revealItem.target = self
        // Fail closed until the first poll resolves. AppKit's default is
        // `true`, and `autoenablesItems = false` below makes that default
        // stick until `render` runs for the first time -- clicking Reveal in
        // that window activates Finder and can break an in-flight press the
        // same way §7 disables it for while an agent is driving.
        revealItem.isEnabled = false
        menu.addItem(revealItem)
        menu.addItem(
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Required, not cosmetic. `autoenablesItems` defaults to true, and
        // AppKit's pre-display `update()` then overwrites every manual
        // `isEnabled`. Without this line the "Reveal is disabled while an agent
        // is driving" guarantee — documented in the README and required by spec
        // section 7 — silently does not hold.
        menu.autoenablesItems = false
        item.menu = menu
    }

    /// Spec section 7 row 1 asks for caution rendered **over** the last known
    /// state, not instead of it — so an unknown swaps only the glyph (to the
    /// exclamation-badge watch, `unknownSymbolName`) while every other field
    /// below still reflects `base`, the last known state. A *bare* unknown —
    /// `.unknown(previous: nil)`, the first poll after launch finding nothing
    /// to revalidate against — has no last known state at all (`base == nil`),
    /// and still renders the caution glyph: nothing here defaults to the
    /// driving glyph or any other shape. What actually keeps a false idle from
    /// inviting the user to touch the keyboard mid-gate is
    /// `revealItem.isEnabled = false` a few lines down, which disables the
    /// one interactive item under uncertainty regardless of what `base` is.
    ///
    /// Measured 2026-08-05: `NSStatusBarButton.contentTintColor` has no visible
    /// effect on this machine — sampled the composited pixel for every state's
    /// intended tint (grey/green/blue/orange), both `isTemplate` true and
    /// false, across two different symbol families, and every combination
    /// rendered identical opaque black. The five states are therefore
    /// distinguished by SHAPE only (an `applewatch.*` family — it looks like
    /// what it drives), which is why no `contentTintColor` assignment appears
    /// below: leaving one in would imply a behaviour that does not happen on
    /// this machine.
    func render(_ state: MonitorState) {
        let uncertain: Bool
        let base: MonitorState?
        if case .unknown(let previous) = state {
            uncertain = true
            base = previous
        } else {
            uncertain = false
            base = state
        }

        // `base` is typed `MonitorState?` because the `if` branch above binds
        // it from `previous: MonitorState?`; `?? .noSimulator` satisfies that
        // type where it's practically unreachable (the `else` branch already
        // guarantees `base` is non-nil whenever `uncertain` is false, which is
        // the only time these two expressions are evaluated).
        let label = uncertain ? "Simulator state unavailable" : Self.label(base ?? .noSimulator)
        item.button?.image = Self.image(
            named: uncertain ? Self.unknownSymbolName : Self.symbolName(base ?? .noSimulator),
            accessibilityDescription: label)
        item.button?.toolTip = label

        if uncertain {
            activityItem.title = "state unavailable"
            activityItem.isHidden = false
            revealItem.isEnabled = false
        }

        switch base {
        case .driving(let summary)?, .drivingWithoutSimulator(let summary)?:
            if !uncertain {
                let elapsed = Date().timeIntervalSince1970 - summary.startedEpochSeconds
                activityItem.title = String(format: "%@ · %.1fs", summary.operation, max(0, elapsed))
                activityItem.isHidden = false
                // Reveal activates Finder, a layer-0 application, which would
                // take key focus from the Simulator and break an in-flight press.
                revealItem.isEnabled = false
            }
            apply(summary.simulator)
        case .idle(let summary)?:
            if !uncertain {
                activityItem.isHidden = true
                revealItem.isEnabled = true
            }
            apply(summary)
        case .noSimulator?:
            if !uncertain {
                activityItem.isHidden = true
                revealItem.isEnabled = true
            }
            apply(nil)
        case .unknown?, nil:
            // A bare unknown (`base == nil`) has no last known state to fall
            // back on -- routing it through `apply(nil)` would print "not
            // running", asserting an absence this poll never actually
            // observed. Say what we know instead: it is the simulator's
            // *state*, not its presence, that is unavailable.
            simulatorItem.title = "Simulator     state unknown"
            sdkItem.isHidden = true
            deviceItem.isHidden = true
        }
    }

    private func apply(_ summary: SimulatorSummary?) {
        guard let summary else {
            simulatorItem.title = "Simulator     not running"
            sdkItem.isHidden = true
            deviceItem.isHidden = true
            return
        }
        simulatorItem.title = "Simulator     running · pid \(summary.pid)"
        sdkItem.title = "SDK           \(summary.sdkVersion)"
        deviceItem.title = "Device        \(summary.device ?? "unset")"
        sdkItem.isHidden = false
        deviceItem.isHidden = false
    }

    // `applewatch.trianglebadge.exclamationmark` -- the symbol specified for
    // `unknown` -- does not resolve on this machine's SF Symbols catalog
    // (`NSImage(systemSymbolName:)` returns nil for it, verified 2026-08-05).
    // `exclamationmark.applewatch` is the closest available symbol in the same
    // family: confirmed to resolve and to render a watch-with-exclamation-
    // badge silhouette, distinct from the other three.
    private static let unknownSymbolName = "exclamationmark.applewatch"

    private static func symbolName(_ state: MonitorState) -> String {
        switch state {
        case .noSimulator: return "applewatch.slash"
        case .idle: return "applewatch"
        case .driving, .drivingWithoutSimulator: return "applewatch.radiowaves.left.and.right"
        case .unknown: return unknownSymbolName
        }
    }

    /// Resolves a system symbol, falling back to a near-universal symbol name
    /// if the requested one is unavailable on the running OS. A missing
    /// symbol must never leave the status item with no image at all -- that
    /// is a worse failure than a merely-wrong icon, since a blank status item
    /// answers no question at all.
    private static func image(named symbolName: String, accessibilityDescription: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: accessibilityDescription)
    }

    private static func label(_ state: MonitorState) -> String {
        switch state {
        case .noSimulator: return "Simulator not running"
        case .idle: return "Simulator idle"
        case .driving(let summary): return "Agent driving: \(summary.operation)"
        case .drivingWithoutSimulator(let summary): return "Agent driving: \(summary.operation)"
        case .unknown: return "Simulator state unavailable"
        }
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".simulator-mcp")
        ])
    }
}
