@preconcurrency import CoreGraphics
import Foundation

/// One window owned by some process, reduced to the three facts the readback
/// needs. `title` is `nil` when macOS redacted `kCGWindowName`, which it does
/// for every caller without the Screen Recording grant.
public struct TitledWindow: Equatable, Sendable {
    public let pid: pid_t
    public let layer: Int
    public let title: String?

    public init(pid: pid_t, layer: Int, title: String?) {
        self.pid = pid
        self.layer = layer
        self.title = title
    }
}

/// Why the loaded device could not be observed. Every case is a value, never
/// an error: an unobservable simulator is a reportable state, not a failure.
public enum ReadbackUnavailable: String, Codable, Equatable, Sendable {
    case screenRecordingDenied
    case noSimulatorWindow
    case multipleSimulatorWindows
    case titleUnreadable
    /// The title does not match the measured loaded form at all. Garmin
    /// changed the format; stop trusting the readback rather than guessing.
    case unrecognisedTitleFormat
    case unknownDisplayName
    case ambiguousDisplayName
}

public enum DeviceObservation: Equatable, Sendable {
    /// A device profile is loaded and resolved to exactly one installed device.
    case device(deviceId: String, displayName: String)
    /// The simulator is up with no device profile loaded.
    case idle
    case unavailable(reason: ReadbackUnavailable)
}

public protocol DeviceObserving: Sendable {
    func observe(simulatorPid: pid_t) async -> DeviceObservation
}

/// Reads which device profile the simulator is showing, from its window title.
///
/// The title is the only observable that distinguishes devices sharing a
/// screen size, which is exactly the case a silent device-switch no-op
/// produces. Geometry is deliberately not consulted; see the design's §3.
///
/// Read-only: no `Foundation.Process`, no AX, no CGEvent. `kCGWindowName`
/// requires the Screen Recording grant, so a missing grant is reported rather
/// than worked around.
public struct DeviceReadback: DeviceObserving {
    /// The title the simulator shows with no device profile loaded.
    /// Measured on both SDKs; see
    /// `docs/verification/simulator-contracts/simulator-window-title.json`.
    public static let idleTitle = "CIQ Simulator"

    /// A loaded title is `CIQ Simulator - <displayName> (<version>)`. Note the
    /// prefix is the idle title plus a separator, which is why idle is tested
    /// first and on the whole string — a "contains" test cannot tell the two
    /// states apart. See the 2026-08-06 window-title-format amendment.
    public static let loadedPrefix = "\(idleTitle) - "

    private let screenRecordingGranted: @Sendable () -> Bool
    private let titledWindows: @Sendable () -> [TitledWindow]
    private let devices: @Sendable () -> [InstalledDevice]

    public init(deviceCatalog: DeviceCatalog = DeviceCatalog()) {
        self.init(
            screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
            titledWindows: Self.liveWindows,
            devices: { deviceCatalog.installedDevices() })
    }

    init(
        screenRecordingGranted: @escaping @Sendable () -> Bool,
        titledWindows: @escaping @Sendable () -> [TitledWindow],
        devices: @escaping @Sendable () -> [InstalledDevice]
    ) {
        self.screenRecordingGranted = screenRecordingGranted
        self.titledWindows = titledWindows
        self.devices = devices
    }

    public func observe(simulatorPid: pid_t) async -> DeviceObservation {
        guard screenRecordingGranted() else {
            return .unavailable(reason: .screenRecordingDenied)
        }
        return Self.observe(
            windows: titledWindows(), pid: simulatorPid, devices: devices())
    }

    /// The pure core. Selection mirrors `ScreenshotWindowSelector`: the
    /// simulator's own windows in the ordinary application layer, and exactly
    /// one of them.
    public static func observe(
        windows: [TitledWindow], pid: pid_t, devices: [InstalledDevice]
    ) -> DeviceObservation {
        let candidates = windows.filter { $0.pid == pid && $0.layer == 0 }
        guard !candidates.isEmpty else { return .unavailable(reason: .noSimulatorWindow) }
        guard candidates.count == 1, let window = candidates.first else {
            return .unavailable(reason: .multipleSimulatorWindows)
        }
        guard let title = window.title, !title.isEmpty else {
            return .unavailable(reason: .titleUnreadable)
        }
        // Idle is tested first and on the WHOLE string: `loadedPrefix` begins
        // with the idle constant, so any containment test conflates them.
        guard title != idleTitle else { return .idle }
        guard let displayName = parseDisplayName(title) else {
            return .unavailable(reason: .unrecognisedTitleFormat)
        }

        // Byte equality, not `==`: `String`'s `==` is canonical (NFC/NFD
        // equivalence), so it would silently accept a title arriving in a
        // different Unicode normal form than the catalog. Amendment §2
        // requires that to fail closed rather than be quietly accommodated.
        let matches = devices.filter {
            $0.displayName.unicodeScalars.elementsEqual(displayName.unicodeScalars)
        }
        guard !matches.isEmpty else { return .unavailable(reason: .unknownDisplayName) }
        guard matches.count == 1, let device = matches.first else {
            return .unavailable(reason: .ambiguousDisplayName)
        }
        return .device(deviceId: device.deviceId, displayName: device.displayName)
    }

    /// Strips `CIQ Simulator - ` from the front and a trailing ` (<version>)`
    /// group from the end, returning the display name between them.
    ///
    /// The tail search is **greedy — the LAST ` (`, never the first, and never
    /// a lazy-head regex**. `epix2`'s display name is
    /// `epix™ (Gen 2) / quatix® 7 Sapphire`; a first-match strip yields
    /// `epix™`, which is the installed device `epix`. That would report a
    /// verified device that is not the one on screen — the exact failure this
    /// readback exists to prevent.
    ///
    /// The version token is discarded unexamined apart from a shape check.
    /// The check delimits the token; it does not validate the version, so a
    /// firmware bump cannot fail it. Without it, a future SDK that dropped the
    /// version group would strip the device's own name from
    /// `fēnix® 7 Pro - Solar Edition (no Wi-Fi)`.
    static func parseDisplayName(_ title: String) -> String? {
        guard title.hasPrefix(loadedPrefix) else { return nil }
        let remainder = title.dropFirst(loadedPrefix.count)
        guard remainder.hasSuffix(")"), let open = remainder.range(of: " (", options: .backwards)
        else { return nil }

        let token = remainder[open.upperBound..<remainder.index(before: remainder.endIndex)]
        // `Character.isNumber` is true for non-ASCII digits and numeric
        // symbols (½, Ⅶ, ٣, ①, 𝟟) — restrict to ASCII digits so those don't
        // pass the shape check as if they were a version.
        guard !token.isEmpty, token.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." })
        else { return nil }

        let name = remainder[remainder.startIndex..<open.lowerBound]
        // An empty name is a malformed title, not an uninstalled device — it
        // must not be reported as unknownDisplayName.
        return name.isEmpty ? nil : String(name)
    }

    private static func liveWindows() -> [TitledWindow] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner > 0 else {
                return nil
            }
            return TitledWindow(
                pid: pid_t(owner),
                layer: window[kCGWindowLayer as String] as? Int ?? -1,
                title: window[kCGWindowName as String] as? String)
        }
    }
}
