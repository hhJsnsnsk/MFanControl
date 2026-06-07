# PRD: Apple Silicon Smart Thermal Manager

## Problem Statement

当前项目已经有热管理框架雏形，但缺乏一份可落地的需求文档与一致的实施边界。现有 M 系列 Mac 用户希望得到一个“可解释、可恢复、低打扰”的热管理系统，而不是只根据单点温度做开关式风扇控制。现有实现需要把以下关键能力统一定义：

- 自动识别机型与风扇控制能力
- 基于温度/功耗趋势的曲线控制
- 模式化控制（静音、均衡、性能、自定义）
- App 触发联动与安全回退机制
- 崩溃/异常/卸载时可验证的可恢复性
- 同步到菜单栏应用、CLI、特权 helper 的架构闭环

## Solution

把“风扇控制”升级为“热管理系统（Smart Thermal Manager）”：

- 启动后先做硬件能力发现（芯片、机型、风扇数、RPM 范围、可用传感器、默认控制状态）
- 用 **thermal_score** 作为主控变量，结合 CPU/GPU/SoC/SSD/功耗与持续高负载进行平滑决策
- 通过固定的优先级与状态机，始终优先保证安全回退
- 采用曲线而非阈值跳变：限速、滞回、平滑、下发节奏和斜坡限制
- 以可解释数据（控制来源、原因、热压力、事件）解释每次风扇升速
- 在异常链路上自动回退 Apple 默认并写入可审计日志
- 提供 MVP 与优秀版本分阶段交付

## User Stories

1. As an Apple Silicon Mac user, I want the app to auto-detect chip/model/fan capabilities on launch, so I can know whether hardware control is truly available.
2. As a MacBook Air user, I want explicit no-fan messaging, so I’m never shown fake fan controls that do nothing.
3. As a normal user, I want a quiet mode, so I can browse docs and chat with lower noise.
4. As a user doing light coding and editing, I want a balanced default mode, so I get lower temperature drift without obvious fan noise.
5. As a performance user, I want a performance mode, so CPU/GPU tasks stay stable longer before throttling.
6. As an advanced user, I want custom fan curves, so I can define RPM behavior at explicit temperatures.
7. As a long-run compile user, I want early fan intervention, so sustained load does not trigger thermal throttling quickly.
8. As a user running heavy workloads intermittently, I want short temperature spikes to be ignored or dampened, so the laptop stays quiet when load is not sustained.
9. As a user with external displays and power changes, I want control to react to environmental/power context, so cooling strategy stays safe and practical.
10. As a user, I want a clear reason message when fan speed changes, so I can trust the policy is explainable.
11. As a user, I want system default mode restored automatically on sensor fault, so safety is preserved.
12. As a user, I want the service to restore Apple default on app crash/daemon failure, so the system never stays in custom control blindly.
13. As a user, I want fan control to resume after wake with revalidation, so post-sleep behavior is stable and predictable.
14. As an engineer, I want app-trigger performance boost by process list, so compile, docker, and media tools get preemptive cooling.
15. As a user, I want custom white-list apps editable in settings, so I can tune where automatic boosts apply.
16. As a developer, I want to run core decisions from CLI too, so I can automate diagnostics and scripting workflows.
17. As a power user, I want to export and import config packages, so I can keep backups and move profiles across machines.
18. As a user, I want per-device mode and telemetry history, so I can compare thermal behavior over time.
19. As a performance-sensitive user, I want to see whether CPU/GPU has been throttled, so I can evaluate if controls protect or hurt throughput.
20. As a user, I want installation, uninstallation, and permission flow to be explicit, so I know when the helper is active and when it is removed.
21. As a maintainer, I want install-time and runtime safety checks logged with schema and state, so troubleshooting is traceable.
22. As a no-fan user, I want read-only sensor visibility, so I still get thermal awareness without unsafe assumptions.
23. As a reliability-focused user, I want no unsupported defaults to be accepted silently, so invalid sensor or helper states always trigger controlled fallback.
24. As a reviewer, I want auditable modules and minimal privileged surface, so security review is straightforward.
25. As an operator, I want default profile values and retention policy documented and persisted, so system behavior remains stable after updates.
26. As a future maintainer, I want architecture separated by domain boundaries, so new capabilities (ML tuning/remote monitor) can be added without rewriting control logic.

## Implementation Decisions

### 1) Domain modules to build/modify

- `Hardware Discovery`（机型与风扇能力识别）
  - 统一识别 M1~M5、MacBook/Mini/Studio/iMac 类别
  - 输出 fanCount/minRPM/maxRPM/controllable + 可控性诊断
  - 识别 Apple Silicon 与无风扇机型并进入只读路径

- `Sensor Federation`（多源传感器聚合）
  - 聚合 CPU 性能核、效率核、GPU、SoC、SSD、battery、memory（若可读）与功耗
  - 每个通道附带可用性与置信标签（可用/过期/缺失）
  - 生成 2s 采样快照

- `Thermal Pressure Engine`（热压力评分引擎）
  - 输入传感器快照与持续时间，输出 `thermal_score`(0~100)
  - 采用平滑、斜率、持续窗口（12~20s 默认）处理尖峰
  - 评分分段：0-30 安静、31-60 预警、61-80 加速、81-100 安全

- `Control Policy Engine`（策略映射）
  - 以模式（静音/均衡/性能/自定义）与 `thermal_score` 产生目标转速/范围
  - 执行上升/下降曲线、温度滞后、最小斜率变化、单次最大 300 RPM 改变量
  - 支持 App 触发偏置（叠加而非覆盖）

- `State Machine + Priority Orchestrator`
  - 维持 `Idle / Discovering / SmartControl / SafetyFallback / ManualDefault`
  - 决策优先级固定：安全回退 > 手动恢复默认 > 系统触发 > App 触发 > 用户模式
  - 异常后立即进入安全回退，并要求经过 Discovering 后才能重入智能控制

- `Safety & Recovery Layer`
  - 关键异常条件（helper、传感器、权限、温控阈值）进入安全回退
  - 实现“崩溃/唤醒后重检/系统升级后保守模式”恢复路径
  - 默认上限保护：不写入低于硬件安全下限和高于上限的 RPM

- `XPC/Daemon Boundary`
  - 菜单栏 App 与 CLI 仅通过 XPC 与 LaunchDaemon helper 交互
  - helper 负责 probe、采样、执行；App 不直接做硬件写入
  - 暴露命令面：读状态、提交策略、恢复默认、健康上报

- `Persistence & Audit`
  - SQLite 持久化历史（原始与聚合）与事件日志
  - 事件字段：timestamp / level / state / reason / payload
  - 配置支持 schema-version 化导入导出

- `Uninstall/Reset Orchestrator`
  - 固化顺序：先恢复默认 -> 再删 helper/启动项 -> 清理缓存；保留可选导出快照

### 2) Deep modules (high testability)

- `ThermalScoreEngine`（纯函数式评分）：输入 SensorSample 与权重，输出 ThermalScore 与质量元数据。
- `ProfileCurveMapper`（策略映射）：输入 profile + score + appBoost + constraints，输出 ControlCommand。
- `SafetyGate`（闸门）：输入状态/通道健康/异常原因，输出 allow/deny 与 fallback action。
- `LifecycleCoordinator`（生命周期）：处理 sleep/wake、crash、upgrade、manual default、retry。
- `EventNormalizer`（事件归并）：将高频内部波动聚合为可展示、可审计事件。

### 3) Interface / schema decisions

- 用统一共享模型进行 App/Helper/CLI 协议交换：控制状态、传感器、控制命令、策略、导入导出与日志。
- ControlCommand 至少包含 action、targetRPM、minRPM/maxRPM/rampStep、reason。
- 关键配置字段：`profile`、`weights`、`history_retention`、`whiteList`、`safety_thresholds`。
- 保留导入导出向后兼容与字段范围校验，不通过即拒绝。

### 4) Non-Goals for first pass

- 不在首版支持 Intel / 非 Apple Silicon。
- 不引入 GPU 厂商私有 API 或复杂进程签名鉴权。
- 不把未验证的云策略或学习模型作为默认控制核心。

## Testing Decisions

- 以外部行为为主：
  - 能否正确识别控制能力与 no-fan 场景
  - 控制优先级是否按次序生效（安全回退始终先行）
  - thermal_score 稳态变化是否产生平滑升降
  - 告警与状态来源是否可解释且可追溯
  - 崩溃/唤醒/卸载流程是否恢复到 Apple 默认

- 单元测试重点：
  - `ThermalScoreEngine` 的平滑与滞后效果
  - `ProfileCurveMapper` 的目标限幅与斜坡限制
  - `SafetyGate` 的优先级与失败模式判定
  - 配置 schema 的兼容性与边界校验

- 集成测试重点：
  - App/Helper/XPC 命令协议链路与失败回退
  - 关键异常注入（传感器丢失/权限丢失/helper 不可达）下的一键恢复
  - App 触发与基础模式叠加策略

- 历史回归验证：
  - 使用本地环形历史数据检查采样间隔、采样保留策略与告警去抖生效
  - 在高负载模拟下，验证不发生无意义振荡（oscillation）

- 外部参考：
  - 现有测试桩（`tests/unit`, `tests/integration`）扩展为可插桩传感器与可控状态机的测试边界。

## Out of Scope

- macOS 低版本不支持的控制通路兼容增强
- 远程监控服务（高级版本）
- 合盖策略与时间段策略（首轮可保留为路线后置）
- 本地大模型自学习（可在优秀版本后续探索）

## Further Notes

- 本 PRD 以当前仓库已有模块骨架为起点，要求优先补齐可运行闭环而非一次性补齐全部高级能力。
- 交付顺序建议：
  1) 机型识别 + 多传感器 + 温度评分；
  2) 安全优先状态机 + 回退；
  3) 三模式与基础 App-Trigger；
  4) 历史图/降频监测/导入导出。
- 目标命名建议统一对外口径为 **Apple Silicon Smart Thermal Manager**，并在产品说明中明确“不是通用手工风扇遥控器”。
