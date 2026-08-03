#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgentMicro"
DISPLAY_NAME="Agent Micro"
BUNDLE_ID="io.github.krypt0ph0ne.agentmicro"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${AGENT_MICRO_VERSION:-0.1.0-dev}"
APP_BUILD="${AGENT_MICRO_BUILD:-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_DIR="$ROOT_DIR/References/ch57x-keyboard-tool"
HELPER_SOURCE="$REFERENCE_DIR/target/release/ch57x-keyboard-tool"
HELPER_DESTINATION="$ROOT_DIR/Support/ch57x-keyboard-tool"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
INSTALL_PARENT="/Applications"
INSTALLED_APP_BUNDLE="$INSTALL_PARENT/$DISPLAY_NAME.app"
INSTALLED_APP_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--package-only|package-only)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--package-only]" >&2
    exit 2
    ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust/Cargo fehlt. Installiere Rust und starte dieses Skript erneut." >&2
  exit 1
fi

for required in Cargo.toml Cargo.lock LICENSE UPSTREAM_COMMIT; do
  if [[ ! -f "$REFERENCE_DIR/$required" ]]; then
    echo "Vendored helper is incomplete: $REFERENCE_DIR/$required" >&2
    exit 1
  fi
done

EXPECTED_HELPER_COMMIT="aff33824af889022eb130db4c01c4c0bbaa8ab89"
if [[ "$(tr -d '[:space:]' < "$REFERENCE_DIR/UPSTREAM_COMMIT")" != "$EXPECTED_HELPER_COMMIT" ]]; then
  echo "Unexpected ch57x-keyboard-tool provenance marker." >&2
  exit 1
fi

if [[ "${AGENT_MICRO_USE_EXISTING_HELPER:-0}" != "1" ]]; then
  echo "Building verified CH57x helper…"
  cargo build --release --manifest-path "$REFERENCE_DIR/Cargo.toml"
  mkdir -p "$(dirname "$HELPER_DESTINATION")"
  cp "$HELPER_SOURCE" "$HELPER_DESTINATION"
  chmod +x "$HELPER_DESTINATION"
elif [[ ! -x "$HELPER_DESTINATION" ]]; then
  echo "AGENT_MICRO_USE_EXISTING_HELPER=1 but helper is missing: $HELPER_DESTINATION" >&2
  exit 1
fi

echo "Building SwiftUI app…"
cd "$ROOT_DIR"
SWIFT_BUILD_ARGUMENTS=()
if [[ -n "${AGENT_MICRO_SWIFT_BUILD_FLAGS:-}" ]]; then
  read -r -a SWIFT_BUILD_ARGUMENTS <<<"$AGENT_MICRO_SWIFT_BUILD_FLAGS"
  swift build "${SWIFT_BUILD_ARGUMENTS[@]}"
  BUILD_BIN_DIR="$(swift build --show-bin-path "${SWIFT_BUILD_ARGUMENTS[@]}")"
else
  swift build
  BUILD_BIN_DIR="$(swift build --show-bin-path)"
fi
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
RESOURCE_BUNDLE="$BUILD_BIN_DIR/AgentMicro_AgentMicro.bundle"
APP_ICON="$ROOT_DIR/Resources/AgentMicroIcon.icns"

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "SwiftPM-Ressourcen fehlen: $RESOURCE_BUNDLE" >&2
  exit 1
fi

if [[ ! -f "$APP_ICON" ]]; then
  echo "App-Symbol fehlt: $APP_ICON" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$APP_ICON" "$APP_RESOURCES/AgentMicroIcon.icns"
cp "$HELPER_DESTINATION" "$APP_RESOURCES/ch57x-keyboard-tool"
cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
# SwiftUI resolves Text("…") against the main bundle, so the English strings
# table has to sit next to the binary and not only inside the SPM resource
# bundle. Fail loudly: silently skipping this ships a German-only app.
if [[ ! -d "$RESOURCE_BUNDLE/en.lproj" ]]; then
  echo "Englische Lokalisierung fehlt: $RESOURCE_BUNDLE/en.lproj" >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE/en.lproj" "$APP_RESOURCES/"
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
  <key>CFBundleDevelopmentRegion</key>
  <string>de</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>de</string>
    <string>en</string>
  </array>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Agent Micro contributors</string>
  <key>CFBundleIconFile</key>
  <string>AgentMicroIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>$DISPLAY_NAME uses Input Monitoring only for legacy CH57x keyboard-HID triggers and the optional passive keyboard diagnostics monitor. Agent Micro firmware uses its direct pad protocol instead.</string>
</dict>
</plist>
PLIST

# TCC permissions are tied to the signing requirement. Never auto-select an
# identity from the keychain: stale Apple Development certificates can appear
# usable in a privileged build shell while GUI/TCC validation rejects their
# chain with CSSMERR_TP_NOT_TRUSTED. Use a stable identity only when the caller
# explicitly supplies one; otherwise produce a valid ad-hoc development build.
SIGNING_IDENTITY="${AGENT_MICRO_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  SIGNING_IDENTITY="-"
  echo "No explicit trusted signing identity supplied; using ad-hoc signing."
else
  echo "Signing with explicitly supplied identity: $SIGNING_IDENTITY"
fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP_RESOURCES/ch57x-keyboard-tool"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"

# A key can still be present while its certificate chain is expired or no
# longer trusted. `security find-identity` has returned such stale identities
# on development Macs, producing an app that launches but is silently rejected
# by TCC's Accessibility/Input Monitoring panes. Verify the finished bundle's
# trust chain and fall back to a locally valid ad-hoc signature instead of
# shipping that poisoned identity. Ad-hoc builds may need their TCC grants
# renewed after the executable changes, but they can be registered at all.
if [[ "$SIGNING_IDENTITY" != "-" ]] \
  && ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
  echo "Selected signing identity is not trusted; falling back to ad-hoc signing."
  /usr/bin/codesign --force --sign - "$APP_RESOURCES/ch57x-keyboard-tool"
  /usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

DESIGNATED_REQUIREMENT="$(/usr/bin/codesign -dr - "$APP_BUNDLE" 2>&1 | sed -n 's/^# designated => //p')"
SIGNING_DETAILS="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
CDHASH="$(sed -n 's/^CDHash=//p' <<<"$SIGNING_DETAILS" | head -n 1)"
SIGNATURE_KIND="$(sed -n 's/^Signature=//p' <<<"$SIGNING_DETAILS" | head -n 1)"
echo "Designated requirement: ${DESIGNATED_REQUIREMENT:-unavailable}"
echo "CDHash: ${CDHASH:-unavailable}"
if [[ "$SIGNATURE_KIND" == "adhoc" || "$DESIGNATED_REQUIREMENT" == *"cdhash"* ]]; then
  echo "WARNING: This build has an ad-hoc/CDHash identity that is not stable across code changes. A code-changing rebuild requires the user to grant Accessibility again; TCC is never reset automatically." >&2
fi

# `dist` is staging only. Never register or launch it: two bundles with the
# same identifier make LaunchServices path resolution ambiguous and can leave
# TCC with a bundle record it cannot resolve. Runtime modes install a verified
# candidate beside the canonical /Applications bundle, then replace it with
# rename operations so no partially copied app can ever be launched.
install_canonical_bundle() {
  local candidate backup
  candidate="$(mktemp -d "$INSTALL_PARENT/.agent-micro-install.XXXXXX")"
  backup="$INSTALL_PARENT/.agent-micro-backup.$$"

  if [[ -e "$backup" ]]; then
    echo "Refusing to overwrite unexpected install backup: $backup" >&2
    /bin/rm -rf "$candidate"
    return 1
  fi

  if ! /usr/bin/ditto "$APP_BUNDLE" "$candidate"; then
    /bin/rm -rf "$candidate"
    echo "Could not stage $DISPLAY_NAME in $INSTALL_PARENT." >&2
    return 1
  fi
  if ! /bin/chmod 755 "$candidate"; then
    /bin/rm -rf "$candidate"
    echo "Could not normalize permissions on the staged bundle." >&2
    return 1
  fi
  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$candidate"; then
    /bin/rm -rf "$candidate"
    echo "Refusing to install an invalid staged bundle." >&2
    return 1
  fi

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  if [[ -e "$INSTALLED_APP_BUNDLE" ]]; then
    if ! /bin/mv "$INSTALLED_APP_BUNDLE" "$backup"; then
      /bin/rm -rf "$candidate"
      echo "Could not move the existing canonical app aside." >&2
      return 1
    fi
  fi

  if ! /bin/mv "$candidate" "$INSTALLED_APP_BUNDLE"; then
    if [[ -e "$backup" ]]; then
      /bin/mv "$backup" "$INSTALLED_APP_BUNDLE" || true
    fi
    /bin/rm -rf "$candidate"
    echo "Could not install the canonical app; the previous bundle was restored when possible." >&2
    return 1
  fi

  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP_BUNDLE"; then
    /bin/rm -rf "$INSTALLED_APP_BUNDLE"
    if [[ -e "$backup" ]]; then
      /bin/mv "$backup" "$INSTALLED_APP_BUNDLE" || true
    fi
    echo "Installed bundle verification failed; the previous bundle was restored when possible." >&2
    return 1
  fi

  /bin/rm -rf "$backup"
  # Clean up any stale registration created by older script versions, then
  # register exactly one canonical bundle for this identifier.
  "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$INSTALLED_APP_BUNDLE"
  echo "$DISPLAY_NAME installed: $INSTALLED_APP_BUNDLE"
}

open_app() {
  /usr/bin/open -n "$INSTALLED_APP_BUNDLE"
}

case "$MODE" in
  run)
    install_canonical_bundle
    open_app
    ;;
  --debug|debug)
    install_canonical_bundle
    lldb -- "$INSTALLED_APP_BINARY"
    ;;
  --logs|logs)
    install_canonical_bundle
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    install_canonical_bundle
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    install_canonical_bundle
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "$DISPLAY_NAME is running: $INSTALLED_APP_BUNDLE"
    ;;
  --package-only|package-only)
    echo "$DISPLAY_NAME staging package ready (not installed or registered): $APP_BUNDLE"
    ;;
esac
