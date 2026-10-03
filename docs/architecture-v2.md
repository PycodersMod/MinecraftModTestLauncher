# MMTL v2 架构基础

本文记录 MMTL v2 Phase A–F 的落地边界。Catalog、上游 Loader availability、项目解析、实际构建、服务端和客户端验证是不同状态；查询结果不能替代 Compatibility Matrix 的实验证据。

## 当前实现与后续计划

### Phase A 已实现

- `src/Architecture/Contracts.psm1` 集中定义 OS、架构、能力、验证等级、Artifact Trust、provenance、Loader、Toolchain 和 Build System identities。
- `PlatformContext`、`LoaderStack`、`BuildJava`/`RuntimeJava` requirement、Toolchain context、Build System context 和 provenance 使用纯数据结构表达。
- Compatibility Matrix v1、Exception Registry 和 Config v2 foundation 由 JSON Schema 描述；旧配置 reader 保留旧格式并保留未知字段。
- CI 在 Ubuntu/macOS 上运行 PowerShell parser 和跨平台纯 fixture 测试；Windows job 运行完整 Pester suite。

### Phase B 已实现

- Windows/Linux/macOS 平台 Provider、各平台 Runtime Root 与路径安全、Java/Gradle Wrapper 选择和 `launcher.sh` 已落地。
- Session 平台元数据、Linux `/proc` 进程身份与受控停止均有实现和 fixture 覆盖。Linux/macOS CLI 与 Gradle build 能力不等价于这些平台上的 Minecraft GUI 实机运行。

### Phase C 已实现

- src/Catalog/MinecraftVersionCatalog.psm1 从 Mojang Version Manifest v2 建立 release Catalog，以字符串 canonical ID 和 releaseTime 确定从 1.0 到 manifest.latest.release 的范围，不做 SemVer 解析或排序。
- Catalog cache 分开保存原始 manifest、规范化 catalog 与校验 metadata；使用临时文件和原子替换，记录本地 manifest SHA-256。实测 Mojang 端点提供 ETag 与 Last-Modified；Windows live conditional refresh 收到 304，并保留原始 fetchedAt、更新 validatedAt。
- Version metadata 按查询惰性拉取，按 manifest SHA-1 校验并拒绝 mismatch；version metadata cache key 使用 canonical ID 与期望 SHA-1。
- src/Catalog/JavaRuntimeResolver.psm1 以显式 Runtime override、Mojang javaVersion、带官方来源的 MMTL fallback、Unknown 为优先级；它不修改现有 Build Java 选择。
- Catalog cache 默认 TTL 为 24 小时。--catalog-offline 不访问网络；stale 在线刷新失败会显式返回 Stale；--refresh-catalog 失败不会报告成功。
- CATALOGUED 仅表示 Mojang manifest 记录了一个 release，不能推导 Loader、构建、服务端或客户端验证通过。

### Phase G — Deep Validation Matrix（进行中）

- Phase G 在独立 schema 中记录精确 target identity 和每次 run 的不可变 evidence。Resolve、build、server、client、integration 是不同等级；没有专属 marker、进程身份与 stop/port 证据时，不接受高等级声明。
- Tier 0 保持全 catalog/availability metadata-only；Tier 1 是本机真实 Mod portfolio；Tier 2/3 采用固定 commit 和许可证来源的代表性官方 fixture，不构造全 Cartesian 矩阵。
- 深度 Gradle builds 位于手动/半月 workflow，不增加到每 PR required CI。覆盖审计数据与验证证据仍然是独立事实。
- 当前分支已实现证据契约、fixture pin/trust/task 检查、超时受控的 Gradle build runner、产物哈希、日志脱敏、不可变 run 存储和矩阵聚合。客户端/服务端/跨平台实机验证仍须以实际 marker 和每 target 报告为准；实现存在不代表 target 已通过。
- 本仓库当前 Linux/macOS 目标仍是 CLI、构建基础与 CI fixtures，不把 WSL/WSLg 当作完整 Linux Desktop 实机验证。

### Phase D Loader metadata 与 Adapter Contract v2

- Forge、Fabric、NeoForge 和 Quilt provider 共用 `src/Catalog/LoaderMetadata.psm1` 的 allowlist HTTPS、重定向校验、ETag/Last-Modified、24 小时缓存、stale/offline 状态与原子写入。provider 各自拥有独立 cache key，单一端点失败不会阻断其它 provider。
- `src/Catalog/LoaderAvailability.psm1` 生成宽度动态跟随 Mojang Catalog 的 availability index；availability 限定为 `Available`、`Unavailable`、`Unknown`，schema 位于 `schemas/loader-availability.schema.json`。该索引不存储 Loader 安装内容，也不表示 build 已验证。
- Forge 保留 Maven 完整版本和 promotions 中独立的 `recommended` / `latest`；Fabric 保留官方 `stable` 与 intermediary 数据，并依上游顺序选 stable；NeoForge 分开处理 `net.neoforged:neoforge` 与 1.20.1 过渡 artifact `net.neoforged:forge`；26.x scheme 保留完整 Minecraft 前缀；Quilt Meta v3 原样保留 hashed、intermediary、quilt-mappings 与 launcherMeta，不推造 stable 语义。
- `src/Adapters/ContractV2.psm1` 表达 Adapter probe evidence、解析冲突和 build plan；`ProjectDetector.psm1` 从 mod metadata 与 Gradle 插件 marker 归并 evidence。Quilt 的 `fabric.mod.json` 是兼容 metadata，识别 Quilt 以 Quilt Loom 插件 evidence 为准；多 Loader marker 返回 `Ambiguous`。
- Toolchain identity 与 Loader identity 分开；`QuiltLoom` 已加入 toolchain registry。Build Java 项目显式要求的 major 是 High confidence；缺失时由 `BuildJavaResolver.psm1` 集中 fallback registry 推断并标记 Low confidence。Runtime Java 仍由 Mojang metadata resolver 负责。
- CLI 的 `--list-loaders` 显示版本 availability，`--loader-info` 返回候选、preferred policy 和 provenance；`--loader-offline` 独立于 Gradle offline。结果可从 Runtime Root 的 Provider cache 离线重建。
- PR CI 使用 metadata/adapter fixture，不依赖 live endpoint；Windows 执行全 suite，Ubuntu、macOS ARM64 和 Intel 增加 Provider、index、Adapter 与 ProjectDetector fixture suite。

### Phase E 已实现 — Historical ecosystem providers

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

## Platform identity

当前 identity registry 接受 `Windows`、`Linux`、`MacOS` 与 `x64`、`ARM64`。`Get-MmtlPlatformContext` 仅检测 OS、架构、WSL 标志和当前 shell；它不安装运行时、不启动 Minecraft，也不代表完整 Platform Provider。

`capabilities` 使用 `Native`、`Compatibility`、`BuildOnly`、`Unsupported`。窗口能力可以单独为 Unsupported，而不推导整个 Launcher 不可用。

## Validation levels

| Level | 证据含义 |
|---|---|
| `CATALOGUED` | 版本或 Loader 候选已发现并能追溯来源 |
| `RESOLVED` | MMTL 能解析项目、组合和执行计划 |
| `BUILD_VERIFIED` | 明确 OS/架构/Java 下构建成功并记录证据 |
| `SERVER_VERIFIED` | Dedicated Server ready/stop 检查通过 |
| `CLIENT_LAUNCH_VERIFIED` | 客户端达到定义的进程启动成功点 |
| `INTEGRATION_VERIFIED` | 场景级端到端验证通过 |

结果 `UNVERIFIED`、`PASSED`、`FAILED`、`STALE` 与 level 分开记录。Schema 不提供笼统的 `supported=true` 字段。

## Artifact trust

Artifact 具有 `TrustedOfficial`、`VerifiedHistorical`、`UnverifiedHistorical` 分类。解析结果的 `downloadPermission` 和 `executePermission` 是不同字段：官方来源可按用户配置自动授权；可信历史来源首次需要明确确认；来源不完整的历史 artifact 默认需要分别确认下载和执行。

## Identity registries 与历史特例

Loader identity 目前包括 Forge、Fabric、NeoForge、Quilt、LegacyFabric、OrnitheLoader、LiteLoader、Rift、ModLoader、ModLoaderMP、JarMod。这是身份词汇表，不是全版本支持声明。Toolchain（ForgeGradle、FabricLoom、NeoGradle、ModDevGradle、QuiltLoom、Ploceus、LegacyLooming）和 Build System（GradleWrapper、Custom、Legacy）独立建模。Ornithe Loader 是独立 runtime loader，Ornithe 是其 ecosystem context，Ploceus 是 toolchain，Calamus/Feather 等 mapping context 独立保留。

### Historical source and safety model

- `HistoricalSourceClass`（ActiveOfficial、HistoricalOfficial、VerifiedCommunityArchive、VerifiedCommunitySource、ManualArtifact、UnknownHistorical）、Artifact Trust、TransportSecurity、IntegrityAlgorithm/Strength、MaintenanceState 是并列字段，来源分类不会替代 artifact trust。
- 历史 metadata 仅接受 allowlisted HTTPS，使用 ETag、Last-Modified、24 小时缓存、离线读取、哈希 envelope、原子替换和 stale 状态。HTTP-only artifact repository 仅作为 provenance；不放宽 metadata transport policy，也不允许其自动执行。
- SHA-256 为 strong integrity evidence；SHA-1 为 legacy integrity；MD5 仅用于 corruption detection。Integrity hash 不等于 execution trust。
- Legacy Fabric 与 Ornithe release coverage 通过精确 Minecraft ID 与 Phase C release Catalog 求交；Beta/Alpha/pre-release 不进入正式 release catalog。Legacy Fabric API 当前官方文档是 v2；实时 endpoint 本轮间歇超时，provider 会返回 Unavailable/Degraded 并保留 cache status。
- LiteLoader manifest 采用 HTTPS，但 manifest 中的历史 artifact repository 为 HTTP-only。Rift 原始仓库、community port 与 MCArchive ModLoader/MP archive records 分开标识，并固定源码 commit 或 archive hash。JarMod 只允许用户提供本地路径、计算 SHA-256 并生成 Manual plan；本轮不会改写 Minecraft JAR 或执行 patch。
- `--include-historical` 是 opt-in，默认 availability 列表维持四个 mainstream loaders。`--provider-status <id>` 输出历史 provider 来源、状态与 release coverage。Forge + LiteLoader evidence 解析为 Forge primary 与 LiteLoader overlay；不相关的多个 primary loader 仍标记 Ambiguous。

将来新增的版本/平台例外应按 `schemas/exception-registry.schema.json` 登记 matcher、rule、reason、provenance、适用范围和复核策略；当前实现不以此 schema 暗示每项历史规则已完成迁移。

## Schema 与 Config

- `schemas/compatibility-matrix.schema.json`：目标组合、LoaderStack、Toolchain、Build System、双 Java requirement、capability 和验证证据。
- `schemas/exception-registry.schema.json`：可审计例外规则。
- `schemas/launcher-config.schema.json`：接受未标记的旧配置，以及 `configVersion` 1/2；Java major map 不限定在某几个 Java 版本；`javaHomesByPlatform` 可按平台保存 map。Config reader 不会把 platform-specific JDK 用于运行时解析；实际解析仍属于后续阶段。

## CI 边界

Windows 执行完整 Pester。Ubuntu、macOS ARM64 和 macOS Intel 执行 parser、Architecture、Schema、Provider、Availability Index、Adapter 与 ProjectDetector fixtures；CI 不调用 live upstream API，也不启动 Minecraft GUI。具体 required job 结果以对应提交的 Actions run 为准。

## Phase F — Full Coverage Audit

Phase F 完成全正式 Mojang release 覆盖审计。每个 release 都列出四种主流 Loader、六种历史 Loader 与 JarMod Manual mode；Unknown 必须附 reason code 与解释。上游支持状态、Resolver、构建、服务端和客户端验证是分开的证据层。候选端点的边界/P0 抽样若与全局 index 冲突，会生成 `COVERAGE_INCONSISTENCY` gap。Ornithe 官方 game-support 记录不会单独推导 Ornithe Loader 候选；只有逐版本 loader candidate metadata 才能标记 Available。

Java 需求不代表构建时实际使用的 JDK。`BuildJavaRequirement.requirementKind` 可以是 Minimum、Preferred、Exact 或 Unknown；构建证据单独记录 `observedBuildJava`（主版本、完整版本、vendor、OS、arch）和 `compilerTarget`。例如 Gradle 最低要求 Java 17、实际使用 Oracle JDK 25、字节码目标 Java 8，三者必须分别保留。Mojang `runtimeJava` 是游戏运行需求，不推导 Mod 构建需求。

Coverage CLI 使用统一入口：`--coverage-report` 输出摘要，`--coverage-report --json` 输出全量模型，`--coverage-gaps` 输出 gaps，`--coverage-version <id>` 输出单个正式 release。Provider 汇总额外给出首末 Available release、连续区间和状态 gap ranges；逐 canonical ID 记录仍是事实来源。`--catalog-offline` 与 `--loader-offline` 保持独立。Live 报告不得写入 source tree；必需 CI 只运行 fixture，不依赖上游服务在线。手动/weekly live workflow 分开报告 Provider health、coverage data errors 与 MMTL invariant errors；已解释的 provider outage 或 upstream unmapped version 不会单独使 workflow 判为代码回归，只有明确列出的 invariant violation 会失败。
