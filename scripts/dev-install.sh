#!/usr/bin/env bash
# dev-install.sh — 本地开发快速安装脚本
#
# 使用方式：
#   ./scripts/dev-install.sh
#
# 执行顺序：
#   1. swift build -c release        构建 release 二进制
#   2. install-launchd.sh --no-build --skip-sign  复制并重启服务（跳过签名，本机开发用）
#
# 注意：需要 sudo 权限（安装到 /Library/PrivilegedHelperTools 和 /usr/local/bin）
# 本机开发证书链不完整时 codesign 会失败，所以跳过签名；正式发布走 package-release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Building release binaries..."
(cd "$PROJECT_ROOT" && swift build -c release)

echo "==> Installing (no-build, skip-sign)..."
"$SCRIPT_DIR/install-launchd.sh" --no-build --skip-sign
