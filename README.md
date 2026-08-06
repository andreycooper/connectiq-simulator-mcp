# simulator-mcp

[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`simulator-mcp` is a macOS stdio MCP server for building, running, testing,
observing, and setting the static GPS position of Garmin Connect IQ apps in the
simulator. MCP JSON-RPC owns stdout; operational diagnostics use stderr.

## Prerequisites

- macOS 14+.
- Swift 6 and Xcode command-line tools.
- Garmin Connect IQ SDK/Device Manager with a device profile installed.
- Java 17+.
- A Connect IQ developer key outside this repository. Set
  `SIM_DEVELOPER_KEY` to its absolute path for integration tests.

## Stable signing and installation

A Developer ID Application identity is preferred when one is available:

```sh
make install SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

For local development, create the persistent self-signed identity once and
install the stable binary:

```sh
./scripts/create-signing-identity.sh
make install SIGNING_IDENTITY="simulator-mcp-local"
```

The supported stable binary path is
`~/.simulator-mcp/bin/simulator-mcp`. `make sign` rejects an empty identity and
ad-hoc signing (`-`), verifies the signature, and uses the production
`SignatureInspector` to require a stable designated identity. `make install`
publishes through a temporary file in the destination directory and verifies
the installed copy.

## TCC onboarding

Start with the stable binary. The onboarding test launches that exact
executable, calls `doctor` with `requestPermissions=true`, prints the structured
report, and invokes no simulator operation:

```sh
SIM_TCC_ONBOARD=1 swift test --filter InstalledServerPermissionOnboardingTests
```

In System Settings, enable the exact executable reported by `doctor` under:

- Privacy & Security > Screen & System Audio Recording
- Privacy & Security > Accessibility

After either grant changes, fully restart the test process and every MCP host;
an already-running responsible process does not acquire the new grant.

After the restart, verify the same installed executable without requesting
another prompt. This pre-attribution check does not read
`tcc-attribution.json`:

```sh
SIM_TCC_PREFLIGHT=1 swift test --filter InstalledServerPermissionPreflightTests
```

If both preflights attach to the stable binary, use deployment mode
`stableBinary`. If macOS attributes them to an application identity, install
the signed host and repeat onboarding against its executable:

```sh
make install-host SIGNING_IDENTITY="simulator-mcp-local"
SIM_TCC_EXECUTABLE="$HOME/.simulator-mcp/SimulatorMCPHost.app/Contents/MacOS/simulator-mcp-host" \
  SIM_TCC_ONBOARD=1 swift test --filter InstalledServerPermissionOnboardingTests
```

After granting and restarting, verify that host executable explicitly:

```sh
SIM_TCC_EXECUTABLE="$HOME/.simulator-mcp/SimulatorMCPHost.app/Contents/MacOS/simulator-mcp-host" \
  SIM_TCC_PREFLIGHT=1 swift test --filter InstalledServerPermissionPreflightTests
```

That fallback is deployment mode `signedHostApp`. Complete the Task 17 gate by
calling `doctor` with `requestPermissions=false` once through the installed
client and once through the actual MCP host, then record exactly one verified
mode in `docs/verification/simulator-contracts/tcc-attribution.json`. Do not
create that file from assumptions. If neither mode keeps both grants, stop for
a design amendment.

The verified 2026-07-16 acceptance selected `stableBinary` at
`~/.simulator-mcp/bin/simulator-mcp`; both installed-client and
Claude-host `doctor(false)` calls retained Screen Recording and Accessibility.
The evidence remains machine-specific and is recorded in
`docs/verification/simulator-contracts/tcc-attribution.json`.

The evidence file is fail-closed and uses this shape; replace every sample
value with the observed installed-client and real-host results:

```json
{
  "deploymentMode": "stableBinary",
  "executablePath": "/Users/you/.simulator-mcp/bin/simulator-mcp",
  "responsibleProcess": { "name": "claude", "pid": 1234 },
  "signature": {
    "identity": "simulator-mcp-local",
    "signingIdentifier": "simulator-mcp"
  },
  "installedClientDoctor": {
    "requestPermissions": false,
    "executablePath": "/Users/you/.simulator-mcp/bin/simulator-mcp",
    "signatureKind": "stable",
    "signingIdentifier": "simulator-mcp",
    "screenRecordingGranted": true,
    "accessibilityGranted": true
  },
  "actualMCPHostDoctor": {
    "requestPermissions": false,
    "executablePath": "/Users/you/.simulator-mcp/bin/simulator-mcp",
    "signatureKind": "stable",
    "signingIdentifier": "simulator-mcp",
    "screenRecordingGranted": true,
    "accessibilityGranted": true
  }
}
```

## MCP host configuration

Use the executable selected by `tcc-attribution.json`; never register a
`.build` product.

For Claude Code with the stable binary:

```sh
claude mcp add garmin-sim -- "$HOME/.simulator-mcp/bin/simulator-mcp"
```

For Codex, add the selected path to `~/.codex/config.toml`:

```toml
[mcp_servers.garmin-sim]
command = "/Users/you/.simulator-mcp/bin/simulator-mcp"
```

For signed-host mode, replace the command in either configuration with
`~/.simulator-mcp/SimulatorMCPHost.app/Contents/MacOS/simulator-mcp-host`.

## Tools

Every call returns a typed envelope in `structuredContent` and the identical
JSON as the first text content item. Success is `{ok:true,result:...}` with
`isError=false`. Failure is `{ok:false,error:{code,message,fix,details?}}` with
`isError=true`; the concrete `fix` is never empty.

| Tool | Arguments | Result and error behavior |
|---|---|---|
| `doctor` | `requestPermissions?` (default `false`) | SDK, Java, simulator, stable signature, responsible-process note, Screen Recording and Accessibility preflights. Permission prompts occur only when explicitly requested. |
| `list_sdks` | none | Installed SDK paths/versions and the active resolution source. Missing SDK state is actionable. |
| `list_devices` | `projectPath?`, `jungle?`, `sdk?` | Installed/manifest-filtered devices. Input capability comes from the verified profile allowlist; devices outside it report `inputSupported=false`, `buttons=[]`, and `inputProfile=null`. |
| `build` | `projectPath`; optional `device`, `sdk`, `jungle`, `developerKey`, `release`, `unitTests` | Artifact identity plus structured diagnostics. Ordinary compiler errors return `succeeded=false`; incompatible build flags are rejected. |
| `sim_start` | `sdk?` | Verified ready status for the exact SDK. A running different SDK returns `sdk_mismatch`. |
| `sim_stop` | none | Confirmed `not_running` status after session and simulator cleanup. |
| `sim_status` | none | State, operation, PID, SDK, current device, and lease holder without taking the lease. |
| `run_app` | `projectPath`; optional `device`, `sdk`, `jungle`, `developerKey`, `rebuild` | Verified session ID, device, PRG, SDK, and rebuild state only after an exact launcher connection. |
| `run_tests` | `projectPath`; optional `device`, `sdk`, `jungle`, `developerKey`, `testFilter` | Transcript-authoritative totals and every per-test result; the child exit code is not trusted. |
| `get_logs` | optional `sessionId`, `sinceToken`, `limit` | Bounded lines, crash state, termination data, dropped count, and next cursor. |
| `screenshot` | `savePath?` | PNG image content plus dimensions, simulator PID, saved path, and `appDisplayRect`. Permission denial names the exact onboarding fix. |
| `set_gps_position` | `lat`, `lon` | Checked coordinates and simulator PID after semantic Accessibility automation and dialog-close proof. |
| `press_button` | `button`; optional `holdMs` (50–5000), `allowFocus` (default `false`) | Delivers a verified hardware button to the focused simulator and reports the button, press type, transport, and simulator PID. |
| `run_sequence` | `steps` (1–20, each `press`/`screenshot`/`waitForLog`); optional `allowFocus` (default `false`) | Runs a scripted interaction under a **single** simulator lease and returns every captured frame inline as an image block. A failed step still returns the frames captured before it plus one taken at the moment of failure. |

### Button automation

`press_button` is verified for **19 fēnix devices** with the buttons `enter`,
`esc`, `up`, and `down`, qualified through 32 device×SDK combinations:

- **SDK 8.4.1 and 9.1.0** — `fenix6`, `fenix6pro`, `fenix6s`, `fenix6spro`,
  `fenix6xpro`, `fenix7`, `fenix7pro`, `fenix7pronowifi`, `fenix7s`,
  `fenix7spro`, `fenix7x`, `fenix7xpro`, `fenix7xpronowifi`.
- **SDK 9.1.0 only** — `fenix843mm`, `fenix847mm`, `fenix8pro47mm`,
  `fenix8solar47mm`, `fenix8solar51mm`, `fenixe`. These profiles need API level
  6.0.0, which 8.4.1 cannot compile, so capability is claimed for 9.1.0 and
  nothing else.

Capability is an explicit allowlist keyed by exact device id *and* SDK version.
The other 143 installed devices advertise `inputSupported=false`, `buttons=[]`
and `inputProfile=null` — including `fenix3`, `fenix5` and `fenixchronos`,
which share the same physical key layout and stay fail-closed anyway. A
device-name or simulator-JSON match is not evidence that a transport works.

The transport posts a key-down/key-up pair to the frontmost simulator. It
requires the ANSI-US input source (`com.apple.keylayout.US`) and the
Accessibility grant. Because the simulator only observes a key that is held
long enough for its event loop to sample it, every press holds the key for at
least the profile's `minimumPressMs` (50 ms); `holdMs` above that is passed
through, and a hold of 300 ms or more reads as a long press on the device.

`allowFocus=true` is required unless the simulator is already frontmost: the
call visibly brings the simulator forward and leaves it frontmost. With
`allowFocus=false` and the simulator in the background, the call returns
`focus_required` and posts no event.

No device in the family exposes a `menu` button. On real hardware and in the
simulator, menu is a long press of `up` (`press_button` with `button: "up"` and
`holdMs: 1000`). All 19 share one layout group and identical key codes,
measured per device rather than inferred from key names.

### Scripted sequences

`run_sequence` runs a short interaction under a **single** simulator lease and
returns every captured frame inline, so the model sees the whole filmstrip in
one response instead of reasoning about screenshots several turns apart.

```jsonc
{
  "steps": [
    { "kind": "screenshot", "label": "initial" },
    { "kind": "press",      "button": "enter", "holdMs": 1000 },
    { "kind": "waitForLog", "contains": "MENU_OPENED", "timeoutMs": 5000 },
    { "kind": "screenshot", "label": "menu" }
  ],
  "allowFocus": true
}
```

Because it holds one lease for the whole run, no other MCP client can drive the
simulator part-way through the interaction. A person typing at the keyboard
still can: `press` posts key events to the frontmost application, which is not
a channel the lease owns.

Four things are worth knowing before writing one:

- **`waitForLog` only matches markers printed after the sequence starts.** It
  baselines on the log's end-of-buffer cursor, so a marker the app printed
  earlier can never satisfy it.
- **Waits are ordered.** Each one resumes where the previous one matched, so
  waiting for a marker that was printed *before* an already-matched one will
  time out.
- **A marker needs a trailing newline.** An unterminated line is not yet a log
  line and stays invisible until the app exits. `System.println` appends one.
- **A marker proves a code path was reached, not that drawing finished.** For a
  wait to imply a completed redraw, print it from inside `onUpdate()` after the
  draw calls.

If a step fails, the call returns `ok:false` **with the frames captured before
it**, plus one taken at the moment of failure, and `details.failedStepIndex`
naming the step. A `waitForLog` short-circuits when the app exits rather than
burning its timeout, and says the app died.

Bounds: at most 20 steps, 3 screenshots, 20 s of declared waits, and a 120 s
budget across the run. The frame cap is small on purpose — a simulator window
PNG measures ~973 KB, so every frame is roughly a megabyte of base64 in the
response.

## Status bar monitor

`make install-menu` installs `simulator-mcp-menu`, a read-only status bar icon
showing whether an agent is currently driving the simulator. States are
distinguished by shape, not colour — `NSStatusBarButton.contentTintColor`
measured inert on this machine — using an `applewatch.*` SF Symbol family:
`applewatch.slash` for no simulator, `applewatch` for idle,
`applewatch.radiowaves.left.and.right` for driving, and
`exclamationmark.applewatch` when the state cannot be determined.

Three things to know:

- **The icon is a strong hint, not a mutex.** It polls every 250 ms, so it can
  lag the start of an operation by up to that long. A process probe retry adds
  to that same poll's resolve latency — it loops *within* the poll, so it
  never costs a second poll interval.
- **Avoid opening the menu during a sequence.** An open menu takes keyboard
  focus, and `press_button` delivers keys to the frontmost application — so
  opening it mid-sequence can silently swallow a press. The icon is designed to
  answer "is an agent driving?" without being clicked.
- **Reveal is disabled while an agent is driving**, because activating Finder
  would take focus away from the simulator for the same reason.

The monitor takes no lease, spawns no processes, and needs no Screen Recording
or Accessibility grant.

## Build and test

Unit tests need no simulator or TCC grant:

```sh
swift package resolve
swift build
swift test
make build
```

After signing, onboarding, host restart, and verified attribution:

```sh
SIM_INTEGRATION=1 SIM_DEVELOPER_KEY="$SIM_DEVELOPER_KEY" \
  swift test --filter InstalledServerIntegrationTests
```

`make integration` enforces the same two environment variables. The installed
suite crosses only the stdio MCP boundary and proves fixture logs, exact test
results, an app-owned red pixel patch, static GPS observation, and cleanup.
The complete flow was additionally verified end to end against a real
Connect IQ project driven through Claude Code.

## State semantics

SDK resolution is explicit parameter, then `CIQ_SDK`, active SDK pointer, then
newest installed semantic version. Simulator operations compare the requested
SDK with the running SDK; on `sdk_mismatch`, call `sim_stop`, then `sim_start`
with the desired SDK.

Screenshot and GPS have no device override: they use the current device set by
the latest verified run. If there is no current device, run an app or test on a
device first. One current app session remains readable after exit. A new
verified session replaces it; old cursors then fail with `stale_session` and
name the newer session instead of reading unrelated logs.

The simulator lease is `~/.simulator-mcp/sim.lock`. Never delete that lock
file. A dead owner releases `flock` automatically; unlinking the pathname can
split mutual exclusion across two inodes.

## Troubleshooting

1. Run `doctor` first and apply every reported fix, including the exact
   executable path and host-restart instruction.
2. For `sdk_mismatch`, stop the simulator and restart it with the requested
   SDK; do not mix `monkeydo` and simulator versions.
3. For TCC denial, rerun onboarding, grant the reported stable binary or signed
   host, and fully restart the responsible MCP host.
4. For a busy lease, inspect the reported holder PID and operation. Do not
   delete `sim.lock`.

## License

MIT — see [LICENSE](LICENSE).
