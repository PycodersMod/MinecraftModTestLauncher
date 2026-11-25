# JarMod Session Overlay 实施计划

> **执行方式：** Native inline，依照原 Goal 第 49–50 节的既有授权与设计约束执行。

**目标：** 在有效 MMTL Session 内，对用户本地提供的 base JAR 与 patch archive 生成经过 SHA-256 复核的隔离 overlay 输出。

**架构：** 新增独立 PowerShell 模块，只在 Session 私有副本上处理 ZIP entry；沿用 Session v2 artifacts 记录输出。保留 `ManualArtifact` 来源分类和拒绝执行策略。

**技术栈：** PowerShell 7、.NET `System.IO.Compression.ZipArchive`、已有 Session v2/lock/atomic file 模块。

**设计：** [JarMod Session Overlay 设计](../specs/2026-10-08-jarmod-session-overlay-design.md)

## 全局约束

- 原输入文件不可写入。
- 工作目录必须位于有效、非终态 Session 之内。
- 用户本地 JarMod 仍为 `UnverifiedHistorical`，`executePermission=Denied`。
- 不下载制品、不运行 patch 内容、不启动 Minecraft。

## Review Focus

- 归档路径含 `..`、绝对路径、盘符或反斜线：拒绝并不落最终产物。
- base 与 patch 有重复 entry：按所选策略精确失败或替换。
- 任一输入为签名 Jar：拒绝，避免输出无效签名副本。
- 不完整、损坏、重复 entry 或超大小限制的 ZIP：失败且清理本次临时目录。
- Session 失效、终态或路径经过 reparse point：拒绝写入。
- provenance 不包含源文件绝对路径，所有输出路径均限定在 Session 根目录内。

---

### Task 1：写入 Session 隔离行为测试

**文件：**
- 新建：`common/tests/JarModSessionOverlay.Tests.ps1`
- 新建：`common/src/Catalog/Providers/JarModSessionOverlay.psm1`

**接口：** `New-MmtlJarModSessionOverlay -SessionPath -BaseJarPath -PatchArchivePath -PatchStrategy`。

- [x] 为 reject/replace 两种冲突策略、SHA-256 输入复核、session-relative artifacts 和原文件不变先写测试。
- [x] 运行定向 Pester，确认测试因模块/函数缺失而 RED。
- [x] 实现最小 Session copy 与 safe ZIP overlay。
- [x] 运行新增测试并验证 Session v2 manifests。

### Task 2：安全拒绝与 Session 生命周期

**文件：**
- 修改：`common/src/Catalog/Providers/JarModSessionOverlay.psm1`
- 修改：`common/tests/JarModSessionOverlay.Tests.ps1`
- 必要时修改：`common/src/SessionLifecycle.psm1` 和对应 schema/tests

- [x] 增加路径穿越、重复 entry、签名 Jar 与终态 Session 测试；坏 ZIP、大小上限和 reparse path 在当前用例中由统一归档/路径保护覆盖，后续可扩展专门 fixture。
- [x] 实施校验、独占 Session lock、失败清理、manifest atomic update。
- [x] 验证 patch/base 输入 hash 前后一致，`Test-MmtlSessionV2` 通过且执行权限仍 Denied。

### Task 3：回归与 checkpoint

- [x] 正式入口运行新增定向测试及官方 Windows Pester。
- [x] `git diff --check`、PowerShell parser、检查无本轮遗留测试进程。
- [x] 更新本地 HANDOVER；保留 Goal 为 PARTIAL。
- [x] 建立本地 checkpoint commit；不创建 PR。

### Task 4：用户 CLI 工作流

- [x] `--jarmod-overlay <session-id>` 严格校验 Session ID、必需参数和允许参数，且只在 Runtime sessions 根目录定位 Session。
- [x] JSON 返回 Session 相对路径和 SHA-256，不包含源 JAR/patch 的绝对路径。
- [x] Windows CLI 集成测试覆盖成功、缺参、未知参数、原始输入不变和 Session v2 校验。
- [x] 官方 Windows Pester 全仓复跑：96 文件，541 passed、0 failed、2 skipped。
