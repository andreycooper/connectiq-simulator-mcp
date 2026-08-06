# AGENTS.md

Guidance for AI agents (Claude Code, Codex CLI, others) and human
contributors working in this repository. CLAUDE.md is a pointer to this
file — keep everything here.

## What this is

`simulator-mcp` — a Swift MCP stdio server that drives the Garmin Connect IQ
simulator on macOS so agent CLIs can build, run, and unit-test Connect IQ
watch apps, read their logs, take screenshots, set GPS position, press watch
buttons, and script short interactions as a single atomic sequence.

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
- **Sequences:** `run_sequence` scripts `press`, `screenshot` and `waitForLog`
  steps under **one** `withOperation`, so no other lease-taking client can drive
  the simulator part-way through an interaction. It is atomic against other MCP
  clients, **not** against the console user — `press` posts CGEvents to the
  frontmost app, a channel the lease does not own.
  - A `waitForLog` baselines on `latestToken` and advances its cursor on
    **every** poll. Both are load-bearing: `nextToken` is the last line of a
    `limit`-bounded page, so it silently matches pre-existing lines, and a
    cursor left in place cannot see past one page however long it waits.
  - A matched page's remaining lines are carried forward in memory, so a second
    marker in the same page can still satisfy a later wait. Waits are therefore
    **ordered**: a marker printed before an already-matched one can never
    satisfy a later wait.
  - A marker printed **without a trailing newline is not a log line** and is
    invisible until the app exits. `System.println` appends one.
  - A marker proves a code path was reached, not that `onUpdate()` finished
    drawing. For a wait to imply a completed redraw, print it from inside
    `onUpdate()` after the draw calls.
  - Steps run inside a 120 s budget, but `ClockSupport.withDeadline` cancels
    cooperatively — a step that ignores cancellation runs to its own ceiling
    (10 s + holdMs for a press, 30 s for a capture). It bounds the steps, not
    wall clock.
  - Step failures are **returned**, not thrown, so the captured frames survive;
    only faults decided before any step runs throw. Cancellation is the one
    exception: it unwinds and the frames are lost, because a cancelled call has
    no response left to carry them.
  - Bounds: 20 steps, 3 screenshots, 20 s of declared waits. The frame cap is
    measured, not guessed — a simulator window PNG is ~973 KB, so each frame is
    about a megabyte of base64 in the response.
- **Secrets:** `SIM_DEVELOPER_KEY` points to a Connect IQ developer key
  stored **outside** this repository. No key material is ever committed.

## Tool rules that surprise callers

Every tool's arguments and result shape are in README.md. This section is only
for behavior a caller gets wrong by reasonable assumption.

- **`get_logs` returns two cursors, and picking the wrong one silently
  misreads the log.** `nextToken` resumes pagination from the last line
  *returned*, so on a page bounded by `limit` it points into the middle of the
  buffer. To establish a "from now on" baseline — waiting for a line the app has
  not printed yet — use `latestToken`, the cursor at the newest line currently
  buffered. Baselining on `nextToken` instead matches lines that were already
  there. The two are equal exactly when the caller has consumed everything
  buffered. `droppedLines` counts lines the ring buffer overwrote: they are
  lost, not deferred. And a marker printed **without a trailing newline is not
  yet a log line** — it stays invisible until the app exits. `System.println`
  appends one.
- **`run_app` and `run_tests` do not trust the child's exit code.** monkeydo's
  is unreliable (SDK regex bug), so `run_tests` totals and per-test results come
  from parsing the transcript. Ownership is established only after an exact
  launcher connection is verified, never from the spawn succeeding. Cleanup
  fails closed: when it cannot verify every member of the owned process group it
  refuses to signal rather than signalling something it has not proven is ours.
- **`sim_status` is the only simulator tool that does not take the lease.** It
  reports the current holder, so it is safe to poll while another client is
  mid-operation — every other simulator-touching tool queues behind that lease.
  `sim_start` against a running *different* SDK returns `sdk_mismatch` rather
  than restarting the simulator; stop it with `sim_stop` first. Because cleanup
  fails closed, `sim_stop` is also the recovery path: a tree that a refused
  cleanup left running is reclaimed by the next successful `sim_stop`.
- **`list_devices` reports input capability from the compiled allowlist, never
  from device JSON.** A device whose hardware has the keys still reports
  `inputSupported=false`, `buttons=[]` and `inputProfile=null` unless it is one
  of the 19 qualified profiles. Device JSON describes hardware; it is never
  proof of an automation transport.
- **`list_sdks` reports which SDK would be resolved, and why.** Precedence is
  explicit parameter → `CIQ_SDK` → `current-sdk.cfg` → newest installed by
  parsed semver, so the active SDK can differ from the newest one present.
- **`set_gps_position` drives the simulator's own GUI.** It automates
  Settings → Set Position through Accessibility, so it needs a running
  simulator and the Accessibility grant — not just a launched app. Coordinates
  are decimal degrees. The contract was verified with the watch app observing
  the result by polling `Position.getInfo()`.

## Commands

- `swift build` / `swift test` — unit tests; no simulator or TCC needed.
- `SIM_INTEGRATION=1 swift test --filter InstalledServerIntegrationTests` —
  integration against the installed signed server (needs simulator + TCC
  grants).
- `SIM_INTEGRATION=1 swift test --filter InstalledSequenceIntegrationTests` —
  the `run_sequence` gate: a press whose delivery is read from the fixture's own
  log marker, a marker that never arrives (which must still return its frames),
  and an `allowFocus=false` refusal compared field by field against a real
  `press_button` call.
- `make install SIGNING_IDENTITY="simulator-mcp-local"` — release build,
  stable-identity signing, install to `~/.simulator-mcp/bin/`. Ad-hoc and
  unsigned builds lose their TCC grants on every rebuild. A stable identity
  avoids that, but an install can still leave a grant reading denied: check
  `doctor` afterwards, and if either permission is denied, remove the
  executable from System Settings and add it again rather than toggling it.
- `SIM_TCC_ONBOARD=1 swift test --filter InstalledServerPermissionOnboardingTests`
  — opt-in permission request through the installed server only.
- `scripts/audit-plan.sh` — fail-closed architecture and pattern audit.
- `make install-menu` — builds and installs `simulator-mcp-menu`, the status
  bar monitor, beside the server and writes a LaunchAgent plist. The monitor
  needs no TCC grant.

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
- `Sources/SimulatorMenu/` — a second, optional executable: a read-only macOS
  status bar monitor that shows whether an agent is currently driving the
  simulator. It may call only `ActivityStore.read`, `RuntimeStore.read`,
  `MonitorStateResolver`, `ProcessPresence`, and
  `DarwinProcessIdentityReader`. It must not construct `Foundation.Process`,
  and must not reference CGEvent, ScreenCaptureKit, or any Accessibility
  API — that is what keeps it out of TCC entirely. Enforced by
  `scripts/audit-plan.sh`.

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
