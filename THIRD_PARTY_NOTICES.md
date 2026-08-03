# Third-party notices

Agent Micro is distributed under the MIT License. The following bundled
component retains its own copyright and license.

## ch57x-keyboard-tool

Agent Micro invokes a locally built copy of
[kriomant/ch57x-keyboard-tool](https://github.com/kriomant/ch57x-keyboard-tool),
commit `aff33824af889022eb130db4c01c4c0bbaa8ab89` (retrieved
2026-07-17). Its source is vendored under
`References/ch57x-keyboard-tool` so a fresh clone builds without downloading
or executing an opaque helper. The vendored source includes local support for
the verified `0x1189:0x8890` device path.

The vendored copy intentionally diverges from that upstream commit in
`Cargo.toml` and `Cargo.lock` only, to carry security updates upstream has not
released: `rustix` 0.36.16, `unsafe-libyaml` 0.2.10, `time` 0.3.47, and
`serde_with` 3.21.0. No Rust source file is modified.

License: MIT License, Copyright 2023 Mikhail Trishchenkov. The full license
text is retained at `References/ch57x-keyboard-tool/LICENSE`.

Agent Micro contains no vendor-supplied configuration software and no
prebuilt binary downloaded from an unknown source. See `ASSETS.md` for the
provenance policy covering project images and data files.
