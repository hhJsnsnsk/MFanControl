# MFanControl scripts

- `scripts/install-launchd.sh`：发布用安装脚本（编译并安装 CLI、菜单栏 App 与后台 helper，使用 launchd/LaunchAgent 自动拉起）。
- `scripts/package-release.sh`：发布打包脚本（生成可直接分发的 `MFanControl.app`、`.build/release` 和 zip 归档）。
- `resources/signing/MFanControl.entitlements`：helper 与本地控制二进制使用的 IOKit temporary exception 签名例外。
- `scripts/uninstall-launchd.sh`：卸载脚本（卸载服务并清理安装产物）。

推荐执行流程：
1. `./scripts/install-launchd.sh`
2. `MFANCONTROL_USE_XPC=1 MFANCONTROL_FORCE_PLACEHOLDER_SMC=1 MFanControlCLI status`
3. 如需仅测试不写真机风扇，可保留 placeholder 模式后再观察曲线与日志。
4. 打包发布：
   - `./scripts/package-release.sh`
5. 卸载：
   - `./scripts/uninstall-launchd.sh`
