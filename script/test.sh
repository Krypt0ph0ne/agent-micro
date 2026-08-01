#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_DIR="$ROOT_DIR/References/ch57x-keyboard-tool"

cd "$ROOT_DIR"
echo "Testing CH57x helper reference…"
cargo test --manifest-path "$REFERENCE_DIR/Cargo.toml"

echo "Testing Agent Micro…"
SWIFT_TEST_ARGUMENTS=()
if [[ -n "${AGENT_MICRO_SWIFT_TEST_FLAGS:-}" ]]; then
  read -r -a SWIFT_TEST_ARGUMENTS <<<"$AGENT_MICRO_SWIFT_TEST_FLAGS"
  swift test "${SWIFT_TEST_ARGUMENTS[@]}"
else
  swift test
fi
