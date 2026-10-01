# MMTL v2 架构基础

本文记录 MMTL v2 Phase A–D 的落地边界。Catalog、上游 Loader availability、项目解析、实际构建、服务端和客户端验证是不同状态；查询结果不能替代 Compatibility Matrix 的实验证据。

## 当前实现与后续计划

### Phase A 已实现

- `src/Architecture/Contracts.psm1` 集中定义 OS、架构、能力、验证等级、Artifact Trust、provenance、Loader、Toolchain 和 Build System identities。
- `PlatformContext`、`LoaderStack`、`BuildJava`/`RuntimeJava` requirement、Toolchain context、Build System context 和 provenance 使用纯数据结构表达。
- Compatibility Matrix v1、Exception Registry 和 Config v2 foundation 由 JSON Schema 描述；旧配置 reader 保留旧格式并保留未知字段。
- CI 在 Ubuntu/macOS 上运行 PowerShell parser 和跨平台纯 fixture 测试；Windows job 运行完整 Pester suite。

### Phase C 已实现

- src/Catalog/MinecraftVersionCatalog.psm1 从 Mojang Version Manifest v2 建立 release Catalog，以字符串 canonical ID 和 releaseTime 确定从 1.0 到 manifest.latest.release 的范围，不做 SemVer 解析或排序。
- Catalog cache 分开保存原始 manifest、规范化 catalog 与校验 metadata；使用临时文件和原子替换，记录本地 manifest SHA-256。实测 Mojang 端点提供 ETag 与 Last-Modified；Windows live conditional refresh 收到 304，并保留原始 fetchedAt、更新 validatedAt。
- Version metadata 按查询惰性拉取，按 manifest SHA-1 校验并拒绝 mismatch；version metadata cache key 使用 canonical ID 与期望 SHA-1。
- src/Catalog/JavaRuntimeResolver.psm1 以显式 Runtime override、Mojang javaVersion、带官方来源的 MMTL fallback、Unknown 为优先级；它不修改现有 Build Java 选择。
- Catalog cache 默认 TTL 为 24 小时。--catalog-offline 不访问网络；stale 在线刷新失败会显式返回 Stale；--refresh-catalog 失败不会报告成功。
- CATALOGUED 仅表示 Mojang manifest 记录了一个 release，不能推导 Loader、构建、服务端或客户端验证通过。

### 后续阶段

- Linux/macOS Runtime、路径 provider、进程树实现、launcher.sh。
- Quilt 与历史 Loader 实际启动或下载支持。
- 全版本/OS/架构组合的更深验证。

### Phase D Loader metadata 与 Adapter Contract v2

- Forge、Fabric、NeoForge 和 Quilt provider 共用 `src/Catalog/LoaderMetadata.psm1` 的 allowlist HTTPS、重定向校验、ETag/Last-Modified、24 小时缓存、stale/offline 状态与原子写入。provider 各自拥有独立 cache key，单一端点失败不会阻断其它 provider。
- `src/Catalog/LoaderAvailability.psm1` 生成宽度动态跟随 Mojang Catalog 的 availability index；availability 限定为 `Available`、`Unavailable`、`Unknown`，schema 位于 `schemas/loader-availability.schema.json`。该索引不存储 Loader 安装内容，也不表示 build 已验证。
- Forge 保留 Maven 完整版本和 promotions 中独立的 `recommended` / `latest`；Fabric 保留官方 `stable` 与 intermediary 数据，并依上游顺序选 stable；NeoForge 分开处理 `net.neoforged:neoforge` 与 1.20.1 过渡 artifact `net.neoforged:forge`；26.x scheme 保留完整 Minecraft 前缀；Quilt Meta v3 原样保留 hashed、intermediary、quilt-mappings 与 launcherMeta，不推造 stable 语义。
- `src/Adapters/ContractV2.psm1` 表达 Adapter probe evidence、解析冲突和 build plan；`ProjectDetector.psm1` 从 mod metadata 与 Gradle 插件 marker 归并 evidence。Quilt 的 `fabric.mod.json` 是兼容 metadata，识别 Quilt 以 Quilt Loom 插件 evidence 为准；多 Loader marker 返回 `Ambiguous`。
- Toolchain identity 与 Loader identity 分开；`QuiltLoom` 已加入 toolchain registry。Build Java 项目显式要求的 major 是 High confidence；缺失时由 `BuildJavaResolver.psm1` 集中 fallback registry 推断并标记 Low confidence。Runtime Java 仍由 Mojang metadata resolver 负责。
- CLI 的 `--list-loaders` 显示版本 availability，`--loader-info` 返回候选、preferred policy 和 provenance；`--loader-offline` 独立于 Gradle offline。结果可从 Runtime Root 的 Provider cache 离线重建。
- PR CI 使用 metadata/adapter fixture，不依赖 live endpoint；Windows 执行全 suite，Ubuntu、macOS ARM64 和 Intel 增加 Provider、index、Adapter 与 ProjectDetector fixture suite。

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

Loader identity 目前包括 Forge、Fabric、NeoForge、Quilt、LegacyFabric、LiteLoader、Rift、ModLoader、ModLoaderMP、JarMod。这是身份词汇表，不是全版本支持声明。Toolchain（ForgeGradle、FabricLoom、NeoGradle、ModDevGradle、QuiltLoom、Ploceus）和 Build System（GradleWrapper、Custom、Legacy）独立建模。Ornithe 可作为 ecosystem context 与 Ploceus 关联，而不是 Loader identity。

将来版本/平台例外应按 `schemas/exception-registry.schema.json` 集中登记 matcher、rule、reason、provenance、适用范围和复核策略；Phase A 尚未迁移现有运行逻辑中的特例。

## Schema 与 Config

- `schemas/compatibility-matrix.schema.json`：目标组合、LoaderStack、Toolchain、Build System、双 Java requirement、capability 和验证证据。
- `schemas/exception-registry.schema.json`：可审计例外规则。
- `schemas/launcher-config.schema.json`：接受未标记的旧配置，以及 `configVersion` 1/2；Java major map 不限定在某几个 Java 版本；`javaHomesByPlatform` 可按平台保存 map。Config reader 不会把 platform-specific JDK 用于运行时解析；实际解析仍属于后续阶段。

## CI 边界

Windows 执行完整 Pester。Ubuntu、macOS ARM64 和 macOS Intel 执行 parser、Architecture、Schema、Provider、Availability Index、Adapter 与 ProjectDetector fixtures；CI 不调用 live upstream API，也不启动 Minecraft GUI。具体 required job 结果以对应提交的 Actions run 为准。
