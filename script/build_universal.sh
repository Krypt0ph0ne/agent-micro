#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_DIR="$ROOT_DIR/References/ch57x-keyboard-tool"
SUPPORT_HELPER="$ROOT_DIR/Support/ch57x-keyboard-tool"

if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup is required for the optional Universal 2 build." >&2
  echo "Install the official Rust toolchain from https://rustup.rs and try again." >&2
  exit 1
fi

rustup target add aarch64-apple-darwin x86_64-apple-darwin
cargo build --locked --release --target aarch64-apple-darwin --manifest-path "$REFERENCE_DIR/Cargo.toml"
cargo build --locked --release --target x86_64-apple-darwin --manifest-path "$REFERENCE_DIR/Cargo.toml"

mkdir -p "$(dirname "$SUPPORT_HELPER")"
xcrun lipo -create \
  "$REFERENCE_DIR/target/aarch64-apple-darwin/release/ch57x-keyboard-tool" \
  "$REFERENCE_DIR/target/x86_64-apple-darwin/release/ch57x-keyboard-tool" \
  -output "$SUPPORT_HELPER"
chmod +x "$SUPPORT_HELPER"

AGENT_MICRO_USE_EXISTING_HELPER=1 \
AGENT_MICRO_SWIFT_BUILD_FLAGS="-c release --arch arm64 --arch x86_64" \
  "$ROOT_DIR/script/build_and_run.sh" --package-only

file "$ROOT_DIR/dist/Agent Micro.app/Contents/MacOS/AgentMicro"
file "$ROOT_DIR/dist/Agent Micro.app/Contents/Resources/ch57x-keyboard-tool"
