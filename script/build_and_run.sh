#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexPad"
BUNDLE_ID="com.codexpad.app"
MIN_SYSTEM_VERSION="14.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_DIR="$ROOT_DIR/References/ch57x-keyboard-tool"
HELPER_SOURCE="$REFERENCE_DIR/target/release/ch57x-keyboard-tool"
HELPER_DESTINATION="$ROOT_DIR/Support/ch57x-keyboard-tool"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust/Cargo fehlt. Installiere Rust und starte dieses Skript erneut." >&2
  exit 1
fi

if [[ ! -d "$REFERENCE_DIR/.git" ]]; then
  echo "Referenzprojekt fehlt: $REFERENCE_DIR" >&2
  exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

echo "Building verified CH57x helper…"
cargo build --release --manifest-path "$REFERENCE_DIR/Cargo.toml"
cp "$HELPER_SOURCE" "$HELPER_DESTINATION"
chmod +x "$HELPER_DESTINATION"

echo "Building SwiftUI app…"
cd "$ROOT_DIR"
swift build
BUILD_BIN_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
RESOURCE_BUNDLE="$BUILD_BIN_DIR/CodexPad_CodexPad.bundle"

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "SwiftPM-Ressourcen fehlen: $RESOURCE_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$HELPER_DESTINATION" "$APP_RESOURCES/ch57x-keyboard-tool"
cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
chmod +x "$APP_BINARY" "$APP_RESOURCES/ch57x-keyboard-tool"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>CodexPad uses Input Monitoring to receive the CH57x encoder's private F22/F23/F24 triggers and control Codex's model picker.</string>
</dict>
</plist>
PLIST

# Give the development bundle a stable identity. Without this explicit bundle
# signature macOS derives a new hash-based identifier after every build, which
# invalidates Input Monitoring and Accessibility permissions.
/usr/bin/codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "CodexPad is running: $APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
