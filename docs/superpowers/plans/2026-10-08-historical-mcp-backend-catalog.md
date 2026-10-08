# 历史 MCP 后端候选目录实施计划

> **执行方式：** Native inline，由当前执行者按任务顺序完成并在每步运行相应验证。

**目标：** 为 ModLoader 与 ModLoaderMP 建立带固定上游快照证据的 RetroMCP-Java 精确 target 候选解析，明确不授权下载或执行。

**架构：** 将版本 Registry 快照与纯本地 resolver 分离。Resolver 只返回 CataloguedOnly 候选，不改变 Ledger 支持状态，也不执行 RetroMCP 或历史制品。

**规范：** [2026-10-08-historical-mcp-backend-catalog-design.md](../specs/2026-10-08-historical-mcp-backend-catalog-design.md)

## 全局约束

- 固定 Universe SHA-256：`0b394322e696d12e393a02baacdf42f164de563e2a9d936f706fbe1ff89c7606`。
- 固定 RetroMCP-Java source commit：`ec16b2a8c5907429ac59f7ebe13f28c4cf8052bd`。
- Registry snapshot SHA-256：`0513d84d885acbfcca81e820410bac8c8dbca90aa73e1b7434bd3c9ddd3a61fa`。
- 解析必须离线、精确匹配；自动下载/执行均为 false。
- 不修改 Universe、既有 family capability、Ledger status 或原始 JAR。

## 文件职责

- 新建 `compatibility/mcp-backend-catalog.json`：固定上游元数据和 39 个候选 target pairs。
- 新建 `common/schemas/mcp-backend-catalog.schema.json`：固定 catalog 字段与安全策略约束。
- 新建 `common/src/Compatibility/HistoricalMcpBackendCatalog.psm1`：验证 catalog 并按精确 pair 解析候选。
- 新建 `common/tests/HistoricalMcpBackendCatalog.Tests.ps1`：精确匹配、安全拒绝、缺失/损坏/重复 profile 行为。
- 新建 `tools/Test-HistoricalMcpBackendCatalog.ps1`：离线比较候选目录与冻结 Universe，输出各 Loader 覆盖数和未匹配 target IDs。
- 新建本设计与本计划；只更新本地 HANDOVER 断点，不上传报告。

## Review Focus

- Loader ID 相同而 Minecraft ID 缺失时不能回退到相邻版本：缺失版本测试。
- ModLoader 与 ModLoaderMP 共用 Minecraft ID 时不能串 Loader：跨 Loader 测试。
- Registry hash / source commit 无效或重复 target pair：拒绝 catalog 测试。
- CataloguedOnly 不能被误读为 Supported 或执行授权：安全标志测试。
- 冻结 Universe 改变后原有候选覆盖断言必须失败：Universe hash 与精确集合测试。

---

### Task 1：Catalog schema 与 exact resolver

**文件：**
- 新建：`compatibility/mcp-backend-catalog.json`
- 新建：`common/src/Compatibility/HistoricalMcpBackendCatalog.psm1`
- 新建：`common/tests/HistoricalMcpBackendCatalog.Tests.ps1`

**接口：**
- `Test-MmtlHistoricalMcpBackendCatalog -Catalog <object> -> { isValid, errors }`
- `Resolve-MmtlHistoricalMcpBackend -Catalog <object> -LoaderId <string> -MinecraftId <string> -> { status, targetId, backendId, evidenceRefs, automaticDownloadAllowed, automaticExecutionAllowed }`

- [x] 先写测试：`resolves-exact-modloader-pair-as-catalogued-only`、`resolves-modloadermp-without-cross-loader-fallback`、`does-not-fallback-from-unlisted-version-to-neighbor`、`rejects-duplicate-or-malformed-pair-catalog`、`candidate-never-authorizes-download-or-execution`。
- [x] 运行单文件 Pester，RED 为 0 passed、6 failed，原因是模块和快照尚未实现。
- [x] 写入带 39 对目标、固定快照 hash 和 backend commit 的 Catalog；实现 JSON Schema、纯本地校验与 Ordinal exact resolver。
- [x] 再运行单文件 Pester，GREEN 为 7 passed、0 failed、0 skipped。

### Task 2：Universe 覆盖审计入口

**文件：**
- 新建：`tools/Test-HistoricalMcpBackendCatalog.ps1`
- 修改：`common/tests/HistoricalMcpBackendCatalog.Tests.ps1`

**接口：**
- 参数：`-UniversePath`、`-CatalogPath`；默认指向仓库冻结 Universe 和候选 catalog。
- 输出：`universeHash`、`targetCount`、各 loader `candidateCount` / `missingTargetIds`、`automaticExecutionAllowed=false`。

- [x] 先写脚本集成测试：输出必须为 ModLoader 23/42、ModLoaderMP 16/20、缺失数 19/4、候选总数 39。
- [x] RED 阶段因预期 catalog 文件缺失失败；GREEN 阶段输出符合精确覆盖矩阵。
- [x] 实现只读离线审计脚本；不联网、不写 Ledger。
- [x] 运行集成测试和完整 `HistoricalMcpBackendCatalog.Tests.ps1`，7 passed、0 failed、0 skipped。

### Task 3：工程验证与 checkpoint

**文件：**
- 更新：`HANDOVER/MMTL_Full_Loader_And_Version_Compatibility_Report.md`（工作区外，本地文件）

- [x] 运行官方 Windows Pester 入口 `.github/scripts/Invoke-MmtlPester.ps1`，完整读取结果：95 个文件，536 passed、0 failed、2 skipped，用时 1,016.63 秒。
- [x] 运行 PowerShell parser、`git diff --check`、候选离线矩阵审计，并确认 Ledger 和冻结 Universe 未变化。
- [x] 确认没有本轮 RetroMCP/Java/Minecraft/Server 测试进程遗留。
- [x] 更新本地 HANDOVER：记录候选目录、缺失 target、测试结果和仍未完成的完整 Goal；不创建 PR。
- [x] 建立本地 checkpoint commit；满足全局门禁后再推送或创建 PR。

### 验证记录

- 初次完整套件曾有 `RehearsalRunner.Tests.ps1` 的 IntegratedLAN Host ready race 失败；同一文件正式入口复跑 13/13 通过，随后完整入口再次复跑 536 passed、0 failed、2 skipped。将首次失败记录为未复现的时序异常，不能据此删除既有错误报告。
- Pester 完整运行日志保存在被 Git 忽略的 `.codex/full-pester-mcp-backend-resume.log`。
- 冻结 Universe hash 与 ledger 未因候选目录变化；候选结果仍为 `CataloguedOnly`，下载/执行许可保持 false。
