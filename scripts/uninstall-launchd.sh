#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/uninstall-launchd.sh [--keep-bins]

Options:
  --keep-bins   Remove launchd services only, keep /usr/local/bin binaries.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

KEEP_BINS=0
if [[ "${1:-}" == "--keep-bins" ]]; then
  KEEP_BINS=1
fi

HELPER_LABEL="com.starrysky.MFanControlHelper"
APP_LABEL="com.starrysky.MFanControlApp"

HELPER_BIN="/Library/PrivilegedHelperTools/MFanControlHelper"
HELPER_LAUNCHD_PLIST="/Library/LaunchDaemons/$HELPER_LABEL.plist"
APP_BIN="/usr/local/bin/MFanControlApp"
CLI_BIN="/usr/local/bin/MFanControlCLI"
APP_LAUNCHER="/usr/local/bin/MFanControlAppLauncher"

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
APP_LAUNCHAGENT_PLIST="$APP_USER_HOME/Library/LaunchAgents/$APP_LABEL.plist"

run_as_user() {
  if [[ -n "$SUDO" ]]; then
    "$SUDO" -u "$TARGET_USER" "$@"
  else
    "$@"
  fi
}

echo "Stopping services..."
run_as_user launchctl bootout gui/"$TARGET_UID" "$APP_LAUNCHAGENT_PLIST" >/dev/null 2>&1 || true
$SUDO launchctl bootout system "$HELPER_LAUNCHD_PLIST" >/dev/null 2>&1 || true

echo "Removing launchd plists..."
rm -f "$APP_LAUNCHAGENT_PLIST"
$SUDO rm -f "$HELPER_LAUNCHD_PLIST"

echo "Removing privileged helper binary..."
$SUDO rm -f "$HELPER_BIN"

if [[ "$KEEP_BINS" -eq 0 ]]; then
  echo "Removing user binaries..."
  rm -f "$APP_BIN" "$CLI_BIN" "$APP_LAUNCHER"
fi

for file in "/var/log/mfancontrol-helper.log" "/var/log/mfancontrol-helper.err" "/tmp/mfancontrol-app.log" "/tmp/mfancontrol-app.err"; do
  [[ -f "$file" ]] && $SUDO rm -f "$file" || true
done

echo "Uninstall complete."
