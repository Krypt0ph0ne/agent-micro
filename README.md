# Agent Micro

Agent Micro is a local native macOS 14+ app for configuring and using a
supported six-key CH552/CH57x macro pad with Codex and Claude desktop sessions.
It is an independent open-source project and is not affiliated with or
endorsed by OpenAI, Anthropic, SinLoon, Amazon, or Apple.

> [!IMPORTANT]
> **Developer Preview — source only.** There is no stable binary release and
> no signed, downloadable macOS app. Clone the app and firmware repositories
> and build both locally. See [DEVELOPER_PREVIEW.md](DEVELOPER_PREVIEW.md) for
> the release scope and validation checklist.

> [!WARNING]
> Flashing the tested pad **permanently replaces its manufacturer firmware**.
> The manufacturer firmware could not be backed up, is not distributed by this
> project, and cannot be restored with the documented recovery procedure.
> Continue only if you accept that the device cannot be returned to its factory
> software state. Support is limited to the exact board identified below.

This repository contains the macOS app. Custom device firmware lives in
[`agent-micro-firmware`](https://github.com/Krypt0ph0ne/agent-micro-firmware).
The commercial pad's PCB, enclosure, factory firmware, and product images are
not part of either open-source project.

## Features

- Detects the verified factory USB device `0x1189:0x8890`.
- Configures six keys and encoder left/press/right using the vendored,
  MIT-licensed `ch57x-keyboard-tool`.
- Supports keyboard chords, short sequences, media controls, mouse actions,
  German ISO, US, and UK layouts.
- Supports Agent Micro Raw HID protocol v2 firmware, including nine live
  bindings, real press/release actions, firmware status, emergency release-all,
  and six independent RGB LEDs.
- Assigns physical controls to existing Codex or Claude desktop sessions.
- Observes local agent states and drives optional per-key status lighting.
- Stores profiles and assignments locally; no project-operated cloud service,
  analytics, telemetry, or automatic updater is included.

See [PRIVACY.md](PRIVACY.md) for the exact local files and permissions used.

## Supported hardware

The only custom-firmware target verified by this project is the SinLoon
SL2024502 sold under Amazon ASIN
[`B0DN9T9J75`](https://www.amazon.de/dp/B0DN9T9J75): six mechanical keys, one
rotary encoder, USB-C, and six addressable LEDs.

Visually identical pads can contain different controllers or pinouts. Never
flash a device based on appearance alone. Check the factory VID/PID and follow
the firmware repository's preflight procedure.

| USB identity | Support |
| --- | --- |
| `1189:8890` | Verified factory CH57x configuration path |
| `4249:4287` | Current experimental Developer Preview app/firmware path; not an allocated identity |
| `1209:A6E1` | Requested from pid.codes; not assigned and not active |

The Developer Preview uses `4249:4287` only as an explicitly experimental
compatibility identity. It is not an official project allocation. The project
does not claim or substitute any third-party USB identity. Do not change the
firmware to `1209:A6E1` unless and until the pid.codes request is accepted.

## Build from source

Agent Micro does not publish an unsigned downloadable `.app`. Without a paid
Apple Developer account, the supported installation path is a local build:

```sh
xcode-select --install
brew install rust

git clone https://github.com/Krypt0ph0ne/agent-micro.git
cd agent-micro

./script/test.sh
./script/build_and_run.sh --verify
```

The build script:

1. verifies the vendored helper provenance marker and required license files;
2. builds the Rust helper from source;
3. builds the SwiftPM executable;
4. creates `dist/Agent Micro.app`;
5. uses a local Apple Development identity when available, otherwise ad-hoc
   signing.

Ad-hoc signing is suitable for a locally built app, but rebuilding can cause
macOS to request Input Monitoring or Accessibility permission again.

For a local Universal 2 package, install the official `rustup` toolchain and
run:

```sh
./script/build_universal.sh
```

This builds both the app and Rust helper for Apple Silicon and Intel. CI also
compiles both architectures, but it does not publish the unsigned artifact.

## Test and diagnose

```sh
./script/test.sh
swift run AgentMicroHIDProbe 90
```

Before preparing a source-only Developer Preview, run the complete local
release preflight:

```sh
./script/release_preflight.sh
```

It tests the Swift app and vendored Rust helper, creates a local staging app
from source, and checks that no binary release artifact is tracked. It does not
create a commit, tag, GitHub Release, upload, or installation.

The live hardware test is opt-in:

```sh
AGENT_MICRO_HARDWARE_TEST=1 swift test
```

Enable it only on a Mac connected to the exact verified test device.

## macOS permissions

- **Input Monitoring** receives private hardware triggers.
- **Accessibility** emits shortcuts selected by the user.
- **Login Item** is optional and keeps the menu-bar controller available.

Agent Micro can observe local approval requests. It never answers one
automatically. Approve or decline is sent only if the user explicitly assigns
that action to a hardware control and physically activates it.

## Data and compatibility

Profiles and assignments are stored under:

```text
~/Library/Application Support/Agent Micro
```

The first open-source build migrates data from the legacy
`Application Support/CodexPad` directory and matching `CodexPad.*`
preferences when the new destination does not already exist.

Codex and Claude integrations depend on local interfaces exposed by installed
desktop/CLI versions. Changes in those applications can temporarily break
session discovery or navigation without affecting basic macro-pad
configuration.

The action catalogs were last verified against Codex desktop
`26.715.21425` and Claude Desktop `1.22209.3` (catalog compatibility label
`1.22+`). These are verification baselines, not guarantees for future private
interfaces. See the `verifiedAgainst` fields in `Resources/CodexActions.json`
and `Resources/ClaudeActions.json`.

## Custom firmware

Build, preflight, flash, recovery, hardware limits, and the Raw HID wire format
are documented in the separate firmware repository:

<https://github.com/Krypt0ph0ne/agent-micro-firmware>

Installing the custom firmware permanently replaces the manufacturer
application. The original application could not be read back, and the project
does not provide a factory image or a path back to the factory software.
Bootloader recovery can install another trusted Agent Micro build only.

## Contributing and security

- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Trademark and compatibility notice](TRADEMARKS.md)

## License

Agent Micro is available under the [MIT License](LICENSE). Bundled third-party
components retain their own licenses as described in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
