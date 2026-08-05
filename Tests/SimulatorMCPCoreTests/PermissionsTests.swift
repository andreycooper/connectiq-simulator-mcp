import Testing

import SimulatorMCPCore

@Suite("Permissions grant instructions")
struct PermissionsGrantInstructionsTests {
    /// The installed layout: a dot-directory, which is the case that cost a
    /// session an hour because the picker appears not to contain the file.
    @Test("names the hidden folder, the executable, and the re-add step")
    func hiddenInstallDirectory() {
        let text = Permissions.grantInstructions(
            settingsPath: Permissions.accessibilitySettingsPath,
            executablePath: "/Users/x/.simulator-mcp/bin/simulator-mcp")

        #expect(text == "Open System Settings > Privacy & Security > Accessibility, "
            + "click +, press Command-Shift-G, enter /Users/x/.simulator-mcp/bin "
            + "(a hidden folder, so it is not browsable), select simulator-mcp, "
            + "and switch it on. If simulator-mcp is already listed, remove it with - "
            + "and add it again: an install can leave a stale entry that looks enabled "
            + "but is not honoured. Then fully restart the MCP host.")
    }

    /// The host-app layout installs to Contents/MacOS, which is browsable.
    /// Claiming it is hidden would be the same class of wrong fact this text
    /// was rewritten to remove.
    @Test("omits the hidden-folder claim when the folder is not hidden")
    func visibleInstallDirectory() {
        let text = Permissions.grantInstructions(
            settingsPath: Permissions.screenSettingsPath,
            executablePath: "/Users/x/Applications/Host.app/Contents/MacOS/simulator-mcp-host")

        #expect(!text.contains("hidden folder"))
        #expect(text.contains("enter /Users/x/Applications/Host.app/Contents/MacOS,"))
        #expect(text.contains("select simulator-mcp-host"))
        #expect(text.contains("Command-Shift-G"))
    }

    @Test("every fix that reports a denial is non-empty and actionable")
    func alwaysActionable() {
        for path in ["/a/.hidden/bin/tool", "/a/visible/tool"] {
            let text = Permissions.grantInstructions(
                settingsPath: Permissions.screenSettingsPath, executablePath: path)
            #expect(!text.isEmpty)
            #expect(text.contains("Command-Shift-G"))
            #expect(text.contains("remove it with -"))
            #expect(text.contains("restart the MCP host"))
        }
    }
}

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
