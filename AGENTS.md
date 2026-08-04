# AGENTS.md

Guidance for AI agents (Claude Code, Codex CLI, others) and human
contributors working in this repository. CLAUDE.md is a pointer to this
file — keep everything here.

## What this is

`simulator-mcp` — a Swift MCP stdio server that drives the Garmin Connect IQ
simulator on macOS so agent CLIs can build, run, and unit-test Connect IQ
watch apps, read their logs, take screenshots, set GPS position, and press
watch buttons.

## Authoritative contracts

`docs/verification/simulator-contracts/` holds empirical evidence captured
from the real simulator on SDK 8.4.1 and 9.1.0. These files are ground
truth; code must match them. If observed simulator behavior contradicts an
evidence file, stop and capture fresh verified evidence — never broaden a
heuristic, guess another constant, or skip a gate.

## Hard rules (apply to every line of code)

- **stdout belongs to MCP JSON-RPC framing.** All diagnostics go to stderr.
  Child processes are always piped, never inherit stdio. One stray print
  corrupts the protocol.
- **Dependency pin:** `modelcontextprotocol/swift-sdk` **exact 0.12.1**
  (tag commit `a0ae212ebf6eab5f754c3129608bc5557637e605`). Never `from:`.
  `Package.resolved` is committed.
- **TDD, and honest verification:** write the failing test first. Run
  build/test commands directly — never pipe them into `head`/`tail`/`tee`
  (that masks the exit status). To keep a transcript, redirect to a file and
  inspect it in a separate command.
- **Serialization:** every simulator-touching operation goes through
  `SimulatorController.withOperation` (in-process FIFO queue + OS-wide flock
  lease at `~/.simulator-mcp/sim.lock`). Swift actor isolation is reentrant
  at `await` and is NOT serialization. Never unlink the lock file — a dead
  holder releases `flock` automatically; unlinking can split the lock.
- **Errors:** every public failure carries a stable code, a message, and a
  non-empty concrete fix. Raw platform errors are translated at the service
  boundary.
- **No sleep is evidence.** Readiness, app launch, redraw, and AX completion
  are proven by probes (lsof listener/connection, log markers, pixel
  assertions), never by fixed delays. Use `ContinuousClock` for all timing.
- **monkeydo's exit code is unreliable** (SDK regex bug). Test transcripts
  are authoritative — parse them, never trust the code.
- **Input capability:** `press_button` is verified for **19 fēnix devices**
  (`enter`, `esc`, `up`, `down`), qualified through the delivery gate on
  2026-08-04 — 32/32 device×SDK combinations, delivery read only from fixture
  markers.
  - **Both SDKs (8.4.1 and 9.1.0), 13 devices:** `fenix6`, `fenix6pro`,
    `fenix6s`, `fenix6spro`, `fenix6xpro`, `fenix7`, `fenix7pro`,
    `fenix7pronowifi`, `fenix7s`, `fenix7spro`, `fenix7x`, `fenix7xpro`,
    `fenix7xpronowifi`.
  - **SDK 9.1.0 only, 6 devices:** `fenix843mm`, `fenix847mm`, `fenix8pro47mm`,
    `fenix8solar47mm`, `fenix8solar51mm`, `fenixe`. The fēnix 8 and fēnix E
    profiles are single-SDK verified: they do not build on 8.4.1, so capability
    is claimed for 9.1.0 and nothing else.

  Capability is an explicit allowlist keyed by exact device id and SDK version;
  every other device advertises `inputSupported=false`, `buttons=[]`, and
  `inputProfile=null` — including `fenix3`, `fenix5` and `fenixchronos`, which
  share the key layout and must stay fail-closed. Device JSON describes
  hardware; it is never proof of an automation transport.

  The device set and the device→key-code mapping are compiled in
  (`qualifiedDevices` and the layout group in `ButtonInput.swift`), and the
  shipped profile resources must equal that set exactly — a missing file and an
  extra file both fail the load. `scripts/audit-plan.sh` checks every qualified
  device fail-closed in both directions.

  Three delivery facts are load-bearing and measured per device in
  `<device>-focused-delivery.json` — do not "simplify" any of them away:
  a press must hold the key down for the profile's `minimumPressMs`, because a
  key pair posted with no dwell is never delivered; an inert `kVK_Shift`
  warm-up absorbs the first key event after an app launch, which the simulator
  always consumes; and posting is authorized by a freshly constructed
  `NSRunningApplication(processIdentifier:).isActive`, because every cached
  workspace property freezes in a process that never pumps a main run loop.
  No device in the family exposes a `menu` button: menu is `up` with
  `holdMs >= 1000`. All 19 share one layout group and identical key codes
  (`36/53/126/125`), measured — not inferred from key names.
- **Secrets:** `SIM_DEVELOPER_KEY` points to a Connect IQ developer key
  stored **outside** this repository. No key material is ever committed.

## Commands

- `swift build` / `swift test` — unit tests; no simulator or TCC needed.
- `SIM_INTEGRATION=1 swift test --filter InstalledServerIntegrationTests` —
  integration against the installed signed server (needs simulator + TCC
  grants).
- `make install SIGNING_IDENTITY="simulator-mcp-local"` — release build,
  stable-identity signing, install to `~/.simulator-mcp/bin/`. Required for
  TCC grants to survive rebuilds; unsigned/ad-hoc builds lose grants.
- `SIM_TCC_ONBOARD=1 swift test --filter InstalledServerPermissionOnboardingTests`
  — opt-in permission request through the installed server only.
- `scripts/audit-plan.sh` — fail-closed architecture and pattern audit.

The integration command requires the external `SIM_DEVELOPER_KEY` path and
both TCC grants (Screen Recording, Accessibility).

## Verified simulator contracts (SDK 8.4.1 and 9.1.0)

- SDK resolution precedence: explicit param → `CIQ_SDK` env →
  `current-sdk.cfg` → newest installed by parsed semver.
- Simulator GPS menu path (both SDKs): **Settings → Set Position**
  (`Simulation` is not a fallback).
- GPS dialog contract (both SDKs): exact decimal-degrees instruction plus one
  direct-child combined `AXTextField`; select by prompt/role/uniqueness/parent,
  never geometry, child index, initial value, or SDK-specific fallback.
- `fenix6xpro`: display 280×280 at (76,141) in the device window image;
  physical keys `enter/up/menu/down/esc`; not touch; **no light key** in
  `simulator.json`.
- 108 of 162 installed device profiles match a naive key-id heuristic —
  which is exactly why capability is an explicit allowlist, not inference.

## Evidence index

- Runtime probes: `sdk-8.4.1-runtime.json`, `sdk-9.1.0-runtime.json`.
- Launcher contracts: `monkeydo-process-8.4.1.json`,
  `monkeydo-process-9.1.0.json`, `monkeydo-launch.json`.
- The button delivery contracts: one `<device>-focused-delivery.json` per
  qualified device, 19 in total. `fenix6xpro-focused-delivery.json` is the
  reference (dwell
  floor, first-key warm-up, active-application observation, activation route,
  rejected buttons, and the installed-server acceptance result), with the
  verified mapping in `fenix6xpro-input.json`.
- The earlier accessibility probe: `fenix6xpro-ax-input-8.4.1.json` and
  `fenix6xpro-ax-input-9.1.0.json`. Neither sanitized tree exposes a semantic
  physical-button control, which is why delivery uses focused key events
  rather than an accessibility action.
- The Task 16 GPS contract: `gps-ax.json` with static `Position.getInfo()`
  polling observation.
- The Task 17 TCC attribution: `tcc-attribution.json` records the verified
  deployment mode (`stableBinary`).

All names above are under `docs/verification/simulator-contracts/`.

## Architecture boundaries

- `Sources/SimulatorMCP/` — executable: transport + bootstrap only.
- `Sources/SimulatorMCPCore/MCP/` — thin tool handlers: decode args → call
  one service → encode typed `ToolEnvelope` (structuredContent + JSON text).
  No `Process`, CGEvent, ScreenCaptureKit, or AX calls here.
- `Sources/SimulatorMCPCore/Sdk|Sim|Automation/` — services. Only
  `Support/Subprocess.swift` constructs `Foundation.Process`.
- `Tests/fixtures/` — deterministic Connect IQ fixture apps; integration
  asserts on app-owned pixels/log markers, never PNG size, non-blank frames,
  or whole-image inequality.

## Contributing

- Build and test with `swift build` / `swift test`; both must stay green and
  need no simulator, SDK, or TCC grant.
- TDD is expected: write the failing test first and keep the red/green
  evidence in your PR description.
- Any change to simulator-facing behavior needs empirical evidence first:
  capture the real simulator's behavior, commit it under
  `docs/verification/simulator-contracts/`, and make the code match the
  evidence. A PR that changes a contract updates the corresponding evidence
  file in the same change.
- `scripts/audit-plan.sh` must pass before every PR.
