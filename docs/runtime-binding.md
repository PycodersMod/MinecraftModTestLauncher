# Runtime Java Binding

Runtime Java Binding 描述 Loader/Gradle 工具链如何为 `runClient` 或 `runServer` 选择最终 JVM。它与 Runtime Java 的版本要求是两项独立信息：知道需要哪个 Java 主版本，并不能证明 MMTL 能控制或确认最终使用的可执行文件。

## Binding 模式

| 模式 | 含义 | Launch 使用条件 |
|---|---|---|
| `Direct` | MMTL 可以明确指定最终 Minecraft JVM，并有可复核的可执行文件证据 | Java 已解析且证据证明可控 |
| `SameAsBuildJvm` | Probe 观察到游戏任务的 launcher 与本次 Gradle Build JVM 一致 | Build/Runtime Java 均解析，且主版本满足 Runtime requirement |
| `ToolchainManaged` | Loader 或插件选择最终 JVM，MMTL 不能承诺独立控制 | 需要提供器支持的进一步运行时解析；否则阻塞 |
| `Unsupported` | 当前适配器明确不支持该绑定能力 | 阻塞 |
| `Unknown` | 证据缺失、过期、项目变脏或观察结果不确定 | 阻塞；不得根据 Java 版本相同推断绑定关系 |

Adapter evidence 包含模式、来源、置信度、控制能力、Build JVM 匹配要求、Probe 策略和原因码。Planner 只消费 evidence，不按 Loader 名称硬编码绑定结果。

## Probe 与证据

`--runtime-binding` 读取当前 Plan 上的绑定结论；`--runtime-binding --probe` 只允许对配置的受信项目或可信 fixture 执行 Gradle configuration/task inspection。Probe 检查 `runClient` / `runServer` 的任务类型与 launcher 来源，不执行这些任务、不启动 Minecraft，也不把设置 `JAVA_HOME` 当作 `Direct` 证据。

Probe evidence 绑定项目 Git SHA、Toolchain、Loader、Minecraft、平台和 Adapter 版本。仅在项目工作树干净且 identity 匹配时复用缓存；项目变脏或 SHA 变化后不沿用旧结论。原始 evidence 可含本机路径，只能保存在本机 Runtime Root。公共文档、测试和 fixture 使用占位路径。

ForgeGradle、Fabric Loom、NeoGradle 与可信 Quilt Loom fixture 的观察方法和结果记录在本机 Phase I–K HANDOVER。Quilt fixture 结果不代表当前十个 Mod 中存在 Quilt 项目。

## Readiness 与验证等级

`BuildReady` 与 `LaunchReady` 分开计算。`SameAsBuildJvm` 只有在 resolved Build Java 满足 Runtime Java requirement 时才可解除 Java binding 阻塞。平台启动能力、项目与 Adapter 解析、Profile、内存、端口策略、必需任务、Runtime Root、Dedicated EULA 和 IntegratedLAN 认证条件仍需单独检查。

`LaunchReady=true` 表示 MMTL 的启动前门禁全部满足；它不等于 `CLIENT_LAUNCH_VERIFIED`。客户端实机等级只能由真实客户端完成规定初始化并取得 marker 后记录。空 Java 进程、Gradle 配置、任务检查和 Plan 均不能升级客户端验证等级。

```powershell
./windows/launcher.ps1 --runtime-binding --json
./windows/launcher.ps1 --runtime-binding --probe --json
./windows/launcher.ps1 --launch-check --json
```
