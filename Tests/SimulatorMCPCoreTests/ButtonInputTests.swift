import Foundation
@preconcurrency import ApplicationServices
import MCP
import os
import Testing
@testable import SimulatorMCPCore

@Suite("ButtonInput")
struct ButtonInputTests {
    @Test("the public surface registers press_button")
    func publicToolSurface() throws {
        let published = try ToolHandlers.live().map(\.definition.name).sorted()
        #expect(published == [
            "build", "doctor", "get_logs", "list_devices", "list_sdks", "press_button", "run_app",
            "run_tests", "screenshot", "set_gps_position", "sim_start", "sim_status", "sim_stop",
        ])
    }

    /// Exactly the qualified devices advertise input, and every other installed
    /// profile stays fail-closed — including `fenix3`, `fenix5` and
    /// `fenixchronos`, which share the same physical key layout and would be
    /// swept in by any shape heuristic.
    @Test("only qualified devices advertise input capability")
    func publicDeviceCapability() async throws {
        let devices = try await ToolHandlerServices.live().listDevices(
            ListDevicesToolRequest(projectPath: nil, jungle: nil, sdk: nil))
        let supported = Set(devices.devices.filter(\.inputSupported).map(\.deviceId))
        #expect(supported == InputProfileLoader.qualifiedDevices)

        for device in devices.devices where InputProfileLoader.qualifiedDevices.contains(device.deviceId) {
            #expect(device.buttons == ["enter", "esc", "up", "down"])
            #expect(device.inputProfile == "\(device.deviceId)-verified/3")
        }
        for device in devices.devices where !InputProfileLoader.qualifiedDevices.contains(device.deviceId) {
            #expect(device.inputSupported == false)
            #expect(device.buttons.isEmpty)
            #expect(device.inputProfile == nil)
        }
        for lookalike in ["fenix3", "fenix5", "fenixchronos"] {
            let device = try #require(devices.devices.first { $0.deviceId == lookalike })
            #expect(device.inputSupported == false)
        }
    }

    @Test("bundled qualification profile is exact and fail-closed")
    func qualificationProfile() throws {
        let qualified = try InputProfileLoader.loadQualificationCandidate()
        let profile = qualified.profile
        let data = try InputProfileLoader.qualificationCandidateData()
        #expect(profile.core.schemaVersion == 2)
        #expect(profile.core.profileVersion == "fenix6xpro-verified/3")
        #expect(profile.core.qualification)
        #expect(profile.core.device == "fenix6xpro")
        #expect(profile.core.buttonOrder == ["enter", "esc", "up", "down"])
        #expect(profile.core.holdEncoding == HoldEncoding(
            mechanism: "down-up", fixtureThresholdMs: 300, gateHoldMs: 1000, minimumPressMs: 50))
        #expect(profile.core.evidence.sdks == ["8.4.1", "9.1.0"])
        #expect(profile.core.evidence.macOSVersion == "26.5.2")
        #expect(profile.core.evidence.surfaceDigests == [
            "garmin-community-keyboard-shortcuts": "d6ed40565ca4e7d116cac01bac256ff27af64385a4eff30cb7c7806b38f6c7ab",
            "apple-hitoolbox-release-notes": "a47905d4f43b6ecf5f7f24465777870849e578c19d4d9d738f4a84fff08d32c1",
            "preserved-hitoolbox-events-header": "f0c475dbc4500f6f4d867fb224d29b18596a9d8880fabf1ba4fd9cfc84eafac0",
        ])
        #expect(profile.core.evidence.gateTranscriptDigests == ["8.4.1": "", "9.1.0": ""])
        #expect(qualified.keyboardLayoutPredicate == KeyboardLayoutPredicate(
            inputSourceID: "com.apple.keylayout.US", requiresEnabled: true))
        #expect(profile.transport.kind == .focusedKeys)
        guard case .focusedKeys(let focused) = profile.transport else {
            Issue.record("qualification profile is not focused-keys")
            return
        }
        #expect(focused.leavesSimulatorFrontmost)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawTransport = try #require(raw["transportProfile"] as? [String: Any])
        #expect(rawTransport["restoration"] == nil)

        let expected = ["enter": 36, "esc": 53, "up": 126, "down": 125]
        for sdk in ["8.4.1", "9.1.0"] {
            let entry = try #require(profile.transport.sdkEntries[sdk])
            #expect(Set(entry.keys) == Set(expected.keys))
            for (button, code) in expected {
                #expect(entry[button] == ["keyCode": .int(code)])
            }
        }

        let registry = try InputCapabilityRegistry(qualified)
        #expect(registry.capability(device: "fenix6xpro", sdkVersion: "8.4.1")?.buttons == profile.core.buttonOrder)
        #expect(registry.capability(device: "fenix6xpro", sdkVersion: "9.1.0")?.profile == profile.core.profileVersion)
        #expect(registry.capability(device: "fenix6xpro", sdkVersion: "9.2.0") == nil)
        #expect(registry.capability(device: "venu3", sdkVersion: "9.1.0") == nil)

        let contractURL = repositoryRoot().appending(
            path: "docs/verification/simulator-contracts/fenix6xpro-input.json")
        let contract = try InputProfileLoader.decodeQualification(Data(contentsOf: contractURL))
        #expect(contract.profile == profile)
        #expect(contract.keyboardLayoutPredicate == qualified.keyboardLayoutPredicate)
    }

    @Test("profile loader rejects unknown keys, stale mappings, malformed and unqualified profiles")
    func qualificationProfileRejections() throws {
        let data = try InputProfileLoader.qualificationCandidateData()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unknown"] = true
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }

        object.removeValue(forKey: "unknown")
        object["qualification"] = false
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }

        object["qualification"] = true
        object["schemaVersion"] = 1
        object["profileVersion"] = "fenix6xpro-qualification/1"
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }

        object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var evidence = try #require(object["evidence"] as? [String: Any])
        evidence["surfaceDigests"] = [:]
        object["evidence"] = evidence
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }

        object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var transport = try #require(object["transportProfile"] as? [String: Any])
        transport.removeValue(forKey: "leavesSimulatorFrontmost")
        transport["restoration"] = ["verifyPreviousFrontmostPID": true]
        object["transportProfile"] = transport
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }

        object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        transport = try #require(object["transportProfile"] as? [String: Any])
        transport["leavesSimulatorFrontmost"] = false
        object["transportProfile"] = transport
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }

        object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        transport = try #require(object["transportProfile"] as? [String: Any])
        var activation = try #require(transport["activation"] as? [String: Any])
        activation["keyboardLayoutPredicate"] = [
            "inputSourceID": "com.apple.keylayout.ABC", "requiresEnabled": true,
        ]
        transport["activation"] = activation
        object["transportProfile"] = transport
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }

        object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        transport = try #require(object["transportProfile"] as? [String: Any])
        activation = try #require(transport["activation"] as? [String: Any])
        activation["keyboardLayoutPredicate"] = [
            "inputSourceID": "com.apple.keylayout.US", "requiresEnabled": false,
        ]
        transport["activation"] = activation
        object["transportProfile"] = transport
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }

        object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        transport = try #require(object["transportProfile"] as? [String: Any])
        var entries = try #require(transport["sdkEntries"] as? [String: Any])
        var sdkEntry = try #require(entries["8.4.1"] as? [String: Any])
        sdkEntry["down"] = ["keyCode": 2]
        entries["8.4.1"] = sdkEntry
        transport["sdkEntries"] = entries
        object["transportProfile"] = transport
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(JSONSerialization.data(withJSONObject: object))
        }
    }

    /// fēnix 8 and fēnix E require Connect IQ API level 6.0.0, which SDK 8.4.1
    /// cannot compile (it caps at 5.2.0). SDK coverage is therefore per-device
    /// data, not a global constant — but the three places that declare it must
    /// still agree exactly, or a profile could claim a gate it never ran.
    @Test("SDK coverage is per profile and must agree across transport and evidence")
    func perProfileSdkCoverage() throws {
        let data = try InputProfileLoader.qualificationCandidateData()

        func mutate(_ change: (inout [String: Any]) throws -> Void) throws -> Data {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            try change(&object)
            return try JSONSerialization.data(withJSONObject: object)
        }

        func setCoverage(
            _ object: inout [String: Any], sdkEntries: [String], evidence sdks: [String],
            digests: [String]
        ) throws {
            var transport = try #require(object["transportProfile"] as? [String: Any])
            let entries = try #require(transport["sdkEntries"] as? [String: Any])
            let template = try #require(entries["9.1.0"])
            transport["sdkEntries"] = Dictionary(
                uniqueKeysWithValues: sdkEntries.map { ($0, template) })
            object["transportProfile"] = transport

            var evidenceObject = try #require(object["evidence"] as? [String: Any])
            evidenceObject["sdks"] = sdks
            evidenceObject["gateTranscriptDigests"] = Dictionary(
                uniqueKeysWithValues: digests.map { ($0, "") })
            object["evidence"] = evidenceObject
        }

        // A device that only exists on 9.1.0 is a valid qualification profile.
        let singleSdk = try mutate {
            try setCoverage(
                &$0, sdkEntries: ["9.1.0"], evidence: ["9.1.0"], digests: ["9.1.0"])
        }
        let loaded = try InputProfileLoader.decodeQualification(singleSdk)
        #expect(loaded.profile.transport.sdkEntries.keys.sorted() == ["9.1.0"])
        #expect(loaded.profile.core.evidence.sdks == ["9.1.0"])

        // Declaring no SDK at all claims capability backed by no gate run.
        let noSdk = try mutate {
            try setCoverage(
                &$0, sdkEntries: [], evidence: [], digests: [])
        }
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(noSdk)
        }

        // Evidence must not claim an SDK the transport cannot drive.
        let evidenceOverclaims = try mutate {
            try setCoverage(
                &$0, sdkEntries: ["9.1.0"], evidence: ["8.4.1", "9.1.0"], digests: ["9.1.0"])
        }
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(evidenceOverclaims)
        }

        // Every declared SDK needs its own gate transcript digest.
        let digestGap = try mutate {
            try setCoverage(
                &$0, sdkEntries: ["8.4.1", "9.1.0"], evidence: ["8.4.1", "9.1.0"], digests: ["9.1.0"])
        }
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(digestGap)
        }

        // An SDK version this server does not recognise is not a gate.
        let unknownSdk = try mutate {
            try setCoverage(
                &$0, sdkEntries: ["7.0.0"], evidence: ["7.0.0"], digests: ["7.0.0"])
        }
        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(unknownSdk)
        }
    }

    /// A1: capability is keyed by exact device id from a compiled-in set. The
    /// public entry point must never accept a device outside it, however well
    /// formed the profile is — this is the guard D1 originally deleted.
    @Test("the qualified device set is compiled in, not taken from the profile")
    func compiledInDeviceAllowlist() throws {
        let data = try InputProfileLoader.qualificationCandidateData()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["device"] = "fenix5"
        object["profileVersion"] = "fenix5-verified/3"
        let forged = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(forged)
        }
        // The same bytes are decodable only when a caller widens the allowlist
        // explicitly, which no profile and no resource file can do for itself.
        let widened = try InputProfileLoader.decodeQualification(forged, allowing: ["fenix5"])
        #expect(widened.profile.core.device == "fenix5")
    }

    /// A2: the device-to-key-code assignment is compiled in. Every permutation
    /// of the permitted codes is still four permitted codes, so only equality
    /// against the layout group catches a transposed mapping.
    @Test("a permuted key mapping is rejected against the compiled-in layout group")
    func permutedMappingRejected() throws {
        let data = try InputProfileLoader.qualificationCandidateData()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var transport = try #require(object["transportProfile"] as? [String: Any])
        var entries = try #require(transport["sdkEntries"] as? [String: Any])
        var entry = try #require(entries["9.1.0"] as? [String: Any])
        entry["enter"] = ["keyCode": 53]
        entry["esc"] = ["keyCode": 36]
        entries["9.1.0"] = entry
        transport["sdkEntries"] = entries
        object["transportProfile"] = transport

        #expect(throws: InputProfileValidationError.self) {
            try InputProfileLoader.decodeQualification(
                try JSONSerialization.data(withJSONObject: object))
        }
    }

    /// A1 again, from the other side: the registry serves several devices, and
    /// two profiles claiming the same device id are a load failure rather than
    /// a last-one-wins overwrite.
    @Test("the capability registry is keyed by device and rejects duplicates")
    func multiDeviceRegistry() throws {
        let data = try InputProfileLoader.qualificationCandidateData()
        func profile(device: String) throws -> QualifiedInputProfile {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["device"] = device
            object["profileVersion"] = "\(device)-verified/3"
            return try InputProfileLoader.decodeQualification(
                try JSONSerialization.data(withJSONObject: object), allowing: [device])
        }

        let registry = try InputCapabilityRegistry(
            [try profile(device: "fenix6xpro"), try profile(device: "fenix7xpro")])
        #expect(registry.capability(device: "fenix6xpro", sdkVersion: "9.1.0") != nil)
        #expect(registry.capability(device: "fenix7xpro", sdkVersion: "8.4.1") != nil)
        #expect(registry.capability(device: "fenix5", sdkVersion: "9.1.0") == nil)
        #expect(registry.capability(device: "fenix7xpro", sdkVersion: "7.0.0") == nil)

        #expect(throws: InputProfileValidationError.self) {
            try InputCapabilityRegistry(
                [try profile(device: "fenix6xpro"), try profile(device: "fenix6xpro")])
        }
    }

    /// A1: the shipped resources and the compiled-in set must agree exactly, so
    /// capability can never become a filesystem side effect in either
    /// direction — an unlisted resource is as fatal as a missing one.
    @Test("shipped profile resources equal the compiled-in qualified device set")
    func shippedResourcesMatchAllowlist() throws {
        let profiles = try InputProfileLoader.loadQualificationCandidates()
        #expect(Set(profiles.map { $0.profile.core.device }) == InputProfileLoader.qualifiedDevices)
    }

    /// A5. Two independently authored artifacts must agree: the shipped profile
    /// resource and the measured delivery contract produced by the gate. This
    /// is what carries the evidence role the compiled-in key code constant used
    /// to carry — a copy-paste or agent error shows up offline and for free,
    /// and forging capability becomes a conspicuous two-file diff that includes
    /// a fabricated measurement document.
    @Test("every shipped profile agrees with its own measured delivery contract")
    func profilesAgreeWithDeliveryContracts() throws {
        struct DeliveryContract: Decodable {
            struct Facts: Decodable {
                struct Buttons: Decodable { let verified: [String: Int] }
                let buttons: Buttons
            }
            let device: String
            let sdks: [String]
            let facts: Facts
        }

        let profiles = try InputProfileLoader.loadQualificationCandidates()
        #expect(!profiles.isEmpty)

        for qualified in profiles {
            let profile = qualified.profile
            let device = profile.core.device
            let url = repositoryRoot().appending(
                path: "docs/verification/simulator-contracts/\(device)-focused-delivery.json")
            #expect(
                FileManager.default.isReadableFile(atPath: url.path),
                Comment(rawValue: "\(device): no measured delivery contract"))
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }

            let contract = try JSONDecoder().decode(
                DeliveryContract.self, from: try Data(contentsOf: url))
            #expect(contract.device == device)
            #expect(Set(contract.sdks) == Set(profile.transport.sdkEntries.keys))

            let measured = Dictionary(
                uniqueKeysWithValues: contract.facts.buttons.verified.map {
                    ($0, ["keyCode": JSONValue.int($1)])
                })
            for (sdk, entry) in profile.transport.sdkEntries {
                #expect(
                    entry == measured,
                    Comment(rawValue: "\(device) on \(sdk): profile disagrees with measurement"))
            }
        }
    }

    @Test("press type changes only at the profile threshold")
    func pressTypeThreshold() async throws {
        let fake = RecordingTransport()
        let service = makeService(transport: fake)
        #expect(try await service.press(PressButtonToolRequest(button: "up", holdMs: 299)).pressType == "press")
        #expect(try await service.press(PressButtonToolRequest(button: "up", holdMs: 300)).pressType == "hold")
    }

    @Test("qualification handler has strict schema, defaults focus, and preserves envelope parity")
    func qualificationHandler() async throws {
        let recorder = QualificationRequestRecorder()
        try await withMCPHarness(handlers: ToolHandlers.qualificationConfigured(qualificationServices(pressButton: { request in
            await recorder.record(request)
            return PressButtonResult(button: request.button, pressType: "press", transport: "focused-keys", simulatorPid: 42)
        }))) { harness in
            let tools = try await harness.listTools()
            let tool = try #require(tools.first { $0.name == "press_button" })
            #expect(String(describing: tool.description).contains("allowFocus=true"))
            #expect(String(describing: tool.description).contains("leaves it frontmost"))
            guard case .object(let schema) = tool.inputSchema else { Issue.record("missing object schema"); return }
            #expect(schema["additionalProperties"] == false)
            #expect(schema["required"] == ["button"])

            let response = try await harness.call("press_button", arguments: ["button": "up"], as: PressButtonResult.self)
            #expect(response.envelope.result?.button == "up")
            #expect(response.raw.content.count == 1)
            #expect(await recorder.requests == [PressButtonToolRequest(button: "up")])

            let unknown = try await harness.call("press_button", arguments: ["button": "up", "extra": true], as: PressButtonResult.self)
            #expect(unknown.envelope.error?.code == "invalid_arguments")
            let invalidHold = try await harness.call("press_button", arguments: ["button": "up", "holdMs": 49], as: PressButtonResult.self)
            #expect(invalidHold.envelope.error?.code == "invalid_arguments")
        }
    }

    @Test("candidate lifecycle preserves ordering and retained/restored payload state")
    func candidateLifecycle() async throws {
        let passing = CandidateLifecycleTestSupport()
        try await passing.runCandidate()
        #expect(await passing.events == [.preInstallValidation, .backup, .verifyBackupDigest, .installCandidate, .verifyCandidate, .runCandidateGate, .candidateSucceeded])
        #expect(await passing.backupRetained)

        let preInstall = CandidateLifecycleTestSupport()
        await #expect(throws: CandidateLifecycleTestError.self) {
            try await preInstall.runCandidate(failurePoint: .preInstall)
        }
        #expect(await preInstall.events == [.preInstallValidation])

        let restored = CandidateLifecycleTestSupport()
        await #expect(throws: CandidateLifecycleTestError.self) {
            try await restored.runCandidate(failurePoint: .candidateVerification)
        }
        #expect(await restored.events == [.preInstallValidation, .backup, .verifyBackupDigest, .installCandidate, .verifyCandidate, .verifyBackupDigest, .restoreExecutableAndResources, .verifyRestoredDigest, .verifyAllDeviceCapability])
        #expect(await restored.restoredToolNames.count == 12)
        #expect(await restored.restoredToolNames.contains("press_button") == false)
        #expect(await restored.allDevicesFailClosed)
        #expect(await restored.installedResourcePresent == false)

        let restoredExistingResource = CandidateLifecycleTestSupport(originalResourcePresent: true)
        await #expect(throws: CandidateLifecycleTestError.self) {
            try await restoredExistingResource.runCandidate(failurePoint: .candidateGate)
        }
        #expect(await restoredExistingResource.installedResourcePresent)

        let corrupt = CandidateLifecycleTestSupport(restoreDigestValid: false)
        await #expect(throws: CandidateLifecycleTestError.self) {
            try await corrupt.runCandidate(failurePoint: .candidateGate)
        }
        #expect(await corrupt.events.contains(.restoreExecutableAndResources) == false)
        #expect(await corrupt.events.contains(.installCandidate))
    }

    @Test("focused transport preflights keyboard and permission before focus or events")
    func focusedPreflightOrdering() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))
        let service = ButtonInputService(
            profile: profile.profile, transport: transport, operationRunner: readyRunner())
        let unsupportedSources: [(Bool, FocusedKeyTransport.KeyboardSource)] = [
            (false, .init(id: "com.apple.keylayout.US", enabled: true)),
            (true, .init(id: nil, enabled: true)),
            (true, .init(id: "com.apple.keylayout.US", enabled: nil)),
            (true, .init(id: "com.apple.keylayout.US", enabled: false)),
            (true, .init(id: "com.apple.keylayout.ABC", enabled: true)),
        ]
        for (available, source) in unsupportedSources {
            environment.reset(source: source)
            environment.sourceAvailable = available
            let keyboardError = await #expect(throws: ToolError.self) {
                try await service.press(PressButtonToolRequest(button: "up", allowFocus: true))
            }
            #expect(keyboardError?.code == "keyboard_layout_unsupported")
            #expect(keyboardError?.fix.contains("ANSI-US") == true)
            #expect(environment.calls.first == "inputSource")
            #expect(environment.calls.contains("permission") == false)
        }

        environment.reset(source: .init(id: "com.apple.keylayout.US", enabled: true))
        environment.permissionGranted = false
        let permissionError = await #expect(throws: ToolError.self) {
            try await service.press(PressButtonToolRequest(button: "up", allowFocus: true))
        }
        #expect(permissionError?.code == "accessibility_denied")
        #expect(environment.calls == ["inputSource", "inputSourceID", "inputSourceEnabled", "permission"])
    }

    @Test("focused transport rejects absent simulator without requiring previous focus")
    func focusedApplicationPreconditions() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        for configure in [
            { (environment: FocusedTransportEnvironment) in environment.missingApplicationPIDs = [42] },
            { environment in environment.terminatedApplicationPIDs = [42] },
        ] {
            let environment = FocusedTransportEnvironment()
            configure(environment)
            let transport = try FocusedKeyTransport(
                profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))
            await #expect(throws: ButtonInputTransportError.self) {
                try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
            }
            #expect(environment.constructed.isEmpty)
            #expect(environment.activations.isEmpty)
        }

        let noPrevious = FocusedTransportEnvironment()
        noPrevious.setFrontmost(99)
        noPrevious.missingApplicationPIDs = [99]
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: noPrevious.dependencies, clock: FakeClock(autoAdvance: true))
        try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        #expect(noPrevious.focusRequests.map(\.pid) == [42])
        #expect(noPrevious.applicationLookups.contains(7) == false)
    }

    @Test("focused transport skips activation when simulator is exact frontmost")
    func focusedAlreadyFrontmostLifecycle() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        environment.setFrontmost(42)
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))

        try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())

        #expect(environment.focusRequests.isEmpty)
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        #expect(environment.applicationLookups.contains(7) == false)
    }

    @Test("focused transport accepts a false request callback after exact focus proof")
    func focusedFalseCallbackWithExactFocus() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        environment.simulatorRequestResult = .init(
            callbackPID: nil, errorDescription: "Launch Services denied activation")
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))

        try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())

        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        #expect(environment.focusRequests.map(\.pid) == [42])
    }

    @Test("focused transport rejects callback PID mismatch and same-PID replacement")
    func focusedIdentityMismatchesFailClosed() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()

        let callbackMismatch = FocusedTransportEnvironment()
        callbackMismatch.simulatorRequestResult = .init(callbackPID: 99, errorDescription: nil)
        let callbackTransport = try FocusedKeyTransport(
            profile: profile, dependencies: callbackMismatch.dependencies, clock: FakeClock(autoAdvance: true))
        await #expect(throws: ButtonInputTransportError.self) {
            try await callbackTransport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        #expect(callbackMismatch.posted.isEmpty)
        #expect(callbackMismatch.focusRequests.map(\.pid) == [42])

        let replacement = FocusedTransportEnvironment()
        replacement.simulatorReplacement = .init(
            pid: 42,
            bundleURL: URL(fileURLWithPath: "/Applications/Replacement.app"),
            executableURL: URL(fileURLWithPath: "/Applications/Replacement.app/Contents/MacOS/Replacement"),
            bundleIdentifier: "example.replacement",
            launchDate: Date(timeIntervalSince1970: 43),
            isTerminated: false)
        replacement.replaceSimulatorOnRequest = true
        let replacementTransport = try FocusedKeyTransport(
            profile: profile, dependencies: replacement.dependencies, clock: FakeClock(autoAdvance: true))
        await #expect(throws: ButtonInputTransportError.self) {
            try await replacementTransport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        #expect(replacement.posted.isEmpty)
        #expect(replacement.focusRequests.map(\.pid) == [42])

        let launchDateReplacement = FocusedTransportEnvironment()
        launchDateReplacement.simulatorReplacement = .init(
            pid: 42,
            bundleURL: URL(fileURLWithPath: "/Applications/Simulator.app"),
            executableURL: URL(fileURLWithPath: "/Applications/Simulator.app/Contents/MacOS/Simulator"),
            bundleIdentifier: "example.simulator",
            launchDate: Date(timeIntervalSince1970: 420),
            isTerminated: false)
        launchDateReplacement.replaceSimulatorOnRequest = true
        let launchDateTransport = try FocusedKeyTransport(
            profile: profile, dependencies: launchDateReplacement.dependencies, clock: FakeClock(autoAdvance: true))
        await #expect(throws: ButtonInputTransportError.self) {
            try await launchDateTransport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        #expect(launchDateReplacement.posted.isEmpty)
        #expect(launchDateReplacement.focusRequests.map(\.pid) == [42])
    }

    @Test("focused transport rejects successful callback without exact focus")
    func focusedCallbackWithoutFocusFailsClosed() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        environment.activationChangesFrontmost = false
        environment.simulatorRequestResult = .init(callbackPID: 42, errorDescription: nil)
        let clock = FakeClock()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: clock,
            focusTimeout: .seconds(1), pollInterval: .milliseconds(10))
        let task = Task {
            try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        await clock.waitUntilPendingSleepCount(1)
        clock.advance(by: .seconds(1))

        await #expect(throws: ButtonInputTransportError.self) { try await task.value }
        #expect(environment.posted.isEmpty)
        #expect(environment.focusRequests.map(\.pid) == [42])
    }

    @Test("focused transport constructs up then down, posts balanced events, and leaves Simulator frontmost")
    func focusedSuccessLifecycle() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))
        try await transport.press(
            ButtonPressRequest(button: "up"), context: focusedContext())
        #expect(environment.constructed == ["up:126", "down:126", "up:56", "down:56"])
        #expect(environment.lifecycle == [
            "construct:up:126", "construct:down:126", "construct:up:56", "construct:down:56",
            "activate:42", "keyfocus:granted",
            "post:down:56", "post:up:56", "post:down:126", "post:up:126",
        ])
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        #expect(environment.activations == [42])
        #expect(environment.frontmostPID == 42)
        #expect(transport.kind == .focusedKeys)
        #expect(transport.requiresFocusOptIn)
    }

    @Test("short press holds the key down long enough for the simulator to observe it")
    func focusedShortPressDwell() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: ContinuousClock())

        try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())

        // Measured on both installed SDKs: a key pair posted with no dwell is
        // never delivered; 10ms and above is delivered every time.
        let dwell = try #require(environment.downToUpDwell)
        #expect(dwell >= .milliseconds(50))
    }

    @Test("an explicit hold longer than the minimum dwell is preserved")
    func focusedExplicitHoldWins() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: ContinuousClock())

        try await transport.press(
            ButtonPressRequest(button: "up", holdMs: 400), context: focusedContext())

        let dwell = try #require(environment.downToUpDwell)
        #expect(dwell >= .milliseconds(400))
    }

    @Test("no key is posted until the activated simulator has taken key focus")
    func focusedWaitsForKeyFocusAfterActivation() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        // Frontmost flips immediately, but the window server hands key focus
        // over a few polls later. A key posted in that window is delivered to
        // the previously focused application instead of the simulator.
        environment.keyFocusReadyAfterChecks = 3

        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies,
            clock: FakeClock(autoAdvance: true))
        try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())

        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        let firstPost = try #require(environment.lifecycle.firstIndex(of: "post:down:126"))
        let keyFocusGranted = try #require(environment.lifecycle.firstIndex(of: "keyfocus:granted"))
        #expect(keyFocusGranted < firstPost)
    }

    @Test("an inert modifier absorbs the simulator's swallowed first key before the real button")
    func focusedWarmsUpBeforePressing() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies,
            clock: FakeClock(autoAdvance: true))

        try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())

        // kVK_Shift. The simulator consumes the first key event delivered
        // after an app launches; a modifier absorbs it and can never be
        // decoded as a device button.
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        let warmUpDown = try #require(environment.lifecycle.firstIndex(of: "post:down:56"))
        let warmUpUp = try #require(environment.lifecycle.firstIndex(of: "post:up:56"))
        let realDown = try #require(environment.lifecycle.firstIndex(of: "post:down:126"))
        #expect(warmUpDown < warmUpUp)
        #expect(warmUpUp < realDown)
    }

    @Test("no key is posted when another application is active, even if the simulator owns the front window")
    func focusedRequiresActiveApplication() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        // A windowless application (Finder with no windows) can be the active
        // application while the simulator still owns the frontmost window.
        // Keys posted to the session tap go to the active application, so
        // window order alone must never authorize a press.
        environment.activePID = 7

        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies,
            clock: FakeClock(autoAdvance: true), focusTimeout: .milliseconds(50))

        _ = await #expect(throws: ButtonInputTransportError.self) {
            try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        #expect(environment.posted.isEmpty)
    }

    @Test("focused transport records one simulator outcome without restoration diagnostics")
    func focusedSuccessDiagnostics() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let diagnostics = FocusedDiagnosticRecorder()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true),
            diagnosticSink: { diagnostics.record($0) })

        try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())

        #expect(diagnostics.events.contains { $0.description.contains("role_capture role=previous") } == false)
        #expect(diagnostics.events.contains { $0.description.contains("restoration") } == false)
        #expect(diagnostics.events.last?.description == "outcome primary=success")
    }

    @Test("focused transport uses one exact simulator observation at the down boundary")
    func focusedImmediateDownObservation() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        environment.setFrontmostObservationSequence([7, 42, 42, 42, 7])
        let diagnostics = FocusedDiagnosticRecorder()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true),
            diagnosticSink: { diagnostics.record($0) })

        try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())

        let boundary = diagnostics.events.compactMap { event -> FocusedKeyTransport.Diagnostic? in
            guard case .eventBoundary(let phase, _) = event,
                  phase == "immediately_before_down"
            else { return nil }
            return event
        }
        #expect(boundary == [.eventBoundary(phase: "immediately_before_down", frontmostPID: 42)])
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
    }

    @Test("focused transport rejects focus drift immediately before down without posting")
    func focusedDriftImmediatelyBeforeDown() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        // Active on the activation poll, then stolen again before key-down.
        environment.setActiveSequence([false, true, false])
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))

        let error = await #expect(throws: ButtonInputTransportError.self) {
            try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        guard case .workspaceActivation? = error else {
            Issue.record("immediate pre-down focus drift did not fail closed")
            return
        }
        #expect(environment.activations == [42])
        #expect(environment.posted.isEmpty)
        #expect(environment.remainingActiveObservations == 0)
    }

    @Test("focused transport proves exact Simulator identity after ordinary up")
    func focusedImmediateUpObservation() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        environment.loseSimulatorFrontmostOnUp = true
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))

        let error = await #expect(throws: ButtonInputTransportError.self) {
            try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        guard case .workspaceActivation? = error else {
            Issue.record("post-up frontmost proof did not fail closed")
            return
        }
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        #expect(environment.activations == [42])
    }

    @Test("focused transport rejects same-PID Simulator identity replacement after up")
    func focusedPostUpIdentityReplacement() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        environment.simulatorReplacement = .init(
            pid: 42,
            bundleURL: URL(fileURLWithPath: "/Applications/ReplacedSimulator.app"),
            executableURL: URL(fileURLWithPath: "/Applications/ReplacedSimulator.app/Contents/MacOS/Simulator"),
            bundleIdentifier: "example.replacement",
            launchDate: Date(timeIntervalSince1970: 43),
            isTerminated: false)
        environment.replaceSimulatorOnUp = true
        let diagnostics = FocusedDiagnosticRecorder()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true),
            diagnosticSink: { diagnostics.record($0) })

        let error = await #expect(throws: ButtonInputTransportError.self) {
            try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        guard case .workspaceActivation? = error else {
            Issue.record("same-PID post-up identity replacement did not fail closed")
            return
        }
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        #expect(environment.frontmostPID == 42)
        let afterUp = diagnostics.events.filter {
            $0 == .eventBoundary(phase: "after_up", frontmostPID: 42)
        }
        #expect(afterUp == [.eventBoundary(phase: "after_up", frontmostPID: 42)])
        #expect(diagnostics.events.last == .outcome(primary: "failure"))
    }

    @Test("focused cancellation after callback returns posts no event")
    func focusedCancellationAfterFocusCallback() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let cancellation = CancellationController()
        environment.cancellationAction = { cancellation.cancel() }
        environment.cancelAfterSimulatorCallback = true
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))
        let task = Task {
            try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        cancellation.setAction { task.cancel() }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(environment.posted.isEmpty)
        #expect(environment.focusRequests.map(\.pid) == [42])
    }

    @Test("focused cancellation while polling posts no event")
    func focusedCancellationDuringFocusPolling() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let cancellation = CancellationController()
        environment.cancellationAction = { cancellation.cancel() }
        environment.cancelOnSimulatorFrontmostObservation = true
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true))
        let task = Task {
            try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        cancellation.setAction { task.cancel() }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(environment.posted.isEmpty)
        #expect(environment.focusRequests.map(\.pid) == [42])
    }

    @Test("focused construction and activation timeout fail without posting")
    func focusedConstructionAndActivationFailures() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let construction = FocusedTransportEnvironment()
        construction.failDownConstruction = true
        let constructionTransport = try FocusedKeyTransport(
            profile: profile, dependencies: construction.dependencies, clock: FakeClock(autoAdvance: true))
        await #expect(throws: ButtonInputTransportError.self) {
            try await constructionTransport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        #expect(construction.posted.isEmpty)
        #expect(construction.activations.isEmpty)

        let upConstruction = FocusedTransportEnvironment()
        upConstruction.failUpConstruction = true
        let upTransport = try FocusedKeyTransport(
            profile: profile, dependencies: upConstruction.dependencies, clock: FakeClock(autoAdvance: true))
        await #expect(throws: ButtonInputTransportError.self) {
            try await upTransport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        #expect(upConstruction.constructed == ["up:126"])
        #expect(upConstruction.posted.isEmpty)
        #expect(upConstruction.activations.isEmpty)

        let activation = FocusedTransportEnvironment()
        activation.simulatorRequestResult = .init(callbackPID: 99, errorDescription: "simulator request failed")
        let activationTransport = try FocusedKeyTransport(
            profile: profile, dependencies: activation.dependencies, clock: FakeClock(autoAdvance: true))
        await #expect(throws: ButtonInputTransportError.self) {
            try await activationTransport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        #expect(activation.activations == [42])

        let timeout = FocusedTransportEnvironment()
        timeout.activationChangesFrontmost = false
        let clock = FakeClock()
        let timeoutTransport = try FocusedKeyTransport(
            profile: profile, dependencies: timeout.dependencies, clock: clock,
            focusTimeout: .seconds(1), pollInterval: .milliseconds(10))
        let task = Task {
            try await timeoutTransport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        await clock.waitUntilPendingSleepCount(1)
        clock.advance(by: .seconds(1))
        await #expect(throws: ButtonInputTransportError.self) { try await task.value }
        #expect(timeout.posted.isEmpty)
        #expect(timeout.activations.last == 42)
    }

    @Test("focused cancellation after down posts up and leaves Simulator frontmost")
    func focusedCancellationLifecycle() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let clock = FakeClock()
        let diagnostics = FocusedDiagnosticRecorder()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: clock,
            diagnosticSink: { diagnostics.record($0) })
        let task = Task {
            try await transport.press(
                ButtonPressRequest(button: "up", holdMs: 1000), context: focusedContext())
        }
        await clock.waitUntilPendingSleepCount(1)          // inert warm-up dwell
        clock.advance(by: .milliseconds(50))
        await clock.waitUntilPendingSleepCount(1)          // the hold under test
        #expect(environment.posted == ["down:56", "up:56", "down:126"])
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        #expect(environment.activations == [42])
        #expect(environment.frontmostPID == 42)
        let events = diagnostics.events
        let upIndex = events.firstIndex { $0 == .eventBoundary(phase: "after_up", frontmostPID: 42) }
        #expect(upIndex != nil)
    }

    @Test("focused cancellation after up preserves one failure-side after_up diagnostic")
    func focusedCancellationAfterUpDiagnostic() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let cancellation = CancellationController()
        environment.cancellationAction = { cancellation.cancel() }
        environment.cancelAfterUpPost = true
        let diagnostics = FocusedDiagnosticRecorder()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: FakeClock(autoAdvance: true),
            diagnosticSink: { diagnostics.record($0) })
        let task = Task {
            try await transport.press(ButtonPressRequest(button: "up"), context: focusedContext())
        }
        cancellation.setAction { task.cancel() }

        let error = await #expect(throws: CancellationError.self) { try await task.value }
        #expect(error != nil)
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        let afterUp = diagnostics.events.filter {
            $0 == .eventBoundary(phase: "after_up", frontmostPID: 42)
        }
        #expect(afterUp == [.eventBoundary(phase: "after_up", frontmostPID: 42)])
    }

    @Test("focused primary cancellation outranks post-up foreground proof")
    func focusedPrimaryErrorPrecedence() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        let clock = FakeClock()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: clock)
        let task = Task {
            try await transport.press(
                ButtonPressRequest(button: "up", holdMs: 1000), context: focusedContext())
        }
        await clock.waitUntilPendingSleepCount(1)          // inert warm-up dwell
        clock.advance(by: .milliseconds(50))
        await clock.waitUntilPendingSleepCount(1)          // the hold under test
        environment.setFrontmost(7)
        task.cancel()

        let error = await #expect(throws: CancellationError.self) { try await task.value }
        #expect(error != nil)
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
    }

    @Test("focused non-cancellation primary error outranks failing post-up foreground proof")
    func focusedNonCancellationPrimaryErrorPrecedence() async throws {
        let profile = try InputProfileLoader.loadQualificationCandidate()
        let environment = FocusedTransportEnvironment()
        environment.setFrontmost(42)
        environment.loseSimulatorFrontmostOnUp = true
        let diagnostics = FocusedDiagnosticRecorder()
        let transport = try FocusedKeyTransport(
            profile: profile, dependencies: environment.dependencies, clock: ThrowingClock(),
            diagnosticSink: { diagnostics.record($0) })

        let error = await #expect(throws: NonCancellationPrimaryError.self) {
            try await transport.press(
                ButtonPressRequest(button: "up", holdMs: 100), context: focusedContext())
        }
        #expect(error != nil)
        #expect(environment.posted == ["down:56", "up:56", "down:126", "up:126"])
        let afterUp = diagnostics.events.filter {
            $0 == .eventBoundary(phase: "after_up", frontmostPID: 7)
        }
        #expect(afterUp == [.eventBoundary(phase: "after_up", frontmostPID: 7)])
        #expect(diagnostics.events.last == .outcome(primary: "failure"))
    }

    @Test("all transport fixtures decode, equal their hand-built values, and have byte parity")
    func canonicalFixtures() throws {
        for name in ["protocol", "ax-keyboard-post", "focused-keys"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/inputprofiles"))
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(InputProfile.self, from: data)
            #expect(value == (try expectedProfile(name: name)))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(value)
            #expect(encoded == data)
        }
    }

    @Test("validation rejects unknown buttons and hold bounds before dispatch")
    func validation() async throws {
        let fake = RecordingTransport()
        let service = makeService(transport: fake)
        for request in [PressButtonToolRequest(button: "light"), PressButtonToolRequest(button: "up", holdMs: 49), PressButtonToolRequest(button: "up", holdMs: 5001)] {
            let error = await #expect(throws: ToolError.self) { try await service.press(request) }
            #expect(error?.code == "invalid_arguments")
        }
        #expect(fake.requests.isEmpty)
    }

    @Test("no current device, unsupported device, SDK, and button fail closed")
    func capabilityFailures() async throws {
        let fake = RecordingTransport()
        let profile = try expectedProfile(name: "protocol")
        let runner = ButtonOperationRunner { _, _, body in
            try await body(OperationContext(simulatorPid: 42, sdk: sdk("9.1.0"), currentDevice: nil, listeningEndpoints: []))
        }
        let noDevice = ButtonInputService(profile: profile, transport: fake, operationRunner: runner)
        #expect((await #expect(throws: ToolError.self) { try await noDevice.press(PressButtonToolRequest(button: "up")) })?.code == "no_current_device")

        let wrongDeviceRunner = ButtonOperationRunner { _, _, body in
            try await body(OperationContext(simulatorPid: 42, sdk: sdk("8.4.1"), currentDevice: "venu3", listeningEndpoints: []))
        }
        let wrongDevice = ButtonInputService(profile: profile, transport: fake, operationRunner: wrongDeviceRunner)
        #expect((await #expect(throws: ToolError.self) { try await wrongDevice.press(PressButtonToolRequest(button: "up")) })?.code == "input_unsupported")

        let wrongSDKRunner = ButtonOperationRunner { _, _, body in
            try await body(OperationContext(simulatorPid: 42, sdk: sdk("9.1.0"), currentDevice: "fenix6xpro", listeningEndpoints: []))
        }
        let wrongSDK = ButtonInputService(profile: profile, transport: fake, operationRunner: wrongSDKRunner)
        let sdkError = await #expect(throws: ToolError.self) { try await wrongSDK.press(PressButtonToolRequest(button: "up")) }
        #expect(sdkError?.message.contains("8.4.1") == true)

        let incomplete = InputProfile(core: profile.core, transport: .protocolShell(ProtocolShellProfile(sdkEntries: ["8.4.1": ["up": ["argv": .array([.string("--button"), .string("up")])]]], transcriptGrammar: ["successPattern": "ok", "errorPattern": "error"])))
        let missingButton = ButtonInputService(profile: incomplete, transport: fake, operationRunner: readyRunner())
        let mappingError = await #expect(throws: ToolError.self) { try await missingButton.press(PressButtonToolRequest(button: "enter")) }
        #expect(mappingError?.code == "input_unsupported")
    }

    @Test("focus opt-in is enforced and hold is forwarded exactly")
    func focusAndHold() async throws {
        let fake = RecordingTransport(requiresFocus: true)
        let service = makeService(transport: fake)
        let denied = await #expect(throws: ToolError.self) { try await service.press(PressButtonToolRequest(button: "up", holdMs: 300)) }
        #expect(denied?.code == "focus_required")
        #expect(fake.requests.isEmpty)
        let result = try await service.press(PressButtonToolRequest(button: "up", holdMs: 300, allowFocus: true))
        #expect(fake.requests == [ButtonPressRequest(button: "up", holdMs: 300)])
        #expect(result == PressButtonResult(button: "up", pressType: "hold", transport: "protocol", simulatorPid: 42))
        #expect(fake.downCount == 1)
        #expect(fake.upCount == 1)
    }

    @Test("deadline cancels a cancellation-aware transport and balances down/up")
    func deadlineBalancesCleanup() async throws {
        let fake = RecordingTransport(hang: true)
        let clock = FakeClock()
        let service = ButtonInputService(profile: try expectedProfile(name: "protocol"), transports: [fake], operationRunner: readyRunner(), clock: clock)
        let task = Task { try await service.press(PressButtonToolRequest(button: "up", holdMs: 1000)) }
        await clock.waitUntilPendingSleepCount(1)
        #expect(clock.pendingSleepCount == 1)
        clock.advance(by: .seconds(10) + .milliseconds(999))
        #expect(clock.pendingSleepCount == 1)
        #expect(clock.pendingSleepCount == 1)
        clock.advance(by: .milliseconds(1))
        let result = await task.result
        guard case .failure(let rawError) = result else {
            Issue.record("deadline unexpectedly succeeded")
            return
        }
        let error = try #require(rawError as? ToolError)
        #expect(error.code == "operation_timeout")
        #expect(fake.downCount == 1)
        #expect(fake.upCount == 1)
    }

    @Test("direct caller cancellation and transport failure both balance down/up")
    func cancellationAndFailureBalanceCleanup() async throws {
        let cancellationTransport = RecordingTransport(hang: true)
        let cancellationClock = FakeClock()
        let cancellationService = ButtonInputService(profile: try expectedProfile(name: "protocol"), transports: [cancellationTransport], operationRunner: readyRunner(), clock: cancellationClock)
        let task = Task { try await cancellationService.press(PressButtonToolRequest(button: "up", holdMs: 500)) }
        await cancellationClock.waitUntilPendingSleepCount(1)
        task.cancel()
        let cancellationResult = await task.result
        guard case .failure(let cancellationError) = cancellationResult else {
            Issue.record("direct cancellation unexpectedly succeeded")
            return
        }
        #expect(cancellationError is CancellationError)
        #expect(cancellationTransport.downCount == 1)
        #expect(cancellationTransport.upCount == 1)

        let failureTransport = RecordingTransport(error: ButtonInputTransportError.subprocess("raw failure"))
        let failureService = makeService(transport: failureTransport)
        _ = await #expect(throws: ToolError.self) { try await failureService.press(PressButtonToolRequest(button: "up")) }
        #expect(failureTransport.downCount == 1)
        #expect(failureTransport.upCount == 1)
    }

    @Test("runner dispatches pressButton and currentReady")
    func runnerContract() async throws {
        let observation = Observation()
        let runner = ButtonOperationRunner { operation, requirement, body in
            observation.operation = operation
            if case .currentReady = requirement { observation.requirement = "currentReady" }
            return try await body(OperationContext(simulatorPid: 42, sdk: sdk("8.4.1"), currentDevice: "fenix6xpro", listeningEndpoints: []))
        }
        let service = ButtonInputService(profile: try expectedProfile(name: "protocol"), transport: RecordingTransport(), operationRunner: runner)
        _ = try await service.press(PressButtonToolRequest(button: "up"))
        #expect(observation.operation == .pressButton)
        #expect(observation.requirement == "currentReady")
    }

    @Test("transport error families become stable errors without raw public interpolation")
    func translatedErrors() async throws {
        let cases: [(ButtonInputTransportError, String, String, String)] = [
            (.accessibilityDenied("secret"), "accessibility_denied", "Accessibility permission denied button delivery.", "Grant Accessibility permission to simulator-mcp, then retry."),
            (.accessibility("secret"), "input_delivery_failed", "The input transport could not deliver the button.", "Restart the simulator, verify the selected input profile and Accessibility state, then retry."),
            (.subprocess("secret"), "input_delivery_failed", "The input transport could not deliver the button.", "Restart the simulator, verify the selected input profile and Accessibility state, then retry."),
            (.workspaceActivation("secret"), "input_delivery_failed", "The input transport could not deliver the button.", "sim_stop -> sim_start -> run_app -> press_button(allowFocus=true)"),
            (.eventPost("secret"), "input_delivery_failed", "The input transport could not deliver the button.", "Restart the simulator, verify the selected input profile and Accessibility state, then retry."),
        ]
        for (raw, code, message, fix) in cases {
            let fake = RecordingTransport(error: raw)
            let service = makeService(transport: fake)
            let error = await #expect(throws: ToolError.self) { try await service.press(PressButtonToolRequest(button: "up")) }
            #expect(error?.code == code)
            #expect(error?.message == message)
            #expect(error?.fix == fix)
            #expect(error?.details == nil)
        }

        let rawFake = RecordingTransport(error: NSError(domain: "secret-domain", code: 99, userInfo: [NSLocalizedDescriptionKey: "secret message", "details": "secret details"]))
        let rawError = await #expect(throws: ToolError.self) { try await makeService(transport: rawFake).press(PressButtonToolRequest(button: "up")) }
        #expect(rawError?.code == "input_delivery_failed")
        #expect(rawError?.message == "The input transport could not deliver the button.")
        #expect(rawError?.fix == "Restart the simulator, verify the selected input profile and Accessibility state, then retry.")
        #expect(rawError?.message.contains("secret") == false)
        #expect(rawError?.details == nil)
    }

    /// `sim_start.activate` was withdrawn with the activated-start machinery. A
    /// fix that still names it costs an agent a retry and a second error, so no
    /// remedy this service emits may mention a parameter the schema rejects.
    @Test("error fixes never name a withdrawn tool parameter")
    func fixesAvoidWithdrawnParameters() async throws {
        let transportFailures: [ButtonInputTransportError] = [
            .accessibilityDenied("secret"), .accessibility("secret"), .subprocess("secret"),
            .workspaceActivation("secret"), .eventPost("secret"), .keyboardLayoutUnsupported,
            .eventConstruction("secret"), .eventPostingDenied,
        ]
        var fixes: [String] = []
        for raw in transportFailures {
            let error = await #expect(throws: ToolError.self) {
                try await makeService(transport: RecordingTransport(error: raw)).press(
                    PressButtonToolRequest(button: "up"))
            }
            fixes.append(try #require(error?.fix))
        }
        let refused = await #expect(throws: ToolError.self) {
            try await makeService(transport: RecordingTransport(requiresFocus: true)).press(
                PressButtonToolRequest(button: "up", allowFocus: false))
        }
        fixes.append(try #require(refused?.fix))

        for fix in fixes {
            #expect(!fix.isEmpty)
            #expect(
                !fix.contains("activate"),
                Comment(rawValue: "fix names the withdrawn sim_start.activate parameter: \(fix)"))
        }
    }

    private func makeService(transport: RecordingTransport) -> ButtonInputService {
        ButtonInputService(profile: try! expectedProfile(name: "protocol"), transport: transport, operationRunner: readyRunner())
    }

    private func qualificationServices(
        pressButton: @escaping @Sendable (PressButtonToolRequest) async throws -> PressButtonResult = { request in
            PressButtonResult(button: request.button, pressType: "press", transport: "focused-keys", simulatorPid: 42)
        }
    ) -> ToolHandlerServices {
        try! ToolHandlerServices.withoutInput().qualification(pressButton: pressButton)
    }

    private func readyRunner() -> ButtonOperationRunner {
        ButtonOperationRunner { _, _, body in
            try await body(OperationContext(simulatorPid: 42, sdk: sdk("8.4.1"), currentDevice: "fenix6xpro", listeningEndpoints: []))
        }
    }

    private func sdk(_ version: String) -> SdkInfo {
        SdkInfo(version: SemVer(version)!, root: URL(fileURLWithPath: "/sdk/\(version)"), source: .installed)
    }

    private func focusedContext() -> OperationContext {
        OperationContext(
            simulatorPid: 42, sdk: sdk("8.4.1"), currentDevice: "fenix6xpro",
            listeningEndpoints: [])
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func expectedProfile(name: String) throws -> InputProfile {
        let buttons = ["enter", "up", "menu", "down", "esc"]
        let keyCodes: [String: Int] = ["enter": 36, "up": 126, "menu": 46, "down": 2, "esc": 53]
        let mappings = Dictionary(uniqueKeysWithValues: buttons.map { button in
            (button, ["keyCode": .int(keyCodes[button] ?? 0)] as [String: JSONValue])
        })
        let focusedSchemaVersion = name == "focused-keys" ? 2 : 1
        let core = InputProfileCore(
            schemaVersion: focusedSchemaVersion,
            device: "fenix6xpro", profileVersion: "test/\(name == "protocol" ? "protocol" : name == "ax-keyboard-post" ? "ax" : "focused")/\(focusedSchemaVersion)", qualification: false,
            buttonOrder: buttons, holdEncoding: HoldEncoding(mechanism: "down-up"),
            evidence: ProfileEvidence(capturedOn: "2026-07-17", macOSVersion: "14.0", sdks: ["8.4.1"], surfaceDigests: [:], gateTranscriptDigests: [:]))
        switch name {
        case "protocol":
            let entries = Dictionary(uniqueKeysWithValues: buttons.map { ($0, ["argv": .array([.string("--button"), .string($0)])] as [String: JSONValue]) })
            return InputProfile(core: core, transport: .protocolShell(ProtocolShellProfile(sdkEntries: ["8.4.1": entries], transcriptGrammar: ["errorPattern": "error", "successPattern": "ok"])))
        case "ax-keyboard-post":
            return InputProfile(core: core, transport: .axKeyboardPost(AXPostProfile(sdkEntries: ["8.4.1": mappings], compatibility: ["api": "AXUIElementPostKeyboardEvent", "deprecatedSince": "10.9", "failureCode": "input_delivery_failed", "verifiedOnMacOS": "14.0"])))
        default:
            return InputProfile(core: core, transport: .focusedKeys(FocusedKeysProfile(sdkEntries: ["8.4.1": mappings], activation: ["frontmostPollTimeoutMs": 2000], leavesSimulatorFrontmost: true)))
        }
    }
}

private final class Observation: @unchecked Sendable {
    var operation: SimOperation?
    var requirement: String?
}

private final class RecordingTransport: ButtonPressing, @unchecked Sendable {
    let kind: ButtonTransportKind = .protocolShell
    let requiresFocusOptIn: Bool
    private let error: (any Error)?
    private(set) var requests: [ButtonPressRequest] = []
    private(set) var downCount = 0
    private(set) var upCount = 0
    private let hang: Bool
    init(requiresFocus: Bool = false, error: (any Error)? = nil, hang: Bool = false) { requiresFocusOptIn = requiresFocus; self.error = error; self.hang = hang }
    func press(_ request: ButtonPressRequest, context: OperationContext) async throws {
        requests.append(request); downCount += 1
        defer { upCount += 1 }
        if let error { throw error }
        if hang {
            while true {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }
}

private actor QualificationRequestRecorder {
    private(set) var requests: [PressButtonToolRequest] = []
    func record(_ request: PressButtonToolRequest) { requests.append(request) }
}

private final class FocusedTransportEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    var keyboardSource = FocusedKeyTransport.KeyboardSource(id: "com.apple.keylayout.US", enabled: true)
    var permissionGranted = true
    var sourceAvailable = true
    var activationChangesFrontmost = true
    var failDownConstruction = false
    var failUpConstruction = false
    var failSimulatorActivation = false
    var missingApplicationPIDs: Set<pid_t> = []
    var terminatedApplicationPIDs: Set<pid_t> = []
    var simulatorRequestResult = FocusedKeyTransport.FocusRequestResult(callbackPID: 42, errorDescription: nil)
    var simulatorReplacement: FocusedKeyTransport.Application?
    var replaceSimulatorOnRequest = false
    var replaceSimulatorOnUp = false
    var cancellationAction: (@Sendable () -> Void)?
    var cancelAfterSimulatorCallback = false
    var cancelAfterUpPost = false
    var keyFocusReadyAfterChecks = 0
    /// nil means "whichever application owns the frontmost window".
    var activePID: pid_t?
    private var activeSequence: [Bool] = []
    var remainingActiveObservations: Int { synchronized { activeSequence.count } }
    func setActiveSequence(_ sequence: [Bool]) { synchronized { activeSequence = sequence } }
    private var keyFocusChecks = 0
    var cancelOnSimulatorFrontmostObservation = false
    var loseSimulatorFrontmostOnUp = false
    private var currentFrontmost: pid_t? = 7
    private var frontmostObservationSequence: [pid_t?] = []
    private var applications: [pid_t: FocusedKeyTransport.Application] = [
        42: FocusedKeyTransport.Application(
            pid: 42,
            bundleURL: URL(fileURLWithPath: "/Applications/Simulator.app"),
            executableURL: URL(fileURLWithPath: "/Applications/Simulator.app/Contents/MacOS/Simulator"),
            bundleIdentifier: "example.simulator",
            launchDate: Date(timeIntervalSince1970: 42),
            isTerminated: false),
    ]
    private var callValues: [String] = []
    private var applicationLookupValues: [pid_t] = []
    private var constructedValues: [String] = []
    private var postedValues: [String] = []
    private var focusRequestValues: [FocusedKeyTransport.Application] = []
    private var lifecycleValues: [String] = []
    private var frontmostObservationValues: [pid_t?] = []
    private var postInstants: [String: ContinuousClock.Instant] = [:]

    /// Wall-clock dwell between the posted key-down and key-up. The simulator
    /// drops a key pair posted with no dwell, so this is delivery-critical.
    var downToUpDwell: Duration? {
        synchronized {
            guard let down = postInstants["down"], let up = postInstants["up"] else { return nil }
            return down.duration(to: up)
        }
    }

    var calls: [String] { synchronized { callValues } }
    var applicationLookups: [pid_t] { synchronized { applicationLookupValues } }
    var constructed: [String] { synchronized { constructedValues } }
    var posted: [String] { synchronized { postedValues } }
    var lifecycle: [String] { synchronized { lifecycleValues } }
    var focusRequests: [FocusedKeyTransport.Application] { synchronized { focusRequestValues } }
    var activations: [pid_t] { synchronized { focusRequestValues.map(\.pid) } }
    var frontmostPID: pid_t? { synchronized { currentFrontmost } }
    var frontmostObservations: [pid_t?] { synchronized { frontmostObservationValues } }
    var remainingFrontmostObservations: Int { synchronized { frontmostObservationSequence.count } }

    var dependencies: FocusedKeyTransport.Dependencies {
        FocusedKeyTransport.Dependencies(
            currentInputSource: { [self] in record("inputSource"); return sourceAvailable ? keyboardSource : nil },
            inputSourceID: { [self] source in record("inputSourceID"); return source.id },
            inputSourceEnabled: { [self] source in record("inputSourceEnabled"); return source.enabled },
            postPermissionGranted: { [self] in record("permission"); return permissionGranted },
            application: { [self] pid in
                synchronized {
                    applicationLookupValues.append(pid)
                    guard !missingApplicationPIDs.contains(pid), let application = applications[pid] else {
                        return nil
                    }
                    guard terminatedApplicationPIDs.contains(pid) else { return application }
                    return .init(
                        pid: application.pid,
                        bundleURL: application.bundleURL,
                        executableURL: application.executableURL,
                        bundleIdentifier: application.bundleIdentifier,
                        launchDate: application.launchDate,
                        isTerminated: true)
                }
            },
            frontmostPID: { [self] in
                synchronized {
                    var observation: pid_t?
                    if !frontmostObservationSequence.isEmpty {
                        observation = frontmostObservationSequence.removeFirst()
                    } else {
                        observation = currentFrontmost
                    }
                    frontmostObservationValues.append(observation)
                    if observation == 42, cancelOnSimulatorFrontmostObservation {
                        cancellationAction?()
                    }
                    return observation
                }
            },
            requestFrontmost: { [self] application in
                synchronized {
                    focusRequestValues.append(application)
                    lifecycleValues.append("activate:\(application.pid)")
                    if application.pid == 42 {
                        if replaceSimulatorOnRequest, let simulatorReplacement {
                            applications[42] = simulatorReplacement
                        }
                        if !failSimulatorActivation && activationChangesFrontmost {
                            currentFrontmost = application.pid
                        }
                        if cancelAfterSimulatorCallback {
                            cancellationAction?()
                        }
                        return failSimulatorActivation
                            ? .init(callbackPID: 999, errorDescription: "simulator request failed")
                            : simulatorRequestResult
                    }
                    return .init(callbackPID: nil, errorDescription: "unexpected application")
                }
            },
            isActive: { [self] pid in
                synchronized {
                    if !activeSequence.isEmpty { return activeSequence.removeFirst() }
                    return (activePID ?? currentFrontmost) == pid
                }
            },
            hasKeyFocus: { [self] pid in
                synchronized {
                    keyFocusChecks += 1
                    let ready = keyFocusChecks > keyFocusReadyAfterChecks
                    if ready, !lifecycleValues.contains("keyfocus:granted") {
                        lifecycleValues.append("keyfocus:granted")
                    }
                    return ready
                }
            },
            makeEvent: { [self] keyCode, keyDown in
                let label = "\(keyDown ? "down" : "up"):\(keyCode)"
                synchronized {
                    constructedValues.append(label)
                    lifecycleValues.append("construct:\(label)")
                }
                if !keyDown && failUpConstruction { return nil }
                if keyDown && failDownConstruction { return nil }
                return FocusedTestEvent { [self] in
                    synchronized {
                        postedValues.append(label)
                        lifecycleValues.append("post:\(label)")
                        postInstants[keyDown ? "down" : "up"] = ContinuousClock().now
                        // The inert warm-up pair is not the button under
                        // test, so it must not trigger these hooks.
                        if !keyDown, keyCode != FocusedKeyTransport.warmUpKeyCode {
                            if replaceSimulatorOnUp, let simulatorReplacement {
                                applications[42] = simulatorReplacement
                            }
                            if loseSimulatorFrontmostOnUp {
                                currentFrontmost = 7
                            }
                            if cancelAfterUpPost {
                                cancellationAction?()
                            }
                        }
                    }
                }
            })
    }

    func reset(source: FocusedKeyTransport.KeyboardSource) {
        synchronized {
            keyboardSource = source
            sourceAvailable = true
            permissionGranted = true
            callValues = []
        }
    }

    func setFrontmost(_ pid: pid_t?) { synchronized { currentFrontmost = pid } }

    func setFrontmostObservationSequence(_ sequence: [pid_t?]) {
        synchronized { frontmostObservationSequence = sequence }
    }

    private func record(_ value: String) { synchronized { callValues.append(value) } }
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
}

private final class CancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var pending = false

    func setAction(_ action: @escaping @Sendable () -> Void) {
        let runNow = synchronized {
            self.action = action
            let pending = self.pending
            self.pending = false
            return pending
        }
        if runNow { action() }
    }

    func cancel() {
        let action: (@Sendable () -> Void)? = synchronized {
            guard let action = self.action else {
                pending = true
                return nil
            }
            return action
        }
        action?()
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
}

private final class FocusedDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FocusedKeyTransport.Diagnostic] = []
    var events: [FocusedKeyTransport.Diagnostic] {
        lock.lock(); defer { lock.unlock() }; return values
    }
    func record(_ event: FocusedKeyTransport.Diagnostic) {
        lock.lock(); values.append(event); lock.unlock()
    }
}

private struct FocusedTestEvent: FocusedKeyTransport.Event, Sendable {
    let body: @Sendable () -> Void
    init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    func post() { body() }
}

private struct NonCancellationPrimaryError: Error, Equatable {}

private final class ThrowingClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        static func == (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset == rhs.offset
        }

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }
    }

    let now = Instant(offset: .zero)
    let minimumResolution: Duration = .zero
    private let sleeps = OSAllocatedUnfairLock(initialState: 0)

    /// The transport's inert warm-up dwell comes first; this clock lets that
    /// one through so the failure lands on the hold, which is what the tests
    /// using it are about.
    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let count = sleeps.withLock { state -> Int in
            state += 1
            return state
        }
        if count > 1 { throw NonCancellationPrimaryError() }
    }
}
