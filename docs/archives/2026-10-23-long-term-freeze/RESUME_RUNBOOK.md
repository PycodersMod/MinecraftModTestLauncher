# 长期暂停项目恢复流程

本档案默认保持暂停。任何项目只能在用户明确恢复后继续。

## MMTL 全版本兼容性

1. 读取此日期档案及私有备份清单，核验备份哈希与 Git bundle。
2. 对照当前远端和兼容性工作树提交，恢复未提交/未跟踪文件时先做差异审查。
3. 重新计算冻结 Universe、Family、Ledger、SourceSnapshot 与 Schema 计数和哈希。
4. 用一个精确 Loader × Minecraft 目标完成构建、真实客户端、Agent/游戏断言、报告和安全停止闭环。
5. 闭环通过并恢复授权后，再按技术族批量运行并保留逐目标失败证据。

## MMTL 模型研究

用户明确解冻后，恢复并审查 RFC、数据授权、场景/动作 Schema、模型边界和确定性验证协议。模型不能成为 Launcher/Agent 基础流程的必要条件。

## XLoader / XTranslator

项目必须分别解冻、分别建立计划和验收。XLoader 先验证原生 Mod 闭环；XTranslator 先审查来源许可与可复现用例。两者继续保持 Runtime 与离线转换工具职责分离。

## 证据原则

以 Git 对象、文件哈希、真实构建与游戏证据为准，不从聊天摘要补造缺失研究材料。历史状态不自动成为当前状态；未完成项保持 `PARTIAL` 或 `NOT_IMPLEMENTED`。
