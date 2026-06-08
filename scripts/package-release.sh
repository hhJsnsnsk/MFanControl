#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/package-release.sh [--no-build] [--skip-sign] [--output DIR] [--version LABEL]

Options:
  --no-build   Skip `swift build -c release`, assume release artifacts already exist.
  --skip-sign   Skip local codesigning. Useful for structure-only packaging.
  --output DIR  Write the package root and zip under DIR. Default: ./dist
  --version    Override the release label used in output names.
EOF
}

SKIP_BUILD=0
SKIP_SIGNING=0
OUTPUT_DIR=""
PACKAGE_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --no-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-sign)
      SKIP_SIGNING=1
      shift
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        echo "--output requires a directory" >&2
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --version)
      if [[ $# -lt 2 ]]; then
        echo "--version requires a label" >&2
        exit 1
      fi
      PACKAGE_VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/release"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"

if [[ -z "$PACKAGE_VERSION" ]]; then
  PACKAGE_VERSION="$(git -C "$PROJECT_ROOT" describe --tags --always --dirty --abbrev=12 2>/dev/null || git -C "$PROJECT_ROOT" rev-parse --short=12 HEAD)"
fi
PACKAGE_VERSION="${PACKAGE_VERSION// /-}"
PACKAGE_VERSION="${PACKAGE_VERSION//\//-}"

PACKAGE_ROOT="$OUTPUT_DIR/MFanControl-$PACKAGE_VERSION-macos-arm64"
ARCHIVE_PATH="$OUTPUT_DIR/MFanControl-$PACKAGE_VERSION-macos-arm64.zip"

HELPER_LABEL="com.starrysky.MFanControlHelper"
APP_LABEL="com.starrysky.MFanControlApp"
RESOURCE_DIR="$PROJECT_ROOT/resources"
SIGNING_DIR="$RESOURCE_DIR/signing"
LAUNCHD_DIR="$RESOURCE_DIR/launchd"
CONTROL_ENTITLEMENTS_SRC="$SIGNING_DIR/MFanControl.entitlements"

HELPER_BIN_SRC="$BUILD_DIR/MFanControlHelper"
APP_BIN_SRC="$BUILD_DIR/MFanControlApp"
CLI_BIN_SRC="$BUILD_DIR/MFanControlCLI"
APP_RESOURCE_BUNDLE_SRC="$BUILD_DIR/MFanControl_MFanControlApp.bundle"

PACKAGE_BUILD_DIR="$PACKAGE_ROOT/.build/release"
PACKAGE_RESOURCES_DIR="$PACKAGE_ROOT/resources"
PACKAGE_LAUNCHD_DIR="$PACKAGE_RESOURCES_DIR/launchd"
PACKAGE_SIGNING_DIR="$PACKAGE_RESOURCES_DIR/signing"
PACKAGE_SCRIPTS_DIR="$PACKAGE_ROOT/scripts"
PACKAGE_APP_BUNDLE="$PACKAGE_ROOT/MFanControl.app"
PACKAGE_APP_MACOS_DIR="$PACKAGE_APP_BUNDLE/Contents/MacOS"
PACKAGE_APP_RESOURCES_DIR="$PACKAGE_APP_BUNDLE/Contents/Resources"
PACKAGE_APP_INFO_PLIST="$PACKAGE_APP_BUNDLE/Contents/Info.plist"

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

sign_artifact() {
  if [[ "$SKIP_SIGNING" -eq 1 ]]; then
    return 0
  fi

  local artifact="$1"
  local entitlements="${2:-}"
  xattr -cr "$artifact" >/dev/null 2>&1 || true
  if [[ -n "$entitlements" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$entitlements" "$artifact" >/dev/null
  else
    codesign --force --sign "$SIGNING_IDENTITY" "$artifact" >/dev/null
  fi
  codesign --verify --strict --verbose=2 "$artifact" >/dev/null
}

copy_executable() {
  local src="$1"
  local dst="$2"
  install -m 755 "$src" "$dst"
}

copy_bundle() {
  local src="$1"
  local dst="$2"
  rm -rf "$dst"
  cp -R "$src" "$dst"
}

write_info_plist() {
  local version_label="$1"
  cat > "$PACKAGE_APP_INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleDisplayName</key>
    <string>MFanControl</string>
    <key>CFBundleExecutable</key>
    <string>MFanControlApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.starrysky.MFanControlApp</string>
    <key>CFBundleName</key>
    <string>MFanControl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version_label}</string>
    <key>CFBundleVersion</key>
    <string>${version_label}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
  </dict>
</plist>
EOF
}

stage_release_tree() {
  rm -rf "$PACKAGE_ROOT" "$ARCHIVE_PATH"
  mkdir -p "$PACKAGE_BUILD_DIR" "$PACKAGE_LAUNCHD_DIR" "$PACKAGE_SIGNING_DIR" "$PACKAGE_SCRIPTS_DIR"
  mkdir -p "$PACKAGE_APP_MACOS_DIR" "$PACKAGE_APP_RESOURCES_DIR"

  if [[ ! -x "$HELPER_BIN_SRC" || ! -x "$APP_BIN_SRC" || ! -x "$CLI_BIN_SRC" ]]; then
    if [[ "$SKIP_BUILD" -eq 1 ]]; then
      echo "Release binaries missing. Remove --no-build or run `swift build -c release` first." >&2
      exit 1
    fi
    echo "Building release binaries..."
    (cd "$PROJECT_ROOT" && swift build -c release)
  fi

  if [[ ! -r "$CONTROL_ENTITLEMENTS_SRC" ]]; then
    echo "Signing entitlements missing, expected at $CONTROL_ENTITLEMENTS_SRC" >&2
    exit 1
  fi

  if [[ ! -d "$APP_RESOURCE_BUNDLE_SRC" ]]; then
    echo "App resource bundle missing, expected at $APP_RESOURCE_BUNDLE_SRC" >&2
    exit 1
  fi

  if [[ ! -r "$LAUNCHD_DIR/com.starrysky.MFanControlApp.plist" || ! -r "$LAUNCHD_DIR/com.starrysky.MFanControlHelper.plist" || ! -r "$LAUNCHD_DIR/MFanControlAppLauncher" ]]; then
    echo "launchd resources missing, expected in $LAUNCHD_DIR" >&2
    exit 1
  fi

  copy_executable "$HELPER_BIN_SRC" "$PACKAGE_BUILD_DIR/MFanControlHelper"
  copy_executable "$APP_BIN_SRC" "$PACKAGE_BUILD_DIR/MFanControlApp"
  copy_executable "$CLI_BIN_SRC" "$PACKAGE_BUILD_DIR/MFanControlCLI"
  copy_bundle "$APP_RESOURCE_BUNDLE_SRC" "$PACKAGE_BUILD_DIR/MFanControl_MFanControlApp.bundle"

  cp "$LAUNCHD_DIR/com.starrysky.MFanControlApp.plist" "$PACKAGE_LAUNCHD_DIR/"
  cp "$LAUNCHD_DIR/com.starrysky.MFanControlHelper.plist" "$PACKAGE_LAUNCHD_DIR/"
  install -m 755 "$LAUNCHD_DIR/MFanControlAppLauncher" "$PACKAGE_LAUNCHD_DIR/MFanControlAppLauncher"
  cp "$CONTROL_ENTITLEMENTS_SRC" "$PACKAGE_SIGNING_DIR/"

  cp "$SCRIPT_DIR/install-launchd.sh" "$PACKAGE_SCRIPTS_DIR/install-launchd.sh"
  cp "$SCRIPT_DIR/uninstall-launchd.sh" "$PACKAGE_SCRIPTS_DIR/uninstall-launchd.sh"
  cp "$SCRIPT_DIR/package-release.sh" "$PACKAGE_SCRIPTS_DIR/package-release.sh"
  chmod 755 "$PACKAGE_SCRIPTS_DIR/install-launchd.sh" "$PACKAGE_SCRIPTS_DIR/uninstall-launchd.sh" "$PACKAGE_SCRIPTS_DIR/package-release.sh"

  write_info_plist "$PACKAGE_VERSION"

  if [[ "$SKIP_SIGNING" -eq 0 ]]; then
    SIGNING_IDENTITY="$(resolve_signing_identity)"
    if [[ -z "$SIGNING_IDENTITY" ]]; then
      echo "No usable code-signing identity found." >&2
      echo "Set MFANCONTROL_CODESIGN_IDENTITY or install a Developer ID / Apple Development certificate." >&2
      exit 1
    fi
    echo "Using signing identity: $SIGNING_IDENTITY"
    sign_artifact "$PACKAGE_BUILD_DIR/MFanControlHelper" "$CONTROL_ENTITLEMENTS_SRC"
    sign_artifact "$PACKAGE_BUILD_DIR/MFanControlCLI" "$CONTROL_ENTITLEMENTS_SRC"
    sign_artifact "$PACKAGE_BUILD_DIR/MFanControlApp" "$CONTROL_ENTITLEMENTS_SRC"
  fi

  copy_executable "$PACKAGE_BUILD_DIR/MFanControlApp" "$PACKAGE_APP_MACOS_DIR/MFanControlApp"

  if [[ "$SKIP_SIGNING" -eq 0 ]]; then
    sign_artifact "$PACKAGE_APP_BUNDLE"
  fi

  cat > "$PACKAGE_ROOT/README.txt" <<EOF
MFanControl release package

Version: $PACKAGE_VERSION

Contents:
- MFanControl.app: launch the menu bar app directly
- .build/release: signed binaries used by the install script
- scripts/install-launchd.sh: install launchd services and user binaries

Quick start:
1. Open MFanControl.app, or
2. Run scripts/install-launchd.sh from this package root
EOF

  if [[ "$SKIP_SIGNING" -eq 0 ]]; then
    codesign --verify --strict --verbose=2 "$PACKAGE_APP_BUNDLE" >/dev/null
    codesign --verify --strict --verbose=2 "$PACKAGE_BUILD_DIR/MFanControlApp" >/dev/null
    codesign --verify --strict --verbose=2 "$PACKAGE_BUILD_DIR/MFanControlCLI" >/dev/null
    codesign --verify --strict --verbose=2 "$PACKAGE_BUILD_DIR/MFanControlHelper" >/dev/null
  fi
}

create_archive() {
  ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_ROOT" "$ARCHIVE_PATH"
  shasum -a 256 "$ARCHIVE_PATH" > "$ARCHIVE_PATH.sha256"
}

stage_release_tree
create_archive

echo "Release package staged at: $PACKAGE_ROOT"
echo "Zip archive created at:    $ARCHIVE_PATH"
echo "Checksum written to:       $ARCHIVE_PATH.sha256"
