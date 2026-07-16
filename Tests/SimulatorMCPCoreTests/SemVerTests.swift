import Foundation
import Testing

import SimulatorMCPCore

@Suite("SemVer")
struct SemVerTests {
    @Test("parses plain versions")
    func testParsesPlainVersions() throws {
        let version = try #require(SemVer("9.1.0"))
        #expect(version.major == 9)
        #expect(version.minor == 1)
        #expect(version.patch == 0)
        #expect(version.description == "9.1.0")
    }

    @Test("rejects non-versions")
    func testRejectsNonVersions() throws {
        #expect(SemVer("") == nil)
        #expect(SemVer("nine.one.zero") == nil)
        #expect(SemVer("9.1") == nil)
        #expect(SemVer("9") == nil)
    }

    @Test("compares numerically, not lexically")
    func testComparesNumerically() throws {
        let v9_2_0 = try #require(SemVer("9.2.0"))
        let v9_10_0 = try #require(SemVer("9.10.0"))
        let v10_0_0 = try #require(SemVer("10.0.0"))

        #expect(v9_10_0 > v9_2_0)
        #expect(v10_0_0 > v9_10_0)
        #expect(v10_0_0 > v9_2_0)
        #expect([v10_0_0, v9_2_0, v9_10_0].sorted() == [v9_2_0, v9_10_0, v10_0_0])
    }

    @Test("extracts the version embedded in an SDK directory name")
    func testExtractsFromSdkDirectoryName() throws {
        // Real installed layout (verified on this machine):
        // connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b
        let name = "connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b"
        #expect(SemVer(firstIn: name) == SemVer("9.1.0"))

        #expect(SemVer(firstIn: "connectiq-sdk-mac-8.4.1-2026-02-03-e9f77eeaa") == SemVer("8.4.1"))
        #expect(SemVer(firstIn: "no-version-here") == nil)
        // The *first* full triple wins; the date suffix must not be
        // mistaken for a version.
        #expect(SemVer(firstIn: "connectiq-sdk-mac-9.10.0-2026-12-31-abc") == SemVer("9.10.0"))
    }

    @Test("round-trips through Codable as a version string")
    func testCodableRoundTrip() throws {
        let version = try #require(SemVer("9.10.0"))
        let data = try JSONEncoder().encode(version)
        #expect(String(decoding: data, as: UTF8.self) == "\"9.10.0\"")
        let decoded = try JSONDecoder().decode(SemVer.self, from: data)
        #expect(decoded == version)
    }

    @Test("decoding a malformed version string fails")
    func testDecodingMalformedFails() throws {
        let data = Data("\"potato\"".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SemVer.self, from: data)
        }
    }
}
