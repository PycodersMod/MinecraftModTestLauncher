# MMTL Phase F 全覆盖审计实施计划

> **面向智能体执行者：**按任务顺序逐项执行本计划。每项任务先编写测试，最后记录验证结果并创建小型提交。

**目标：**审计从 1.0 到 CurrentStable 的每个 Mojang 正式版本，覆盖主流、历史和手动 Loader 模式；报告有依据的可用性与验证证据，不得声称执行过未运行的构建。

**架构：**保留现有 Provider 模块中的来源事实；新增纯审计层，将事实规范化为逐版本记录和不变量缺口；实时报告保存在 Runtime Root 或 HANDOVER。明确区分 Java 要求和实测构建证据，并通过现有 CLI 提供摘要、缺口及逐版本视图。

**技术栈：**PowerShell 7 模块、Pester 5+、JSON Schema Draft 7、GitHub Actions、Mojang 与 Loader 上游元数据。

**规格：**`.superpowers/sdd/2026-10-02-phase-f-full-coverage-audit/phase-f-user-spec.txt`（仅本地保存的用户附件副本，不纳入 Git）

## 全局约束

- 正式范围为 Mojang Java Edition 从 1.0 到 `CurrentStable` 的版本 ID；数量和最新 ID 必须从实时 manifest 推导，不得写死 103 或 26.3。
- 审计 Loader 包括 Forge、Fabric、NeoForge、Quilt、LegacyFabric、OrnitheLoader、LiteLoader、Rift、ModLoader、ModLoaderMP 和 JarMod 手动模式；Ploceus 仅作为工具链/生态背景信息。
- 不得加入新的主流 Loader 生态，也不得执行 Minecraft GUI、Dedicated Server、账号、安装器、二进制程序、JarMod 补丁、CurseForge、Modrinth 或 Phase G 相关工作。
- Provider 网络故障必须彼此隔离；Unknown 记录必须说明原因。要达到 PASS，无法解释的 Unknown、静默缺失行、矛盾、不安全的信任升级和阻塞级缺口都必须为零。
- 实时全覆盖结果不得进入已提交源码，只能保存在 Runtime Root 或本地 HANDOVER。提交审计引擎、Schema、测试和准确文档。
- 不安装软件包或 Java，不修改用户 Mod 源码，也不得执行历史二进制程序。
- Build Java 要求、实测构建 JVM、编译目标和 Mojang Runtime Java 是相互独立的事实。
- 必需 CI 仍覆盖 Windows、Ubuntu、macOS ARM64 和 macOS Intel，且不得依赖实时上游服务。

## 审查重点

- 一个 Provider 格式错误或超时，不得影响其余十种 Loader 模式或其他版本的记录；测试必须覆盖隔离的部分失败。
- 只接受准确的规范版本 ID：快照版、预发布版和 NeoForge 各时期格式不得被静默映射到其他版本；测试代表性边界与未映射条目。
- 精选历史来源中没有记录时，不得直接报告为确定不支持，除非已证明该上游索引完整；逐个 Provider 测试缺少记录时的语义。
- `Available` 却没有候选项、缺少来源信息或缺少 reason/cache/lastChecked 时，必须产生明确的不变量缺口；逐项测试这些矛盾。
- BuildJava 最低要求、实际运行的 JDK、编译目标和 Runtime Java 绝不能混为一谈；使用更高版本的实测 JDK 和缺失 Runtime 元数据的证据进行测试。

---

### 任务 1：环境纠正与 Java 证据契约

**Files:**
- 修改：`src/Architecture/Contracts.psm1`
- 修改：`schemas/` 下相关的 Java/build evidence schema
- 按需修改：仅当审计需要只读的规范 Runtime Java 投影时，才修改 `src/Catalog/JavaRuntimeResolver.psm1`
- 测试：`tests/Architecture.Tests.ps1` 和新增的 `tests/JavaEvidence.Tests.ps1`
- 仅本地：在 `HANDOVER/MMTL_Phase_E_Historical_Ecosystem_Report.md` 追加纠正说明

**Interfaces:**
- 为兼容性保留现有 `New-MmtlJavaRequirement` 字段；只有现有值可由证据分类时，才添加具有 `Minimum`、`Preferred`、`Exact`、`Unknown` 语义的 `requirementKind`。
- 构建证据定义字段包括 `minecraftId`、`loaderId`、`loaderVersion`、`toolchain`、`platform`、`buildJavaRequirement`、`observedBuildJava`、`compilerTarget`、`result`、`artifactSha256`、`verifiedAt` 和 fixture 溯源信息。

- [x] 记录测试：Gradle 9 最低要求 Java 17 时，可使用实测 JDK 25 和编译目标 8，同时不改写原要求。
- [x] 运行新测试，确认当前模型无法表达该区别或会丢失必需字段。
- [x] 实施最小的向后兼容契约/schema 扩展，并在本地 Phase E 报告中明确纠正 WSL JDK 信息。
- [x] 运行 Java evidence、Architecture、Schema 和历史测试；验证五个 `/opt/java/oracle/jdk-{8,16,17,21,25}` 的 java/javac 绝对路径均未修改且可调用。
- [x] Commit as `feat: 区分 Java 需求与实测构建证据`.

预期验证结果：`Invoke-Pester -Path ./tests/JavaEvidence.Tests.ps1,./tests/Architecture.Tests.ps1,./tests/Schema.Tests.ps1,./tests/HistoricalAdapters.Tests.ps1 -CI` 无失败；每个 WSL Java 二进制均报告预期主版本，且 javac 退出码为 0。

### 任务 2：Provider 覆盖规范化与上游边界

**Files:**
- 根据证据修改：`src/Catalog/LoaderAvailability.psm1`、`src/Catalog/HistoricalAvailability.psm1`、`src/Catalog/Providers/{Forge,Fabric,NeoForge,Quilt,HistoricalProviders}.psm1`
- 测试：现有 Provider 测试，以及新增的 `tests/CoverageProviderMapping.Tests.ps1`
- Fixture：在 `tests/fixtures/coverage/` 下放置小型合成全局索引和候选文档

**Interfaces:**
- 尽可能保留来源专属函数；新增规范化的 Loader/版本状态投影，包含 `availability`、`reasonCode`、`source`、`sourceClass`、`cacheStatus`、`lastChecked`、`notes` 和 `provenance`。
- 候选详情探测仅限于缺失/矛盾案例、最早/最新版本、时期转换、必需历史锚点和 P0 现代版本；完整矩阵由全局元数据驱动。

- [x] 添加精确 ID 映射测试，覆盖 Fabric 稳定版/预发布版、包括 1.20.1 过渡期与 26.x 在内的 NeoForge 命名时期，以及 Quilt 仅表示候选项的语义。
- [x] 添加先失败的测试，覆盖“Ornithe 游戏版本存在但没有 Loader 候选项”、Legacy Fabric provider 故障汇总、LiteLoader 完整性语义、Rift 原版/社区版区分，以及归档无记录语义。
- [x] 实时核对当前官方来源格式和时间戳；Legacy Fabric 与 Ornithe 文档说明 `/v2/versions` 是完整数据库，因此可用时优先发起一次有界的完整索引请求；只固定来源仓库或格式，不固定当前全版本快照。
- [x] 实现明确的历史 provider reason code；将 Legacy Fabric 故障保留为 provider 级缺口，且不把 Ploceus 提升为 OrnitheLoader。静态精选归档中未找到记录时仍标记为 Unknown。
- [x] 运行 provider 映射测试和现有 provider 测试；无法证明穷尽性缺失的来源一律按 Unknown/HISTORICAL_SOURCE_NO_RECORD 记录。
- [x] Commit as `fix: 明确全版本 provider 映射语义`.

预期验证结果：`Invoke-Pester -Path ./tests/CoverageProviderMapping.Tests.ps1,./tests/ForgeProvider.Tests.ps1,./tests/FabricProvider.Tests.ps1,./tests/NeoForgeProvider.Tests.ps1,./tests/QuiltProvider.Tests.ps1,./tests/HistoricalProviders.Tests.ps1 -CI` 无失败，且 fixture 证明版本 ID 精确匹配。

### 任务 3：Coverage Audit 引擎、Schema、指标与不变量缺口

**Files:**
- 新建：`src/Audit/CoverageAudit.psm1`
- 新建：`schemas/coverage-audit.schema.json`
- 仅为集中管理覆盖原因/严重性注册表而修改：`src/Architecture/Contracts.psm1`
- 测试：`tests/CoverageAudit.Tests.ps1`、`tests/CoverageSchema.Tests.ps1`、`tests/CoverageGap.Tests.ps1`

**Interfaces:**
- `New-MmtlCoverageAudit -Catalog <catalog> -RuntimeRoot <path> [-Offline] [-ProviderInputs <testable inputs>]` 返回完整审计对象。
- `Test-MmtlCoverageAudit -Audit <object>` 返回明确的不变量缺口；`Get-MmtlCoverageVersion -Audit <object> -MinecraftId <id>` 返回单个版本记录。
- 顶层契约包括目录溯源/哈希/范围/数量、Provider、规范版本行、摘要指标、缺口、警告和来源信息。每个版本包含四个主流状态、六个历史状态、JarMod 手动模式状态、Runtime Java、验证证据、覆盖状态和说明。
- 缺口严重性为 `Info`、`Warning`、`Error` 或 `Blocker`；原因代码集中管理且保持稳定。

- [x] 编写符合与不符合 schema 的 fixtures，覆盖缺失 reason、非法 status、缺失 provenance 和 null release 行。
- [x] 添加引擎测试，覆盖目录中每个正式版本的生成记录、全部十一种模式、provider 故障隔离、离线部分缓存、汇总计数/区间/缺口，以及不伪造 JarMod 候选项。
- [x] 添加不变量测试，覆盖无法解释的 Unknown、Available 却没有候选项、候选项与状态矛盾、缺失 provenance/检查时间、无效信任级别，以及缺少精确目标的构建证据。
- [x] 针对当前树运行这些测试，观察到预期失败。
- [x] 实现纯规范化与汇总，隔离 provider 异常；实时审计输出保留在源码数据之外。
- [x] 运行 coverage 引擎/schema/gap 测试以及全部现有 provider/Java/历史测试。
- [ ] Commit as `feat: 建立全版本 coverage audit 引擎`.

预期验证结果：`Invoke-Pester -Path ./tests/CoverageAudit.Tests.ps1,./tests/CoverageSchema.Tests.ps1,./tests/CoverageGap.Tests.ps1,./tests/CoverageProviderMapping.Tests.ps1,./tests/Schema.Tests.ps1 -CI` 无失败；生成的测试审计恰好有 `Catalog.entries.Count` 个版本行，且 Loader 模式无缺失。

### 任务 4：验证证据审计与 CLI/帮助一致性

**Files:**
- Modify: `launcher.ps1`
- 如现有 Compatibility Matrix 证据需要规范化，则新建或修改：`src/Audit/ValidationEvidence.psm1`
- 修改：`README.md`、`docs/architecture-v2.md`
- 测试：`tests/CoverageCli.Tests.ps1`、`tests/ValidationEvidence.Tests.ps1`、`tests/DocumentationConsistency.Tests.ps1`

**Interfaces:**
- 使用 `New-MmtlCoverageAudit` 添加 `--coverage-report`（默认摘要；`--json` 输出完整报告）、`--coverage-gaps` 和 `--coverage-version <minecraftId>`。
- 保留现有退出码/JSON 约定。只有在 `--loader-info` 能显示可用性原因和验证证据、且无需重复增加解释命令时，才扩展该选项。
- 正式 CLI 选项尽可能使用同一份经过测试的注册表/来源，供解析器、帮助和文档一致性检查使用；确保帮助中列出 `--provider-status` 和 `--loader-offline`。

- [ ] 添加测试枚举正式 CLI 选项；若已实现的选项未出现在 help 或 README 中，测试应失败。
- [ ] 添加 CLI 测试，覆盖简明摘要、完整 JSON、缺口列表、单版本查询、拒绝未知版本、离线缓存和 provider 部分失败。
- [ ] 为 `CATALOGUED`、`RESOLVED`、`BUILD_VERIFIED`、`SERVER_VERIFIED`、`CLIENT_LAUNCH_VERIFIED` 与 `INTEGRATION_VERIFIED` 添加证据审计测试；构建声明必须要求精确目标和实测 Java 信息。
- [ ] 更新文档，准确标注 A–F 阶段状态并保留平台/游戏验证边界；纠正 Java 要求与 JDK 25 实测构建信息之间的表述。
- [ ] 运行 CLI/evidence/docs 测试和完整 Pester 套件。
- [ ] Commit as `feat: 添加 coverage CLI 与证据审计`.

预期验证结果：`Invoke-Pester -Path ./tests/CoverageCli.Tests.ps1,./tests/ValidationEvidence.Tests.ps1,./tests/DocumentationConsistency.Tests.ps1,./tests/Launcher.Tests.ps1 -CI` 无失败；帮助中包含注册的每个公开选项。

### 任务 5：完整实时审计、锚点/P0 复核、报告与 CI 交付

**Files:**
- 修改：`.github/workflows/test.yml`，用于仅基于 fixture 的测试；只有能分别报告 Provider 健康状况和不变量失败时，才加入可手动触发的实时审计
- 仅在实时发现需要时修改最终文档
- 仅在本地创建：`HANDOVER/MMTL_Phase_F_Full_Coverage_Audit_Report.md`
- 可选：仅在本地追加 Phase E 交接报告纠正说明；不得改写旧 Phase E 提交

- [ ] 在有界超时内实时刷新一次 Mojang 与所有 provider 全局索引；完整审计写入 Runtime Root 或本地 HANDOVER，不进入版本控制。
- [ ] 确认动态目录的最早版本、当前稳定版和正式版本数；将每个版本行与四种主流、六种历史及 JarMod 手动模式记录逐一核对。
- [ ] 在每个 provider 覆盖的最早/最新版本、时期边界、全部必要历史锚点和 P0 版本抽样检查候选一致性；仅在缺口显示矛盾时扩大抽查范围。
- [ ] 复核完整审计的全部不变量；确保无法解释的 Unknown、静默缺失、可用性矛盾、不安全信任升级和阻塞缺口均为零。可解释的上游故障保留为 provider 级警告。
- [ ] 核对完整报告的计数/reason code，确保实时快照和私人路径均未进入 Git diff。
- [ ] 运行完整 Pester（至少达到 147 项基线）、解析器检查、`git diff --check`、隐私/密钥扫描，以及 Ubuntu/macOS fixture 专项测试。
- [ ] 按逻辑提交实现与文档并推送 `main`；检查四个必需 CI 任务，若有失败则修复并重跑。
- [ ] 验证 local HEAD、origin/main 与 GitHub main 一致、工作树干净且 HANDOVER 仅本地保存；完成后移除隔离 worktree/分支。

预期验证结果：生成的完整审计报告准确记录实时 manifest 的版本数量/最早版本/当前稳定版；四个必需 Actions 任务均为 `success`；本地、跟踪分支和 API 返回的 main SHA 相同；`git status --porcelain` 为空。

## 计划自审

- 规格覆盖：任务覆盖第 4–5/19–24 节（环境、Provider 映射、Java）、第 6–18/25–33 节（审计模型、完整覆盖、指标、缺口、Schema）、第 34–44 节（CLI 与文档一致性）、第 45–61 节（清理、实时策略、证据、CI）以及第 64–68 节（PASS 标准和 HANDOVER）。排除的功能列于“全局约束”。
- 接口一致性：引擎接收动态目录和规范化 Provider 输入；CLI 调用引擎；不变量针对其结果运行；实时审计仅写入 Runtime Root/HANDOVER。
- 审查重点对应任务 2–4 中的失败测试。
- 执行方式：由主执行者直接实施，因为共享 Provider 映射和统一审计 Schema 是跨任务接口；修复后进行一次最终独立审查。
