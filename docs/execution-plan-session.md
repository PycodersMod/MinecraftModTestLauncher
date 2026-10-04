# 执行计划、Launch Readiness 与 Session v2

## 执行计划

`--plan --json` 使用当前 Profile、项目探测结果、平台能力和本地 Java 配置生成版本化 Plan；默认只读 Mojang 现有缓存。它不会联网刷新缓存、运行 Java/Gradle、分配 Auto 端口、创建 Runtime/Session 或修改配置。`--plan-output <路径>` 仅写入明确指定的目标文件。Plan 文件可能包含本机绝对路径，应保存在本地运行目录，不应提交或公开。

```powershell
./windows/launcher.ps1 --plan --json
./windows/launcher.ps1 --plan --plan-output C:/temp/mmtl-plan.json
./windows/launcher.ps1 --explain-java --json
./windows/launcher.ps1 --validate
./windows/launcher.ps1 --dry-run
```

Plan 分别记录 Build Java 与 Minecraft Runtime Java 的 requirement 和本机 candidate。解析只读取 JDK `release` 文件，不调用 `java -version`。没有 Loader 适配器提供的、可审计的 Runtime Java 绑定证据时，binding mode 为 `Unknown`，计划会阻止 Launch；该情形不影响独立 Build gate。Runtime Java 的来源顺序为 Profile 显式 override、Mojang 缓存元数据、带低/中置信度标记的兼容性回退、Unknown。

`semanticDigest` 对规范化后的语义字段计算 SHA-256；排除时间、Plan ID、工作区/JDK/Runtime 绝对路径和本机解析结果。`Test-MmtlExecutionPlan` 同时检查 JSON Schema、摘要和 Java/Session 一致性。Auto 端口只写入计划策略，不在 Plan/dry-run 阶段检查或绑定端口。

## BuildReady 与 LaunchReady

`--validate` 验证 Execution Plan 和 Build Java 门禁；`--launch-check` 执行完整启动前检查，但不运行 `runClient`/`runServer`。输出包括项目、Minecraft、Loader、模式、Build/Runtime Java、binding、内存、端口策略、平台能力和阻塞原因。

Planner 分别计算 `BuildReady`、`LaunchReady`、`LaunchBlockingReasons[]` 与 `LaunchWarnings[]`。启动门禁还会检查项目和 Adapter 解析、必需任务、平台 Launch 能力、Profile、内存、端口策略及 Runtime Root。Dedicated 的 `acceptEula=false` 会阻塞 Launch；MMTL 不替用户接受 EULA。IntegratedLAN 的 Host/Guest 按角色分别记录 readiness；缺少合法认证时 Guest 为 `AUTH_REQUIRED`。

Runtime Java Binding 只能由 Adapter/Probe evidence 决定，详见 [Runtime Java Binding](runtime-binding.md)。`LaunchReady` 表示本机所需启动前检查通过；`CLIENT_LAUNCH_VERIFIED` 则要求真实 Minecraft 客户端完成初始化并取得规定 marker。两者不等价。

## Session Manifest v2

运行阶段创建的 Session 保留现有 `session.json`、`pids.json` 与 `report.md`，并增加：

- `session.v2.json`：Schema v2、生命周期状态、Plan 语义摘要及 Plan 工件 SHA-256。
- `execution-plan.json`：创建 Session 时使用的不可变 Plan 快照。

合法状态转换为 Created → Preparing/Building/Launching → Running → Completed/Failed/Stopped；非法转换会以稳定错误码拒绝。验证能区分旧版 Session、缺失 Plan 工件、工件损坏及摘要不一致。读取旧版 Session 只提供兼容展示，不会自动升级或改写它。停止和清理仍以原有 Session 进程登记与目录安全检查为准，不根据 PID 猜测或终止其他进程。

```powershell
./windows/launcher.ps1 --list-sessions --json
./windows/launcher.ps1 --session-info <Session-ID> --json
./windows/launcher.ps1 --session-validate <Session-ID>
```

Linux/macOS 当前提供 CLI 与 Gradle Build 基础能力；不由 WSL/CI 结果推断 GUI Client、IntegratedLAN 或 Dedicated Server 实机通过。Dedicated Server 仍要求用户本机配置明确接受 EULA；IntegratedLAN 仍要求可用的合法认证会话。

Session 锁、崩溃检测和保守恢复规则见 [Session 生命周期与安全恢复](session-lifecycle.md)。环境诊断与 Java 候选发现见 [Doctor](doctor.md)。
