# MMTL v2 架构基础

本文记录 MMTL v2 Phase A–F 的落地边界。Catalog、上游 Loader availability、项目解析、实际构建、服务端和客户端验证是不同状态；查询结果不能替代 Compatibility Matrix 的实验证据。

严格平台目录、provider 注入与依赖规则见[平台架构说明](platform-architecture.md)。

## 平台身份与验证来源

产品平台身份只有 `Windows`、`Linux`、`MacOS`（用户界面显示为 macOS）；CPU 架构单独建模。Ubuntu 归属 Linux 发行版元数据，WSL/WSL2 归属 Linux 环境元数据，GitHub Actions 仅作为验证来源。Linux CLI/build 基础能力不代表 Ubuntu Desktop、Dedicated Server 或 GUI Client 已验证；macOS runner 上的 fixture/build 证据也只适用于报告中的精确 OS、架构和 target。

## 当前实现与后续计划

### Phase A 已实现

- `common/src/Architecture/Contracts.psm1` 集中定义 OS、架构、能力、验证等级、Artifact Trust、provenance、Loader、Toolchain 和 Build System identities。
- `PlatformContext`、`LoaderStack`、`BuildJava`/`RuntimeJava` requirement、Toolchain context、Build System context 和 provenance 使用纯数据结构表达。
- Compatibility Matrix v1、Exception Registry 和 Config v2 基础结构由 JSON Schema 描述；旧配置读取器保留旧格式与未知字段。
- CI 在 Ubuntu/macOS 上运行 PowerShell parser 和跨平台纯 fixture 测试；Windows job 运行完整 Pester suite。

### Phase B 已实现

- Windows/Linux/macOS 平台 Provider、各平台 Runtime Root 与路径安全、Java/Gradle Wrapper 选择和各平台 CLI 入口已落地。
- Session 平台元数据、Linux `/proc` 进程身份与受控停止均有实现和 fixture 覆盖。Linux/macOS CLI 与 Gradle build 能力不等价于这些平台上的 Minecraft GUI 实机运行。

### Phase C 已实现

- src/Catalog/MinecraftVersionCatalog.psm1 从 Mojang Version Manifest v2 建立 release Catalog，以字符串 canonical ID 和 releaseTime 确定从 1.0 到 manifest.latest.release 的范围，不做 SemVer 解析或排序。
- Catalog cache 分开保存原始 manifest、规范化 catalog 与校验 metadata；使用临时文件和原子替换，记录本地 manifest SHA-256。实测 Mojang 端点提供 ETag 与 Last-Modified；Windows live conditional refresh 收到 304，并保留原始 fetchedAt、更新 validatedAt。
- Version metadata 按查询惰性拉取，按 manifest SHA-1 校验并拒绝 mismatch；version metadata cache key 使用 canonical ID 与期望 SHA-1。
- src/Catalog/JavaRuntimeResolver.psm1 以显式 Runtime override、Mojang javaVersion、带官方来源的 MMTL fallback、Unknown 为优先级；它不修改现有 Build Java 选择。
- Catalog cache 默认 TTL 为 24 小时。--catalog-offline 不访问网络；stale 在线刷新失败会显式返回 Stale；--refresh-catalog 失败不会报告成功。
- CATALOGUED 仅表示 Mojang manifest 记录了一个 release，不能推导 Loader、构建、服务端或客户端验证通过。

### 阶段 G — 深度验证矩阵（已完成）

- Phase G 在独立 schema 中记录精确 target identity 和每次 run 的不可变 evidence。Resolve、build、server、client、integration 是不同等级；没有专属 marker、进程身份与 stop/port 证据时，不接受高等级声明。
- Tier 0 保持全 catalog/availability metadata-only；Tier 1 是本机真实 Mod portfolio；Tier 2/3 采用固定 commit 和许可证来源的代表性官方 fixture，不构造全 Cartesian 矩阵。
- 深度 Gradle builds 位于手动/半月 workflow，不增加到每 PR required CI。覆盖审计数据与验证证据仍然是独立事实。
- 当前分支已实现证据契约、fixture pin/trust/task 检查、超时受控的 Gradle build runner、产物哈希、日志脱敏、不可变 run 存储和矩阵聚合。客户端/服务端/跨平台实机验证仍须以实际 marker 和每 target 报告为准；实现存在不代表 target 已通过。
- 本仓库当前 Linux/macOS 目标仍是 CLI、构建基础与 CI fixtures，不把 WSL/WSLg 当作完整 Linux Desktop 实机验证。

### 阶段 D：Loader 元数据与 Adapter Contract v2

- Forge、Fabric、NeoForge 和 Quilt provider 共用 `common/src/Catalog/LoaderMetadata.psm1` 的 allowlist HTTPS、重定向校验、ETag/Last-Modified、24 小时缓存、stale/offline 状态与原子写入。provider 各自拥有独立 cache key，单一端点失败不会阻断其它 provider。
- `common/src/Catalog/LoaderAvailability.psm1` 生成宽度动态跟随 Mojang Catalog 的 availability index；availability 限定为 `Available`、`Unavailable`、`Unknown`，schema 位于 `common/schemas/loader-availability.schema.json`。该索引不存储 Loader 安装内容，也不表示 build 已验证。
- Forge 保留 Maven 完整版本和 promotions 中独立的 `recommended` / `latest`；Fabric 保留官方 `stable` 与 intermediary 数据，并依上游顺序选 stable；NeoForge 分开处理 `net.neoforged:neoforge` 与 1.20.1 过渡 artifact `net.neoforged:forge`；26.x scheme 保留完整 Minecraft 前缀；Quilt Meta v3 原样保留 hashed、intermediary、quilt-mappings 与 launcherMeta，不推造 stable 语义。
- `common/src/Adapters/ContractV2.psm1` 表达 Adapter probe evidence、解析冲突和 build plan；`ProjectDetector.psm1` 从 mod metadata 与 Gradle 插件 marker 归并 evidence。Quilt 的 `fabric.mod.json` 是兼容 metadata，识别 Quilt 以 Quilt Loom 插件 evidence 为准；多 Loader marker 返回 `Ambiguous`。
- Toolchain identity 与 Loader identity 分开；`QuiltLoom` 已加入 toolchain registry。Build Java 项目显式要求的 major 是 High confidence；缺失时由 `BuildJavaResolver.psm1` 集中 fallback registry 推断并标记 Low confidence。Runtime Java 仍由 Mojang metadata resolver 负责。
- CLI 的 `--list-loaders` 显示版本 availability，`--loader-info` 返回候选、preferred policy 和 provenance；`--loader-offline` 独立于 Gradle offline。结果可从 Runtime Root 的 Provider cache 离线重建。
- PR CI 使用 metadata/adapter fixture，不依赖 live endpoint；Windows 执行全 suite，Ubuntu、macOS ARM64 和 Intel 增加 Provider、index、Adapter 与 ProjectDetector fixture suite。

### 阶段 E 已实现 — 历史生态提供器

Legacy Fabric、Ornithe Loader、LiteLoader、Rift、ModLoader、ModLoaderMP 与 JarMod Manual Mode 均保留独立 Loader/source/trust/provenance 语义；不可用上游与历史目录缺项不能推导为已验证不兼容。

## 概念分层

```text
Minecraft release identity
  └─ LoaderStack: primaryLoader + overlayLoaders[]
       └─ Toolchain context (例如 FabricLoom 或 Ploceus + Ornithe ecosystem)
            └─ Build System (例如 GradleWrapper)
                 ├─ BuildJava requirement
                 └─ RuntimeJava requirement

Target: OS + architecture + capability
Evidence: validation level/result + provenance + lastVerified
```

Loader Provider 的上游候选发现与 Compatibility Matrix 中 MMTL 的验证证据是两个独立事实。Provider 返回版本不能自动提升 `validation.level`。Capability 描述目标能做什么；Validation Level 描述 MMTL 取得了什么证据。

## 平台身份

当前 identity registry 接受 `Windows`、`Linux`、`MacOS` 与 `x64`、`ARM64`。`Get-MmtlPlatformContext` 从入口注入的 provider 读取 OS、架构、WSL 标志和当前 shell；common 不自行探测操作系统或加载系统实现。它不安装运行时、不启动 Minecraft，也不代表完整的真实系统验证。

`capabilities` 使用 `Native`、`Compatibility`、`BuildOnly`、`Unsupported`。窗口能力可以单独为 Unsupported，而不推导整个 Launcher 不可用。

## 验证等级

| 等级 | 证据含义 |
|---|---|
| `CATALOGUED` | 版本或 Loader 候选已发现并能追溯来源 |
| `RESOLVED` | MMTL 能解析项目、组合和执行计划 |
| `BUILD_VERIFIED` | 明确 OS/架构/Java 下构建成功并记录证据 |
| `SERVER_VERIFIED` | Dedicated Server ready/stop 检查通过 |
| `CLIENT_LAUNCH_VERIFIED` | 客户端达到定义的进程启动成功点 |
| `INTEGRATION_VERIFIED` | 场景级端到端验证通过 |

结果 `UNVERIFIED`、`PASSED`、`FAILED`、`STALE` 与 level 分开记录。Schema 不提供笼统的 `supported=true` 字段。

## 制品信任级别

Artifact 具有 `TrustedOfficial`、`VerifiedHistorical`、`UnverifiedHistorical` 分类。解析结果的 `downloadPermission` 和 `executePermission` 是不同字段：官方来源可按用户配置自动授权；可信历史来源首次需要明确确认；来源不完整的历史 artifact 默认需要分别确认下载和执行。

## 身份注册表与历史特例

Loader identity 目前包括 Forge、Fabric、NeoForge、Quilt、LegacyFabric、OrnitheLoader、LiteLoader、Rift、ModLoader、ModLoaderMP、JarMod。这是身份词汇表，不是全版本支持声明。Toolchain（ForgeGradle、FabricLoom、NeoGradle、ModDevGradle、QuiltLoom、Ploceus、LegacyLooming）和 Build System（GradleWrapper、Custom、Legacy）独立建模。Ornithe Loader 是独立 runtime loader，Ornithe 是其 ecosystem context，Ploceus 是 toolchain，Calamus/Feather 等 mapping context 独立保留。

### 历史来源与安全模型

- `HistoricalSourceClass`（ActiveOfficial、HistoricalOfficial、VerifiedCommunityArchive、VerifiedCommunitySource、ManualArtifact、UnknownHistorical）、Artifact Trust、TransportSecurity、IntegrityAlgorithm/Strength、MaintenanceState 是并列字段，来源分类不会替代 artifact trust。
- 历史 metadata 仅接受 allowlisted HTTPS，使用 ETag、Last-Modified、24 小时缓存、离线读取、哈希 envelope、原子替换和 stale 状态。HTTP-only artifact repository 仅作为 provenance；不放宽 metadata transport policy，也不允许其自动执行。
- SHA-256 为 strong integrity evidence；SHA-1 为 legacy integrity；MD5 仅用于 corruption detection。Integrity hash 不等于 execution trust。
- Legacy Fabric 与 Ornithe release coverage 通过精确 Minecraft ID 与 Phase C release Catalog 求交；Beta/Alpha/pre-release 不进入正式 release catalog。Legacy Fabric API 当前官方文档是 v2；实时 endpoint 本轮间歇超时，provider 会返回 Unavailable/Degraded 并保留 cache status。
- LiteLoader manifest 采用 HTTPS，但 manifest 中的历史 artifact repository 为 HTTP-only。Rift 原始仓库、community port 与 MCArchive ModLoader/MP archive records 分开标识，并固定源码 commit 或 archive hash。JarMod 只允许用户提供本地路径、计算 SHA-256 并生成 Manual plan；本轮不会改写 Minecraft JAR 或执行 patch。
- `--include-historical` 是 opt-in，默认 availability 列表维持四个 mainstream loaders。`--provider-status <id>` 输出历史 provider 来源、状态与 release coverage。Forge + LiteLoader evidence 解析为 Forge primary 与 LiteLoader overlay；不相关的多个 primary loader 仍标记 Ambiguous。

将来新增的版本/平台例外应按 `common/schemas/exception-registry.schema.json` 登记 matcher、rule、reason、provenance、适用范围和复核策略；当前实现不以此 schema 暗示每项历史规则已完成迁移。

## Schema 与配置

- `common/schemas/compatibility-matrix.schema.json`：目标组合、LoaderStack、Toolchain、Build System、双 Java requirement、capability 和验证证据。
- `common/schemas/exception-registry.schema.json`：可审计例外规则。
- `common/schemas/launcher-config.schema.json`：接受未标记的旧配置，以及 `configVersion` 1/2；Java major map 不限定在某几个 Java 版本；`javaHomesByPlatform` 可按平台保存 map。Config reader 不会把 platform-specific JDK 用于运行时解析；实际解析仍属于后续阶段。

## CI 验证边界

Windows 执行完整 Pester。Ubuntu、macOS ARM64 和 macOS Intel 执行 parser、Architecture、Schema、Provider、Availability Index、Adapter 与 ProjectDetector fixtures；CI 不调用 live upstream API，也不启动 Minecraft GUI。具体 required job 结果以对应提交的 Actions run 为准。

## 阶段 F — 全版本覆盖审计

Phase F 完成全正式 Mojang release 覆盖审计。每个 release 都列出四种主流 Loader、六种历史 Loader 与 JarMod Manual mode；Unknown 必须附 reason code 与解释。上游支持状态、Resolver、构建、服务端和客户端验证是分开的证据层。候选端点的边界/P0 抽样若与全局 index 冲突，会生成 `COVERAGE_INCONSISTENCY` gap。Ornithe 官方 game-support 记录不会单独推导 Ornithe Loader 候选；只有逐版本 loader candidate metadata 才能标记 Available。

Java 需求不代表构建时实际使用的 JDK。`BuildJavaRequirement.requirementKind` 可以是 Minimum、Preferred、Exact 或 Unknown；构建证据单独记录 `observedBuildJava`（主版本、完整版本、vendor、OS、arch）和 `compilerTarget`。例如 Gradle 最低要求 Java 17、实际使用 Oracle JDK 25、字节码目标 Java 8，三者必须分别保留。Mojang `runtimeJava` 是游戏运行需求，不推导 Mod 构建需求。

Coverage CLI 使用统一入口：`--coverage-report` 输出摘要，`--coverage-report --json` 输出全量模型，`--coverage-gaps` 输出 gaps，`--coverage-version <id>` 输出单个正式 release。Provider 汇总额外给出首末 Available release、连续区间和状态 gap ranges；逐 canonical ID 记录仍是事实来源。`--catalog-offline` 与 `--loader-offline` 保持独立。Live 报告不得写入 source tree；必需 CI 只运行 fixture，不依赖上游服务在线。手动/weekly live workflow 分开报告 Provider health、coverage data errors 与 MMTL invariant errors；已解释的 provider outage 或 upstream unmapped version 不会单独使 workflow 判为代码回归，只有明确列出的 invariant violation 会失败。

### Phase H–K — Runtime binding、Doctor 与可靠 Session

Phase H 建立规范化执行计划、Build Java/Runtime Java 双轨解析和 Session Manifest v2。Phase I 由 Loader Adapter 产出 Runtime Java Binding Evidence，并由只读 Gradle task inspection 检查 `runClient`/`runServer` launcher；缺少匹配证据时保持 `Unknown`。Phase J 增加 Launch Preflight、Java Discovery、环境 Doctor 和平台 Capability 报告。Phase K 增加 Session 并发锁、原子 manifest/Plan 写入、崩溃后保守恢复，以及按平台注入的进程身份与生命周期能力。

Planner 不包含按 Loader 名称散落的绑定判断，只消费 Adapter evidence。`BuildReady` 与 `LaunchReady` 独立；`LaunchReady` 不是 `CLIENT_LAUNCH_VERIFIED`。Doctor 只诊断，不安装 Java、不登录、不构建或启动进程、不修改配置或 EULA。Session recovery 只修复 owner identity 可以证明过期的元数据，不终止进程、不删除 Session。详见 [Runtime Binding](runtime-binding.md)、[Doctor](doctor.md)、[执行计划](execution-plan-session.md) 和 [Session 生命周期](session-lifecycle.md)。

### Phase L–O — 运行时观察、编排演练与人工验证准备

Phase L 为当前 Session 的已登记进程与日志建立结构化 Runtime Event、Client/Server/LAN/Auth/Crash Observer 和独立 Observed Runtime Java 证据。Observer 只读 Session 身份，不重建执行计划；synthetic/rehearsal evidence 永远不能晋级真实验证等级。Phase M 通过 Single、Dedicated 和 IntegratedLAN dummy harness 验证 ready 顺序、端口、停止、补偿清理、内存预算与 linked project/JAR 完整性，不启动真实 Minecraft。

Phase N 的 `--human-validation-plan` 生成本机人工验证矩阵、步骤清单和安全 helper；helper 默认只展示计划，只有用户显式确认才允许未来调用真实 Launch。Phase O 汇总 CLI、文档、配置字段、TODO 分类、公开仓库卫生与架构边界。交接包留在本机 `HANDOVER/manual-validation/`，不得提交或上传。完整边界见 [运行时观察](runtime-observation.md)、[人工验证计划](human-validation.md)、[配置字段审计](config-profile-field-audit.md) 与 [发布门禁审计](pre-human-validation-audit.md)。
