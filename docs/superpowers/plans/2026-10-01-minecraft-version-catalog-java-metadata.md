# Minecraft 版本目录与运行时 Java 元数据实施计划

> **面向智能体执行者：**每项任务都先编写 fixture 测试，再运行列出的验证命令后继续。

**目标：**新增权威 Mojang 版本目录、校验完整性的惰性版本元数据缓存、Runtime Java resolver v2 和跨平台目录 CLI，同时不改变旧版 Build Java 行为。

**架构：**HTTP、manifest 规范化、缓存策略、元数据完整性和 Java 来源信息放在职责明确的 Catalog 模块中。Launcher 在解析项目 Profile 前分派目录命令；现有 `JavaMajor` 继续作为旧版 Build Java 别名。Fixture 覆盖所有确定性行为，实时 Mojang 检查仍作为显式 smoke test。

**技术栈：**PowerShell 7、.NET HTTP/JSON/密码学 API、Pester、GitHub Actions、Mojang Version Manifest v2。

**规格来源：**用户提供的 Phase C 任务，以及仓库的 Phase A/B 架构契约。

## 全局约束

- 将规范 Minecraft ID 作为字符串并保留来源顺序；不得使用 SemVer 解析或排序。
- 权威 manifest 仅使用 `https://piston-meta.mojang.com/mc/game/version_manifest_v2.json`。
- 只将目录发现报告为 `CATALOGUED`；这不代表支持 Loader、构建或客户端。
- 在将各版本 JSON 解析或作为权威数据缓存前，必须根据 manifest 中的 SHA-1 校验。
- 缓存写入 `<RuntimeRoot>/metadata/mojang/` 并采用原子操作；不得提交实时缓存或个人机器路径。
- Runtime Java 与 Build Java 分离，同时保留 `JavaMajor` 兼容性。
- 离线模式不得发起网络请求；过期数据回退必须明确标注。
- PR 测试必须使用 fixture，与 Mojang 服务是否可用无关。
- 不实现 Loader Provider、不下载 JAR、不启动 Minecraft、不修改 Mod，也不重试 NeoForge 卡顿问题。

## 审查重点

- 非 SemVer 和年份格式 ID 必须作为准确字符串保留；在 manifest 规范化和 CurrentStable 测试中固定此行为。
- 拒绝损坏、不匹配、格式错误或 ID 错误的元数据；在完整性/缓存测试中固定此行为。
- 离线与强制刷新语义必须保持不同；使用伪造 HTTP 请求计数断言验证。
- 旧版 `JavaMajor` 和 Build 行为不得继承 Minecraft Runtime Java；使用检测器和项目模型测试固定此行为。
- 除非适用经过审计的回退规则，未知 Java 元数据必须继续保持 Unknown；验证 resolver 优先级和任意主版本契约。

---

### 任务 1：Mojang Manifest 目录与 HTTP 边界

**文件：**
- 新建：`src/Catalog/MinecraftVersionCatalog.psm1`
- 新建：`schemas/minecraft-version-catalog.schema.json`
- 新建：`tests/MinecraftVersionCatalog.Tests.ps1`

**接口：**
- 实现 manifest 获取、验证和规范化；从 manifest 的 `1.0` 锚点筛选到 `latest.release` 的正式版本；提供规范 ID 查询、数据新鲜度状态、原子 manifest 缓存和可注入 HTTP 行为。

- [ ] 添加 fixture 测试，覆盖 Schema 验证、重复 ID、锚点查询、来源顺序、仅正式版本筛选、CurrentStable 和年份格式 ID。
- [ ] 添加缓存测试，覆盖 fresh/stale/offline/corrupt/atomic-write 和条件请求标头。
- [ ] 根据观察到的官方端点实现规范化 Schema、HTTPS 和主机验证。
- [ ] 运行 `Invoke-Pester tests/MinecraftVersionCatalog.Tests.ps1 -CI`。

### 任务 2：惰性版本元数据、完整性与 Runtime Java Resolver

**文件：**
- 新建：`src/Catalog/JavaRuntimeResolver.psm1`
- 新建：`src/Catalog/data/java-runtime-fallback.json`
- 修改：`src/Catalog/MinecraftVersionCatalog.psm1`
- 修改：`tests/MinecraftVersionCatalog.Tests.ps1`
- 新建：`tests/JavaRuntimeResolver.Tests.ps1`

**接口：**
- `Get-MmtlMinecraftVersionMetadata -CatalogEntry <entry> -RuntimeRoot <path> [-Offline]` 在返回解析后的元数据前验证 SHA-1 和规范元数据 ID。
- `Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId <string> -Catalog <catalog> [-RuntimeOverride <requirement>]` 返回 major/component/source/confidence/requirementKind/provenance/metadataStatus。

- [ ] 测试元数据 SHA-1 成功/不匹配、格式错误的 JSON、错误 ID、不安全 URL 和缓存重新验证。
- [ ] 测试权威元数据、已审计的回退规则、显式覆盖、Unknown 和任意 Java 主版本。
- [ ] 仅在官方发行说明支持时添加保守且注明来源的回退规则；证据不足的历史版本继续标记 Unknown。
- [ ] 运行这两个定向 Pester 文件。

### 任务 3：CLI、项目模型兼容性、文档与跨平台 Fixture

**文件：**
- 修改：`launcher.ps1`
- 修改：`src/ProjectDetector.psm1`
- 修改：`tests/CrossPlatformCli.Tests.ps1`
- 修改：`tests/JavaResolver.Tests.ps1`
- 修改：`docs/architecture-v2.md`
- 修改：`README.md`
- 仅在必须加入新 fixture 套件时修改：`.github/workflows/test.yml`

- [ ] 在解析 Profile/项目之前加入 `--list-minecraft-versions`、`--minecraft-info <id>`、`--refresh-catalog` 和 `--catalog-offline`。
- [ ] 添加可选 Runtime/Build Java 要求字段，同时保留 `JavaMajor` 和现有构建选择行为。
- [ ] 测试命令解析、离线时不访问网络、刷新失败、状态显示和旧行为回归。
- [ ] 说明目录覆盖边界、缓存、CurrentStable、来源信息以及 Runtime/Build 的区别。
- [ ] 运行完整 Windows Pester 套件；在 WSL 中运行跨平台 fixture 套件。

### 任务 4：实时 Smoke、隐私审查、提交、CI 与交接

**文件：**
- 仅在本地创建 Phase C 证据报告，不纳入 Git。

- [ ] 在 Windows 和 WSL 获取 manifest 与 P0 元数据；比较 CurrentStable、正式版本数量、锚点和逐版本元数据结果。
- [ ] 运行所有必需的平台 fixture 套件与可用 CI 任务。
- [ ] 运行 `git diff --check`，并扫描暂存内容中的凭据、个人路径和实时缓存。
- [ ] 使用中文 Conventional Commit 标题提交并推送 `main`；核对本地/origin/GitHub HEAD 及四个必需 CI 任务。
- [ ] 写入本地 HANDOVER 证据；只有每项门禁均通过时才将 Phase C 标记为 PASS。
