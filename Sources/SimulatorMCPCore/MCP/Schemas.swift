import MCP

/// JSON Schema builders and the declared schema for every public result
/// model. Every tool definition's `outputSchema` must be
/// `Schemas.envelopeSchema(result:)` over the tool's result schema —
/// `ToolSchemaTests` validates encoded success/failure envelopes for each
/// model against these.
///
/// Nullable fields ("when present"/"nullable" in the plan's model table)
/// are still schema-required: the models encode explicit `null` (see
/// `ResultModels.swift`), so every documented key is always on the wire.
public enum Schemas {

    // MARK: - Building blocks

    public static let string: Value = ["type": "string"]
    public static let boolean: Value = ["type": "boolean"]
    public static let integer: Value = ["type": "integer"]
    public static let number: Value = ["type": "number"]

    public static func stringEnum(_ cases: [String]) -> Value {
        ["type": "string", "enum": .array(cases.map { .string($0) })]
    }

    public static func array(of item: Value) -> Value {
        ["type": "array", "items": item]
    }

    public static func object(properties: [String: Value], required: [String]) -> Value {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.sorted().map { .string($0) }),
        ]
    }

    /// Widens a schema's `type` to also accept `null`.
    public static func nullable(_ schema: Value) -> Value {
        guard case .object(var fields) = schema else { return schema }
        switch fields["type"] {
        case .string(let single)?:
            fields["type"] = .array([.string(single), .string("null")])
        case .array(let names)? where !names.contains(.string("null")):
            fields["type"] = .array(names + [.string("null")])
        default:
            break
        }
        return .object(fields)
    }

    // MARK: - Envelope

    public static let toolFailure: Value = object(
        properties: [
            "code": string,
            "message": string,
            "fix": string,
            "details": nullable(["type": "object"]),
        ],
        required: ["code", "message", "fix"]
    )

    /// The `ToolEnvelope` schema over a concrete result schema. Success
    /// envelopes omit `error`, failure envelopes omit `result`, so only
    /// `ok` is required at the top level; the branches themselves are
    /// strict.
    public static func envelopeSchema(result: Value) -> Value {
        object(
            properties: [
                "ok": boolean,
                "result": nullable(result),
                "error": nullable(toolFailure),
            ],
            required: ["ok"]
        )
    }

    // MARK: - Shared wire enums

    public static let simulatorState: Value = stringEnum([
        "not_running", "starting", "ready", "busy", "stopping",
    ])

    public static let buildMode: Value = stringEnum([
        "debugApp", "releaseApp", "unitTests",
    ])

    public static let rebuildReason: Value = stringEnum([
        "cacheHit", "cacheMiss", "forced", "keyChanged",
    ])

    public static let logStream: Value = stringEnum(["stdout", "stderr"])

    public static let permissionStatus: Value = object(
        properties: [
            "granted": boolean,
            "prompted": boolean,
            "systemSettingsPath": string,
            "restartRequired": boolean,
        ],
        required: ["granted", "prompted", "systemSettingsPath", "restartRequired"]
    )

    // MARK: - Result schemas (one per tool, all fields required)

    public static let doctorResult: Value = object(
        properties: [
            "executablePath": string,
            "signatureKind": stringEnum(["unsigned", "adHoc", "stable"]),
            "signingIdentifier": nullable(string),
            "teamIdentifier": nullable(string),
            "cdhash": nullable(string),
            "sdkFound": boolean,
            "javaFound": boolean,
            "simulator": boolean,
            "screenRecording": permissionStatus,
            "accessibility": permissionStatus,
            "responsibleProcessNote": nullable(string),
            "checks": array(
                of: object(
                    properties: [
                        "name": string,
                        "ok": boolean,
                        "observed": string,
                        "fix": nullable(string),
                    ],
                    required: ["name", "ok", "observed", "fix"]
                )),
        ],
        required: [
            "executablePath", "signatureKind", "signingIdentifier", "teamIdentifier",
            "cdhash", "sdkFound", "javaFound", "simulator", "screenRecording",
            "accessibility", "responsibleProcessNote", "checks",
        ]
    )

    public static let listSdksResult: Value = object(
        properties: [
            "sdks": array(
                of: object(
                    properties: [
                        "version": string,
                        "path": string,
                        "source": string,
                        "active": boolean,
                    ],
                    required: ["version", "path", "source", "active"]
                ))
        ],
        required: ["sdks"]
    )

    public static let listDevicesResult: Value = object(
        properties: [
            "devices": array(
                of: object(
                    properties: [
                        "deviceId": string,
                        "displayName": string,
                        "touch": boolean,
                        "buttons": array(of: string),
                        "inputSupported": boolean,
                        "inputProfile": nullable(string),
                    ],
                    required: [
                        "deviceId", "displayName", "touch", "buttons", "inputSupported",
                        "inputProfile",
                    ]
                ))
        ],
        required: ["devices"]
    )

    public static let buildResult: Value = object(
        properties: [
            "succeeded": boolean,
            "prgPath": nullable(string),
            "rebuilt": boolean,
            "rebuildReason": rebuildReason,
            "artifactKey": string,
            "sdk": string,
            "device": string,
            "mode": buildMode,
            "diagnostics": array(
                of: object(
                    properties: [
                        "file": nullable(string),
                        "line": nullable(integer),
                        "column": nullable(integer),
                        "severity": string,
                        "message": string,
                    ],
                    required: ["file", "line", "column", "severity", "message"]
                )),
        ],
        required: [
            "succeeded", "prgPath", "rebuilt", "rebuildReason", "artifactKey", "sdk", "device",
            "mode", "diagnostics",
        ]
    )

    public static let simStatusResult: Value = object(
        properties: [
            "state": simulatorState,
            "operation": nullable(string),
            "pid": nullable(integer),
            "executablePath": nullable(string),
            "sdkPath": nullable(string),
            "sdkVersion": nullable(string),
            "currentDevice": nullable(string),
            "requestedDevice": nullable(string),
            "deviceSource": stringEnum(["observed", "unobserved"]),
            "leaseHolder": nullable(string),
        ],
        required: [
            "state", "operation", "pid", "executablePath", "sdkPath", "sdkVersion",
            "currentDevice", "requestedDevice", "deviceSource", "leaseHolder",
        ]
    )

    public static let simStartResult: Value = object(
        properties: ["status": simStatusResult],
        required: ["status"]
    )

    public static let simStopResult: Value = object(
        properties: ["status": simStatusResult],
        required: ["status"]
    )

    public static let runAppResult: Value = object(
        properties: [
            "sessionId": integer,
            "device": string,
            "prgPath": string,
            "sdkPath": string,
            "sdkVersion": string,
            "rebuilt": boolean,
            "rebuildReason": rebuildReason,
            "deviceVerified": boolean,
            "deviceVerificationUnavailable": nullable(string),
            "observedDeviceDisplayName": nullable(string),
            "simulatorRestarted": boolean,
            "invalidatedSessionId": nullable(integer),
        ],
        required: [
            "sessionId", "device", "prgPath", "sdkPath", "sdkVersion", "rebuilt", "rebuildReason",
            "deviceVerified", "deviceVerificationUnavailable", "observedDeviceDisplayName",
            "simulatorRestarted", "invalidatedSessionId",
        ]
    )

    public static let runTestsResult: Value = object(
        properties: [
            "passed": integer,
            "failed": integer,
            "errors": integer,
            "overallPassed": boolean,
            "perTest": array(
                of: object(
                    properties: [
                        "name": string,
                        "status": string,
                        "duration": nullable(number),
                        "message": nullable(string),
                    ],
                    required: ["name", "status", "duration", "message"]
                )),
            "device": string,
            "sdkPath": string,
            "prgPath": string,
        ],
        required: [
            "passed", "failed", "errors", "overallPassed", "perTest", "device", "sdkPath",
            "prgPath",
        ]
    )

    public static let getLogsResult: Value = object(
        properties: [
            "sessionId": integer,
            "state": string,
            "terminationReason": nullable(string),
            "exitCode": nullable(integer),
            "crashDetected": boolean,
            "droppedLines": integer,
            "lines": array(
                of: object(
                    properties: [
                        "seq": integer,
                        "monotonicNanos": integer,
                        "stream": logStream,
                        "text": string,
                        "crash": boolean,
                    ],
                    required: ["seq", "monotonicNanos", "stream", "text", "crash"]
                )),
            "nextToken": string,
            "latestToken": string,
        ],
        required: [
            "sessionId", "state", "terminationReason", "exitCode", "crashDetected",
            "droppedLines", "lines", "nextToken", "latestToken",
        ]
    )

    public static let displaySize: Value = object(
        properties: ["width": integer, "height": integer],
        required: ["width", "height"]
    )

    public static let screenshotResult: Value = object(
        properties: [
            "path": string,
            "mimeType": string,
            "width": integer,
            "height": integer,
            "capturedPid": integer,
            "device": nullable(string),
            "deviceDisplayName": nullable(string),
            "nativeResolution": nullable(displaySize),
            "appDisplayRect": nullable(object(
                properties: [
                    "x": integer,
                    "y": integer,
                    "width": integer,
                    "height": integer,
                ],
                required: ["x", "y", "width", "height"]
            )),
        ],
        required: [
            "path", "mimeType", "width", "height", "capturedPid", "device",
            "deviceDisplayName", "nativeResolution", "appDisplayRect",
        ]
    )

    public static let pressButtonResult: Value = object(
        properties: [
            "button": string,
            "pressType": stringEnum(["press", "hold"]),
            "transport": stringEnum(["protocol", "ax-keyboard-post", "focused-keys"]),
            "simulatorPid": integer,
        ],
        required: ["button", "pressType", "transport", "simulatorPid"]
    )

    /// One flat outcome record with per-kind nullable columns, the idiom
    /// `diagnostics` and `perTest` already use. Frame bytes are not here: they
    /// travel as `image` content blocks, and `index`/`label` correlate them.
    public static let runSequenceResult: Value = object(
        properties: [
            "sessionId": nullable(integer),
            "steps": array(
                of: object(
                    properties: [
                        "index": integer,
                        "kind": stringEnum(["press", "screenshot", "waitForLog"]),
                        "status": stringEnum(["completed", "failed", "skipped"]),
                        "label": nullable(string),
                        "button": nullable(string),
                        "pressType": nullable(string),
                        "transport": nullable(string),
                        "waitedMs": nullable(integer),
                        "linesScanned": nullable(integer),
                        "path": nullable(string),
                        "width": nullable(integer),
                        "height": nullable(integer),
                        "device": nullable(string),
                        "deviceDisplayName": nullable(string),
                        "nativeResolution": nullable(displaySize),
                    ],
                    required: [
                        "index", "kind", "status", "label", "button", "pressType", "transport",
                        "waitedMs", "linesScanned", "path", "width", "height", "device",
                        "deviceDisplayName", "nativeResolution",
                    ]
                )),
            "frameCount": integer,
        ],
        required: ["sessionId", "steps", "frameCount"]
    )

    public static let setGpsPositionResult: Value = object(
        properties: [
            "latitude": number,
            "longitude": number,
            "simulatorPid": integer,
        ],
        required: ["latitude", "longitude", "simulatorPid"]
    )
}
