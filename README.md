# MFanControl

Apple Silicon 安全优先热管理项目（骨架版）。

## 当前状态

- 文档决策：`CONTEXT.md`、`docs/adr/*.md`
- 模块骨架：`src/MFanControlApp`, `src/MFanControlHelper`, `src/MFanControlShared`, `src/MFanControlCLI`
- SwiftPM：`Package.swift`
- 本地结构与运行参数：`resources/configs/default-profile.json`

## 快速构建

```bash
swift build
swift test
```

当前代码主要为占位骨架，控制路径与 XPC/SMC 通道尚未接入真实硬件。
