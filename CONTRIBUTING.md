# Contributing to Agent Micro

Thanks for helping improve Agent Micro. Contributions are accepted under the
MIT License in this repository.

## Development setup

Requirements:

- macOS 14 or newer
- Xcode Command Line Tools
- Rust/Cargo

Run the complete local checks:

```sh
./script/test.sh
./script/build_and_run.sh --package-only
```

Hardware tests are opt-in because they require the exact supported pad:

```sh
AGENT_MICRO_HARDWARE_TEST=1 swift test
```

Never enable the hardware test on an unverified device variant.

## Pull requests

1. Keep a pull request focused on one change.
2. Add or update tests for behavior changes.
3. Document permission, storage, USB protocol, or hardware compatibility
   changes.
4. Do not commit profiles, session data, device dumps, signing identities,
   application bundles, or generated build output.
5. Sign every commit using the Developer Certificate of Origin:

```sh
git commit -s
```

The sign-off states that you have the right to contribute the change under
this repository's license. See <https://developercertificate.org/>.

Firmware changes belong in the separate
[`agent-micro-firmware`](https://github.com/Krypt0ph0ne/agent-micro-firmware)
repository and follow that repository's CC BY-SA 3.0 terms.
