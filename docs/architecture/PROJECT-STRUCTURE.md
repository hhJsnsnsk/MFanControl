# MFanControl 项目结构（v1）

## 模块总览

```text
MFanControl
├── AGENTS.md                     // 团队协作与开发约束
├── CONTEXT.md                    // 术语与领域边界（权威）
├── docs/
│   ├── adr/                      // 决策记录（架构/风险）
│   └── architecture/             // 本文件与架构图说明
├── resources/
│   ├── configs/                  // 默认 profile、阈值、导入导出 schema
│   └── assets/
├── scripts/                      // 构建/签名/发布脚本
├── tools/                        // 开发辅助工具
├── tests/
│   ├── unit/
│   └── integration/
├── src/
│   ├── MFanControlApp/           // SwiftUI 菜单栏 App 与状态管理
│   │   ├── Application/
│   │   ├── Domain/
│   │   ├── Infrastructure/
│   │   ├── Presentation/
│   │   └── Resources/
│   ├── MFanControlCLI/           // CLI 代理与命令定义
│   │   └── Sources/
│   ├── MFanControlHelper/        // LaunchDaemon/helper（核心执行层）
│   │   ├── Daemon/
│   │   ├── IPC/
│   │   ├── SMC/
│   │   ├── SMCKeys/
│   │   └── Resources/
│   ├── MFanControlShared/         // 所有模块共享类型与协议
│   │   ├── Domain/
│   │   ├── Models/
│   │   ├── Persistence/
│   │   └── Telemetry/
│   └── TestSupport/              // 测试桩与 mock
│       ├── Fixtures/
│       ├── Stubs/
│       └── Drivers/
```

## 分层职责（第一版）

- `MFanControlApp`  
  - 负责菜单栏 UI、模式切换、配置入口、策略决策状态可视化。  
  - 不直接操作硬件。  

- `MFanControlHelper`  
  - 负责 `helper` 生命周期、XPC 通信端点、传感器采样、风扇执行、崩溃兜底回退。  

- `MFanControlShared`  
  - 统一 `thermal_score` 输入/输出模型、控制协议、日志 event schema、导入导出 schema。  

- `MFanControlCLI`  
  - 使用只读/受控命令与 helper 通道对齐 App 行为，不绕开安全边界。  

## 与 ADR 的关系

- 安全优先、恢复机制、MVP 范围、栈选择均已在 `docs/adr/` 对应记录。  
- 后续新增能力前优先确认 `CONTEXT.md` 与 ADR 的术语一致性。  
