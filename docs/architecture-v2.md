# MMTL v2 架构基础

本文记录 MMTL v2 Phase A–C 已落地架构。Catalog、项目构建、服务端和客户端验证是不同状态；实现某个平台的 CLI 或 Catalog 查询不代表 Minecraft GUI 或 Loader 组合已获得验证。

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
- Forge/Fabric/NeoForge/Quilt Provider v2。
- Quilt 与历史 Loader 实际构建、启动或下载支持。
- 全版本/OS/架构组合的更深验证。

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

Loader identity 目前包括 Forge、Fabric、NeoForge、Quilt、LegacyFabric、LiteLoader、Rift、ModLoader、ModLoaderMP、JarMod。这是身份词汇表，不是适配器或支持声明。Toolchain（ForgeGradle、FabricLoom、NeoGradle、ModDevGradle、Ploceus）和 Build System（GradleWrapper、Custom、Legacy）独立建模。Ornithe 可作为 ecosystem context 与 Ploceus 关联，而不是 Loader identity。

将来版本/平台例外应按 `schemas/exception-registry.schema.json` 集中登记 matcher、rule、reason、provenance、适用范围和复核策略；Phase A 尚未迁移现有运行逻辑中的特例。

## Schema 与 Config

- `schemas/compatibility-matrix.schema.json`：目标组合、LoaderStack、Toolchain、Build System、双 Java requirement、capability 和验证证据。
- `schemas/exception-registry.schema.json`：可审计例外规则。
- `schemas/launcher-config.schema.json`：接受未标记的旧配置，以及 `configVersion` 1/2；Java major map 不限定在某几个 Java 版本；`javaHomesByPlatform` 可按平台保存 map。Config reader 不会把 platform-specific JDK 用于运行时解析；实际解析仍属于后续阶段。

## CI 边界

Windows 执行原有完整 Pester。Ubuntu/macOS 只执行 parser、Architecture 与 Schema tests，不能导入当前 Win32 WindowManager，也不运行完整启动器、Gradle Minecraft 项目或游戏。这些 smoke 只证明纯契约代码在 runner 上可执行。当前 workflow 使用 `ubuntu-latest` 和 `macos-latest`；GitHub 文档（2026-10-01 查阅）将 `macos-latest` 标为 Apple Silicon arm64，因此该 macOS job 不提供 Intel x64 覆盖。[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
