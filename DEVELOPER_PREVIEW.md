# Agent Micro Developer Preview

These are the release notes and final checks for the public, source-only
Developer Preview. This document deliberately does not assign a version or tag.
A maintainer must choose the release identifier and explicitly approve the
publication step.

## Release designation

- **Developer Preview / experimental**, not a stable release.
- App and firmware are provided as source. Users clone both repositories and
  build locally.
- No signed or downloadable macOS app and no prebuilt firmware image is part of
  this preview.
- The app and current firmware work together as `4249:4287`. This is an
  experimental, locally selected USB identity, not an official allocation.
- `1209:A6E1` has been requested from pid.codes but is not assigned or active.
  The preview does not claim that allocation and does not use a third party's
  USB identity as its own.

## Hardware and irreversible flashing warning

> [!WARNING]
> Flashing **permanently replaces the manufacturer firmware**. The original
> application could not be backed up, is not distributed, and is not restored
> by the documented bootloader recovery path. Proceed only if losing the
> factory software permanently is acceptable.

Custom-firmware support is limited to the tested SinLoon SL2024502 sold under
Amazon ASIN `B0DN9T9J75`: six keys, one rotary encoder, USB-C, six addressable
LEDs, CH552G, and factory USB identity `1189:8890`. Similar appearance, product
name, or enclosure is not evidence of compatibility.

Before flashing, users must follow the firmware repository's complete macOS
procedure. In particular, they must identify the exact board and SW2 pads, run
the read-only native preflight, build with the pinned toolchain, review the
locally built image hash, and use the guarded flash wrapper. Recovery installs
another Agent Micro image; it does not restore the manufacturer application.

## Build from source

App:

```sh
git clone https://github.com/Krypt0ph0ne/agent-micro.git
cd agent-micro
./script/release_preflight.sh
./script/build_and_run.sh --verify
```

Firmware:

```sh
git clone https://github.com/Krypt0ph0ne/agent-micro-firmware.git
cd agent-micro-firmware
make doctor
make test
```

Run the firmware repository's documented native preflight and flashing
sequence only with the exact supported board. Do not flash a binary copied
from an issue, comment, release attachment, or untrusted fork.

## Preview scope and known limits

- Basic factory-firmware configuration uses the verified `1189:8890` path.
- Raw HID protocol v2 features require the experimental Agent Micro firmware
  enumerating as `4249:4287`.
- Hardware validation is opt-in and cannot be inferred from unit-test success.
- Codex and Claude integrations depend on local interfaces that those apps may
  change. The catalog baselines in the app resources are observations, not
  forward-compatibility guarantees.
- Ad-hoc local app signing is not a distributable or stable identity. A
  code-changing rebuild can require Accessibility and Input Monitoring grants
  again.
- The pending pid.codes request is not a prerequisite to publishing this
  source-only preview. Its status must be checked before any future USB
  identity change.

## Publication gate

Before publication, record the exact app and firmware commits and retain the
output of these checks:

1. App: `./script/release_preflight.sh`.
2. Firmware: `make doctor && make test` from a clean checkout.
3. Hardware: state explicitly whether the opt-in live acceptance test was run
   on the exact supported board; do not present a skipped test as passing.
4. Confirm the release notes still say Developer Preview, source only,
   experimental `4249:4287`, and pending `1209:A6E1`.
5. Confirm there are no `.app`, `.dmg`, `.pkg`, firmware `.bin`/`.hex`, signing
   identities, device dumps, or factory backups in the release assets.
6. Obtain explicit maintainer approval for the chosen release identifier and
   the public publication action.

Only after that approval, create a GitHub **pre-release** using these notes and
source archives only. Do not attach app or firmware binaries and do not label
the release stable.
