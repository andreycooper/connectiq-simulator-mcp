import Foundation
import Testing

@testable import SimulatorMCPCore

@Suite("DeviceReadback")
struct DeviceReadbackTests {
    private func device(_ id: String, _ name: String) -> InstalledDevice {
        InstalledDevice(
            deviceId: id, displayName: name, touch: false, physicalKeyIds: [], displayRect: nil)
    }

    private var catalog: [InstalledDevice] {
        [device("fenix6xpro", "fēnix 6X Pro"), device("fenix7s", "fēnix 7S")]
    }

    /// Builds the measured loaded-title form around a display name.
    private func loaded(_ displayName: String, _ version: String) -> TitledWindow {
        TitledWindow(pid: 42, layer: 0, title: "CIQ Simulator - \(displayName) (\(version))")
    }

    @Test("a loaded device window resolves to its device id")
    func loadedResolves() {
        let windows = [loaded("fēnix 6X Pro", "3.4.5")]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: catalog)
                == .device(deviceId: "fenix6xpro", displayName: "fēnix 6X Pro"))
    }

    // THE TWO REQUIRED COLLISION TESTS. Every other case in this suite passes
    // under a first-`(` implementation; only these two fail. Do not drop them.

    @Test("a display name containing ' (' resolves to itself, never to its prefix")
    func greedyTailStripAvoidsPrefixCollision() {
        // epix2's real display name contains ' (' internally, and its prefix
        // up to that point is epix's entire real display name. A first-match
        // strip resolves epix2 to epix — a wrong device reported as verified.
        let devices = [
            device("epix2", "epix™ (Gen 2) / quatix® 7 Sapphire"),
            device("epix", "epix™"),
        ]
        let windows = [loaded("epix™ (Gen 2) / quatix® 7 Sapphire", "4.0.0")]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: devices)
                == .device(deviceId: "epix2", displayName: "epix™ (Gen 2) / quatix® 7 Sapphire"))
    }

    @Test("a display name that both contains ' - ' and ends in a parenthesised group resolves")
    func nameWithDashAndTrailingParenResolves() {
        let name = "fēnix® 7 Pro - Solar Edition (no Wi-Fi)"
        let devices = [device("fenix7pronowifi", name)]
        #expect(
            DeviceReadback.observe(windows: [loaded(name, "5.2.0")], pid: 42, devices: devices)
                == .device(deviceId: "fenix7pronowifi", displayName: name))
    }

    @Test("a malformed title is unrecognised, never an uninstalled device")
    func malformedTitlesAreUnrecognised() {
        for title in [
            "CIQ Simulator - ",  // prefix, nothing else
            "CIQ Simulator -  (1.0)",  // empty display name
            "CIQ Simulator - fēnix® 7S",  // no version group
            "CIQ Simulator - fēnix® 7S (no Wi-Fi)",  // non-numeric token
            "CIQ Simulator - fēnix® 7S ()",  // empty token
            "fēnix® 7S (5.2.0)",  // no prefix
            "CIQ Simulator - fēnix® 7S (5.2.0",  // unterminated version group
        ] {
            #expect(
                DeviceReadback.observe(
                    windows: [TitledWindow(pid: 42, layer: 0, title: title)],
                    pid: 42, devices: catalog)
                    == .unavailable(reason: .unrecognisedTitleFormat),
                "title: \(title)")
        }
    }

    @Test("the idle title is idle, not an unknown device")
    func idleIsIdle() {
        // Pin both constants to the measured contract as literals, not just
        // to each other — a test that only compares `idleTitle` against
        // itself would stay green even if someone respelled `loadedPrefix`
        // as a hardcoded literal elsewhere and let the constants drift.
        #expect(DeviceReadback.idleTitle == "CIQ Simulator")
        #expect(DeviceReadback.loadedPrefix == "CIQ Simulator - ")

        let windows = [TitledWindow(pid: 42, layer: 0, title: DeviceReadback.idleTitle)]
        #expect(DeviceReadback.observe(windows: windows, pid: 42, devices: catalog) == .idle)
    }

    @Test("real measured display names resolve, not just fabricated short ones")
    func realMeasuredDisplayNamesResolve() {
        // From docs/verification/simulator-contracts/simulator-window-title.json.
        let fenix7sName = "fēnix® 7S"
        let fenix6xproName =
            "fēnix® 6X Pro / 6X Sapphire / 6X Pro Solar / tactix® Delta Sapphire / "
            + "Delta Solar / Delta Solar - Ballistics Edition / quatix® 6X / 6X Solar / "
            + "6X Dual Power"
        let devices = [
            device("fenix7s", fenix7sName),
            device("fenix6xpro", fenix6xproName),
        ]
        #expect(
            DeviceReadback.observe(
                windows: [loaded(fenix7sName, "5.2.0")], pid: 42, devices: devices)
                == .device(deviceId: "fenix7s", displayName: fenix7sName))
        #expect(
            DeviceReadback.observe(
                windows: [loaded(fenix6xproName, "3.4.5")], pid: 42, devices: devices)
                == .device(deviceId: "fenix6xpro", displayName: fenix6xproName))
    }

    @Test("a version token containing a non-ASCII numeral is unrecognised")
    func nonASCIINumeralTokenUnrecognised() {
        // Character.isNumber is true for ½, Ⅶ, ٣, ①, 𝟟 — none of those are
        // digits, and none may pass the version shape check.
        let windows = [loaded("fēnix® 7S", "½")]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: catalog)
                == .unavailable(reason: .unrecognisedTitleFormat))
    }

    @Test("an NFD-normalised title against an NFC catalog fails closed, never matches")
    func nfdTitleAgainstNFCCatalogFailsClosed() {
        let nfc = "fēnix® 7S"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        // Canonically equivalent but not byte-identical: `==` on String would
        // treat these as equal; the readback must not.
        #expect(nfc == nfd)
        #expect(!nfc.unicodeScalars.elementsEqual(nfd.unicodeScalars))

        let devices = [device("fenix7s", nfc)]
        let windows = [loaded(nfd, "5.2.0")]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: devices)
                == .unavailable(reason: .unknownDisplayName))
    }

    @Test("windows owned by another pid are ignored")
    func foreignPidIgnored() {
        let windows = [TitledWindow(pid: 99, layer: 0, title: "CIQ Simulator - fēnix 6X Pro (3.4.5)")]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: catalog)
                == .unavailable(reason: .noSimulatorWindow))
    }

    @Test("non-zero window layers are ignored")
    func overlayLayersIgnored() {
        let windows = [TitledWindow(pid: 42, layer: 25, title: "CIQ Simulator - fēnix 6X Pro (3.4.5)")]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: catalog)
                == .unavailable(reason: .noSimulatorWindow))
    }

    @Test("two primary simulator windows are unavailable, never a guess")
    func ambiguousWindowsUnavailable() {
        let windows = [
            loaded("fēnix 6X Pro", "3.4.5"),
            loaded("fēnix 7S", "5.2.0"),
        ]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: catalog)
                == .unavailable(reason: .multipleSimulatorWindows))
    }

    @Test("a redacted title is unavailable, never idle")
    func redactedTitleUnavailable() {
        let windows = [TitledWindow(pid: 42, layer: 0, title: nil)]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: catalog)
                == .unavailable(reason: .titleUnreadable))
    }

    @Test("a well-formed title naming no installed device is unknown, never idle")
    func unknownTitleUnavailable() {
        let windows = [loaded("Venu 3", "6.0.0")]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: catalog)
                == .unavailable(reason: .unknownDisplayName))
    }

    @Test("a display name shared by two installed devices is unavailable, never a guess")
    func duplicateDisplayNameUnavailable() {
        let ambiguous = [device("alpha", "Shared Name"), device("beta", "Shared Name")]
        let windows = [loaded("Shared Name", "1.0")]
        #expect(
            DeviceReadback.observe(windows: windows, pid: 42, devices: ambiguous)
                == .unavailable(reason: .ambiguousDisplayName))
    }

    @Test("a denied Screen Recording grant is reported as its own reason")
    func deniedGrantReported() async {
        let readback = DeviceReadback(
            screenRecordingGranted: { false },
            titledWindows: { [self.loaded("fēnix 6X Pro", "3.4.5")] },
            devices: { self.catalog })
        #expect(await readback.observe(simulatorPid: 42)
            == .unavailable(reason: .screenRecordingDenied))
    }

    @Test("the live path reads the catalog through the injected closure")
    func liveObservesThroughClosures() async {
        let readback = DeviceReadback(
            screenRecordingGranted: { true },
            titledWindows: { [self.loaded("fēnix 7S", "5.2.0")] },
            devices: { self.catalog })
        #expect(await readback.observe(simulatorPid: 42)
            == .device(deviceId: "fenix7s", displayName: "fēnix 7S"))
    }
}
