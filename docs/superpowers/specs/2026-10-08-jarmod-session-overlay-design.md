# JarMod Session Overlay 设计

## 目标与边界

为现有 `JarMod ManualArtifact` 增加一个本地 Session 隔离的 JAR overlay 流程。它只处理用户显式给出的 base Minecraft JAR 和 patch ZIP/JAR，不查询或下载 Loader availability，不推断 Minecraft target，不启动修改后的 JAR，也不改写任何输入文件。

## 批准约束

原 Goal 第 49–50 节要求记录 patch strategy、输入完整性和输出隔离；原始 JAR 永不修改，所有工作都落在当前 MMTL Session 的副本中。手动 artifact 仍为 `UnverifiedHistorical`，patch 操作需调用者显式选择策略；执行权限保持 Denied。

## 接口

新增 `New-MmtlJarModSessionOverlay`：

```powershell
New-MmtlJarModSessionOverlay \
  -SessionPath <validated-session-v2-path> \
  -BaseJarPath <local-file> \
  -PatchArchivePath <local-file> \
  -PatchStrategy OverlayRejectConflicts|OverlayReplaceConflicts
```

用户 CLI 入口：

```powershell
launcher.cmd --jarmod-overlay <session-id> --base-jar <path> --patch-archive <path> \
  --patch-strategy OverlayRejectConflicts|OverlayReplaceConflicts [--json]
```

CLI 只允许在已配置 Runtime 下寻址已有 Session，并严格限制本命令可用参数。JSON 输出只给 Session 相对路径，不暴露 base/patch 源路径或 Runtime 绝对路径。

Session 必须是有效 v2 Session 且状态为 `Created`、`Preparing` 或 `Building`。所有输入必须是普通本地文件、在大小上限内并可解析为 ZIP/JAR。函数记录输入 SHA-256，复制输入到 Session 私有子目录，重新校验副本，再对 base 副本执行 overlay。返回的输出 JAR 与 provenance manifest 均位于 Session 目录下并写入 v2 artifacts。

## Overlay 规则

- 不把 ZIP 内容解压到文件系统；逐 entry 流式复制。
- 只接受相对、正斜线 ZIP entry path；拒绝绝对路径、盘符、反斜线、`.`/`..` 段、NUL 和重复 entry。
- 限制压缩输入为 256 MiB、每份归档展开后总大小为 1 GiB、每份最多 100,000 entries。
- 拒绝 base 或 patch 中的 JAR 签名文件及 `META-INF/INDEX.LIST`，避免输出带有失效签名/索引。
- `OverlayRejectConflicts` 遇到任何同名 entry 立即失败，不产生最终 JAR。
- `OverlayReplaceConflicts` 只在 Session 输出副本里删除同名 entry 并加入 patch entry。
- patch/base 原文件在执行前后必须保持同一 SHA-256；任何异常都清理本次新建的临时目录，不清理既有 Session 内容。
- provenance 不存储用户源文件的绝对路径；记录 session 相对路径、输入/输出摘要、strategy、entry 统计和 `executePermission=Denied`。

## 不支持

未知的专有 patch 格式、原生/可执行内容运行、网络制品、签名 Jar 重签名、任何自动 Minecraft 启动。签名 Jar 被明确拒绝；调用者需先在受控外部环境提供无签名且可核验的输入。

## 验收

- 两种冲突策略行为确定且只更改 Session 副本。
- 原始 base 与 patch SHA 始终不变；session artifacts 可由 `Test-MmtlSessionV2` 校验。
- 恶意 entry path、重复 entry、签名 Jar、超限归档、无效 Session 状态、源输入变化均失败且无最终输出。
- 结果保持手动 artifact / `UnverifiedHistorical`，自动执行权限为 Denied。
