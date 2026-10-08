# Runtime Java 元数据缺失阻塞证据实施计划

**目标：** 用冻结 Mojang manifest / version JSON 的精确哈希证据区分可实现能力与官方数据缺口，不猜 Java 主版本。

**设计：** [Runtime Java 元数据缺失的外部阻塞证据](../specs/2026-10-08-runtime-java-metadata-blocker-design.md)

## Task 1：先补 Ledger 行为测试

- [x] 以精确 manifest absence / version JSON `javaVersion` absence provenance 生成 External Blocker。
- [x] 缺字段、非 HTTPS、错误 ID、无效 SHA 或错 metadataStatus 时不得 ExternalBlocked。
- [x] 普通无证据 unknown 保持 PendingImplementation。

## Task 2：把校验过的来源证明传给 Ledger

- [x] Collector 为两类缺失写 provenance；只使用已 hash-verified 的本地 snapshot 状态。
- [x] Ledger 只在严格字段匹配时创建 `RuntimeJava=ExternallyBlocked` 和完整 blocker details。
- [x] 更新/验证 JSON schema 与 blocker evidence validator。

## Task 3：离线再生成和全量验证

- [x] 使用 `-Offline` 从冻结 snapshots 重建 runtime catalog、Universe requirement projection 与 Ledger。
- [x] 确认 RuntimeJava Pending 减少 138，其余目标与维度未被弱化，Universe source hash 不变。
- [x] 定向 Pester、官方 Windows 全量 Pester、Parser、`git diff --check`。
- [x] 更新本地 HANDOVER，提交本地 checkpoint；Goal 继续 active / PARTIAL，不推送 PR。
