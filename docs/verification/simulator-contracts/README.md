# Simulator Implementation Contracts

This directory holds the locked empirical contracts for the simulator-mcp implementation. These documents are ground truth and govern the verification gates that unlock each phase of development.

## Contents

- **static-contracts.json** — Approved baseline facts: MCP SDK version and
  revision, supported simulator SDKs, GPS menu paths, and candidate device
  input profiles. A value changes only through an approved evidence-backed
  design amendment; the 2026-07-15 GPS amendment is the first such change.
- **Evidence files** (generated during tasks 8–16) — Dynamic verification
  results proving the implementation meets each gate, including negative
  evidence that closes an affected v1 feature under an approved amendment.

## Dynamic Evidence Gates

These gates must be closed before the corresponding tool can be installed as the supported v1 server. If a gate fails, stop implementation and write a design amendment next to the approved spec. Do not broaden a heuristic, guess another constant, or register the affected tool.

| Gate | Owning Task | Requirement | Stop Rule |
|------|------------|-------------|-----------|
| 1 | Task 8 | Show the exact simulator PID and a loopback listener for SDK 8.4.1 and 9.1.0 | Simulator process not detected or listener not bound to loopback |
| 2 | Task 10 | Show monkeydo establishes a TCP connection to that listener before run_app returns | TCP handshake not observed or connection established after return |
| 3 | Task 17 | Record whether TCC attributes checks the signed binary or responsible host and select the documented install command (Task 12 supplies diagnostic APIs) | TCC check target undetermined or install command not validated |
| 4 | Task 15 | Resolve background input under the approved 2026-07-15 amendment and commit both sanitized SDK AX trees | Closed negatively: CGEvent delivery changed no fixture state and neither SDK exposed exact semantic controls, so v1 has no input tool/profile |
| 5 | Task 16 | Save AX-tree fixtures for SDK 8.4.1 and 9.1.0 and prove the approved field selector | Original label contract closed negatively on both SDKs; shared combined-field replacement approved for TDD and live acceptance |

Task 15 evidence:

- `fenix6xpro-ax-input-8.4.1.json`
- `fenix6xpro-ax-input-9.1.0.json`

The candidate-input block intentionally retains its original keycodes.
Candidate means proposed input to the dynamic gate, not a shipped or verified
capability.

The GPS menu path was amended from the contradicted original value to exact
`Settings -> Set Position`; `Simulation` is not a fallback. See
`gps-menu-path-blocker-9.1.0.json`.

Task 16 dialog-contract evidence:

- `gps-dialog-contract-blocker-8.4.1.json`
- `gps-dialog-contract-blocker-9.1.0.json`

Both captures contradict the original labelled-field selector and support the
approved shared combined-field replacement (one direct-child combined
`AXTextField` selected by prompt/role/uniqueness/parent). Task 16 proceeded
through TDD and the live acceptance gates under that exact contract.
