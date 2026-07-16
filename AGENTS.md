# AGENTS.md

Guidance for AI agents (Claude Code, Codex CLI, others) and human
contributors working in this repository. CLAUDE.md is a pointer to this
file — keep everything here.

## What this is

`simulator-mcp` — a Swift MCP stdio server that drives the Garmin Connect IQ
simulator on macOS so agent CLIs can build, run, and unit-test Connect IQ
watch apps, read their logs, take screenshots, and set GPS position.
Watch-button automation is deferred from v1: both investigated
background-input routes failed their evidence gates (see the evidence index).

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
- **Input capability:** v1 has no verified button profile and does not
  register `press_button`; every device advertises `inputSupported=false`,
  `buttons=[]`, and `inputProfile=null`. The Task 15 CGEvent and semantic AX
  gates failed closed. Device JSON describes hardware; it is never proof of
  an automation transport. Future input requires a separate v2 design.
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
- The Task 15 deferred button decision: `fenix6xpro-ax-input-8.4.1.json` and
  `fenix6xpro-ax-input-9.1.0.json`. Both sanitized trees have no exact
  semantic physical-button control; v1 has no input transport.
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
