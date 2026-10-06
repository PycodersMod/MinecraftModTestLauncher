# MMTL 全 Loader 与 Minecraft 版本兼容实施计划

> 执行方式：由当前主 Agent 按里程碑原生执行；每阶段验证、中文 checkpoint commit，并按任务要求推送。

**Goal:** 对当前 MMTL Loader taxonomy 的每个 Loader，以权威来源确定其精确 Minecraft Target Universe；为所有真实 Available target 建立逐维兼容证据，并在结束时做到 `Unknown=0`、`PendingImplementation=0`。

**Architecture:** 以可复现的官方 metadata 快照作为冻结 Universe，生成 exact-target Ledger。用有来源证据的 Compatibility Family 复用 Detection/Build/Launch/Java/Agent 实现；family 只复用实现，能力与结果仍展开到精确版本。Target runner 分块、有界并行、可续跑并将 source/toolchain/spec hash 绑定到结果。

**Tech Stack:** PowerShell 7、JSON Schema、现有 MMTL Adapter/Provider 模块、Gradle、Java Agent、Pester、GitHub Actions。

**Spec:** 用户提供的 `GOAL TASK — MMTL 全 Loader × 全 Minecraft 版本完整兼容适配` 附件（本轮会话输入；完整约束在该附件中）。

## Global Constraints

- Availability 必须来自每个 Loader 的权威来源；不可用组合是 `NotApplicable`，不能构造 Loader × 所有 Minecraft 版本的笛卡尔积。
- `JarMod` 在 MMTL taxonomy 中属于 Compatibility method，不提供全局 Loader availability；Universe 必须将它显式记录为 `ManualArtifact` strategy，不生成伪造 target pair。JarMod 的 patch/session-copy capability 仍需单独实现和验证。
- Universe 记录 `generatedAt` 与 catalog/source hash 并冻结；后续上游新增项只作为 drift/new-unverified 记录。
- 精确 Target 至少区分 Catalogued、LoaderResolved、ProjectDetection、BuildPlan、BuildJava、RuntimeJava、RuntimeBinding、BuildVerified、LaunchPlan、LaunchCheck、AgentBuild、AgentInjection、Single、IntegratedLAN、Dedicated、LogObservation、EvidenceLevel。
- Compatibility Family 必须有 API、Loader、toolchain、Java、mapping 或 run task 边界证据；未知新版本不得自动继承旧 family。
- 历史 Loader 只有在来源可信、传输安全、构建可审计时才可自动执行；不得自动下载/运行未知 JAR 或仅 HTTP artifact。
- Agent offline auth 与 LAN 仅限 MMTL 管理的本机 Session，绑定 `127.0.0.1` / `::1`；不得改用户原版 JAR 或用户 Mod 源码。
- 不删除 Gradle 全局缓存，不一次启动大量 Gradle；Agent 与 fixture 缓存按 SHA-256 验证。
- 公开 capability、生成文档和 Ledger 必须一致；报告使用路径占位符，避免本机身份、凭据和 hostname。
- 所有 commit 中文；不 force push、不改写历史、不修改 Ruleset、不创建 Release/Tag；本轮不开发 AI 或 GUI。

## Review Focus

1. Mojang `release`、snapshot、pre-release 与 RC 类型混合时保留原 ID 与 source type；新增测试断言不使用普通 SemVer 排序。
2. Loader metadata 变慢、缺字段、错误 JSON 或中途断网时，结果不得被折叠成 `Unavailable`/`NotApplicable`；必须保留 `Unknown` 或带证据的外部阻塞，并支持继续抓取。
3. family 边界附近的 Loader 版本、Minecraft 小版本及未来未知版本不得越界套用 adapter/Agent；测试 first、last、change point 和未知 ID。
4. Java Build/Runtime 要求、旧 Gradle/JDK 与平台差异必须独立记录；缺少本机 JDK 只阻塞环境验证，不得冒充产品 `Unsupported`。
5. 历史安装器/patcher 必须在 Session 私有副本上工作；验证用户 `.minecraft` 原版 JAR 哈希不变、输出隔离、路径/符号链接检查和安全停止。

---

### Task 1：建立官方来源清单与冻结 Compatibility Universe

**Files:**
- Create: `common/schemas/compatibility-universe.schema.json`
- Create: `compatibility/sources.json`
- Create: `compatibility/compatibility-universe.json`
- Create: `tools/Refresh-CompatibilityUniverse.ps1`
- Test: `common/tests/CompatibilityUniverse.Tests.ps1`

**Interfaces:**
- Source provider 输出 `providerId`, `sourceUrl`, `sourceClass`, `trustClass`, `transportSecurity`, `maintenanceState`, `retrievedAt`, `contentHash`, `records`。
- Universe builder 输入 Mojang catalog 与 Loader snapshots，输出按 `targetId` 稳定排序的 schema v1 document。

- [ ] 列出并审核 Mojang、Forge、Fabric、NeoForge、Quilt、LegacyFabric、Ornithe、LiteLoader、Rift、ModLoader、ModLoaderMP 的 availability 来源；保存可核对 URL、抓取时间与 SHA-256。审计 JarMod taxonomy 边界并维护独立 ManualArtifact evidence。
- [ ] 将 Mojang 所有 `release` 与 Loader 官方明确列出的 snapshot/pre/RC ID 按字面值收录。
- [ ] 对每条 Loader/game availability 建立精确 record；来源未能判定时显式保留 `Unknown` 和错误证据，不推测支持范围。
- [ ] 生成 `targetId`, `minecraftId`, `minecraftType`, `minecraftReleaseTime`, `loaderId`, `loaderVersionCandidates`, 来源信任字段、toolchain/Java/Agent 初始要求和 status。
- [ ] 测试：冻结时间/hash、原始 ID、权威来源缺失、重复 ID、未知字段、空来源和 deterministic output。
- [ ] 自审所有 11 个 Loader taxonomy 项和“不纳入”的 server/plugin 项；提交冻结快照 checkpoint。

### Task 2：Full Compatibility Ledger 与 Compatibility Family 模型

**Files:**
- Create: `common/schemas/full-compatibility-ledger.schema.json`
- Create: `compatibility/families.json`
- Create: `compatibility/ledger-template.json`
- Modify: coverage CLI / capability serializer
- Test: `common/tests/FullCompatibilityLedger.Tests.ps1`

**Interfaces:**
- Ledger target 以 Universe `targetId` 为主键，具有独立能力维度、`familyId`、各阶段 evidence ref、`sourceHash`, `toolchainHash`, `targetSpecHash`, `status`。
- Family entry 至少为 `familyId`, `loaderId`, exact `minecraftIds` 或经证据验证的区间、toolchain、build/runtime Java、detection/build/launch strategy、agent bridge 和 evidence。

- [x] 定义 schema 枚举 `Supported`, `PartiallySupported`, `NotApplicable`, `ExternallyBlocked`, `Unsupported`, `Unknown` 及内部 `PendingImplementation`。
- [x] 对每个 Available Target 生成 Ledger entry；对非适用组合记录来源 availability，但不计为 Target。
- [x] 加入动态一致性规则：Available 项缺行、重复 target、未知状态、无法映射 family 或能力不完整均失败。
- [ ] 加入 family first/last/change point 与 future-version 不继承验证。
- [x] 保持 ContractV2、旧 Execution Plan、Session 读取兼容。

### Task 3：Loader Adapter Contract 与 Java/Toolchain 双轨解析

**Files:**
- Create: `common/src/Adapters/ContractV3.psm1`
- Create: 各 Loader family manifest / toolchain registry
- Modify: `common/src/BuildJavaResolver.psm1`, `common/src/Catalog/JavaRuntimeResolver.psm1`
- Test: `common/tests/AdapterV3.Tests.ps1`, `common/tests/CompatibilityJavaMatrix.Tests.ps1`

- [ ] 定义 adapter `detect`, `resolve`, `build`, `launch`, `agent`, `offlineLan`, `dedicated`, `historicalSafety` 能力及向后兼容 shim。
- [ ] 以数据驱动注册 Loader families，不通过 Minecraft 字符串前缀猜测兼容。
- [ ] 建立 per-target Build Java 和 Runtime Java 要求来源；优先 Mojang javaVersion，其余 fallback 必须有 family/source evidence。
- [ ] 分开记录产品支持与当前机器 JDK 可用性；不自动安装/切换系统 Java。
- [ ] 测试旧版本 ID、release/snapshot ID、Java 边界、未知 family 和 ContractV2 migration。

### Task 4：通用 exact-target fixture 与可续跑矩阵 runner

**Files:**
- Create: `common/src/Compatibility/FixtureGenerator.psm1`
- Create: `common/src/Compatibility/TargetRunner.psm1`
- Create: `common/src/Compatibility/EvidenceStore.psm1`
- Create: fixture templates 与 target specs
- Test: `common/tests/CompatibilityFixture.Tests.ps1`, `common/tests/TargetRunner.Tests.ps1`

- [ ] 为每个现代 Target 动态生成最小自有 marker Mod fixture，不复制第三方 Mod，不提交生成项目。
- [ ] 每个 target 隔离 Gradle project/cache/output 与日志；不清理全局 Gradle cache。
- [ ] 以 source、toolchain、target spec、Agent hash 缓存成功证据；hash 不同则重新执行，成功项可续跑。
- [ ] 加入有界并行、每 target timeout、有限重试、分类结果、崩溃恢复和 artifact SHA 记录。
- [ ] 测试中断恢复、损坏缓存、重复/并发 target、超时取消只终止本任务登记进程。

### Task 5：现代 Forge、Fabric、NeoForge、Quilt exact-target adapters

**Files:**
- Modify: `common/src/Adapters/{Forge,Fabric,NeoForge,Quilt}.psm1`
- Create: `common/src/Adapters/Families/<loader>/` family resolvers/build strategy
- Test: 各 Loader/family exact boundary fixture suites

- [ ] 先 Fabric、NeoForge、Quilt，再 Forge 全历史；对 Universe 内所有 Available exact target 提供确定 Detection、BuildPlan、LaunchPlan、Java 和 launch-check 语义。
- [ ] 把 Loom generations、NeoGradle/ModDevGradle、Quilt Loom 和 ForgeGradle generation 划为有证据的 families。
- [ ] 每 target 执行 fixture clean build 或明确可归因的外部 blocker；Loader/plugin、Gradle task 与 artifact resolution 均需记录来源。
- [ ] 精确验证 CurrentStable；不能用单一主版本代表所有 patch target。
- [ ] 对无法下载、缺失 upstream artifact、仅 HTTP、非法/不安全历史工具分别落入可证明状态，内部实现失败必须修复。

### Task 6：Agent Core、Loader/Version Bridge 与协议兼容

**Files:**
- Restructure: `common/agent/src/main/java/...`
- Create: `common/agent/core/` as a pure-Java Gradle subproject
- Create: per-family Loader bridge / version bridge manifests
- Test: Java unit tests, provider artifact/hash tests, PowerShell Agent contract tests

- [ ] 把 session handshake、角色/身份、签名动作、protocolVersion、事件序列化和受控 event sink 拆为尽可能纯 Java Core。
- [ ] 每 family 仅放必要 Minecraft hooks、Loader entrypoint/event registration/mixin bootstrap。
- [ ] Agent build cache key 包含 source hash、Loader、exact Minecraft、loader version、mapping、JDK、toolchain、provider/protocol version。
- [ ] 每个声称 Agent 支持的 exact target 必须通过精确 build/injection contract；禁止模糊版本范围推断。
- [ ] 旧 Agent/protocol 不兼容时显式拒绝；保持 loopback-only 与当前 Session 行为边界。

### Task 7：现代 Loader Agent 与 Live Boundary Matrix

**Files:**
- Create/modify: Forge/Fabric/NeoForge/Quilt bridge sources and manifests
- Modify: Agent provider registry and public capability generator
- Test: family first/last/change point compile and boundary live scripts

- [ ] 逐 Loader、逐 family 实现可行 Agent；逐 exact target 生成并记录 Agent compile evidence。
- [ ] 对每现代 Loader 每个 family 执行 Single boundary live；CurrentStable 必须 Live Single。
- [ ] 每 LAN-capable Agent family 至少一次真实 loopback Host+Guest live；safe-stop、world-join、LAN port release 证据归档。
- [ ] 不使用屏幕坐标；需要 World 自动化时仅通过版本桥公开的确定 API，失败时有 timeout 和证据。
- [ ] Dedicated 仅在预先接受 EULA 的 profile/config/session 执行，否则明确记录跳过。

### Task 8：历史 Loader Detection/Build/Launch/Agent 安全适配

**Files:**
- Modify: 历史 providers/adapters 与 `historical-availability` schemas
- Create: 历史 family specs、独立 patch strategy、Session-copy manager
- Test: 每 Loader historical metadata/fixture/safety suites

- [ ] 对 LegacyFabric、Ornithe、LiteLoader、Rift、ModLoader、ModLoaderMP 逐项收集 exact availability 与 build/run model；JarMod 不作为普通 Loader availability source，须记录 ManualArtifact strategy 及 patch/session-copy 能力证据。
- [ ] 对 LegacyFabric 与 Ornithe 按 Looming/Ploceus/mappings 等真实边界建立 families。
- [ ] 调查 LiteLoader/Rift 历史 Gradle/Maven；对 ModLoader 系列按时代检测 jar/mod-folder/patch 机制；JarMod 必须隔离输入 artifact 与输出副本。
- [ ] 自动执行仅限 HTTPS、可信来源、可审计构建；否则以 source hash 与尝试记录为依据形成真实 `ExternallyBlocked`，不得填空成 `Unsupported`。
- [ ] 评估每个历史 family 的 Agent 可能性，不能仅因年代旧而直接标 Unsupported。
- [ ] 测试原版 JAR/用户项目内容未变、patch 可逆、越界路径/链接拒绝和污染隔离。

### Task 9：全量 CI、drift、缓存与 schema consistency

**Files:**
- Create: `.github/workflows/full-compatibility.yml`
- Create: `tools/Invoke-FullCompatibilityMatrix.ps1`
- Create: result merge / schema and consistency gates
- Modify: required CI workflow for sampled fast contracts
- Test: workflow planning, sharding, merge and drift unit suites

- [ ] 按 Loader/family/target chunk 分片，限制 job 与 Gradle 并行，结果 JSON/脱敏日志可重组并续跑。
- [ ] 提供 `workflow_dispatch` 和低频 schedule；发现新/删除/变更官方 target 时给出 drift 报告，新 target 为 `NewUnverified`。
- [ ] 快速 PR CI 覆盖每 family 边界；全矩阵可手动/周期运行。
- [ ] 禁止上传 Minecraft 原发行文件或无分发许可的第三方 Loader 二进制；可上传 MMTL 自建 Agent 与脱敏证据。
- [ ] CI 比较 frozen Universe、Ledger、Public capability、`docs/compatibility.md` 与 schema 汇总一致。

### Task 10：公开能力文档、回归门禁与最终状态

**Files:**
- Create: `docs/compatibility.md`（由 Ledger 生成）
- Modify: `README.md`, `common/config/public-capabilities.json`
- Create: no-Pycoders regressions, current-stable matrix, end-to-end matrix evidence

- [ ] 以多维符号生成每 Loader 摘要，不使用单一勾号掩盖 Detection/Build/Launch/Agent/LAN 差异。
- [ ] Pester Windows 保持大于基线 465；四平台 CI、Agent Java tests、10 Mod 通用回归、generic fixture、Architecture Boundary、Public Hygiene 全通过。
- [ ] 执行完整 frozen Universe 矩阵；按外部 blocker 定义分类，确保 `Unknown=0`、`PendingImplementation=0`、内部失败为 0 才可报告 `PASS` 或 `PASS_WITH_EXTERNAL_BLOCKERS`。
- [ ] 如存在内部未完项则报告 `PARTIAL`，不创建最终 PR、不合并；提交 checkpoint 与最新 Universe/completed/remaining/current Loader/failure/blocker 记录。
- [ ] 完成后生成本地-only `HANDOVER/MMTL_Full_Loader_And_Version_Compatibility_Report.md` 与 exact target JSON/CSV，使用路径占位符，不上传。
- [ ] 最终 PR 仅在全目标门禁达成后建立；正常合并，若唯 Code Owner 审批阻塞且 CI 全绿，则使用任务已授权的现有 bypass；合并后同步 main、核验 SHA、清理 task worktree/branch；不发布、不打 Tag。

### Task 11：Checkpoint / 持续恢复规则

- [ ] 每完成一个 Loader 或独立安全兼容族，运行其测试、更新 Ledger 与报告，提交中文 checkpoint 并推送同一 task branch。
- [ ] 每次续跑先核验 branch、HEAD、Ledger hash、Universe hash、目标总数/完成/剩余、当前 Loader、失败和外部 blocker。
- [ ] 上游 drift 不重写冻结 Universe；按新 snapshot 单独生成 diff，并经显式 refresh 决策建立下一 Universe。

