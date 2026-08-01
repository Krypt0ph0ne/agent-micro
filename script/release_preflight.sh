#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"
mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

for required in \
  README.md \
  DEVELOPER_PREVIEW.md \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  References/ch57x-keyboard-tool/UPSTREAM_COMMIT; do
  if [[ ! -f "$required" ]]; then
    echo "Required source-release file is missing: $required" >&2
    exit 1
  fi
done

if git ls-files | grep -Eiq '(\.app/|\.(dmg|pkg|zip|bin|hex|ihx)$)'; then
  echo "A binary release artifact is tracked; the Developer Preview must be source-only." >&2
  git ls-files | grep -Ei '(\.app/|\.(dmg|pkg|zip|bin|hex|ihx)$)' >&2
  exit 1
fi

git diff --check
"$ROOT_DIR/script/test.sh"
"$ROOT_DIR/script/build_and_run.sh" --package-only

echo "Source-only Developer Preview preflight passed."
echo "Hardware acceptance was not run by this script and must be reported separately."
echo "No commit, tag, upload, release, or application installation was performed."
