#!/usr/bin/env python3
"""Fail-closed audit of the input-capability allowlist.

Checks EVERY compiled-in qualified device, not a sample. For each one there
must be a shipped profile resource and its own measured delivery contract, and
the two must agree on the declared SDK set.

Both directions are failures:

  * a compiled-in device with no profile or no contract — capability claimed
    without evidence;
  * a profile or contract for a device that is not compiled in — capability
    arriving as a filesystem side effect, which A1 of the capability gate
    amendment exists to prevent.

The runtime loader enforces the profile half of this in `swift test`. The
contract half cannot be enforced there for a device whose profile was never
shipped, which is exactly the gap this closes.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUTTON_INPUT = ROOT / "Sources/SimulatorMCPCore/Automation/ButtonInput.swift"
PROFILES = ROOT / "Sources/SimulatorMCPCore/Resources/InputProfiles"
CONTRACTS = ROOT / "docs/verification/simulator-contracts"

failures = []


def fail(message):
    failures.append(message)


def compiled_in_devices():
    """Parse the `qualifiedDevices` literal out of the Swift source."""
    source = BUTTON_INPUT.read_text()
    match = re.search(
        r"static let qualifiedDevices:\s*Set<String>\s*=\s*\[(.*?)\]",
        source,
        re.DOTALL,
    )
    if not match:
        fail(f"could not find the qualifiedDevices literal in {BUTTON_INPUT}")
        return set()
    devices = set(re.findall(r'"([^"]+)"', match.group(1)))
    if not devices:
        fail("the qualifiedDevices literal is empty")
    return devices


devices = compiled_in_devices()

profile_files = {p.name[: -len("-input.json")] for p in PROFILES.glob("*-input.json")}
contract_files = {
    p.name[: -len("-focused-delivery.json")]
    for p in CONTRACTS.glob("*-focused-delivery.json")
}

for missing in sorted(devices - profile_files):
    fail(f"{missing}: qualified but has no profile resource")
for extra in sorted(profile_files - devices):
    fail(f"{extra}: profile resource ships for a device that is not compiled in")
for missing in sorted(devices - contract_files):
    fail(f"{missing}: qualified but has no measured delivery contract")
for extra in sorted(contract_files - devices):
    fail(f"{extra}: delivery contract exists for a device that is not compiled in")

# Cross-artifact agreement (A5), re-checked here so the audit stands alone.
for device in sorted(devices & profile_files & contract_files):
    try:
        profile = json.loads((PROFILES / f"{device}-input.json").read_text())
        contract = json.loads(
            (CONTRACTS / f"{device}-focused-delivery.json").read_text()
        )
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{device}: evidence could not be read: {error}")
        continue

    entries = (profile.get("transportProfile") or {}).get("sdkEntries") or {}
    declared = set(entries)
    measured = set(contract.get("sdks") or [])
    if not declared:
        fail(f"{device}: profile declares no SDK entries")
    if declared != measured:
        fail(
            f"{device}: profile SDKs {sorted(declared)} disagree with "
            f"measured contract SDKs {sorted(measured)}"
        )
    if set((profile.get("evidence") or {}).get("sdks") or []) != declared:
        fail(f"{device}: profile evidence.sdks disagrees with its own sdkEntries")
    if contract.get("device") != device:
        fail(f"{device}: contract names device {contract.get('device')!r}")

    # The key mapping the profile claims must be the one the gate measured.
    verified = (
        ((contract.get("facts") or {}).get("buttons") or {}).get("verified") or {}
    )
    if not verified:
        fail(f"{device}: contract records no verified buttons")
    for sdk, mapping in sorted(entries.items()):
        claimed = {button: spec.get("keyCode") for button, spec in mapping.items()}
        if claimed != verified:
            fail(
                f"{device} on {sdk}: profile key codes {sorted(claimed.items())} "
                f"disagree with measured {sorted(verified.items())}"
            )

if failures:
    print("plan audit failed: input-capability evidence is incomplete", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    sys.exit(1)

print(f"input-capability evidence complete for {len(devices)} qualified devices")
