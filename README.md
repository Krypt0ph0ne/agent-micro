# CodexPad

CodexPad is a local native macOS 14+ SwiftUI application for configuring a connected 3×2 CH57x macro pad with one encoder. It is an independent project inspired by calm desktop tooling—not an official OpenAI product, and it contains no OpenAI logos or copied assets.

## What it does

- Detects the connected USB device through the IORegistry. It does not depend on `system_profiler`, which returns an empty USB list on this Mac despite a connected HID device.
- Supports the verified `0x1189:0x8890` CH57x-2 path: six keys, one encoder (counter-clockwise, press, clockwise), direct keyboard chords, sequences, media keys and mouse actions.
- Supports the custom CH552 CodexPad firmware at `0x4249:0x4287`: nine live-reconfigurable keyboard/media bindings, real press/release hold actions, app-only events, firmware status, emergency release-all, and six independent RGB LEDs with off, steady, blink and pulse effects.
- Translates semantic keys for automatic, German ISO, English US and English UK layouts before sending HID usages; German Y/Z and common punctuation no longer require profile workarounds.
- Supports a **Text absenden** action: it types up to four ASCII letters or digits and then sends Enter (for example `Yeet`).
- Generates `ch57x-keyboard-tool` YAML, invokes `validate`, and only then invokes a VID/PID-pinned `upload` after an in-app confirmation. A transport success needs exit code 0 **and an empty stderr**; it is not presented as an input verification.
- Includes a passive HID input monitor for real F13–F21 verification. Input Monitoring may be required by macOS; the monitor cannot intercept or synthesize input.
- Provides a versioned JSON Codex action catalog based on the official [Commands reference](https://learn.chatgpt.com/docs/reference/commands), including supported deep links as metadata.
- Stores profiles locally in `~/Library/Application Support/CodexPad/Profiles.json`, and supports JSON import/export.
- Captures helper stdout/stderr and raw USB discovery output in its Diagnostics view.

The app does not use vendor software, network services, a cloud account or telemetry.

## Device and LED support

The shipped device path is intentionally exact:

| USB ID | Driver model | Endpoint | Confirmed LED capability |
| --- | --- | --- | --- |
| `0x1189:0x8890` | `ch57x-2` | `0x02` | global numeric LED mode transport; only mode `1` is documented by the helper as likely “Steady on” |
| `0x4249:0x4287` | CodexPad CH552 | Raw HID `FF60:0061` | six independent RGB colors, brightness, steady, blink, pulse and off |

The helper also knows `0x1189:0x8840` and `0x1189:0x8842`, but CodexPad does not claim the 3×2 layout or LED capability for those variants. It reports them as recognized-but-not-uploadable instead of uploading a guessed configuration. The manufacturer firmware at 0x8890 only exposes the known global LED-mode message. Individual light controls therefore activate only when the custom CH552 firmware is detected.

The custom firmware keeps live profile data in RAM. The app stores the profile permanently on the Mac, but after unplugging the pad, click **Übertragen** once to restore the chosen bindings and lighting. The immutable WCH bootloader and manufacturer DataFlash are not modified by profile transfer.

Its Raw HID protocol v2 reports physical key-down/key-up edges and encoder detents back to the app. The Diagnostics view shows the reported firmware version, capability flags, pressed-control mask and latest physical event. USB resets clear held keyboard state as a guard against stuck modifiers.

## Build, test and run

Prerequisites: Xcode command-line tools, macOS 14+, and Rust/Cargo. The repository includes the separate MIT reference checkout in `References/ch57x-keyboard-tool`.

```sh
./script/test.sh
./script/build_and_run.sh --verify
```

`script/build_and_run.sh` always stops an old `CodexPad` process, builds the locally checked-out Rust helper, builds the SwiftPM target, stages `dist/CodexPad.app`, and launches it. Its modes are `run`, `--debug`, `--logs`, `--telemetry`, and `--verify`.

For a terminal-level, read-only hardware check after uploading the safe profile:

```sh
swift run CodexPadHIDProbe 90
```

Press Key 1–6, then rotate the encoder left, press it, and rotate it right. Expected HID keyboard usages are `0x68…0x70` (F13…F21). Note that HID F13 begins at `0x68`, not immediately after the F12 range (`0x3a…0x45`).

The app is deliberately unsandboxed for local development so the helper can claim the USB HID interface. No elevated privilege is normally needed on macOS; a failed claim is recorded verbatim in Diagnostics.

## Safe use

1. Start with the `Sichere F13–F21-Belegung` profile.
2. Click **Validieren** and inspect Diagnostics.
3. Click **Übertragen**, review the confirmation, then test one key in a harmless text field.
4. The **Factory-like C mapping** profile is an approximation only. The original factory mapping cannot be read by the verified helper.

The confirmed 0x8890 hardware limits a keyboard sequence to five chords and does not support the helper's delay option. Deep links and local shell commands are stored as non-uploadable profile metadata; CodexPad will not execute them automatically.

## Codex actions and the encoder

`Resources/CodexActions.json` combines the official Commands reference with the command IDs registered by the locally installed Codex desktop app (`26.715.21425`, build `5488`). Cards distinguish three honest states: a direct, uploadable shortcut; a documented deep link; and a real app action that is configurable in **Codex > Settings > Keyboard Shortcuts** but has no default keybinding in this installed version.

The visible app is intentionally limited to one **Codex** profile and three encoder actions. F22/F23/F24 are private hardware triggers. Rotation is translated to the configured Codex shortcuts F18/F19 and changes reasoning directly without opening a picker. The first encoder press opens the Model Picker; the next press sends Escape to close it. CodexPad performs no model navigation or confirmation. Older unchanged encoder defaults are migrated automatically.

The built-in dictation action uses a held `Command+F17` chord. Assign that chord in Codex under **Settings > Keyboard Shortcuts > Zum Diktieren gedrückt halten**. Pressing the physical button sends key-down; releasing it sends key-up, so no second tap is required.

`Examples/SafeF13F21.yaml` is the matching standalone safe configuration for direct helper diagnosis. `Examples/CodexDefault.yaml` is the generated built-in Codex-profile counterpart.

## References

- [ch57x-keyboard-tool](https://github.com/kriomant/ch57x-keyboard-tool), MIT; technical source and USB protocol helper.
- [Official Codex commands and deep links](https://learn.chatgpt.com/docs/reference/commands); shortcut/deep-link source, catalog verified 2026-07-17.
