# MFanControl scripts

- `scripts/install-launchd.sh`：发布用安装脚本（编译并安装 CLI、菜单栏 App 与后台 helper，使用 launchd/LaunchAgent 自动拉起）。
- `scripts/uninstall-launchd.sh`：卸载脚本（卸载服务并清理安装产物）。

推荐执行流程：
1. `./scripts/install-launchd.sh`
2. `MFANCONTROL_USE_XPC=1 MFANCONTROL_FORCE_PLACEHOLDER_SMC=1 MFanControlCLI status`
3. 如需仅测试不写真机风扇，可保留 placeholder 模式后再观察曲线与日志。
4. 卸载：
   - `./scripts/uninstall-launchd.sh`
