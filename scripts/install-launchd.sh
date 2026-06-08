#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/install-launchd.sh [--no-build] [--skip-sign]

Options:
  --no-build   Skip `swift build -c release`, assume .build/release binaries exist.
  --skip-sign  Skip local codesigning step, assume release binaries are already signed with the helper entitlement.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SKIP_BUILD=0

SKIP_SIGNING=0

for arg in "$@"; do
  case "$arg" in
    --no-build)
      SKIP_BUILD=1
      ;;
    --skip-sign)
      SKIP_SIGNING=1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/release"

HELPER_LABEL="com.starrysky.MFanControlHelper"
APP_LABEL="com.starrysky.MFanControlApp"
RESOURCE_DIR="$PROJECT_ROOT/resources/launchd"
SIGNING_DIR="$PROJECT_ROOT/resources/signing"
HELPER_PLIST_SRC="$RESOURCE_DIR/$HELPER_LABEL.plist"
APP_PLIST_SRC="$RESOURCE_DIR/$APP_LABEL.plist"
APP_LAUNCHER_SRC="$RESOURCE_DIR/MFanControlAppLauncher"
CONTROL_ENTITLEMENTS_SRC="$SIGNING_DIR/MFanControl.entitlements"

HELPER_BIN_SRC="$BUILD_DIR/MFanControlHelper"
APP_BIN_SRC="$BUILD_DIR/MFanControlApp"
CLI_BIN_SRC="$BUILD_DIR/MFanControlCLI"
APP_LAUNCHER_DST="/usr/local/bin/MFanControlAppLauncher"

HELPER_BIN_DST="/Library/PrivilegedHelperTools/MFanControlHelper"
APP_BIN_DST="/usr/local/bin/MFanControlApp"
CLI_BIN_DST="/usr/local/bin/MFanControlCLI"
USR_LOCAL_BIN_DIR="/usr/local/bin"
HELPER_LAUNCHD_DIR="/Library/LaunchDaemons"
HELPER_LAUNCHD_PLIST="$HELPER_LAUNCHD_DIR/$HELPER_LABEL.plist"

SUDO=()
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO=(sudo -S)
fi
_sudo() { ${SUDO[@]+"${SUDO[@]}"} "$@"; }

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  TARGET_USER="$SUDO_USER"
  TARGET_UID="$SUDO_UID"
else
  TARGET_USER="$(id -un)"
  TARGET_UID="$(id -u)"
fi

APP_USER_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' | tail -n 1)"
if [[ -z "$APP_USER_HOME" ]]; then
  APP_USER_HOME="$(eval echo "~$TARGET_USER")"
fi
APP_LAUNCHAGENT_DIR="$APP_USER_HOME/Library/LaunchAgents"
APP_LAUNCHAGENT_PLIST="$APP_LAUNCHAGENT_DIR/$APP_LABEL.plist"

resolve_signing_identity() {
  if [[ -n "${MFANCONTROL_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$MFANCONTROL_CODESIGN_IDENTITY"
    return 0
  fi

  security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '
    BEGIN {
      found = 0
      fallback = ""
    }
    /Developer ID Application:/ {
      print $2
      found = 1
      exit
    }
    /Apple Development:/ && fallback == "" {
      fallback = $2
    }
    END {
      if (found == 0 && fallback != "") {
        print fallback
      }
    }
  '
}

run_as_user() {
  if [[ "${#SUDO[@]}" -ne 0 ]]; then
    _sudo -u "$TARGET_USER" "$@"
  else
    "$@"
  fi
}

sign_binary() {
  if [[ "$SKIP_SIGNING" -eq 1 ]]; then
    return 0
  fi
  local binary="$1"
  local entitlements="${2:-}"
  xattr -cr "$binary" >/dev/null 2>&1 || true
  if [[ -n "$entitlements" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$entitlements" "$binary" >/dev/null
  else
    codesign --force --sign "$SIGNING_IDENTITY" "$binary" >/dev/null
  fi
  codesign --verify --strict --verbose=2 "$binary" >/dev/null
}

SIGNING_IDENTITY=""
if [[ "$SKIP_SIGNING" -eq 0 ]]; then
  SIGNING_IDENTITY="$(resolve_signing_identity)"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No usable code-signing identity found." >&2
    echo "Set MFANCONTROL_CODESIGN_IDENTITY or install a Developer ID / Apple Development certificate." >&2
    exit 1
  fi
fi

if [[ ! -x "$HELPER_BIN_SRC" || ! -x "$APP_BIN_SRC" || ! -x "$CLI_BIN_SRC" ]]; then
  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    echo "Release binary missing. Remove --no-build or run `swift build -c release` first." >&2
    exit 1
  fi
  echo "Building release binaries..."
  (cd "$PROJECT_ROOT" && swift build -c release)
fi

if [[ ! -r "$HELPER_PLIST_SRC" || ! -r "$APP_PLIST_SRC" ]]; then
  echo "launchd plist templates missing, expected in $RESOURCE_DIR" >&2
  exit 1
fi

if [[ "$SKIP_SIGNING" -eq 0 && ! -r "$CONTROL_ENTITLEMENTS_SRC" ]]; then
  echo "Signing entitlements missing, expected at $CONTROL_ENTITLEMENTS_SRC" >&2
  exit 1
fi

echo "Installing helper binary to $HELPER_BIN_DST..."
if [[ "$SKIP_SIGNING" -eq 1 ]]; then
  echo "Skipping local signing step."
else
  echo "Using signing identity: $SIGNING_IDENTITY"
  sign_binary "$HELPER_BIN_SRC" "$CONTROL_ENTITLEMENTS_SRC"
  sign_binary "$APP_BIN_SRC" "$CONTROL_ENTITLEMENTS_SRC"
  sign_binary "$CLI_BIN_SRC" "$CONTROL_ENTITLEMENTS_SRC"
fi

_sudo mkdir -p /Library/PrivilegedHelperTools
_sudo install -m 755 "$HELPER_BIN_SRC" "$HELPER_BIN_DST"

echo "Installing app + cli binaries to /usr/local/bin..."
_sudo mkdir -p "$USR_LOCAL_BIN_DIR"
_sudo cp "$APP_BIN_SRC" "$APP_BIN_DST"
_sudo cp "$CLI_BIN_SRC" "$CLI_BIN_DST"
_sudo cp "$APP_LAUNCHER_SRC" "$APP_LAUNCHER_DST"
_sudo chmod 755 "$APP_BIN_DST" "$CLI_BIN_DST" "$APP_LAUNCHER_DST"

echo "Installing MFanControl.app to /Applications..."
APP_BUNDLE="/Applications/MFanControl.app"
APP_BUNDLE_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BUNDLE_RESOURCES="$APP_BUNDLE/Contents/Resources"
APP_BUNDLE_INFO="$APP_BUNDLE/Contents/Info.plist"
APP_VERSION="$(git -C "$PROJECT_ROOT" describe --tags --always --abbrev=8 2>/dev/null || echo "1.0")"
_sudo rm -rf "$APP_BUNDLE"
_sudo mkdir -p "$APP_BUNDLE_MACOS" "$APP_BUNDLE_RESOURCES"
_sudo cp "$APP_BIN_SRC" "$APP_BUNDLE_MACOS/MFanControlApp"
_sudo chmod 755 "$APP_BUNDLE_MACOS/MFanControlApp"
if [[ -d "$BUILD_DIR/MFanControl_MFanControlApp.bundle" ]]; then
  _sudo cp -R "$BUILD_DIR/MFanControl_MFanControlApp.bundle" "$APP_BUNDLE_RESOURCES/"
fi
_sudo tee "$APP_BUNDLE_INFO" > /dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>MFanControl</string>
  <key>CFBundleExecutable</key><string>MFanControlApp</string>
  <key>CFBundleIdentifier</key><string>com.starrysky.MFanControlApp</string>
  <key>CFBundleName</key><string>MFanControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${APP_VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Installing helper launch daemon..."
_sudo mkdir -p "$HELPER_LAUNCHD_DIR"
_sudo cp "$HELPER_PLIST_SRC" "$HELPER_LAUNCHD_PLIST"
_sudo chown root:wheel "$HELPER_LAUNCHD_PLIST"
_sudo chmod 644 "$HELPER_LAUNCHD_PLIST"

echo "Installing menu bar launch agent..."
_sudo mkdir -p "$APP_LAUNCHAGENT_DIR"
_sudo cp "$APP_PLIST_SRC" "$APP_LAUNCHAGENT_PLIST"

echo "Stopping existing services..."
"$CLI_BIN_DST" force-default >/dev/null 2>&1 || true
run_as_user launchctl bootout gui/"$TARGET_UID" "$APP_LAUNCHAGENT_PLIST" >/dev/null 2>&1 || true
run_as_user pkill -x MFanControlApp >/dev/null 2>&1 || true
_sudo launchctl bootout system "$HELPER_LAUNCHD_PLIST" >/dev/null 2>&1 || true

echo "Loading helper launch daemon..."
_sudo launchctl bootstrap system "$HELPER_LAUNCHD_PLIST"

echo "Loading menu bar launch agent..."
if ! run_as_user launchctl bootstrap gui/"$TARGET_UID" "$APP_LAUNCHAGENT_PLIST"; then
  echo "Menu bar launch agent bootstrap requires interactive user context."
  echo "Please run manually:"
  echo "  launchctl bootstrap gui/$TARGET_UID \"$APP_LAUNCHAGENT_PLIST\""
fi

echo "Restoring default control strategy once to verify service path..."
"$CLI_BIN_DST" status >/dev/null 2>&1 || true

echo "Install complete."
echo "Helper:  launchctl print system/$HELPER_LABEL"
echo "App:     launchctl print gui/$TARGET_UID/$APP_LABEL (if bootstrap was deferred)"
echo "Run `MFANCONTROL_USE_XPC=1 MFANCONTROL_FORCE_PLACEHOLDER_SMC=1 MFanControlCLI status` for smoke check."
