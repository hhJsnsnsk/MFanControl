# MFanControl

Apple Silicon 安全优先热管理项目。

## 当前状态

- 文档决策：`CONTEXT.md`、`docs/adr/*.md`
- 模块：`src/MFanControlApp`, `src/MFanControlHelper`, `src/MFanControlShared`, `src/MFanControlCLI`
- SwiftPM：`Package.swift`
- 本地结构与运行参数：`resources/configs/default-profile.json`
- 传感器：通过 HID event service 读取 Apple Silicon raw 温度传感器；无法可靠分类的私有传感器会以原始名称展示。

## 快速构建

```bash
swift build
swift test
```

当前版本优先保证读数真实性：读不到的分类温度明确显示为 unavailable，不用模拟值代替；无法可靠映射到 CPU/GPU/SoC 的 raw 传感器不会直接用于自动控制。

## 本地部署（launchd 持久化）

```bash
./scripts/install-launchd.sh
```

脚本会执行：

- 构建 release 可执行体（可用 `--no-build` 跳过）
- 安装 `MFanControlHelper` 到 `/Library/PrivilegedHelperTools/MFanControlHelper`
- 安装并启动：
  - `com.starrysky.MFanControlHelper`（LaunchDaemon）
  - `com.starrysky.MFanControlApp`（LaunchAgent，当前用户）
- 安装 CLI/菜单栏入口到 `/usr/local/bin`

验证命令：

```bash
MFANCONTROL_USE_XPC=1 MFANCONTROL_FORCE_PLACEHOLDER_SMC=1 MFanControlCLI status
MFANCONTROL_USE_XPC=1 MFanControlCLI set-mode performance
MFANCONTROL_USE_XPC=1 MFanControlCLI status
```

卸载：

```bash
./scripts/uninstall-launchd.sh
```

如需仅去服务不删二进制：

```bash
./scripts/uninstall-launchd.sh --keep-bins
```
