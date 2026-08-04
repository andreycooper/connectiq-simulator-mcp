import Foundation
import Testing

@Suite("Task 17 install contract")
struct Task17InstallContractTests {
    @Test("Make targets preserve stable signing and TCC install paths")
    func makeTargets() throws {
        let makefile = try source("Makefile")

        for target in ["build", "test", "sign", "install", "install-host", "integration", "clean"] {
            #expect(makefile.contains("\(target):"), "missing make target \(target)")
        }
        #expect(makefile.contains("swift build -c release"))
        #expect(makefile.contains("codesign --force --options runtime --timestamp=none"))
        #expect(makefile.contains("codesign --verify --strict --verbose=2"))
        #expect(makefile.contains(".simulator-mcp"))
        #expect(makefile.contains("INSTALL_BINARY := $(INSTALL_DIR)/simulator-mcp"))
        #expect(makefile.contains("RELEASE_RESOURCE_BUNDLE := .build/release/simulator-mcp_SimulatorMCPCore.bundle"))
        #expect(makefile.contains("INSTALL_RESOURCE_BUNDLE := $(INSTALL_DIR)/simulator-mcp_SimulatorMCPCore.bundle"))
        #expect(makefile.contains("/usr/bin/ditto \"$(RELEASE_RESOURCE_BUNDLE)\" \"$$tmp_bundle\""))
        #expect(makefile.contains("mv -f \"$$tmp_bundle\" \"$(INSTALL_RESOURCE_BUNDLE)\""))
        #expect(makefile.contains("trap 'rm -f \"$$tmp\"; rm -rf \"$$tmp_bundle\"'"))
        #expect(makefile.contains("dev.simulator-mcp.host"))
        #expect(makefile.contains("LSBackgroundOnly"))
        #expect(makefile.contains("swift package clean"))
        #expect(!makefile.contains("rm -rf $(HOME)/.simulator-mcp"))
        #expect(!makefile.contains("sim.lock"))
    }

    @Test("bootstrap publishes one composition with no private selector")
    func bootstrapComposition() throws {
        let main = try source("Sources/SimulatorMCP/main.swift")
        #expect(main.contains("try ToolHandlers.live()"))
        // press_button is published, so there is no longer an environment
        // selector that can silently swap the served tool surface.
        #expect(!main.contains("SIM_BUTTON_QUALIFICATION"))
        #expect(!main.contains("qualificationCandidate"))
        #expect(main.contains("version: \"0.3.2\""))
    }

    @Test("v0.3.2 release metadata is consistent across bootstrap and packaging")
    func releaseMetadata() throws {
        let main = try source("Sources/SimulatorMCP/main.swift")
        let makefile = try source("Makefile")

        #expect(main.contains("version: \"0.3.2\""))
        #expect(makefile.contains(
            "/usr/bin/plutil -insert CFBundleShortVersionString -string 0.3.2"))
        #expect(!main.contains("0.3.1"))
    }

    @Test("identity creation uses a persistent code-signing certificate")
    func identityScript() throws {
        let script = try source("scripts/create-signing-identity.sh")
        #expect(script.hasPrefix("#!/bin/sh") || script.hasPrefix("#!/usr/bin/env bash"))
        #expect(script.contains("simulator-mcp-local"))
        #expect(script.contains("1.3.6.1.5.5.7.3.3"))
        #expect(script.contains("openssl pkcs12 -export -legacy"))
        #expect(script.contains("basicConstraints = critical,CA:false"))
        #expect(script.contains("keyUsage = critical,digitalSignature"))
        #expect(!script.contains("keyCertSign"))
        #expect(script.contains("security find-identity -v -p codesigning"))
        #expect(script.contains("security find-certificate"))
        #expect(script.contains("valid_identities="))
        #expect(script.contains("usable code-signing identity and private key"))
        #expect(!script.contains("\n    -A"))
        #expect(!script.contains("add-trusted-cert -d"))
        #expect(!script.contains("|| true"))
        #expect(script.contains("certificate_status="))
    }

    @Test("TCC verification can run installed doctor preflight before attribution exists")
    func tccPreflightContract() throws {
        let onboarding = try source(
            "Tests/SimulatorMCPCoreTests/Integration/InstalledServerPermissionOnboardingTests.swift")
        let integration = try source(
            "Tests/SimulatorMCPCoreTests/Integration/InstalledServerIntegrationTests.swift")
        let readme = try source("README.md")

        #expect(onboarding.contains("SIM_TCC_PREFLIGHT"))
        #expect(onboarding.contains("[\"requestPermissions\": false]"))
        #expect(onboarding.contains("#expect(doctor.screenRecording.granted)"))
        #expect(onboarding.contains("#expect(doctor.accessibility.granted)"))
        #expect(onboarding.contains("validateTask17ToolAdvertisement"))
        #expect(integration.contains("validateTask17ToolAdvertisement"))
        #expect(readme.contains("SIM_TCC_PREFLIGHT=1"))
        #expect(readme.contains(
            "SIM_TCC_EXECUTABLE=\"$HOME/.simulator-mcp/SimulatorMCPHost.app/Contents/MacOS/simulator-mcp-host\" \\\n  SIM_TCC_PREFLIGHT=1"))
        for evidenceField in [
            "responsibleProcess", "signature", "installedClientDoctor",
            "actualMCPHostDoctor", "screenRecordingGranted", "accessibilityGranted",
        ] {
            #expect(readme.contains(evidenceField), "README misses \(evidenceField)")
        }
    }

    @Test("the screenshot fixture patch is fully inside the round fenix display")
    func screenshotFixturePatchContract() throws {
        let fixture = try source("Tests/fixtures/testapp/source/FixtureView.mc")
        let integration = try source(
            "Tests/SimulatorMCPCoreTests/Integration/InstalledServerIntegrationTests.swift")

        #expect(fixture.contains("dc.fillRectangle(48, 48, 64, 64);"))
        #expect(integration.contains("fixturePatchOrigin = 48.0"))
        #expect(integration.contains("fixturePatchInset = 4.0"))
    }

    @Test("plan audit is executable and carries every prohibited-pattern family")
    func auditScript() throws {
        let url = root.appending(path: "scripts/audit-plan.sh")
        let script = try source("scripts/audit-plan.sh")
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(script.contains("plan audit passed"))
        for fragment in [
            "Foundation.", "Process", "Support/Subprocess.swift", "MCP", "CG",
            "Event", "ScreenCapture", "Kit", "AXUI", "Element", "Simu", "lation",
            "swift (build|test)",
        ] {
            #expect(script.contains(fragment), "audit misses \(fragment)")
        }
        #expect(!script.contains("Foundation.Process"))
        #expect(!script.contains("CGEvent"))
        #expect(!script.contains("ScreenCaptureKit"))
        #expect(!script.contains("AXUIElement"))
    }

    @Test("README covers installation, onboarding, hosts, tools, and state semantics")
    func readmeContract() throws {
        let readme = try source("README.md")
        for required in [
            "macOS 14+", "Swift 6", "Java 17+", "SIM_DEVELOPER_KEY",
            "create-signing-identity.sh", "make install", "SIM_TCC_ONBOARD=1",
            "requestPermissions", "fully restart", "stable binary", "signed host",
            "Claude Code", "Codex", "structuredContent", "sdk_mismatch",
            "current device", "stale_session", "sim.lock", "doctor",
        ] {
            #expect(readme.localizedCaseInsensitiveContains(required), "README misses \(required)")
        }
        for tool in [
            "doctor", "list_sdks", "list_devices", "build", "sim_start", "sim_stop",
            "sim_status", "run_app", "run_tests", "get_logs", "screenshot",
            "set_gps_position", "press_button",
        ] {
            #expect(readme.contains("`\(tool)`"), "README misses tool \(tool)")
        }
    }

    @Test("agent guidance stays authoritative and CLAUDE remains a one-line pointer")
    func agentGuidance() throws {
        let agents = try source("AGENTS.md")
        #expect(agents.contains("fenix6xpro-focused-delivery.json"))
        #expect(agents.contains("fenix6xpro-ax-input-8.4.1.json"))
        #expect(agents.contains("fenix6xpro-ax-input-9.1.0.json"))
        #expect(agents.contains("Task 17"))
        #expect(!agents.contains("implementation has not started"))

        let claude = try source("CLAUDE.md").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(claude == "@AGENTS.md")
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // Integration
            .deletingLastPathComponent() // SimulatorMCPCoreTests
            .deletingLastPathComponent() // Tests
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
