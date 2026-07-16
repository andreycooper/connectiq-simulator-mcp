import Foundation

/// A rectangle in device-window content coordinates, as `simulator.json`'s
/// `display.location` reports it (verified for fenix6xpro: 280×280 at
/// (76,141)). A full-window screenshot must add its platform-derived content
/// top inset before scaling this rectangle into capture pixels.
public struct PixelRect: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One installed simulator device profile, read from
/// `Devices/<id>/compiler.json` + `simulator.json`. This is hardware
/// description only — it says nothing about verified input support, which
/// is an explicit allowlist owned by Task 15 (see AGENTS.md: device JSON
/// is never proof of a verified key mapping).
public struct InstalledDevice: Codable, Equatable, Sendable {
    public let deviceId: String
    public let displayName: String
    public let touch: Bool
    public let physicalKeyIds: [String]
    public let displayRect: PixelRect?

    public init(
        deviceId: String,
        displayName: String,
        touch: Bool,
        physicalKeyIds: [String],
        displayRect: PixelRect?
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.touch = touch
        self.physicalKeyIds = physicalKeyIds
        self.displayRect = displayRect
    }
}

/// Reads the installed device profiles. A broken or incomplete device
/// directory is skipped with a stderr diagnostic rather than failing the
/// whole listing — one corrupt profile must not take down `list_devices`
/// (and a missing developer key can never be involved at all: no key
/// resolution happens here).
public struct DeviceCatalog: Sendable {
    private let devicesRoot: URL
    private let logSink: Log.Sink

    /// Production layout: `~/Library/Application Support/Garmin/ConnectIQ/Devices`.
    public init() {
        self.init(
            devicesRoot: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Garmin/ConnectIQ/Devices")
        )
    }

    public init(devicesRoot: URL, logSink: @escaping Log.Sink = Log.standardError) {
        self.devicesRoot = devicesRoot
        self.logSink = logSink
    }

    /// Every readable installed device, sorted by deviceId. A missing
    /// devices root is an empty list (nothing is installed), not an error.
    public func installedDevices() -> [InstalledDevice] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: devicesRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(readDevice(at:))
            .sorted { $0.deviceId < $1.deviceId }
    }

    /// Installed devices limited to ids a manifest declares
    /// (`ProjectDescriptor.manifestDevices`).
    public func installedDevices(intersecting manifestDevices: [String]) -> [InstalledDevice] {
        let allowed = Set(manifestDevices)
        return installedDevices().filter { allowed.contains($0.deviceId) }
    }

    // MARK: - Parsing

    private func readDevice(at directory: URL) -> InstalledDevice? {
        let compilerURL = directory.appending(path: "compiler.json")
        let simulatorURL = directory.appending(path: "simulator.json")
        let decoder = JSONDecoder()

        do {
            let compiler = try decoder.decode(
                CompilerJson.self, from: Data(contentsOf: compilerURL))
            let simulator = try decoder.decode(
                SimulatorJson.self, from: Data(contentsOf: simulatorURL))

            return InstalledDevice(
                deviceId: compiler.deviceId,
                displayName: compiler.displayName,
                touch: simulator.display?.isTouch ?? false,
                physicalKeyIds: (simulator.keys ?? []).map(\.id),
                displayRect: simulator.display?.location
            )
        } catch {
            Log.err(
                "device catalog: skipping \(directory.lastPathComponent): \(error.localizedDescription)",
                sink: logSink
            )
            return nil
        }
    }

    private struct CompilerJson: Decodable {
        let deviceId: String
        let displayName: String
    }

    private struct SimulatorJson: Decodable {
        struct Display: Decodable {
            let isTouch: Bool?
            let location: PixelRect?
        }
        struct Key: Decodable {
            let id: String
        }
        let display: Display?
        let keys: [Key]?
    }
}
