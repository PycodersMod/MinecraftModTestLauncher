# MMTL Phase P–V 通用 Mod 开发者测试工作台实施计划

> **执行约束：** 使用 `superpowers:executing-plans` 由当前执行者逐任务实施；每项行为改动遵循 TDD，步骤以复选框追踪。

**目标：** 将 MMTL 扩展为可导入任意 Gradle Minecraft Mod 项目、使用隔离离线测试身份运行场景、自动收集并分析角色日志的开发者测试工作台，并形成 Public Alpha 分发候选。

**架构：** 复用既有 Project Detector、Execution Plan、Session v2、Runtime Events、Process/Port Manager 与 Adapter contract。公共 PowerShell 编排、Registry、Scenario、日志及规则分析放在 `common`；平台执行沿既有 Windows/Linux/macOS provider contract；MMTL Agent 独立于用户 Mod，通过受支持 Loader compatibility provider 选择并注入 Session。Project Registry、Session、原始日志、世界、截图、配置和本机运行证据仅在 Runtime/HANDOVER。

**技术栈：** PowerShell 7、Pester 5、Java/Gradle Loader Agent 子项目、JUnit（适用时）、GitHub Actions 四平台矩阵。

**Spec：** 用户附件 `GOAL TASK — MMTL Phase P–V 通用 Mod 开发者测试工作台`，第 0–230 条。本计划不得弱化附件的硬边界。

## Global Constraints

- 产品面向任意 Minecraft Java Mod 项目；现有十项目只作回归语料，禁止项目名/Mod ID 特判。
- Import 默认只登记并只读探测，不复制或修改用户项目、不执行项目自定义 shell。
- Test Identity 是 MMTL 管理 Session 的离线开发身份；不读取、保存、请求或登录正版凭据。
- 默认仅 loopback；不得自动绑定 `0.0.0.0` 或连接第三方公网服务器。
- Dedicated 仅当本机 Profile 明确 `acceptEula=true` 时 live；否则记录 `SKIPPED_EULA_NOT_PREAUTHORIZED`。不改写用户配置或 EULA。
- Agent 默认 inert，仅由 MMTL 当前 Session token/role/event sink 显式激活；不进入用户 Mod JAR。
- 所有角色使用独立可写 gameDir；共享构建产物必须只读或复制隔离；复用 Session lock、进程身份和 safe stop。
- CI 不下载/启动 Minecraft GUI；只运行 unit、fixture、rehearsal 与 Agent build。
- 只清理本 Goal 创建且能以 Session 身份验证的进程/端口；保留用户现有 Java/Gradle/编辑器进程。
- Git 分支 `codex/phase-p-v-developer-test-workbench`，commit 中文，身份 `ZYQ-2020` noreply；不 force push、不改写历史、不改 Ruleset。
- Public 文档/HANDOVER 不写本机绝对路径、邮箱、token、用户名或 hostname；原始 smoke evidence 保持 local-only。
- 本机现有 Profile 无 EULA 明确接受项；Dedicated live 默认跳过。

## Review Focus

- Registry 路径迁移、重解析点、损坏 JSON、并发导入/删除不能逃逸 Runtime Root 或误删项目。
- 多 Mod、nested Gradle root 与元数据冲突不能静默选错 Primary Mod。
- Host/Guest 间身份碰撞、可写目录共享及凭据字段不得污染隔离边界。
- 不匹配/缺失 Agent token、任意 event sink、外部地址或未管理进程必须 fail closed。
- 日志中的依赖栈、Agent 错误、路径/账号类敏感数据不得错误归属当前 Mod 或泄漏到 Public 报告。

---

## 文件/模块边界

- `common/src/ProjectRegistry.psm1`：Runtime 内 registry CRUD、稳定本地 ID、并发/原子写与损坏恢复。
- `common/src/ProjectImport.psm1`：通用 Gradle 根发现、Loader 元数据、Mod ID/入口/package/mixin/artifact 候选，不写项目。
- `common/src/TestIdentity.psm1`：稳定合法用户名、offline UUID、role identity contract。
- `common/src/Agent/`：Provider capability、manifest/hash 校验、Session token/event sink、安全注入参数。
- `common/src/Scenario/`：Scenario plan、动作 contract、启动排序、超时/补偿/safe stop。
- `common/src/Logs/`：按角色 raw log、structured records、timeline、Mod-aware extraction 与 RuleBasedAnalyzer。
- `common/agent/`：独立 Forge/Fabric/NeoForge Agent compatibility line 构建、测试与产物；不混进用户 Mod 工程/JAR。
- `common/tests/`：匿名 loader fixtures、unit/integration/rehearsal、rename/no-Pycoders 回归。
- `docs/`、README、`.github/workflows/`：产品说明、支持矩阵、first-run 与可复现 Alpha package。
- 本地 `HANDOVER/logs/phase-p-v/`：基线、live smoke 与回收检查；保持仓库外。

## 执行任务

### Task 1：通用项目探测与本地 Registry（Phase P）

- [x] 为 Forge/Fabric/NeoForge/Quilt 单 Mod、多 Mod、nested root、冲突 ID、invalid project 编写匿名 fixture 与 Registry/CLI Pester 测试。
- [x] 先运行新测试并观察正确失败；定义 Import Result 与 project ID contract。
- [x] 实现 read-only discovery/metadata parsers 和 Runtime Root Registry 的原子、锁安全 CRUD；ID 使用本地 UUID，semantic Plan 不依赖绝对路径。
- [x] 增加 `--import-project`、`--list-projects`、`--project-info`、`--remove-project`，JSON stdout purity/退出码测试。
- [x] 将十项目通过同一 importer 扫描，保证无名称特判；运行 Pester 与 read-only 项目文件 hash 对比。
- [x] 中文 commit：`功能：增加通用项目导入与本地项目注册表`。

### Task 2：Mod 元数据与多候选语义（Phase P）

- [x] 测试 Forge `mods.toml`、NeoForge 两类 metadata、Fabric/Quilt JSON、多 ID/entrypoint/mixin/package 发现及 malformed metadata。
- [x] 实现 primary ID 唯一选择与 `AMBIGUOUS_PRIMARY_MOD`；packageCandidates 按 entrypoint、source scan、mixin、artifact 顺序保留来源/置信度。
- [x] 增加 Profile `primaryModId` 的显式消歧；覆盖匿名 rename/no-Pycoders fixtures。
- [x] 运行 importer 全套测试及十项目 Discovery/Import/Plan smoke。
- [x] 中文 commit：`测试：覆盖匿名 Loader 项目导入与元数据识别`。

### Task 3：Test Identity 与角色隔离（Phase Q）

- [x] 先写 v1/v2 config 兼容、稳定合法 Host/Guest 命名、唯一性、offline UUID、敏感字段拒绝与目录隔离测试。
- [x] 实现向后兼容的 Test Identity profile model；身份记录包含 identity/role/session/instance、工作目录、log 目录、process identity/runtime java/network role/offline；不含认证 token。
- [x] 为每个角色创建独立 gameDir/logs/config/options/screenshots/crash-reports；Host saves 独立；共享 artifact 只读/复制并校验。
- [x] 覆盖 containment、reparse、跨 Session 冲突和 v2→新配置读取；不写回原配置。
- [x] 中文 commit：`功能：建立离线测试身份与实例目录隔离`。

### Task 4：Agent manifest、token 与 provider contract（Phase R）

- [ ] 测试 Agent manifest 支持/不支持、artifact SHA-256、兼容版本、Session nonce、role allowlist、event sink containment 与默认 inert。
- [ ] 实现 OS-independent Agent Provider contract：loader/version → Supported/Unsupported、artifact/hash/version/capabilities/reason；加载只允许 Session-contained artifact 与 event file。
- [ ] 定义 Agent 事件并映射至既有 Runtime Event contract；Agent 错误来源标为 `MMTL_INFRASTRUCTURE`。
- [ ] 构建 independent Forge 1.20.1 Agent；用 compile/unit test 固定 Forge event/API 接口，普通 `runClient` 无 MMTL 参数时无动作。
- [ ] 中文 commit：`功能：建立 MMTL 测试代理与能力契约`。

### Task 5：Forge IntegratedLAN Agent 与安全握手（Phase R）

- [ ] 用 Forge Agent 测试覆盖 host role/session token、world joined、IntegratedServer detection、offline auth gate、LAN publish request/result/port event 与重放/错误 token 拒绝。
- [ ] 实现仅受管 Host 可触发的 IntegratedServer offline-auth 与 publish；默认拒绝非 loopback、无效身份、Dedicated API 混用及不匹配 token。
- [ ] Guest 只允许 Quick Play 到 `127.0.0.1:<PortManager port>`；Host ready/published/listening 前不得启动 Guest；有界重试及阶段 timeout。
- [ ] Agent jar 独立记录，不进入用户 Mod jar；build/metadata/hash 测试通过。
- [ ] 中文 commit：`功能：实现 Forge 本机离线 LAN 测试代理`。

### Task 6：Scenario Orchestrator 与 Action Controller（Phase S）

- [ ] 先写 Single/IntegratedLAN/Dedicated scenario plan、players 总数语义、并发上限、action sequencing、超时、部分失败、安全回收测试。
- [ ] 实现 `--scenario-plan`（read-only）、`--run-scenario`（显式执行）、`--scenario-status`、`--scenario-action`；显式 non-interactive，无 Read-Host 卡住。
- [ ] 将 Build→Session→Host/Server→ready→Guest→observe→analyze→safe stop 接入既有 Execution Plan/Session/Process/Port 管理。
- [ ] Action contract 支持 WAIT、受权限校验的 SEND_COMMAND、SCREENSHOT、STOP_ROLE、STOP_ALL；不做脆弱坐标输入。
- [ ] 模拟 launcher/Agent crash、有限超时、多进程 recovery；禁止广域 kill。
- [ ] 中文 commit：`功能：实现多实例场景编排与安全动作控制`。

### Task 7：Structured Log Workspace 与 Timeline（Phase T）

- [ ] 测试各 role 原始日志不可覆盖、结构化记录字段、跨角色/Event 合并、原始与 observed timestamps 并存、损坏/空/旋转日志行为。
- [ ] 实现 raw/relevant/analysis Session 布局、UTF-8 append-safe 日志写入和 `timeline.jsonl`。
- [ ] 以 Test Identity、source file、role、logger、level、message 关联 log lines；目录安全限制到当前 Session。
- [ ] 实现 `--follow-session`（若生命周期可靠且不阻塞 session control），保持输出有界/可停止。
- [ ] 中文 commit：`功能：增加按角色结构化日志与统一时间线`。

### Task 8：Mod-aware Extraction 与 Rule-Based Analyzer（Phase T）

- [ ] 匿名 synthetic log 测试覆盖全部附件规则、Caused-by 完整异常块、20–40 行上下文、mixin/network/resource/dependency 分类。
- [ ] 测试 Direct/Indirect/Unknown；依赖栈没有当前 Mod frame 时不能归 Direct；Agent 栈单列 `MMTL_INFRASTRUCTURE`。
- [ ] 实现保留 raw log 的相关日志提取、finding Evidence/Observed/Likely category/Possible next check/Confidence 与 Analyzer Provider contract。
- [ ] 实现 `--analyze-session`、`--session-report [--json]`，stdout JSON 纯净；报告中文、不过度断言根因、不把“无异常”当功能正确。
- [ ] 中文 commit：`功能：实现 Mod 相关日志提取与规则式分析`。

### Task 9：Forge Windows live Single 与 IntegratedLAN smoke（Phase U）

- [ ] 确认候选项目无 TaCZ automation dependency；必要时 Forge smoke 使用其他简单 Forge fixture。检查 world template；没有可安全复制世界则用 Agent 最小创建或记录 `WORLD_TEMPLATE_REQUIRED`。
- [ ] 运行单 Loader Single 真机 smoke：init/Agent handshake、限定观察时长、分析证据、Session safe stop。
- [ ] 在 Forge IntegratedLAN 中先启动 Host，确认 world/auth/publish/loopback listener 后才启动 Guest；验证不同 offline usernames、两端 join evidence、运行存活与 safe stop。
- [ ] Dedicated 仅当所选本机 config 的 `acceptEula=true`；否则记录 `SKIPPED_EULA_NOT_PREAUTHORIZED`，不得写 EULA。
- [ ] 每个 live session 产出 local-only summary/findings/timeline；验证所有 Session 进程身份退出、端口释放；不触碰基线 VS Code Java/Gradle identities。
- [ ] 中文 commit：`测试：验证 Forge 单人及本机离线多人流程`。

### Task 10：跨 Loader live、十项目泛化及错误分类（Phase U）

- [ ] 运行 Forge/Fabric/NeoForge 三代表目标 Single live smoke；Agent unsupported 必须准确显示，只有 provider 稳定时跑 Fabric/NeoForge LAN。
- [ ] 对十项目通过同一 Import/Plan/Build/LaunchCheck/log metadata extraction；禁止 10 个 GUI 全量启动和任何项目名特判。
- [ ] 对匿名项目 rename 并移除所有 Pycoders 名称、Mod ID、package 后重跑 Import/Agent selection/Analyzer。
- [ ] 汇总 smoke 失败阶段与机器 evidence；不把外部下载卡住变无限等待。
- [ ] 中文 commit：`测试：增加跨 Loader 泛化与真实启动回归`。

### Task 11：Public Alpha 初始化、文档、包与校验和（Phase V）

- [ ] 测试 `--init` 空目录行为及重复执行安全；创建本地 Runtime/Registry/example profiles，不修改用户 Mod。
- [ ] 提供 Single/IntegratedLAN/Dedicated examples；IntegratedLAN 明示离线身份和 loopback，Dedicated EULA 仍显式门禁。
- [ ] 重写 README 定位；新增 project-import/test-identities/test-agent/scenarios/offline-multiplayer/log-analysis/public-alpha 文档与实际 Agent support matrix。
- [ ] 建立 0.x alpha version metadata、可复现 distribution package、SHA-256 manifest、allowlist contents/unzip smoke；禁止 local config/registry/world/logs/JDK/Minecraft runtime/User Mod。
- [ ] 不创建 GitHub Release 或正式 tag；新增 Alpha readiness checklist。
- [ ] 中文 commit：`构建：建立 Public Alpha 可复现分发基础`。

### Task 12：V+ 稳定性扩展

- [ ] 按附件优先级实现：scenario rerun/restart、报告差异、JUnit/Gradle 报告导入、public capabilities manifest、Registry 损坏恢复/并发、20 次 rehearsal、10 次并发端口、Agent artifact cache integrity、20 次短 scenario stress、陌生用户 first-run 空目录 smoke。
- [ ] 每个 extension 独立 TDD；只实现通过全部主流程后仍有时间且保持安全的条目。

### Task 13：全局回归、隐私、CI、PR、合并与交付

- [ ] 完整 PowerShell parse、Pester >400/0 fail、Agent compile/unit、10 项 matrix、四平台 required CI、真实日志规则回归、public hygiene equivalent 全 PASS。
- [ ] 检查 CLI/noninteractive 无阻塞、Architecture Boundary、README/docs/support matrix、distribution allowlist、所有输出脱敏。
- [ ] 逐一核对初始 Java/Minecraft identities 与任务子进程、Session process registry、port registry；只停止当前任务拥有且身份一致的进程。
- [ ] 确认 repo-local Git identity；中文 commits；fast-forward push、PR；CI 全绿。只有独立 Code Owner gate 导致阻塞时才按用户授权使用既有 bypass；不修改 Ruleset。
- [ ] 合并后同步 main，核对 local/origin/GitHub SHA，删除远端/本地 task branch、worktree 并 prune。
- [ ] 写脱敏 local-only `HANDOVER/MMTL_Phase_P_V_Developer_Test_Workbench_Report.md`，完成 public privacy 检查。

## 任务依赖与门禁

Registry/Importer → Test Identity → Agent provider/artifact → Forge LAN → Scenario → Logs/Analyzer → Live smoke → distribution/CI/PR。Dedicated live 与任何 GUI 启动都要在运行前重新核对该 profile 的显式 preconditions；Mojang/Microsoft auth 与外部服务器永不调用。

## 计划自审

- 第 0–230 条均映射至 Task 1–13；Phase V+ 优先项归 Task 12，安全、CI、隐私、merge/cleanup/HANDOVER 归 Task 13。
- Agent 与日志系统复用 Runtime Events，不建立第二套平行 Session/evidence。
- 任意导入项目按 UserOwned；不执行项目 shell；artifact cache 与 public package 强制 allowlist/哈希校验。
- Live smoke 需要离线启动 profile与可复制/可创建测试世界；Dedicated EULA 不满足时按机器证据跳过。
- Review Focus 五类边界分别由 Task 1、2、3、4–6、7–8 的测试覆盖。
