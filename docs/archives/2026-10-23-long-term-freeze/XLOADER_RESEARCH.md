# XLoader 研究断点

日期：2026-10-23  
状态：`PAUSED_RESEARCH` / `NOT_IMPLEMENTED`。

XLoader 是计划中的独立 Minecraft Mod Loader，目标是加载 XLoader 原生 Mod。它与 Mod 转换器 XTranslator 分离；XLoader 不负责把其他 Loader 的 Mod 自动转换为自身格式。

此前讨论的主题包括 bootstrap、Mod discovery、生命周期、依赖解析、ClassLoader 隔离、注册表、事件/网络、XAPI、XGameBridge 以及 Hook/Transformer/Mixin 边界。这些仅是待研究主题。没有查实可运行 Loader、正式 API、最小 Mod 或任何 Minecraft/Forge/Fabric/NeoForge 版本支持。

恢复前需用户明确解冻，重新检查 RFC 状态、研究来源与许可证，定义一个最小原生 Mod 的构建及真实运行验收。逐 Loader 的兼容支持必须由精确证据证明。

独立项目文档位于组织仓库 `PycodersMod/XLoader`；此链接不表示该项目已实现。
