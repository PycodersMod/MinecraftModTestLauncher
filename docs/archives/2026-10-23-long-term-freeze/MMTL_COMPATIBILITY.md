# MMTL 全 Loader / 全版本兼容性断点

日期：2026-10-23  
状态：`ARCHIVED_PAUSED`；全矩阵目标仍为 `PARTIAL`。

## 目标与现状

冻结 Universe 的目标规模为 **1,631 个精确 Loader × Minecraft 版本组合**。项目已有 Compatibility Universe、Family、Adapter/Provider、Runtime Java Catalog、精确 Ledger、来源快照、Schema、Runner 和测试设施。这些是兼容性基础设施，不是 1,631 项真实兼容验收结果。

GitHub `main` 的基础设施提交为 `a5ef212e585efa3c444fb7c5c4f3227067d4c31f`。PR #10 合并了全版本基础设施与数据；对应 Goal 尚未完成。暂停前的本地兼容性工作树包含未提交及未跟踪成果，已纳入私有恢复副本；它们不应被推断为已发布或 CI 验证。

## 不得推断为通过的项目

- 仅有 Universe、Family、Recipe、LaunchPlan 或 Adapter 声明。
- 仅有精确构建成功或 Runtime Java 解析。
- 仅有 Agent 就绪事件、模拟测试或单客户端启动。
- 未完成真实窗口、多人断言、报告或停止验证的目标。

各目标当前证据应以精确 Ledger 和 Evidence 为准。真实外部阻塞可标记阻塞，但内部缺少实现不能归因给上游。

## 恢复入口

恢复前核对来源提交、工作树快照、Universe/Family/Ledger Schema 与哈希；先验证一个精确目标的完整可重现闭环，再恢复 Family 批处理。具体验收维度、停止规则及环境要求见私有完整研究备份及项目当前文档。
