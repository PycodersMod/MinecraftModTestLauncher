# Phase D — 主流 Loader Provider 与 Adapter Contract v2 实施计划

## 目标与约束

实现 Forge、Fabric、NeoForge 和 Quilt 的官方元数据发现、独立缓存与三态可用性；基于证据解析项目及 LoaderStack、Toolchain、BuildJava；提供安全的 CLI 发现、代表性项目/构建证据和四平台 fixture CI。保留 Phase C，不得把上游可用性升级为 MMTL 验证结论；探测期间不得运行安装器或项目 Gradle，不修改 Mod 源码，Phase E 延后处理。

## 基线

- 必须基于干净 `main` 上的基线：`bca5d12314f6a76ef2f92b1049f3809f6d1d4a2a`。
- Windows Pester 基线：84/84 PASS。
- 最终报告：仅本地保存于 `HANDOVER/MMTL_Phase_D_Mainstream_Loader_Providers_Report.md`。

## 任务

1. **Provider 契约与通用元数据传输**——加入可注入的 HTTPS 传输层，并按 Provider 限制主机许可清单；跟随重定向前先验证；安全解析 XML；原子写入缓存封装；支持 TTL、条件式元数据请求，以及明确的 Fresh/Stale/OfflineCache/Unavailable 状态。先添加契约、恶意 XML、重定向和缓存隔离 fixture。
2. **官方 Provider**——实现 Forge promotions 与 Maven 版本、Fabric v2 game/loader、Quilt v3 game/loader/detail，以及 NeoForge `neoforge` 和 1.20.1 过渡期 `forge` Maven 系列。保留上游顺序与字段，精确映射规范 Minecraft 版本 ID，并实现各 Provider 的首选策略。每个 Provider 都先写 fixture 测试。
3. **可用性索引**——组合 Phase C 版本目录与 Provider 的游戏/版本索引，避免 N×4 次详情请求。隔离 Provider 错误；区分 Available/Unavailable/Unknown，并提供 Schema/缓存溯源。测试部分失败、离线和过期缓存状态。
4. **Adapter v2 与项目解析**——建立统一的 Probe/Resolve/BuildPlan/ValidateCombination 输出；加入 QuiltLoom。只探测项目静态证据；冲突时保留 Ambiguous；选取证据最强的结果；区分 NeoForge 过渡产物；解析 Toolchain/BuildSystem/BuildJava 并记录依据。将 ProjectDetector 中的 Java 版本推断迁入经过审计的兼容性数据。
5. **CLI、fixture 与 CI**——加入 `--list-loaders`、`--loader-info`、Provider 状态与离线行为、Schema 和跨平台确定性测试；PR 任务不访问实时上游服务。保留所有既有测试与 Phase C CLI。
6. **实时数据与代表性验证**——针对官方端点运行指定 P0 矩阵；在 Windows 上解析/构建 SharecodeChest Forge 与 CarpetPlayerAddition Fabric；在 Windows 上验证 CreateProbabilityTuning NeoForge，并诊断受限的 WSL 卡顿；仅使用固定到 commit 的官方 Quilt fixture 执行解析/构建，随后清理它或将其放在仓库之外。
7. **文档、审查、提交、CI 与交接**——准确记录当前证据和边界，运行完整 Windows/WSL fixture 与隐私扫描，使用中文 Conventional Commit 标题提交并推送 `main`，等待 Windows/Ubuntu/macOS ARM64/Intel CI，核对远端 SHA，并生成仅本地保存的最终报告。只有每项任务门禁均通过，Phase D 才能标记 PASS；否则报告确切阻塞项。

## 验证规则

- 每个 fixture 契约都要先确认测试在实现前失败、实现后通过。
- 每个子系统完成后运行定向 Pester；最后运行完整 Windows 套件。Linux/macOS 确定性套件由 CI 运行。
- 验证离线测试不会发起 Provider 网络请求，PR CI 不依赖任何实时端点。
- 提交前运行 PowerShell AST 解析、`git diff --check`、密钥/路径/缓存扫描，并确认 Mod 树未变化。
- 四个必需 CI 任务全部成功且本地、origin、GitHub 的 `main` 一致前，不得宣称完成。
