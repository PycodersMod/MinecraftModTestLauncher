# MMTL Phase L–O 人工实机验证前收口实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不启动真实 Minecraft、不认证账号、不处理 EULA 的前提下，完成 MMTL 的运行时观察、三种模式的 dummy 编排演练、人工验证证据包及全平台发布前门禁，并将仓库推进到只需用户本人进行真实游戏行为验证。

**Architecture:** ExecutionPlan、Session v2、ProcessManager、PortManager 和平台 Provider 是执行与进程身份的唯一可信来源；独立 Observer 只订阅已登记 Session、进程与日志，追加结构化事件，不重新发现或重解释项目计划。Rehearsal 通过依赖注入的受信任 dummy harness 复用真实编排器但禁止形式验证晋级；人工验证计划只读生成本地验证包。平台支持声明只能由契约测试与实际平台 CI 证据升级。

**Tech Stack:** PowerShell 7、Pester、JSON/JSONL、GitHub Actions、现有跨平台 Native process providers；不增加 Python/Node 运行时或第三方服务依赖。

**Spec:** 用户提供的 Phase L–O 完整规范及 176 节验收要求。

## Global Constraints

- 真实 Minecraft GUI、真实 Dedicated Server、真实世界、EULA、账号认证及 GUI 自动化一律禁止；只用合成 fixture、dummy Java 和 loopback TCP harness。
- Observer 仅观察登记的 Session/进程/日志；不得重新发现 Project、Java、Loader、Profile 或自动修复认证。
- dummy/rehearsal 永远 `validationEligible=false`，不得晋级真实验证证据。
- 所有停止操作仅作用于 Session 已登记且身份匹配的进程树；禁止全局按 `java.exe`/`java` 名称杀进程。
- 结构化事件、错误码、CLI JSON、超时、进程身份、Java 证据与晋级规则必须可测试、可追溯、向后兼容 Session v2。
- 本地人工验证包和报告不得提交或上传；不得包含原始日志、用户目录、主机名、账户、token 或敏感路径。
- 保持未证实的平台能力为 Unsupported/Unknown；不安装 WSL Java，不启动 Minecraft。
- GitHub 主账号必须是已验证的主账号；单一任务分支 `codex/phase-l-o-pre-human-validation`；repo-local commit identity 使用该账号 noreply；禁止 force push 和 history rewrite。
- 按附件要求完成 10 项项目门禁、Pester >329 且零失败、Windows/Linux/macOS ARM64/macOS Intel CI、PR/merge/清理及本地 HANDOVER。

## Review Focus

- 进程 PID 重用、早退及身份变化：observer 不得把别的进程事件归入当前 Session；在 Observer/Session 测试中验证。
- 并发 JSONL 写入、截断日志、超时：事件不丢失、不损坏，超时输出 `TIMED_OUT`；在 EventStore/Observer 测试中验证。
- 客户端 marker 与日志伪造：dummy 或无身份的 marker 永远不能得到 `CLIENT_LAUNCH_VERIFIED`；在 Validation Gate 测试中验证。
- 端口并发分配、竞态和异常清理：loopback harness 端口不冲突且所有出口释放；在 Port/Rehearsal 测试中验证。
- 部分失败、Host 未 ready、客户端认证提示、旧配置字段：保留准确状态并禁止虚报 Completed/Validated；在编排、Config Audit 与 Human Plan 测试中验证。

---

## 计划任务

### Task 1：基线与证据边界

**Files:** 修改本计划；必要时仅本地记录基线。测试：仓库门禁命令。

- [x] 确认 local `main`、`origin/main`、GitHub `main` 均为 `bf1126abe77f4ca3f14bf0e03eef483c9d32f120`，身份为已验证主账号，并记录 repo-local identity、Ruleset、CI required checks 与未提交状态。
- [x] 盘点现有 Launcher CLI、ExecutionPlan、Session v2、ProcessManager、PortManager、Validation Evidence、platform provider、Pester 收集脚本及配置 schema，形成精确变更清单。
- [x] 运行 Windows Pester 基线；57 文件，329 passed、0 failed、2 skipped。

### Task 2：Runtime Event 契约与安全存储

**Files:** Create `common/src/Observation/RuntimeEvents.psm1`, `common/src/Observation/RuntimeEventStore.psm1`, 对应 Pester；Modify common 导入入口。

- [x] 先写 schema、事件码、必填 Session/Role/PID/identity/time/source/code 字段及无敏感原始内容断言。
- [x] 实现 UTF-8 JSONL 并发追加、跨平台锁/原子边界、坏行容忍读取、确定性排序和只记录安全摘要。
- [x] 测试并发写入、重开追加、无效事件、编码及路径/账户/token 脱敏。

### Task 3：已登记进程与 Java 运行时观察

**Files:** Create `common/src/Observation/ProcessObserver.psm1`, `JavaRuntimeObservation.psm1` 及测试；必要时小幅扩展各 OS process provider。

- [x] 仅从 Session 登记表读取进程；比较 PID、StartIdentity、Executable、SessionID；报告 start/exit/identity lost/orphan/timeout。
- [x] 对真实登记 Java 进程采集 executable、major/exact version、vendor、OS、architecture；隐去本地 `java.home` 原文，仅用安全描述或 hash。
- [x] 将 `SameAsBuildJvm` resolved `BuildJavaPath` 传给实际 child process，测试可观测 Java 与解析结果一致。
- [x] 提供 fixture-only dummy Java 观察；其结果明确 synthetic，不可用作真实绑定证据。

### Task 4：Client、Server、LAN、Crash 与 Auth Observer

**Files:** Create `ClientObserver.psm1`, `DedicatedServerObserver.psm1`, `LanObserver.psm1`, `CrashObserver.psm1`, `AuthenticationObserver.psm1` 及测试；修改 Adapter marker hints 与 docs。

- [x] Client 状态区分 ProcessStarted、初始化、主菜单、早退、崩溃；marker 按版本/Loader adapter 提供。
- [x] 只有真实进程身份、显式 init marker、当前 Session marker 全部匹配才产生 `CLIENT_LAUNCH_VERIFIED` 候选；dummy 永不可晋级。
- [x] Server ready/listener/stop 与 Lan port 事件绑定到当前 Session 日志和角色；不扫描其他日志。
- [x] Crash 分类分开 BUILD_FAILED、PROCESS_START_FAILED、CLIENT_CRASH、SERVER_CRASH、AUTH_FAILURE、TIMED_OUT。
- [x] Auth 仅分类 `AUTH_REQUIRED`、`INVALID_SESSION`、认证失败；禁止读取凭据或自动修复认证。
- [x] Observer 超时始终留存 `TIMED_OUT` 及证据；不能降级成 Unsupported。

### Task 5：只读 Session Events CLI 与晋级门禁

**Files:** Modify `common/src/Launcher.ps1`、Session/Validation modules；Create CLI/Evidence tests；更新帮助和 docs。

- [x] 只接受 `--observe-session <ID>` 或 `--session-events <ID> [--json]`，校验互斥、只读、JSON purity 和退出码。
- [x] 输出登记进程、事件、ready/crash、Java、validation candidate；不自动运行 Project/Build/Launch。
- [x] 与 Session v2 / Phase G 证据向后兼容；未经人工确认不得生成 `Validated`。
- [x] 对历史 evidence 仅做安全结构复核，不复制原始日志或个人信息。

### Task 6：Launch Rehearsal 基础与安全 Dummy Harness

**Files:** Create `common/src/Rehearsal/RehearsalRunner.psm1`、dummy fixtures/harness、测试；Modify dependency injection boundaries。

- [x] 将真实执行编排与可替换 process backend 分离；不允许把 dummy executable 写入正式 ExecutionPlan。
- [x] `--launch-rehearsal [--json]` 复用 Plan/Session/ProcessManager/PortManager/Observers，输出 `rehearsal=true`、`validationEligible=false`。
- [x] 实现单客户端正常初始化、安全停止、早退、初始化后崩溃、超时、PID identity mismatch。
- [x] 所有 stop 验证仅触及任务创建且身份一致的进程树；验证 harness 退出后无遗留进程。

### Task 7：Dedicated、IntegratedLAN、端口与内存演练

**Files:** Modify Rehearsal/PortManager/RunManager；Create loopback TCP server/client harness 与测试。

- [x] Dedicated dummy 仅绑定 `127.0.0.1` 的随机/指定端口，输出 ready，接收安全 stop，关闭 socket 并验证端口释放；不触发 EULA。
- [x] IntegratedLAN dummy host 发布 port，clients 只在 host ready 后启动；Dedicated clients 只在 server ready 后启动。Host/Server 退出时阻止后续 guest 启动；异常出口完整性仍需覆盖。
- [x] 保留部分失败真实状态；不得伪报 Completed。Dedicated 第二个 Client 与 IntegratedLAN 第二个 Guest 注入失败均留下准确的进程退出状态并将 Session 标为 Failed；认证场景仍可为 `AUTH_REQUIRED`。
- [x] 压测 PortManager 并发自动端口及 late allocation/retry，检验冲突、TOCTOU 和全部退出清理；正式 Dedicated 启动路径也已接入限次 Auto port retry，固定端口不自动改号。
- [x] 以显式物理内存测试 Single、IntegratedLAN、Dedicated+clients 与 80% RAM 上限；Dedicated/IntegratedLAN 验证每角色使用独立 runtime directory。

### Task 8：配置、构建产物、extraMods 与窗口布局审计

**Files:** Modify config/schema/Doctor/ExecutionPlan、artifact validation、WindowLayout；新增相应测试与配置审计文档。

- [x] 逐项审计附件列出的 20+ 配置字段；每项标记 consumed、带文档的 metadata 或 deprecated-with-compatibility；无消费者时提供稳定 warning code。
- [x] 验证 JVM/game args 真实到达 dummy；`options.txt guiScale` 只有存在消费者才记录生效，否则 Doctor 告警。
- [x] 用 fixture JAR 测 `extraMods` copy、重复拒绝、hash、路径 containment；形成 Session-local hash manifest，不记录来源绝对路径。
- [x] Validation build evidence 记录 source fingerprint，源码在构建期间变化或产物 hash/time 未刷新时拒绝 `BUILD_VERIFIED`，并保留 `ARTIFACT_STALE` / `BUILD_SOURCE_CHANGED_DURING_RUN` 证据。
- [x] linkedProjects 检查顺序、artifact、注入及失败取消；清理构建产物信任与 dirty source 的剩余审计。
- [x] Tile/Cascade/Auto/None 全部 dummy/mock；窗口管理只作用于已登记进程树。

### Task 9：macOS ProcessManagement 和 WSL 能力重审

**Files:** 如满足合同才修改 `macos/src/MacOS.Process.psm1`、provider、tests、architecture docs；否则保持状态并写清具体缺失项。

- [ ] 从实际 provider、ARM64/Intel CI、stop semantics、PID reuse 逐条件审查 Native 合同；不得只因本地模拟通过而声明支持。
- [x] WSL 只读发现 Linux JDK 与能力；无 JDK 时不安装/下载/sudo，标为明确限制。
- [x] GUI client 维持 LIMITED；WSLg 不代表真实 Ubuntu Desktop 实机验证。

### Task 10：Human Validation Plan 与本地验证包

**Files:** Create `common/src/Validation/HumanValidationPlan.psm1`、测试、`docs/human-validation.md`；local-only `HANDOVER/manual-validation/*`（不进入 Git）。

- [x] 实现只读 `--human-validation-plan [--json]`，不启动任何进程；按工具链覆盖、依赖简单度、LaunchCheck、历史证据、build 稳定性选首批项目。
- [x] 矩阵覆盖 Forge/Fabric/NeoForge Single；按 Tier1/2→Tier3 Dedicated→Tier4 IntegratedLAN 顺序，未完成 Single 时不得建议 Tier3/4。
- [x] 11 步用户 checklist 每项包含 Doctor、LaunchCheck、build/artifact、命令、预期窗口/marker、用户视觉确认、Safe Stop、Session Info/Validate、证据结果。
- [x] 生成 local-only checklist/matrix/status/helper；helper 默认只显示 help/plan，显式 Launch 才可将来运行；本任务只调用 help/plan/preflight。
- [x] 明确未来证据包括 Session v2、plan digest、artifact hash、binding、process identity、observed Java、events、crash/stop；用户无需自行搜索 latest.log。
- [x] 可选 `--confirm-observation <SessionID> <code>` 未纳入必需范围；本轮不依赖该可选命令。

### Task 11：Phase O TODO、CLI、文档与跨平台声明审计

**Files:** Modify `README.md`、`docs/*`、CLI help/errors/comments、tests 和必要平台 docs。

- [x] 扫描 TODO/FIXME/NotImplemented/Unsupported/future/Phase 并分类 A-E；实现前置 A 清零，其余项明确 owner/限制/未来范围。
- [x] 对比实际参数解析、help、JSON purity、退出码，移除幽灵命令或补齐实现。
- [x] 中文化新增/改动的 CLI、注释、错误及文档；commit message 将在 Task 13 使用中文。同步 README、architecture、runtime/session 与验证文档。
- [x] 复核 common→OS 和 OS→sibling OS 架构边界无泄漏。

### Task 12：10 项目矩阵与全局回归

**Files:** 修改测试/CI 脚本仅在发现缺口时；生成验证数据只留本机。

- [x] 逐一运行 10 项 Project Discovery、Plan、Runtime Binding、LaunchCheck、默认 Windows `--validate`；每项目执行 MMTL real clean build，目标 10/10。
- [x] Pester 全集 397 passed、0 failed、2 skipped；Windows 全集 PASS。WSL Help/Capabilities PASS；Plan/Binding 可运行；Doctor/LaunchCheck 与 Java-backed Rehearsal 记录 Linux JDK 缺失阻塞；已通过 `/bin/sleep` fixture 验证登记进程 Observer 与安全停止。
- [ ] GitHub Actions required Windows、Ubuntu、macOS ARM64、macOS Intel 全绿；首轮 CI 暴露 macOS/Linux 跨平台测试缺陷及 Windows 合成 server 端口标记竞态，已修复并需等待新 CI 验证；不在 CI 启动 Minecraft GUI、真实 server 或依赖在线服务。
- [x] 任务前后只检查任务自有 process；不杀其他 Java/Gradle daemon；运行后核验无泄漏。

### Task 13：本地证据、PR、CI、合并与清理

**Files:** 仓库提交仅包含源码、测试、公开文档和 workflow；本地 `HANDOVER/MMTL_Phase_L_O_Pre_Human_Validation_Completion_Report.md` 脱敏保存。

- [x] 执行 public hygiene、secret/path/log 检查，确认 manual bundle、session/log、build output 未跟踪。
- [x] 验证 repo-local Git identity 为主账号 noreply；已使用中文 commit message；不改写历史或 force push。
- [ ] 推送唯一任务分支、创建 PR、等待 required CI；PR #6 已建立，首轮 CI 未通过；修复已本地验证，等待提交、推送和新 required CI。若独立 CodeOwner review 因唯一 CODEOWNER/作者限制失败，仅按附件许可记录并使用既有 always bypass，不改 ruleset。
- [ ] Merge 后同步并验证本地 main、origin/main、GitHub main 三方 SHA 相同；删除任务分支/worktree、prune。
- [ ] 编写本地完整 HANDOVER 与附件规定的 35 项最终状态报告；证据不能含本机敏感路径或原始日志。

### Task 14：最终硬停止与交接

- [ ] 逐条核验所有非人工门禁 PASS，限制项写出证据和阻断用户验证的原因。
- [ ] 确认未启动真实 Minecraft GUI、Dedicated、世界、认证或 EULA 流程；未运行人工 helper 的 Launch。
- [ ] 若任何“前置自动工作”仍失败，不宣布收口；修复或明确阻塞原因。仅当唯一剩余步骤是用户真实 Minecraft 行为观察时结束 Goal。

## 执行说明

- 严格按 Task 顺序执行；每个测试先写失败用例，再做最小实现并运行关联测试。
- 每一项平台支持升级都要求相应真实平台 CI 证据；没有证据时保留 Unsupported/Unknown 并记录限制。
- Goal 只能在 Phase L–O、10 项项目验证、CI、PR 合并、清理和 HANDOVER 全部完成后关闭。
