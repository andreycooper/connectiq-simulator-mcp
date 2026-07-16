import Foundation
import Testing

import SimulatorMCPCore

@Suite("ToolError")
struct ToolErrorTests {
    @Test("stores code, message, fix, and defaults details to nil")
    func testDefaultsDetailsToNil() throws {
        let error = ToolError(code: "sdk_not_found", message: "No SDK found.", fix: "Install a Connect IQ SDK.")
        #expect(error.code == "sdk_not_found")
        #expect(error.message == "No SDK found.")
        #expect(error.fix == "Install a Connect IQ SDK.")
        #expect(error.details == nil)
    }

    @Test("stores provided details")
    func testStoresDetails() throws {
        let error = ToolError(
            code: "operation_timeout",
            message: "monkeyc did not finish within 120s.",
            fix: "Increase the timeout and retry.",
            details: ["executable": "/usr/bin/monkeyc", "timeoutSeconds": 120]
        )
        #expect(error.details == ["executable": "/usr/bin/monkeyc", "timeoutSeconds": 120])
    }

    @Test("equal when every field matches, unequal when any field differs")
    func testEquatable() throws {
        let base = ToolError(code: "build_failed", message: "m", fix: "f", details: ["a": 1])
        let same = ToolError(code: "build_failed", message: "m", fix: "f", details: ["a": 1])
        let differentCode = ToolError(code: "internal_error", message: "m", fix: "f", details: ["a": 1])
        let differentMessage = ToolError(code: "build_failed", message: "other", fix: "f", details: ["a": 1])
        let differentFix = ToolError(code: "build_failed", message: "m", fix: "other fix", details: ["a": 1])
        let differentDetails = ToolError(code: "build_failed", message: "m", fix: "f", details: ["a": 2])
        let noDetails = ToolError(code: "build_failed", message: "m", fix: "f")

        #expect(base == same)
        #expect(base != differentCode)
        #expect(base != differentMessage)
        #expect(base != differentFix)
        #expect(base != differentDetails)
        #expect(base != noDetails)
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("literals construct the expected case")
    func testLiterals() throws {
        let null: JSONValue = nil
        let bool: JSONValue = true
        let int: JSONValue = 42
        let double: JSONValue = 3.5
        let string: JSONValue = "hello"
        let array: JSONValue = ["a", 1, true]
        let object: JSONValue = ["key": "value", "count": 2]

        #expect(null == .null)
        #expect(bool == .bool(true))
        #expect(int == .int(42))
        #expect(double == .double(3.5))
        #expect(string == .string("hello"))
        #expect(array == .array([.string("a"), .int(1), .bool(true)]))
        #expect(object == .object(["key": .string("value"), "count": .int(2)]))
    }

    @Test("round-trips a nested value through JSONEncoder/JSONDecoder")
    func testCodableRoundTrip() throws {
        let value: JSONValue = [
            "name": "fenix6xpro",
            "buttons": ["up", "down", "select"],
            "touch": false,
            "batteryLevel": 87.5,
            "lastError": nil,
        ]

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == value)
    }

    @Test("decodes raw JSON text produced by something other than this type")
    func testDecodesExternalJSON() throws {
        let json = """
            {"code":"sdk_not_found","retryable":false,"attempts":3,"delaySeconds":1.5,"details":null,"tags":["a","b"]}
            """
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))

        #expect(
            decoded
                == .object([
                    "code": .string("sdk_not_found"),
                    "retryable": .bool(false),
                    "attempts": .int(3),
                    "delaySeconds": .double(1.5),
                    "details": .null,
                    "tags": .array([.string("a"), .string("b")]),
                ]))
    }
}
