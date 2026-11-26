# MMTL 临时测试与运行数据摘要（2026-11-26）

本文是本地 MMTL 测试/缓存目录的脱敏归档摘要，保留清理前的证据类别与实际结果。它不包含本机绝对路径、玩家进程信息、世界存档、JAR/DLL、Minecraft 资产或第三方依赖。

## 范围与结论

清理前的临时数据分为全版本适配构建/运行输出、Forge 控制器多客户端会话、DualMod/TaCZ/Tetra 实验、Gradle/Minecraft 可再生成依赖与资源缓存，以及测试世界。此次归档只说明清理前保存了哪些结论，不代表兼容性 Goal 完成。

### MMTL 临时实验报告

对 64 份 report JSON 的原始尝试计数：**59 PASS、4 FAIL、1 PARTIAL**；另有 72 份 session JSON、106 个 JSONL 事件文件、889 个日志文件。失败记录包含客户端进程意外退出（2）、客户端就绪超时（1）、Guest 登录断开（1）。这些记录来自多轮混合实验，未按精确版本去重，不能解读为 64 个独立目标，也不能据此宣称全版本兼容。

### Forge 控制器运行报告

122 个 session 目录中有 115 份报告：**89 PASS、17 FAIL、2 PARTIAL、7 未分类**。失败阶段包括 Guest 就绪等待（8）、Guest 进入世界等待（7）及未记录阶段（2）；错误类别包括 Guest 登录断开（9）、Agent 客户端就绪超时（5）、Host 玩家加入超时（1）、世界加入超时（1）和 JSONL 文件共享冲突（1）。另识别出 117 个 MMTL 生成的测试世界目录。数据为尝试总数，未去重。

## 数据规模快照

首轮清理后尚存的三个数据集约为：兼容性/实验临时数据 34.301 GiB、运行时会话目录 2.795 GiB、验证环境 staging 0.790 GiB。专用 Gradle 用户缓存已在首轮清理时移除。上述数字是本地递归文件枚举的字节总量，适用于描述归档时快照。

临时数据中的主要文件类型约为 JAR 15.71 GiB、OGG 5.64 GiB、JSON 4.25 GiB、ZIP 2.33 GiB、MCA 世界区块 2.00 GiB、PNG 0.68 GiB。大量源码扩展名文件来自展开的工具/映射分发目录，不等于 MMTL 产品源码；产品代码应从下面列出的远端 Git refs 恢复。

## 可恢复代码 refs

- 全版本兼容性基础设施：[`PycodersMod/MinecraftModTestLauncher`](https://github.com/PycodersMod/MinecraftModTestLauncher)，分支 `codex/full-loader-version-compatibility`，审计时 HEAD `8a910ec9c6b8a24f490de0dfce5a895e41f9e046`。当前 Goal 仍为 PARTIAL；没有完成 1,631 项全真实实机验收。
- 历史暂停研究档案：同仓库分支 `codex/long-term-freeze-archive-20261023`，归档起点 `3ee4b1fd3bfd99e1a4feae4f703581423a4d660a`。
- TaCZ × Tetra 项目：[`PycodersMod/TaCZinTetra`](https://github.com/PycodersMod/TaCZinTetra)，`main` 审计时 HEAD `3e48445063e03b1e477a6874331c04201e67cf00`。
- Create/Tetra 手搓学项目：[`PycodersMod/CreateTetraHandcraft`](https://github.com/PycodersMod/CreateTetraHandcraft)，`main` 审计时 HEAD `16abcecb60ed7e2b66f2bb415e3f74a171bc0189`。

## 没有公开上传的内容

JAR、游戏资源、原始世界、运行时二进制和第三方依赖没有上传。原始日志中可能包含机器路径、测试身份和进程信息，因此只发布以上脱敏汇总。重要实验原始文本另行保存在本机忽略的私有证据包；该包不是 GitHub 备份，公开仓库不包含其内容。

## 历史状态说明

该归档是一次时间点快照。通过数量不能替代失败分析，也不构成任何 Loader × Minecraft 目标的完整兼容声明。
## 清理完成复核

2026-11-26 的最终本机复核确认，`mmtl-temp`、`mmtl-cleanup-staging`、`mmtl-forge-control-runtime` 与 `mmtl-gradle-home` 四个目标目录均已不存在。清理前的容量和测试统计仍作为历史快照保留；全版本适配状态仍为 PARTIAL。私有原始文本证据另存本地校验归档，未上传公开仓库；JAR、运行时、世界和第三方依赖未公开。