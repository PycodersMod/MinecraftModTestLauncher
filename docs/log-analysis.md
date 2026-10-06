# 日志收集与 Mod-aware 分析

MMTL 保留原始日志，并将 Host、Guest、Client、Server、Build、Agent、Runtime 与 Scenario 记录整理为结构化事件。分析器依项目 ID、入口类、package、Mixin 与 artifact 元数据评估异常归属，并生成 findings JSON、摘要 Markdown 与相关日志片段。

匿名依赖栈、Loader 错误与 MMTL Agent/Session IPC 问题不应自动归因给当前 Mod。归属置信度可能为 `Direct`、`Indirect` 或 `Unknown`；报告保留证据与可能的下一步检查。

规则分析只表示 Profile 能观察到的启动、加入和生命周期信号，不代表 Mod 功能全面正确。导出分享前检查原始日志是否含本机路径、玩家名或其它隐私内容。
