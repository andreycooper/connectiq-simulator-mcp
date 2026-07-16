import Foundation
import Testing

import SimulatorMCPCore

@Suite("DeviceCatalog")
struct DeviceCatalogTests {

    private var fixtureRoot: URL {
        Bundle.module.resourceURL!.appending(path: "Fixtures/devices")
    }

    @Test("reads touch, physical keys, and display crop from the device JSON")
    func testReadsFenix6xproFixture() throws {
        let catalog = DeviceCatalog(devicesRoot: fixtureRoot)
        let devices = catalog.installedDevices()

        let fenix = try #require(devices.first(where: { $0.deviceId == "fenix6xpro" }))
        #expect(fenix.touch == false)
        // Physical key ids exactly as simulator.json lists them (verified
        // against the real installed profile: enter/up/menu/down/esc — and
        // notably no "light").
        #expect(fenix.physicalKeyIds == ["enter", "up", "menu", "down", "esc"])
        #expect(fenix.displayRect == PixelRect(x: 76, y: 141, width: 280, height: 280))
        #expect(fenix.displayName.contains("fēnix® 6X Pro"))
    }

    @Test("a touch device without keys yields touch=true and no key ids")
    func testTouchDeviceWithoutKeys() throws {
        let catalog = DeviceCatalog(devicesRoot: fixtureRoot)
        let devices = catalog.installedDevices()

        let venu = try #require(devices.first(where: { $0.deviceId == "venu3fixture" }))
        #expect(venu.touch == true)
        #expect(venu.physicalKeyIds.isEmpty)
        #expect(venu.displayRect == nil)
    }

    @Test("devices are sorted by deviceId")
    func testSortedByDeviceId() throws {
        let devices = DeviceCatalog(devicesRoot: fixtureRoot).installedDevices()
        #expect(devices.map(\.deviceId) == devices.map(\.deviceId).sorted())
        #expect(devices.count == 2)
    }

    @Test("intersecting with manifest devices keeps only listed ids")
    func testManifestIntersection() throws {
        let catalog = DeviceCatalog(devicesRoot: fixtureRoot)

        let devices = catalog.installedDevices(
            intersecting: ["fenix6xpro", "fr965"])  // fr965 is not installed

        #expect(devices.map(\.deviceId) == ["fenix6xpro"])
    }

    @Test("a device directory with broken JSON is skipped and logged, not fatal")
    func testBrokenDeviceIsSkippedAndLogged() throws {
        let temp = try TempDevices()
        defer { temp.tearDown() }
        try temp.copyFixture("fenix6xpro", from: fixtureRoot)
        try temp.makeDevice("brokenjson", compilerJson: "{ not json")
        try temp.makeDevice("nocompiler", compilerJson: nil)

        let logLines = LineCollector()
        let catalog = DeviceCatalog(devicesRoot: temp.root, logSink: { logLines.append($0) })
        let devices = catalog.installedDevices()

        #expect(devices.map(\.deviceId) == ["fenix6xpro"])
        let logged = logLines.lines.joined(separator: "\n")
        #expect(logged.contains("brokenjson"))
    }

    @Test("a missing devices root yields an empty list, not an error")
    func testMissingRootYieldsEmpty() throws {
        let catalog = DeviceCatalog(
            devicesRoot: URL(fileURLWithPath: "/definitely/not/here/\(UUID().uuidString)"))
        #expect(catalog.installedDevices().isEmpty)
    }
}

private struct TempDevices {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "device-catalog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func copyFixture(_ deviceId: String, from fixtureRoot: URL) throws {
        try FileManager.default.copyItem(
            at: fixtureRoot.appending(path: deviceId),
            to: root.appending(path: deviceId))
    }

    func makeDevice(_ deviceId: String, compilerJson: String?) throws {
        let dir = root.appending(path: deviceId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let compilerJson {
            try compilerJson.write(
                to: dir.appending(path: "compiler.json"), atomically: true, encoding: .utf8)
        }
        try #"{"display": {"isTouch": false}}"#.write(
            to: dir.appending(path: "simulator.json"), atomically: true, encoding: .utf8)
    }
}
