import Testing

import SimulatorMCPCore

@Suite("Permissions")
struct PermissionsTests {
    @Test("preflight-only diagnosis never invokes permission request APIs")
    func preflightOnlyDoesNotPrompt() async {
        let calls = PermissionCallRecorder()
        let permissions = Permissions(
            screenPreflight: { false },
            screenRequest: { await calls.screenRequested(); return true },
            accessibilityPreflight: { false },
            accessibilityRequest: { await calls.accessibilityRequested(); return true })

        let result = await permissions.inspect(requestPermissions: false)

        #expect(result.screenRecording.granted == false)
        #expect(result.screenRecording.prompted == false)
        #expect(result.accessibility.granted == false)
        #expect(result.accessibility.prompted == false)
        #expect(await calls.counts == [0, 0])
    }

    @Test("opt-in diagnosis requests each denied permission exactly once")
    func promptsDeniedPermissionsOnce() async {
        let calls = PermissionCallRecorder()
        let permissions = Permissions(
            screenPreflight: { false },
            screenRequest: { await calls.screenRequested(); return false },
            accessibilityPreflight: { false },
            accessibilityRequest: { await calls.accessibilityRequested(); return false })

        let result = await permissions.inspect(requestPermissions: true)

        #expect(result.screenRecording.prompted == true)
        #expect(result.accessibility.prompted == true)
        #expect(await calls.counts == [1, 1])
    }

    @Test("a successful opt-in request preserves preflight health until host restart")
    func successfulPromptRequiresRestartBeforeGrantIsHealthy() async {
        let permissions = Permissions(
            screenPreflight: { false }, screenRequest: { true },
            accessibilityPreflight: { false }, accessibilityRequest: { true })

        let result = await permissions.inspect(requestPermissions: true)

        #expect(result.screenRecording.granted == false)
        #expect(result.screenRecording.prompted == true)
        #expect(result.screenRecording.restartRequired == true)
        #expect(result.accessibility.granted == false)
        #expect(result.accessibility.prompted == true)
        #expect(result.accessibility.restartRequired == true)
    }

    @Test("granted permissions are not prompted and statuses carry exact settings paths")
    func grantedPermissionsAreNotPrompted() async {
        let calls = PermissionCallRecorder()
        let permissions = Permissions(
            screenPreflight: { true },
            screenRequest: { await calls.screenRequested(); return true },
            accessibilityPreflight: { true },
            accessibilityRequest: { await calls.accessibilityRequested(); return true })

        let result = await permissions.inspect(requestPermissions: true)

        #expect(result.screenRecording == PermissionStatus(
            granted: true, prompted: false,
            systemSettingsPath: "System Settings > Privacy & Security > Screen & System Audio Recording",
            restartRequired: false))
        #expect(result.accessibility == PermissionStatus(
            granted: true, prompted: false,
            systemSettingsPath: "System Settings > Privacy & Security > Accessibility",
            restartRequired: false))
        #expect(await calls.counts == [0, 0])
    }
}

private actor PermissionCallRecorder {
    private var screen = 0
    private var accessibility = 0
    var counts: [Int] { [screen, accessibility] }
    func screenRequested() { screen += 1 }
    func accessibilityRequested() { accessibility += 1 }
}
