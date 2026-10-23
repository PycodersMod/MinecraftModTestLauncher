# 长期暂停研究档案（2026-10-23）

**状态：`ARCHIVED_PAUSED`。** 本档案记录 MMTL 全 Loader/全版本兼容性、MMTL 可选模型研究、XLoader 与 XTranslator 的阶段状态和恢复条件。暂停不代表完成，也不代表当前具备档案中描述的未来能力。

这是一份依据该日期可复核的 GitHub 源码和本地研究盘点制作的脱敏摘要。它不包含本机路径、用户配置、原始 Session、游戏世界、私有 Mod/JAR、令牌或原始提示词。完整私有恢复资料保存在独立本地归档中，不会提交到本仓库。

## 档案内容

- [MMTL 全版本兼容性](MMTL_COMPATIBILITY.md)
- [MMTL 可选模型研究](MMTL_AI.md)
- [XLoader 研究断点](XLOADER_RESEARCH.md)
- [XTranslator 研究断点](XTRANSLATOR_RESEARCH.md)
- [恢复流程](RESUME_RUNBOOK.md)
- [来源与状态清单](SOURCE_MANIFEST.json)
- [SHA-256 校验值](SHA256SUMS.txt)

## GitHub 基线

- 目标仓库：`PycodersMod/MinecraftModTestLauncher`
- 归档所依据的 `main`：`a5ef212e585efa3c444fb7c5c4f3227067d4c31f`
- 全版本基础设施于 PR #10 合并；合并本身没有完成全矩阵兼容性验收。
- 近期 Forge 1.20.1 Windows 交付见仓库的独立基线目录；本归档只冻结后续研究状态。

## 状态解释

精确版本 Universe 中存在一个目标，不表示该目标已经构建、启动或通过真实游戏验证。任何恢复工作都必须读取当前 Ledger 和 Evidence，而不能把本归档的日期快照视作实时能力声明。
