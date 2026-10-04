# Phase G 深度验证矩阵实施计划

> **面向智能体执行者：**在现有 `codex/phase-g-deep-validation` worktree 中逐项实施本计划。保护用户数据，不得修改 Mod 业务源码。

**目标：**建立可审计、由证据驱动的验证框架，取得具有代表性的 Phase G 构建/运行证据，同时不降低信任或身份验证边界。

**架构：**在 `src/Validation/` 下添加职责明确的 PowerShell 模块，用于目标规划、安全执行、不可变运行证据、聚合和 CLI 分派。验证证据保存在 Runtime Root；本地 `HANDOVER/` 仅保存简要报告和矩阵快照。构建通过可信 Gradle Wrapper 和许可清单中的任务执行，并采用串行或低并发。

**技术栈：**PowerShell 7、Pester、JSON Schema Draft 7、GitHub Actions、Gradle Wrapper、GitHub CLI。

**规格：**用户提供的 Phase G 任务，附件 `58c691ad-179f-4fc2-8b9e-b78460b01c73`。

## Global Constraints

- Phase F 覆盖仍为 103 个官方版本 × 11 条 Loader/模式记录；不得根据目录或可用性推断真实构建结果。
- 不构建全部 1,133 种组合、不下载所有客户端发行包、不运行不可信历史二进制、不绕过身份验证，也不接受新的 EULA。
- 不修改用户 Mod 业务源码，也不删除 Gradle 缓存或用户构建产物。
- 仅运行明确指定的验证命令和可信/固定版本的官方 fixture；历史来源未知的二进制仍须阻止执行。
- 使用不可转移的证据区分 RESOLVED、BUILD_VERIFIED、SERVER_VERIFIED、CLIENT_LAUNCH_VERIFIED 和 INTEGRATION_VERIFIED。
- 保持 PR 必需 CI 轻量；深度验证仅手动/定期运行，并且只上传数量受限且已脱敏的证据。
- 不得提交本地运行证据、密钥、Minecraft 资源、个人绝对路径或最终本地 HANDOVER 报告。
- 使用本工作区已配置的主 GitHub/GCM 身份；不得更改其他工作区的账号选择。

## Review Focus

- 伪造或不完整的进程信号不得升级为 SERVER_VERIFIED；测试必须要求就绪标记、进程身份、监听端口和安全停止证据。
- 启动 Gradle 任务不得升级为 CLIENT_LAUNCH_VERIFIED；测试必须要求真实且能容忍版本/Loader 差异的初始化标记。
- 元数据字符串不得变成任意 Shell 命令；测试必须拒绝不可信 fixture 来源和未列入许可清单的任务。
- 中断或重复运行必须保留旧的不可变证据，并使用不同的运行 ID。
- 日志和报告在保存或上传前必须脱敏凭据并移除个人绝对路径。

---

### 任务 1：建立项目组合与平台基线

**文件：**不修改产品文件。只有模型建立后，才将本地发现写入 Phase G 交接报告草稿。

- [x] 确认 Phase F SHA、干净的 MMTL 基线、186 项 Pester 基线、必需 CI、十个仓库 worktree 和 GitHub 身份。
- [x] 对十个嵌套英文项目根目录分别运行 ProjectDetector/Adapter v2，并记录项目身份、Wrapper、工具链和 Java 要求。
- [x] 重新确认各 Mod 仓库跟踪的工作树干净后，串行运行 Windows `clean build`；只记录输出和产物哈希，不编辑源码。
- [x] 检查 WSL Ubuntu、Linux JDK 路径、本地 EULA 预先授权、启动器运行时/会话 API、全部 CI workflow 名称和 macOS runner 架构可用性。

### 任务 2：定义验证契约和 Schema

**文件：**
- 新建：`schemas/validation-matrix.schema.json`
- 如矩阵和不可变运行记录需要独立 Schema，则新建：`schemas/validation-evidence.schema.json`
- 新建：`src/Validation/Contracts.psm1`
- 测试：`tests/ValidationMatrix.Tests.ps1`、`tests/ValidationSchema.Tests.ps1`

- [ ] 定义稳定的目标/运行 ID、来源信任类别、验证级别、失败分类、平台标识、实测 Java、fixture 溯源信息、产物哈希、时间戳和证据路径。
- [ ] 验证必需字段，并禁止提出高于实际证据级别的声明。
- [ ] 添加 Schema 测试，覆盖有效记录、缺失/null 字段、不安全的信任升级、目标身份不匹配，以及可发布输出中的个人路径拦截。

### 任务 3：实现确定性规划与安全 Fixture 解析

**文件：**
- 新建：`src/Validation/ValidationPlan.psm1`
- 新建：`src/Validation/FixtureCatalog.psm1`
- 测试：`tests/ValidationPlan.Tests.ps1`、`tests/ValidationSafety.Tests.ps1`

- [ ] 生成 Tier 0 纯元数据范围和有界的 Tier 1/2/3 目标计划，不展开笛卡尔积。
- [ ] 只有来源、固定 commit/tag、许可证、信任级别、工具链和 Wrapper 许可任务均明确时，才解析官方 fixture manifest。
- [ ] 拒绝来源未知、可变/未固定来源、任意命令/任务、错误 Java、路径越界和历史二进制执行。
- [ ] 根据 Mojang Catalog 动态选择 CurrentStable 目标，并使用准确的 P0 锚点。

### 任务 4：实现不可变证据与矩阵聚合

**文件：**
- 新建：`src/Validation/ValidationEvidence.psm1`
- 新建：`src/Validation/ValidationMatrix.psm1`
- 测试：`tests/ValidationEvidence.Tests.ps1`、`tests/ValidationMatrix.Tests.ps1`

- [ ] 使用原子 JSON 写入，将每次执行写入新的 `RuntimeRoot/validation/<targetId>/<runId>/` 目录。
- [ ] 记录脱敏日志、来源溯源信息、实际工具链/Gradle/Java/平台、耗时、产物路径/大小/SHA-256、进程身份、标记和分类。
- [ ] 不得修改已完成的运行记录；保留历史，并聚合最新的可信运行结果。
- [ ] 添加测试，覆盖脱敏、哈希不匹配、证据不完整、重复运行、中断输出和导入的历史溯源信息。

### 任务 5：实现有界运行器、服务端/客户端标记和 CLI

**文件：**
- 新建：`src/Validation/ValidationRunner.psm1`
- 新建：`src/Validation/ValidationCli.psm1`
- 修改：`launcher.ps1`、`src/Architecture/Contracts.psm1`
- 测试：`tests/ValidationRunner.Tests.ps1`、`tests/ValidationCli.Tests.ps1`、`tests/ValidationSafety.Tests.ps1`

- [ ] 明确实现仅规划模式和执行模式、串行/低并发、单目标超时、进程身份跟踪、安全停止及带类型的失败分类。
- [ ] 构建验证要求退出码为 0，且存在预期产物和哈希；服务端验证要求就绪标记、匹配的运行进程、监听端口和安全停止；客户端验证要求经过研究确认的真实初始化标记。
- [ ] 添加 `--validation-plan`、显式的 `--validate-matrix`、`--validation-summary`、`--validation-version` 和 `--validation-loader`；普通 `--validate` 必须保持不执行操作。
- [ ] 不尝试 Microsoft 登录，不伪造会话，不自动接受 EULA，不终止无关 Java 进程，也不通过 Shell 传递元数据。

### 任务 6：取得有代表性的 Windows 证据

**文件：**运行证据放在 Git 之外；报告保存在本地 `HANDOVER/`。

- [ ] 完成十个项目的 Windows 构建审计，并对每个结果分类。
- [ ] 为 Forge 1.12.2、Forge 1.16.5/1.20.1、Fabric 1.16.5/1.20.1/1.21.1、NeoForge 1.20.1 过渡版/1.21.1、官方来源可靠的 Quilt 1.18.2/1.20.1/1.21.1，以及一个 CurrentStable 主流 Loader，构建可信官方或生成的 fixture。
- [ ] 复现并限制 NeoForge 1.21.1 在 Windows/WSL 上的行为；无输出达到 20 分钟时进行诊断，并将单个目标总时限控制在约 30 分钟。
- [ ] 仅使用已有授权的离线开发 Profile，尝试启动 Windows 客户端，覆盖两种不同主流 Loader；使用经过研究的标记并跟踪清理相关进程。
- [ ] 仅在当前预授权/配置允许时运行 Dedicated Server；否则记录 `SKIPPED_EULA_NOT_PREAUTHORIZED`。

### 任务 7：加入真实 Gradle 深度验证 CI 并取得 Linux/macOS 证据

**文件：**
- 新建：`.github/workflows/deep-validation.yml`
- 仅在必要时修改必需 workflow，并保持 PR 范围轻量
- 在 `docs/superpowers/plans` 中新建/修改 fixture manifest 与 CI fixture 定义

- [ ] 添加手动 `workflow_dispatch` 范围选择和低成本定期代表性覆盖；使用固定版本的官方 fixture、Gradle 缓存、有界产物保留期，以及脱敏的结果 JSON/日志。
- [ ] 在 Ubuntu 托管环境取得 Fabric 与 Forge/NeoForge 的真实 fixture 构建结果。
- [ ] 取得 macOS ARM64 上 Fabric/Quilt 类及 Forge/NeoForge 类构建，以及 macOS Intel 上现代 Loader 构建；准确分类本机平台/工具链相关失败。
- [ ] 在本地 WSL 中使用 JDK 绝对路径运行 Forge、Fabric、NeoForge 和 Quilt 代表性构建；不得修改全局 Java 环境。
- [ ] 不在托管 CI 或 WSL 上声称具备 GUI 验证结果。

### 任务 8：审计历史缺口并保护 Phase F 不变量

**文件：**只有权威证据支持纠正时，才修改 `src/Catalog/Providers/*`；同时更新相关测试和本地证据。

- [ ] 在有界次数内重试 Legacy Fabric 官方元数据/来源；如果仍不可用，保留 Provider 故障状态。
- [ ] 调查三个 `0.25w14craftmine.*-beta` 和 `47.1.82` NeoForge 缺口；只有精确官方证据才能重新映射或分类。
- [ ] 重新生成 1,133 条记录的覆盖审计，并验证原因/溯源/状态/信任不变量没有回退。
- [ ] 保持 LiteLoader HTTP 产物、Rift 二进制、ModLoader/ModLoaderMP 二进制和 JarMod 补丁执行的历史不安全边界。

### 任务 9：文档、最终报告、卫生扫描、提交、CI 与同步

**文件：**
- 修改：`README.md`、`docs/architecture-v2.md`
- 新建：`docs/validation.md`
- 仅本地：`HANDOVER/MMTL_Phase_G_Deep_Validation_Matrix_Report.md`、`HANDOVER/MMTL_Phase_G_Validation_Matrix.json`、`HANDOVER/MMTL_Phase_G_Validation_Gaps.json`

- [ ] 准确说明验证级别、规划/查询/执行命令、信任边界，以及 Phase E/F/G 的完成情况。
- [ ] 生成本地最终矩阵/缺口与项目组合/启动报告，不含账号数据或个人绝对路径。
- [ ] 运行完整 Pester（至少 186 项，不得减少）、定向 WSL 套件、Schema 检查、`git diff --check`、密钥/个人路径扫描和 Phase F 覆盖不变量。
- [ ] 按逻辑划分提交，推送功能分支并创建 PR；等待必需检查、修复 CI 失败，仅在必需检查全部通过后合并；随后核对本地/origin/GitHub `main` 一致及最终 CI。

## 执行说明

- 用户已明确提供设计范围与执行授权；按授权继续，不因日常实现选择而停下来请求确认。
- 功能分支为 `.worktrees/phase-g-deep-validation` 中的 `codex/phase-g-deep-validation`。
- 只有任务要求的证据下限、必需 CI、如实报告失败、安全边界和覆盖不回退门禁全部满足，Phase G 才能通过；否则报告有证据支持的阻塞项。
