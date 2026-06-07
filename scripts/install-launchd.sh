#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/install-launchd.sh [--no-build]

Options:
  --no-build   Skip `swift build -c release`, assume .build/release binaries exist.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SKIP_BUILD=0
if [[ "${1:-}" == "--no-build" ]]; then
  SKIP_BUILD=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/release"

HELPER_LABEL="com.starrysky.MFanControlHelper"
APP_LABEL="com.starrysky.MFanControlApp"
RESOURCE_DIR="$PROJECT_ROOT/resources/launchd"
HELPER_PLIST_SRC="$RESOURCE_DIR/$HELPER_LABEL.plist"
APP_PLIST_SRC="$RESOURCE_DIR/$APP_LABEL.plist"
APP_LAUNCHER_SRC="$RESOURCE_DIR/MFanControlAppLauncher"

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

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

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

run_as_user() {
  if [[ -n "$SUDO" ]]; then
    "$SUDO" -u "$TARGET_USER" "$@"
  else
    "$@"
  fi
}

sign_binary() {
  local binary="$1"
  $SUDO xattr -cr "$binary" >/dev/null 2>&1 || true
  $SUDO codesign --force --sign - "$binary" >/dev/null
}

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

echo "Installing helper binary to $HELPER_BIN_DST..."
$SUDO mkdir -p /Library/PrivilegedHelperTools
$SUDO install -m 755 "$HELPER_BIN_SRC" "$HELPER_BIN_DST"

echo "Installing app + cli binaries to /usr/local/bin..."
$SUDO mkdir -p "$USR_LOCAL_BIN_DIR"
$SUDO cp "$APP_BIN_SRC" "$APP_BIN_DST"
$SUDO cp "$CLI_BIN_SRC" "$CLI_BIN_DST"
$SUDO cp "$APP_LAUNCHER_SRC" "$APP_LAUNCHER_DST"
$SUDO chmod 755 "$APP_BIN_DST" "$CLI_BIN_DST" "$APP_LAUNCHER_DST"

echo "Signing installed binaries..."
sign_binary "$HELPER_BIN_DST"
sign_binary "$APP_BIN_DST"
sign_binary "$CLI_BIN_DST"

echo "Installing helper launch daemon..."
$SUDO mkdir -p "$HELPER_LAUNCHD_DIR"
$SUDO cp "$HELPER_PLIST_SRC" "$HELPER_LAUNCHD_PLIST"
$SUDO chown root:wheel "$HELPER_LAUNCHD_PLIST"
$SUDO chmod 644 "$HELPER_LAUNCHD_PLIST"

echo "Installing menu bar launch agent..."
$SUDO mkdir -p "$APP_LAUNCHAGENT_DIR"
$SUDO cp "$APP_PLIST_SRC" "$APP_LAUNCHAGENT_PLIST"

echo "Stopping existing services..."
run_as_user launchctl bootout gui/"$TARGET_UID" "$APP_LAUNCHAGENT_PLIST" >/dev/null 2>&1 || true
run_as_user pkill -x MFanControlApp >/dev/null 2>&1 || true
$SUDO launchctl bootout system "$HELPER_LAUNCHD_PLIST" >/dev/null 2>&1 || true

echo "Loading helper launch daemon..."
$SUDO launchctl bootstrap system "$HELPER_LAUNCHD_PLIST"

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
