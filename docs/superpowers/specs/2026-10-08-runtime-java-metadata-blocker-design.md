# Runtime Java 元数据缺失的外部阻塞证据设计

## 目标

对冻结 Compatibility Universe 中没有官方 Runtime Java 主版本数据的 exact Minecraft IDs，区分“实现尚缺”与“官方上游没有可用字段”。只把可由冻结、校验过的 Mojang version manifest 或逐版本 JSON 证明的缺口标成 `ExternallyBlocked`；没有对应证据时仍为 `PendingImplementation`。

## 当前证据

- Runtime Java catalog 覆盖 974 个 distinct Minecraft IDs，其中 850 有 authoritative Java requirement、124 unknown。
- 108 个 unknown IDs 不在冻结 Mojang version manifest；108 个中有 Loader target 对 112 个。
- 16 个 IDs 在 manifest 中且对应逐版本 JSON 已校验，但 JSON 缺少 `javaVersion`；这些对应 26 个 Loader target。
- 合计 138 个 exact Loader×Minecraft target 的 RuntimeJava requirement 无可验证 Java 主版本。

## 约束

- 不从相邻版本、版本年代、其他 Loader 或非官方兼容表推断 Java major。
- Manifest absence 必须绑定 HTTPS Mojang manifest URL、manifest SHA-256 与 exact absent Minecraft ID。
- Per-version field absence 必须绑定 HTTPS Mojang version JSON URL、manifest SHA-1、snapshot SHA-256 与 exact Minecraft ID。
- 只有来源字段、hash 格式、metadataStatus、reasonCode 与 exact ID 完全匹配时，Ledger 才生成 `RuntimeJava=ExternallyBlocked`；所有其他 missing/invalid evidence 保持 Pending。
- Blocker detail 写入 dimension 的 `reasonCode/source/evidence/attemptedRemediation`，保留证据引用；不改变 frozen Universe catalogHash 或 Loader capability。
- 未知 Java requirement 继续 fail closed，不启动游戏；用户显式 override 的工作流保持独立。

## 验收

- Offline collector 为精确 absence 记录 provenance；manifest 与 version JSON 证据通过现有 snapshot/hash 验证。
- Ledger 测试覆盖两类外部阻塞、篡改来源/哈希时回退 Pending、普通未知项不变。
- 重新生成 Universe、runtime catalog 和 Ledger 后，RuntimeJava Pending 数减少 138，Unknown target 仍为 0，summary 一致。
- 定向与全量 Windows Pester、PowerShell parser、`git diff --check` 通过。
