# MMTL 平台架构、语言与 README 规范实施计划

> **执行说明：**按本计划逐项完成任务。步骤使用复选框（`- [ ]`）跟踪状态。

**Goal:** 按已批准的本任务书将 MMTL 拆分成严格单向依赖的平台目录，并完成 PycodersMod 中文规范、Mod README 链接/介绍纠偏及全量回归。

**Architecture:** 由 `windows/`、`linux/`、`macos/` 的薄 composition root 加载各自 provider 并注入 `common/`；common 不识别实现路径。组织治理仓库提供 README 目录链接审计与长期规范；10 个 Mod 保留原 Loader/Minecraft 工程布局，仅修改说明文字与发布介绍。

**技术栈：**PowerShell 7、Pester、PowerShell 语法解析器、GitHub Actions、Gradle Wrapper、GitHub CLI、PowerShell/.NET HTML/XML 解析。

**设计文档：**`docs/superpowers/specs/2026-10-04-mmtl-strict-platform-architecture-design.md`

## 全局约束

- Product platforms 固定为 Windows、Linux、macOS；WSL/Ubuntu 仅为 Linux validation metadata。
- 唯一允许依赖方向是每个 OS 层 → common；禁止 common → OS 和 OS → sibling OS。
- 公共路径使用 `$PSScriptRoot`、RepositoryRoot 和 repo-relative path；不得写机器绝对路径。
- 10 个 Mod 仅可修改 README/introduction/既有 changelog/说明文字，不改业务逻辑。
- 自然语言默认为中文；机器标识、第三方原文和发布 introduction 中按规范保留英文。
- 不改写历史 commit、privacy finding 或 GitHub rulesets；不 force push；所有本轮新提交标题/正文使用中文。
- 不开始 Phase H、不启动 Minecraft GUI、不发布 CurseForge/Modrinth、不重跑 Phase G。
- 保留 Pester 基线并达到至少 226 passed、0 failed；10 个 Mod 均完成 Windows clean build。

## 审查重点

- PowerShell 模块导入与 session registry 易受 `-Force` 重载影响；每个测试均显式注入 provider 并验证隔离。
- Windows/macOS 大小写语义与 Linux 路径边界不同；边界测试覆盖大小写、根目录自身、父目录前缀相似路径与路径分隔符。
- Markdown 内嵌 HTML 表格可能格式变化；README 测试覆盖缺失/重复表格、非法列、外链、路径穿越、缺目录和未解析模板表达式。
- macOS provider 能力当前有限；测试确认 unsupported 操作明确拒绝，不错误映射为 Linux/Windows 实现。
- 公共语言审计不能将 ASCII 技术名误判为英语句子；人工复核命中上下文并排除标识、第三方文本和协议内容。

---

### Task 1：冻结当前基线并增加目录链接回归门禁

**Files:**
- Create: `.github/scripts/Test-ModReadmeTargets.ps1`
- Create: `.github/tests/Test-ModReadmeTargets.Tests.ps1`（若 `.github` 当前无测试框架，则在脚本内提供可执行 fixture smoke，不增加依赖）
- 修改：`.github/docs/MOD_REPOSITORY_LAYOUT.md`
- Test: workspace 中 10 个 Mod README

**Interfaces:**
- Consumes: `-WorkspaceRoot <path>` 或 `-RepositoryRoot <path>`。
- Produces: 每仓库 target 链接、外链数、模板泄漏数、缺失/无效目标清单；错误时非零退出。

- [ ] **Step 1: 记录 12 个仓库初始 SHA、README link/template 计数和分支/worktree 状态**
- [ ] **Step 2: 建立解析良好与错误 README fixture，验证 audit 在缺表/错 href/外链/不存在目录/模板表达式时报错**
- [ ] **Step 3: 实现 README HTML 表格语义解析、路径安全检查、Loader 顺序及 release chronology 校验**
- [ ] **Step 4: 修订 MOD_REPOSITORY_LAYOUT 中文规则与正确/错误 href 示例**
- [ ] **Step 5: 对当前十个 README 跑 audit，输出 before 计数和逐仓 mapping**

### Task 2：纠正 10 个 Mod README 与 CurseForge introduction

**Files:**
- Modify: 10 个 Mod 根目录 `README.md`
- Modify: 10 个 Mod `introduction.md`
- Modify: 仅存在且由 first-party 编写的公开 changelog

**Interfaces:**
- Consumes: Task 1 audit contract；现有源码、工程元数据与公开说明。
- Produces: README 中文表格 `支持目标` + repo-relative target links；introduction 英文全文后接完整中文翻译。

- [ ] **Step 1: 在 10 个 README 中将 Loader/Minecraft href 改为本仓库目录，标题与构建说明中文化**
- [ ] **Step 2: 删除泄漏的 PowerShell 模板表达式与重复错误模板段**
- [ ] **Step 3: 依据各 Mod 已实现功能编写英文完整介绍与对应中文译文，不添加未实现特性**
- [ ] **Step 4: 检查现有 changelog；仅对真实存在的 first-party changelog 做英全文/中文全文整理**
- [ ] **Step 5: 对 10 个仓库运行自动链接审计与双语/隐私人工复核**

### Task 3：冻结组织级中文自然语言政策

**Files:**
- 新建：`.github/docs/REPOSITORY_LANGUAGE_POLICY.md`
- 修改：`.github/README.md`、`.github/CONTRIBUTING.md`、`.github/docs/*.md`、`.github/profile/README.md`
- Modify: 12 仓库 description（仅 first-party 自然语言描述）
- Modify: 12 仓库 tracked first-party docs/comments/help/workflow descriptions

**Interfaces:**
- Consumes: Task spec §44–60 与第三方/技术文本例外。
- Produces: 可供各仓库 `CONTRIBUTING` 引用的中文政策和逐仓人工审计结果。

- [ ] **Step 1: 扫描 12 个仓库 tracked 文件中的 first-party 自然语言注释、文档、help/error/log 和 workflow descriptions**
- [ ] **Step 2: 排除 License、第三方 NOTICE/vendor、上游元数据、协议和机器标识**
- [ ] **Step 3: 翻译确认属于 first-party 的英文自然语言，保持代码和运行语义不变**
- [ ] **Step 4: 建立并引用 REPOSITORY_LANGUAGE_POLICY.md，中文化 .github 与组织 profile**
- [ ] **Step 5: 中文化现存英文 repository descriptions；验证仅修改了公开 About 文本**

### Task 4：构建 MMTL 平台 contract 与 composition roots

**Files:**
- 新建：`common/src/Platform/PlatformContract.psm1`
- 新建：`windows/src/WindowsPlatformProvider.psm1`、`windows/launcher.ps1`、`windows/launcher.cmd`
- 新建：`linux/src/LinuxPlatformProvider.psm1`、`linux/launcher.ps1`、`linux/launcher.sh`
- 新建：`macos/src/MacOSPlatformProvider.psm1`、`macos/launcher.ps1`、`macos/launcher.sh`
- 修改：现有平台感知的 common 模块与平台专属模块
- 测试：新增的 common 和平台 provider 测试

**Interfaces:**
- 输入：各平台入口在加载 common core 前创建并注册对应 provider。
- 输出：`New-MmtlPlatformProvider`、`Set-MmtlPlatformProvider`、`Get-MmtlPlatformProvider`、`Get-MmtlPlatformContext`；通过回调传递平台操作，不允许 common 导入平台目录。

- [ ] **步骤 1：编写 provider contract 与注入隔离测试**
- [ ] **步骤 2：将 Windows/Linux 操作系统实现迁入各自目录，并创建独立的 macOS provider**
- [ ] **步骤 3：将身份检测、WSL 检测、本机路径行为、内存与进程 API 从 common 迁出**
- [ ] **步骤 4：重构 common 进程/runtime/Java/Gradle 流程，使其使用注入的操作与 capability 值**
- [ ] **步骤 5：添加三个精简入口/包装器，并验证按 RepositoryRoot 相对路径加载 common**

### Task 5：迁移 MMTL 工程树并适配测试、配置和文档

**Files:**
- 移动：根目录 `src/` → `common/src/`；common schemas/fixtures/config/tests → `common/`
- 移动：Windows 专属源码/测试 → `windows/`；Linux 专属源码/测试 → `linux/`；macOS 专属源码/测试 → `macos/`
- 移除：迁移后的引用验证通过后，移除根目录 launcher 实现与配置示例
- 修改：`.gitignore`、CI workflows、README、文档和测试导入路径
- 新建：架构边界与根布局 Pester 测试，以及中文平台架构文档

**Interfaces:**
- 输入：任务 4 的 provider contract。
- 输出：根目录仅保留平台目录、common、docs、.github 与仓库元数据；禁止 common 指向平台目录以及平台间相互引用。

- [ ] **步骤 1：添加先失败的根布局与依赖边界测试**
- [ ] **步骤 2：迁移 schemas、fixtures、configs、launchers、tests 和源码，不改变行为**
- [ ] **步骤 3：更新所有导入、CLI 示例、fixture 位置与 workflow 路径**
- [ ] **步骤 4：添加路径安全边界扫描、common 操作系统分支检查与跨平台重复实现审计**
- [ ] **步骤 5：更新文档，并将 MMTL 所有面向用户的 CLI/help/workflow 描述改为中文**
- [ ] **步骤 6：验证 MMTL 与 Linux 入口的 `--help`、安全的 `--validate`/`--dry-run`，以及 10/10 Project Discovery**

### Task 6：全量验证、提交同步与 HANDOVER

**Files:**
- 新建：仅本地保存的 `HANDOVER/PycodersMod_MMTL_Platform_Architecture_And_Language_Normalization_Report.md`
- 修改：按需修复任务范围内各仓库的测试/build/CI 问题

**Interfaces:**
- 输入：任务 1–5 的产物。
- 输出：经过验证的 12 仓库结果矩阵、四平台 CI 状态、已清理的分支/worktree，以及一致的 local/origin/GitHub `main` SHA。

- [ ] **步骤 1：运行 README 目标审计、双语介绍审计、语言/隐私扫描和仓库 ruleset 只读审计**
- [ ] **步骤 2：运行架构边界/根布局/重复实现测试与完整 MMTL Pester；要求至少 226 项通过且零失败**
- [ ] **步骤 3：为全部 10 个 Mod 运行 Windows clean build，并验证 Project Discovery 10/10**
- [ ] **步骤 4：以中文提交说明正常推送到 main，并等待 Windows、Ubuntu、macOS ARM64 与 macOS Intel 必需 CI 完成**
- [ ] **步骤 5：仅修复本任务引入的回归，重跑受影响检查，并确认没有改写历史或 force push**
- [ ] **步骤 6：移除临时分支/worktree，验证 12/12 分支/SHA/clean 状态，并按 §94 全字段编写本地 HANDOVER**

## 执行方式

按任务授权由当前执行者逐项实施；跨仓库步骤先完成一组、验证并普通推送，再继续下一组。禁止并行写入相互依赖的仓库状态。最终审计以 GitHub 当前 `main` 与 CI 运行结果为准。
