# MMTL 可配置离线多客户端实现计划

> **For agentic workers:** 实施时按任务逐项执行；每项使用仓库标准 Pester 入口。保留当前工作树中的全部既有修改。未经单独授权，不执行 commit、push、merge、stash、reset、clean、分支切换或缓存删除。

**目标：** 在现有 MMTL Launcher、Config、ExecutionPlan、Session、Agent 和 Scenario 生命周期上，支持可配置的离线单人及 N 客户端真实 Integrated LAN 测试，并为全 1,631 目标提供显式双窗口验证配置。

**架构：** 将旧配置和命令行输入先规范化为一个不可变的有效场景配置，再由现有规划器、离线身份模块和受管 Session 执行。Integrated LAN 始终由 Host 客户端内的原版 Integrated Server 提供，Guest 顺序启动；现有 Agent 事件、窗口证明、共享世界断言和逐目标验收模块负责生成证据。历史 Dedicated 等价路径独立显式选择，不伪装成原生 LAN。

**技术栈：** PowerShell 7、JSON Schema draft-07、Pester、现有 MMTL Agent Java 模块及 Session JSON/JSONL。

**设计规格：** docs/superpowers/specs/2026-10-17-configurable-offline-multiclient-design.md

## 全局约束

- 默认有效配置为一个 Offline 客户端、Single 场景、Multiplayer=NotRequested。
- 配置优先级固定为 CLI 显式覆盖 > 已选 Profile > 内置安全默认值。
- 不读取、导入、传递或保存 Microsoft/Mojang 凭据、令牌或启动器认证缓存。
- clientCount=N 的 Integrated LAN 计划严格生成 1 个 Host 和 N−1 个 Guest，每个身份、GameDir、PID、日志及报告记录独立。
- Integrated LAN 只允许默认 loopback；Host 必须是真实客户端中的受控世界及 Integrated Server。
- Guest 按序加入并以实际观察到的 Host 端口连接；窗口、进程、端口或模拟事件不能替代游戏断言。
- Hosted Dedicated Server 仅在明确选择 Dedicated 或历史等价流程时启动；历史等价证据标记 HistoricalDedicatedEquivalent。
- Session 停止只能针对已登记且身份复核通过的进程；失败时保留恢复证据。
- 保留 1,631 项完整验收，不以日常单客户端默认值降低 Goal 的双窗口、单人断言、多人共享断言、报告和安全停止要求。
- 2026-10-18 重新核对工作树为 283 个 dirty/untracked 路径；实施中保留既有修改，仅编辑本计划列明的相关文件。
- 所有正式测试通过 .github/scripts/Invoke-MmtlPester.ps1；不直接调用裸 Invoke-Pester。
- 未取得用户授权前不做 Git 历史写入操作。

## 重点审查输入

- Config v1/v2 的 mode 与 players 语义：必须保持原行为，歧义必须在启动前拒绝；由 Task 1 的迁移用例固定。
- clientCount 与 mode/transport 的冲突：不得静默降为单人或擅自启动 Dedicated；由 Task 1、2 的解析用例固定。
- 玩家名称重复、大小写冲突、超长模式、非法占位符：身份计划创建前失败；由 Task 3 固定。
- Host 未开放 LAN、观测端口与请求端口不一致、端口不属于当前 Host：Guest 不得启动；由 Task 4、5 固定。
- Agent 缺失、Host/Guest 中途退出、断言失败或停止不完整：留下失败分类并安全停止已登记进程；由 Task 5、6 固定。

---

### Task 1：Config v3 与旧 Profile 语义迁移

**文件：**
- 修改：common/schemas/launcher-config.schema.json
- 修改：common/config/launcher.config.example.json
- 修改：common/src/Config.psm1
- 修改：common/src/FirstRun.psm1
- 新建：common/tests/Config.Tests.ps1
- 修改：common/tests/Schema.Tests.ps1
- 修改：common/tests/FirstRun.Tests.ps1

**接口：**
- 新增 Resolve-MmtlScenarioProfile -Config <object> -ProfileName <string>，返回规范化 Profile 对象。
- 规范化结果固定含 schemaVersion、sourceConfigVersion、sourceProfileName、mode、clientCount、transport、identity、world、limits 和 provenance。
- v1/v2 只接受原字段并保留原 mode/players 语义；v3 接受 clientCount、identity.kind、multiplayer.transport。
- 新建配置默认 Profile 改为 single-example；已有配置不自动改写。

- [x] 编写 v3 Schema、单客户端默认、显式 N 客户端、Offline-only 身份、transport 枚举和字段冲突的失败用例。
- [x] 编写 v1/v2 Single、IntegratedLAN、Dedicated 迁移用例，验证玩家数保持既有含义。
- [x] 通过仓库标准入口运行 Config、Schema、FirstRun 定向测试，确认新行为先失败。
- [x] 实现 v3 Schema 与 Resolve-MmtlScenarioProfile；歧义旧配置、未知身份类型、无效 transport、非法 clientCount 失败关闭。
- [x] 更新首次运行生成器与示例，使新配置默认 single-example；不重写用户已有配置。
- [x] 通过标准入口运行定向与整仓测试并验证旧 v1/v2 fixtures 保持原语义。

### Task 2：CLI 覆盖解析与最终值来源记录

状态：已实现并通过定向回归（2026-10-18）。Task 1 已完成；Task 2 先运行 CLI RED（4 项接口缺失失败），随后完成解析、配置合并、ExecutionPlan/schema 元数据及 Launcher 前置门禁。使用仓库标准入口运行六个公共测试文件和 Windows CLI 测试：71 passed / 0 failed / 0 skipped。没有运行整仓回归；真实 Minecraft 生命周期尚未实现或验证。

**文件：**
- 修改：common/src/Launcher.ps1
- 修改：common/src/Execution/ExecutionPlan.psm1
- 修改：common/schemas/execution-plan.schema.json
- 修改：common/tests/ExecutionPlan.Tests.ps1
- 新建：common/tests/ScenarioConfiguration.Tests.ps1
- 修改：windows/tests/Launcher.Tests.ps1

**接口：**
- 新增 ConvertFrom-MmtlScenarioCliOverrides -Arguments <string[]>，返回 clientCount、transport、hostName、guestNamePattern、world 的覆盖映射及原始参数来源。
- 新增 Merge-MmtlScenarioConfiguration -Profile <object> -Overrides <object>，返回唯一的有效场景配置。
- 支持 --client-count N、--multiplayer auto|none|integrated-lan|dedicated|historical-dedicated-equivalent、--host-name NAME、--guest-name-pattern PATTERN、--world NAME。
- --client-count N 且未指定 multiplayer 时，N=1 解析为 Single，N>=2 解析为 IntegratedLAN 请求；Dedicated 和历史等价路径必须显式指定。

- [x] 为优先级、重复参数、缺值、未知参数、范围、冲突参数及 Dedicated 显式选择写失败/拒绝用例。
- [x] 通过标准入口运行 CLI/Plan 定向测试，确认参数尚未被支持（RED）。
- [x] 实现参数解析和合并；多客户端 LAN 请求在 Session 创建及进程启动前失败关闭，等待生命周期任务完成。
- [x] 将配置摘要、Profile 原值、CLI 覆盖项、最终 clientCount/transport 与解析来源写入 ExecutionPlan。
- [x] 通过标准入口运行 CLI 与 ExecutionPlan 定向测试；确认默认计划保持单客户端且 Multiplayer=NotRequested。

### Task 3：离线身份与 N 客户端 Session 绑定

状态：实现完成；仓库标准整仓入口 1,060 passed / 0 failed / 3 skipped（157 个文件）。首次整仓运行发现一项 v3 示例夹具仍使用 v2 字段，已迁移到 `clientCount` 与 `multiplayer.transport`，单文件 13/13，之后整仓复跑全绿。未启动 Minecraft。

**文件：**
- 修改：common/src/TestIdentity.psm1
- 修改：common/src/SessionManager.psm1
- 修改：common/src/SessionLifecycle.psm1
- 修改：common/schemas/launcher-config.schema.json
- 修改：common/schemas/execution-plan.schema.json
- 修改：common/tests/TestIdentity.Tests.ps1
- 新建：common/tests/SessionManager.Tests.ps1
- 修改：common/tests/SessionLifecycle.Tests.ps1

**接口：**
- 新增 New-MmtlScenarioIdentityPlan -EffectiveConfig <object> -MinecraftVersion <string>，返回按 ordinal 排序的 Client 实例列表；每项含 role、username、identityId、offlineUuid、instanceId、gameDir、networkRole。
- 身份计划固定一项 Host + clientCount−1 项 Guest；Dedicated 模式的 server process 单独建模，不计入 GUI clientCount。
- 每个实例进程启动后，现有 PID registry 记录必须能通过 identityId/instanceId 关联到唯一身份和 GameDir。

- [x] 写 1/2/N 客户端身份映射、Host/Guest 名称冲突（忽略大小写）、模板校验、UUID 稳定性和 Dedicated 独立 Server 的失败/边界测试。
- [x] 写 Session manifest/PID registry 对身份、GameDir、Runtime Java、PID 一一绑定的测试。
- [x] 通过标准入口运行 TestIdentity、SessionManager（由 TestIdentity 集成覆盖）、SessionLifecycle 和 ProcessManager 定向测试。
- [x] 实现身份计划及 Session manifest 持久化；验证所有路径均位于受管 Session 根内且拒绝 reparse point。
- [x] 确认新身份与进程绑定代码不读取环境、官方启动器目录或认证配置中的在线账号状态。
- [x] 通过标准入口重跑定向测试；验证 Session identity JSON 不含凭据字段，PID 记录与 manifest 身份字段一致。

### Task 4：单人先行与 Integrated LAN 角色生命周期

状态：进行中（2026-10-18 更新）。Task 4 已完成：Single 启动路径在 ClientReady 前核验受管 PID 清单，受影响四组定向 Pester 为 77 passed / 0 failed / 0 skipped。Task 5 已完成：Host LAN_PUBLISHED 与 Guest WORLD_JOINED 绑定世界身份和端口，共享断言校验 Guest 连接端口、Guest world join 端口、Host listener 端口一致；exact Forge/Fabric Agent 构建、事件契约与能力声明门控均已验证。多客户端执行 CLI 仍 fail closed，直到 Task 6 报告和全目标验收链路接通。完整 Windows Pester：1081 passed / 0 failed / 3 skipped。

**文件：**
- 修改：common/src/Scenario/ScenarioOrchestrator.psm1
- 修改：common/src/Launcher.ps1
- 修改：common/src/Agent/AgentActions.psm1
- 修改：common/src/Agent/AgentProvider.psm1
- 修改：common/tests/ScenarioOrchestrator.Tests.ps1
- 修改：common/tests/AgentProvider.Tests.ps1
- 修改：common/tests/AgentLanReadiness.Tests.ps1

**接口：**
- 新增 Resolve-MmtlScenarioMode -EffectiveConfig <object> -TargetCapabilities <object>，只可返回 Single、IntegratedLAN、Dedicated、HistoricalDedicatedEquivalent 或明确 unsupported 状态。
- 更新 New-MmtlScenarioPlan 支持 clientCount，并生成 HostStarting → HostReady → WorldReady → LanPublishing → LanReady → GuestsStarting → GuestsReady → Asserting → Stopping 的可恢复阶段。
- Guest 必须顺序启动；只有前一个 Guest 加入并报告同一 world identity 后才可启动下一个。

- [x] 写单人优先、clientCount=1 无 Guest、clientCount=2 与 N 的角色数，以及 LAN 能力/Host world 或 publish 证据缺失时 fail-closed 测试。
- [x] 写 Host 中断、端口冲突、Guest 中断时状态转移及停止序列测试；覆盖 Guest→Host→Server 安全停止顺序。
- [x] 通过标准入口运行 ScenarioOrchestrator、Agent LAN readiness、AgentProvider 和 Launcher 定向测试（77 passed / 0 failed / 0 skipped）。
- [x] 将有效配置、clientCount 与 Offline identity Guest 模板接入现有 ScenarioOrchestrator；多客户端启动入口在未完成共享断言前保持 fail closed。
- [x] 按 exact Agent manifest 版本 pin 门控 Host Open-to-LAN；通过 LAN_PUBLISHED、真实 loopback TCP 探测与 listener owner PID 属于受管 Host 进程树交叉核验，不使用请求端口或日志单行作为唯一证据。尚无 manifest 的其余精确目标明确 Unsupported。
- [x] 对 Guest 串行执行受控加入并要求匹配 Host world/dimension identity；异常由 Session 的既有安全回收按 Guest→Host 顺序停止。
- [x] 通过标准入口补充运行路径级 Single 进程数断言；Launcher 在标记 ClientReady 前核验 Session PID 清单中的角色/用户名数量与实际返回 PID 一致，Single 恰好一个 Client，额外 Host/Guest/Server 会失败关闭。

### Task 5：离线身份 Agent 事件、端口观测与跨玩家断言

**文件：**
- 修改：common/agent/src/main/java/org/pycodersmod/mmtl/agent/MmtlForgeAgent.java
- 修改：common/agent/src/main/java/org/pycodersmod/mmtl/agent/MmtlForgeClientEvents.java
- 修改：common/src/Agent/AgentEvents.psm1
- 修改：common/src/Observation/LanObserver.psm1
- 修改：common/src/Scenario/SharedWorldAssertion.psm1
- 修改：common/tests/SharedWorldAssertion.Tests.ps1
- 修改：common/tests/LanObserver.Tests.ps1
- 新建：common/agent/src/test/java/org/pycodersmod/mmtl/agent/MmtlForgeAgentTest.java

**接口：**
- Host 事件至少包括带 Session、角色、进程身份和 world identity 的 LAN_PUBLISHED。
- Guest 事件至少包括带相同 world identity 和实际端口的 WORLD_JOINED。
- SharedWorldAssertion 输入必须验证两名不同 Offline 身份、不同 PID、相同受管 world identity、因果一致的跨玩家操作与观察事件。
- Agent 事件不携带账号令牌；内部 nonce 只用于 Session 归属验证。

- [x] 为错误 world identity、重复身份、Guest/Host 端口不一致、跨 Session 事件、重复/伪造 PID 和缺失 action/observer evidence 写失败测试；标准入口 SharedWorldAssertion.Tests 11 项通过。
- [x] 通过仓库标准入口运行 PowerShell Agent、LAN readiness、SharedWorldAssertion 测试及仓库 Gradle Wrapper Agent 测试。
- [x] 实现 Host LAN_PUBLISHED 世界身份、Guest WORLD_JOINED 实际端口及其 schema；保留受管 Session nonce、角色权限、loopback 端点检查。
- [x] 核查五份 exact Agent manifest 的精确目标和能力声明；Forge 1.20.1 声明 IntegratedLAN/受控动作能力，四个 Fabric exact provider 仅声明 Session/事件遥测，不满足共享联机能力门槛；无 manifest 目标仍 Unsupported。
- [x] 按标准入口复测：全仓 Pester 1081 passed / 0 failed / 3 skipped；Forge Agent `test` 和 Fabric 1.21.11 Agent `test` 均 BUILD SUCCESSFUL，二者 stageMmtlAgent 均成功；五份精确 manifest 均由 Get-MmtlAgentProviderStatus 核验为 Supported 且 SHA 匹配。

### Task 6：精确目标报告、验收矩阵与安全停止

**文件：**
- 修改：common/src/Compatibility/ExactGoalAcceptance.psm1
- 修改：common/src/Compatibility/FullCompatibilityLedger.psm1
- 修改：common/src/Compatibility/GoalProgress.psm1
- 修改：common/src/SessionManager.psm1
- 修改：common/schemas/target-validation-evidence-index.schema.json
- 修改：common/tests/ExactGoalAcceptance.Tests.ps1
- 修改：common/tests/FullCompatibilityLedger.Tests.ps1
- 修改：common/tests/GoalProgress.Tests.ps1
- 修改：common/tests/RunManager.Dependency.Tests.ps1

**接口：**
- 每目标报告拆分 SingleAssertion、ClientLaunch、MultiWindow、IntegratedLanPublished、GuestJoined、SharedWorldAssertion、Multiplayer、TargetReport 和 SafeStop。
- clientCount=1 时 Multiplayer=NotRequested，不能计 MultiplayerPass。
- 全目标测试配置显式要求两客户端；现代版本要求 NativeIntegratedLAN 完整证据，历史等价路径要求 HistoricalDedicatedEquivalent 证据。

- [x] 写报告字段、缺失阶段、NotRequested 非通过、历史等价标签、错误 NativeIntegratedLAN 标注及安全停止不完整时拒绝 fullTargetPass 的测试。
- [x] 通过标准入口运行 ExactGoalAcceptance、FullCompatibilityLedger 和 GoalProgress 定向测试，先取得预期 RED。
- [x] 实现各维度独立计数、逐目标维度结果与 JSON/Markdown 报告引用校验；禁止缓存状态作为实测 PASS。
- [x] 复用并验证 Task 1 已实现的 D 盘 Goal JSONL 追加、flush 与去重 API；本 Task 未伪造精确目标尝试事件。
- [x] 通过标准入口重跑定向测试；核验缺失阶段、NotRequested、冲突路径和不完整安全停止保持 PARTIAL 且不进入通过计数。

Task 6 完成记录（2026-10-18）：单客户端 Agent 断言可以独立通过而不依赖双窗口；单客户端联机显示 `NotRequested` 且 Multiplayer PASS 保持为 0。完整 Goal 报告必须显式声明 `clientCount=2`。逐目标维度结果包含 ClientLaunch、SingleAssertion、MultiWindow、IntegratedLanPublished、GuestJoined、SharedWorldAssertion、Multiplayer、TargetReport、SafeStop，并返回 PASS/NotRequested/NotApplicable/Missing/Failed 计数；历史 Dedicated 与 Native Integrated LAN 证据冲突会被拒绝。报告 JSON/Markdown 路径与哈希仍需匹配 evidence index。标准 Pester 定向入口最终结果：65 tests，64 passed / 0 failed / 1 skipped（ExactGoalAcceptance 5、FullCompatibilityLedger 30、GoalProgress 28、RunManager.Dependency 2）。真实逐目标报告文件将在 Task 8 的实机执行时产生，本 Task 仅实现验收字段与引用门禁；没有启动 Minecraft。

### Task 7：历史 Integrated LAN 边界与 Dedicated 等价计划

**文件：**
- 修改：common/src/Scenario/ScenarioOrchestrator.psm1
- 修改：common/src/Compatibility/ExactGoalAcceptance.psm1
- 修改：common/src/Validation/HumanValidationPlan.psm1
- 修改：docs/offline-multiplayer.md
- 修改：docs/execution-plan-session.md
- 修改：common/tests/ScenarioOrchestrator.Tests.ps1
- 修改：common/tests/ExactGoalAcceptance.Tests.ps1
- 修改：common/tests/HumanValidationPlan.Tests.ps1

**接口：**
- 原版 Integrated LAN 不可用的精确目标返回 NativeIntegratedLAN=UnsupportedByMinecraftVersion。
- 只有可信、精确版本匹配的本机历史 Dedicated 路径才能运行，并且产出 HistoricalDedicatedEquivalent。
- HistoricalDedicatedEquivalent 与 NativeIntegratedLAN 作为互斥路径标签保存；历史服务器另有 PID、制品来源/哈希、EULA 状态及安全停止证据。

Task 7 进度（2026-10-18）：Scenario mode resolver 已按目标正式版本标出 1.3.1 之前 `NativeIntegratedLAN=UnsupportedByMinecraftVersion`；历史 Dedicated 等价计划拒绝现代/未知版本，并要求精确 targetId、Minecraft ID、可信目录解析结果及证据摘要。Exact target acceptance 要求历史服务器 PID、process identity、DedicatedServer role、listener port、ready event、明确 EULA authorization reference、EULA hash/时间、停止 PID/释放端口，并要求运行证明的 artifact 元数据逐字段匹配有效 Scenario 配置的解析结果。新增固定 SHA-256 的 Mojang 历史服务端目录、官方元数据快照 schema 与 resolver；目录仅记录 Minecraft 1.2.5 vanilla base server，验证内容寻址 Mojang 元数据 URL、元数据 SHA-1/SHA-256/长度、server URL/SHA-1/长度及本机 JAR SHA-1/SHA-256/长度，自动下载与自动执行均禁止。resolver 将其报告为 `BaseArtifactVerified`，并显式标记 `exactLoaderServerReady=false`；Scenario 忽略调用方伪造的 `VerifiedHistorical` 对象，缺少精确 Loader-ready recipe/artifact 时保持 Unsupported。官方清单未给 1.0.0–1.2.4 提供可用 server entry，且现有 1.2.5 制品是未安装 Loader 的原版基础服务端，因此目前没有历史目标获准进入 Dedicated 等价实机路径。HumanValidationPlan 与两份用户文档已把旧 AUTH_REQUIRED 认证措辞改为本地离线身份/Agent 逐目标就绪门禁；保留旧参数别名以兼容调用方。标准 Pester 入口最终定向回归 37 passed / 0 failed / 0 skipped（HistoricalDedicatedServerCatalog 4、ScenarioOrchestrator 22、ExactGoalAcceptance 6、HumanValidationPlan 5）；另有 1 次 HumanValidationPlan RED 被观察到。没有下载或执行服务器 JAR，没有启动 Minecraft。

- [x] 写历史边界、可信制品缺失、版本/哈希不匹配、禁止隐式下载、等价路径不得升格为 NativeIntegratedLAN 的测试。
- [x] 通过标准入口运行历史 Scenario 和 acceptance 定向测试。
- [x] 实现仅依据代码固定 SHA-256 的官方 Catalog 解析服务端；目录无精确 Loader-ready recipe、文件缺失或哈希不匹配时失败关闭，不临时下载或执行未知依赖。现阶段仅可验证原版基础制品，无法授予任何 Loader 目标 HistoricalDedicatedEquivalent。
- [x] 更新旧文档 AUTH_REQUIRED 的语义，说明本地 Offline 身份/nonce 与在线凭据的区别。
- [x] 通过标准入口复测并检查旧历史证据的标签兼容。

### Task 8：跨平台回归与有限真实冒烟验收

状态更新（2026-10-18）：Job 生成器现为每个精确目标固定 `clientCount=2`、Offline 身份、按 exact capability 明确分流 Native Integrated LAN / Historical Dedicated Equivalent，并列出完整 Goal 维度；整个 Job 集附 SHA-256 内容摘要，Matrix Runner 执行前校验契约与摘要。仓库标准 Pester 定向回归：Windows ValidationMatrixJobs 8/8、FullCompatibilityMatrixRunner 7/7；WSL Ubuntu 24.04 的 Linux PowerShell/Pester 回归：ValidationMatrixJobs 7 passed / 1 Windows-junction skip、FullCompatibilityMatrixRunner 7/7、ScenarioConfiguration.Linux 2/2。WSL 使用的是本机 Windows 用户目录中的 Pester 6.2 模块路径（仅对子进程临时加入），不是 Linux 包安装；这不是 GitHub CI 结果。另已按 Frozen Universe/Ledger/Family 生成 D 盘规划清单 `[LOCAL_PATH_REDACTED] 个唯一目标、72 个 Family 内批次（最多 30 项；小 Family 批次可少于 20 项），双离线客户端契约与每批/总清单 SHA-256 均通过交叉校验；清单明确为 `PLANNING_ONLY`，不包含已验证 Recipe，也不代表可执行或兼容通过。资源测量已保存，但游戏测试槽位仍被用户启动的 Minecraft 占用；未启动 MMTL 游戏。跨平台 CI、Family 实机冒烟及实际可执行 1,631 目标批次仍未完成，因此本 Task 与 Goal 仍为 PARTIAL。

追加 Recipe 覆盖审计（只读）：对 Frozen Universe 的 1,631 个目标调用 `CompatibilityRecipeResolver`，结果为 32 个 `RecipeReady`、1,599 个 `InternalPending/EXACT_RECIPE_NOT_IMPLEMENTED`、0 个 ValidationError。32 个 Ready Recipe 已生成 D 盘可复核快照 `[LOCAL_PATH_REDACTED] 10 个同 Family 不可变批次（最大 12 项）及全部 1,599 个 Pending 目标；每个 Snapshot 和当前 Recipe 输入逐批验证通过，整体状态为 `PREPARED_NOT_EXECUTED`。此清单仅表示 Build batch preflight 已准备，不等于可信 BuildVerified，也尚未执行 Build。Recipe 审计明细见 `[LOCAL_PATH_REDACTED] Build 执行和双窗口测试保持未完成。

追加回归（2026-10-18）：Windows 仓库标准入口 `.github/scripts/Invoke-MmtlPester.ps1` 全量执行 158 个文件，最终 1090 passed / 0 failed / 3 skipped，Pester 报告耗时 1628.9s；完整日志位于 `[LOCAL_PATH_REDACTED] `7656CE1EE3559903D6806EDB1B869B9BC9E957AA957E5123A49929C1BB1A7FE5`。此前首轮发现唯一失败为 `TargetIdentity.Tests.ps1` fixture 漏掉当前 Jobs Manifest 必需的 `jobsHash` 和场景契约；只修正该测试 fixture，并确保导入顺序不会被依赖模块的 `Import-Module -Force` 覆盖。定向 Windows 回归 4/4；WSL Ubuntu 24.04 通过相同标准入口对该文件执行 4/4，日志 `[LOCAL_PATH_REDACTED] `58A3D2520D5013B2F9CA156C43EC7D909CC6F42875E193DF19E33C69CB817054`。该 Linux 结果是 WSL 本地回归，不是 GitHub CI；macOS CI 仍未运行。实时重查发现用户 Minecraft PID 57188 仍在运行（约 5.42 GiB working set），因此没有启动 MMTL GUI 或新 Java 子进程。全 Goal 计数仍为 58 attempts、Build=20、RuntimeBinding=5、ClientLaunch/MultiWindow/Multiplayer/Reports/FullTargets 均为 0。

**文件：**
- 新建：linux/tests/ScenarioConfiguration.Linux.Tests.ps1
- 新建：macos/tests/ScenarioConfiguration.MacOS.Tests.ps1
- 修改：windows/tests/Launcher.Tests.ps1
- 修改：docs/superpowers/plans/2026-10-07-full-loader-version-compatibility.md
- 生成：D 盘 Goal run 下的批次 JSONL、每目标 JSON/Markdown 和运行摘要

- [x] 为 Windows/Linux/macOS 的参数透传、Config 版本解析、默认单窗口及 Session PID 映射补齐平台测试；Unix shell 与 PowerShell argument splat、CLI override 和默认离线单客户端均有覆盖，PID/身份/GameDir/Runtime Java 绑定由共同 SessionLifecycle 测试覆盖。
- [ ] 通过各平台 CI 的标准入口验证；不可把单平台单测声称为跨平台通过。
- [x] 测量当前 CPU、RAM、GPU、磁盘 IO、端口及单实例资源，再设定游戏测试并发；测试槽位上限为 1，当前无可用槽位。
- [ ] 先按 Family 执行受控单窗口 Single 测试；经单项证据通过后再执行双窗口 LAN 冒烟，并验证实际端口、两 PID、两个 GUI、共享断言、完整报告和安全停止。
- [ ] 对 1,631 个精确目标显式生成 clientCount=2 的不可变批次；继续按约 20–40 项批量执行，逐项事件 flush、失败最多自动重试两次、聚类修复并复测受影响目标。
- [ ] 通过已有 Goal Progress/Acceptance 入口核对六项维度唯一通过数量；最终仅在全部目标完整通过时标 PASS，否则 PARTIAL。
- [ ] 保留已有 dirty/untracked 文件；在用户另行授权前不创建提交或推送。

## 依赖顺序

Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6。Task 7 与 Task 6 的历史证据路径并行但必须在最终验收前完成。Task 8 依赖 Task 1–7 的接口冻结；真实 Family 冒烟结果必须回写到精确目标证据。

## 完成定义

实现计划获用户审阅后，按原 Goal 逐项执行；本计划完成不等于产品能力或任何精确目标已通过。只有冻结 Universe 的 1,631 个目标均具有精确 Build/RuntimeBinding、两个真实客户端窗口、单人断言、多人共享断言、适用的 Agent/Dedicated 证据、独立报告及安全停止证据，才可宣布完整 Goal PASS。
