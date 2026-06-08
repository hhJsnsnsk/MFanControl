# AGENTS

## 目标

将 `MFanControl` 打造成一个面向 Apple Silicon 的安全优先热管理系统：  
- 菜单栏优先交互  
- 后台特权 helper 负责硬件写入  
- 以可解释策略与安全回退为核心  

本仓库的决策词汇与架构约束优先级如下：  
- [CONTEXT.md](./CONTEXT.md)  
- [docs/adr/](./docs/adr/)

## 目录结构（当前版本）

- `src/`
  - `MFanControlApp/`: 菜单栏应用与 CLI 入口（UI/命令行、策略协调、状态聚合）  
  - `MFanControlHelper/`: LaunchDaemon/helper，包含 SMC 与 XPC 服务边界  
  - `MFanControlShared/`: 共享类型与策略、配置、日志 schema  
  - `MFanControlCLI/`: CLI 命令封装（与 App 共用共享层）  
  - `TestSupport/`: 测试桩、mock、fixture（后续补齐）  
- `docs/`
  - `adr/`: 架构与权衡决策（必读）  
  - `architecture/`: 结构图与模块说明（本文件）
- `resources/`: 运行配置、默认策略、导入导出 schema 示例  
- `scripts/`: 构建/签名/发布脚本  
- `tools/`: 本地开发小工具与辅助命令  
- `tests/`: 单元与集成测试（后续补齐）

## 开发边界

- 不允许 UI/CLI 直接写风扇寄存器或 SMC key。  
- 所有硬件读写必须经 `MFanControlHelper` 的受限接口。  
- 异常优先：helper 不可用、传感器关键缺失、链路异常时，必须回退到 Apple 默认控制。  
- 无风扇机型不提供可控模式入口。  

## 交付约束（工程层）

- 阶段优先：先完成 MVP，再逐步推进高级能力。  
- 变更新建文件/目录前先保持路径与 `CONTEXT.md` 的术语一致。  
- 文档优先：涉及策略优先级、控制边界、安全回退的变更必须同步更新 `CONTEXT.md` 或新增 ADR。  

## 常用目录约定

- 运行时配置：`MFanControl/Config`（内部文档暂放 `resources/configs`）  
- 共享模型与协议：`MFanControlShared/Models`  
- 核心策略：`MFanControlApp/Domain`  
- 控制执行：`MFanControlHelper/Daemon` 与 `MFanControlHelper/SMC`

## 构建入口（当前）

- 默认使用 `swift package` 进行阶段性骨架编译：`swift build`、`swift test`。  
- 后续接入 Xcode 工程时，保持 `AGENTS.md` 与`Package.swift` 的模块边界不变，逐步映射到 target。  

## 本地开发安装流程

**正确顺序**（错误顺序会导致旧二进制被部署）：

```bash
# 一键安装（推荐）
sudo ./scripts/dev-install.sh

# 等价的手动步骤：
swift build -c release                                        # 1. 先构建
sudo ./scripts/install-launchd.sh --no-build --skip-sign     # 2. 再安装
```

**关键说明：**
- 必须先 `swift build -c release`，再运行 install 脚本；若直接用 `--no-build` 但没有先 build，会部署旧的 `.build/release` 二进制。
- 本机开发证书链不完整，`codesign` 会报 `errSecInternalComponent`，必须加 `--skip-sign`；正式发布走 `package-release.sh`。
- `xcodebuild` 的产物在 DerivedData，**不是** `.build/release`，不能替代 `swift build`。
- 安装后用 `MFanControlCLI status` 验证新版本是否生效。

## 风险与审计点

- 协议变更要带向后兼容与版本号。  
- 任何控制指令都要记录 state/reason/payload 最小日志字段。  
- 卸载路径必须执行“恢复默认控制”回退动作。  
