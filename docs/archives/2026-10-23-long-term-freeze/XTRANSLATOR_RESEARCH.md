# XTranslator 研究断点

日期：2026-10-23  
状态：`PAUSED_RESEARCH` / `NOT_IMPLEMENTED`。

XTranslator 是计划中的离线独立 Mod 转换工具：在来源可信且许可允许的范围内分析已知 Loader 的 Mod JAR，并尝试生成新的 XLoader 原生 Mod JAR。它不嵌入 XLoader Runtime。本项目目前没有可运行转换器、IR、转换规则、模型或成功转换证据；不能声称任意 JAR 可转换。

研究方向包括纯 JAR 可观察证据、用户授权的源码来源匹配、可追溯来源阶段、确定性构建和真实行为测试。未来应明确返回 `PARTIAL` 或 `UNSUPPORTED`，不应自动执行未审查的第三方构建脚本。具体方案仍须从私有研究资料恢复并重新核验。

恢复前需用户明确解冻，并审查输入许可、来源与威胁模型，先定义一个精确、可复现的转换用例。

独立项目文档位于组织仓库 `PycodersMod/XTranslator`；此链接不表示该项目已实现。
