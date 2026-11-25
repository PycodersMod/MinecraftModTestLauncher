# ModLoader 历史 MCP 后端候选目录设计

## 目的与范围

为全 Loader × 全 Minecraft Java 版本 Goal 建立第一份可审计的历史 MCP 后端候选注册表，精确区分“后端版本目录收录”与“项目探测、构建计划、实际构建、启动已验证”。本设计先覆盖 ModLoader 和 ModLoaderMP 的候选后端解析；它不缩减或替代 Goal 的全版本、全 Loader、Agent、四平台及最终门禁要求。

## 已核实事实

- 冻结 Universe hash 为 `c15c01a750f74971a1b322cd3d5c2366a2ac05394a3ad56563fde0f75764241c`，包含 1,631 个 Available exact targets，其中 ModLoader 42 个、ModLoaderMP 20 个。
- RetroMCP-Java v1.2 上游源码 tag 固定到 `ec16b2a8c5907429ac59f7ebe13f28c4cf8052bd`。官方 README 描述版本 setup/decompile、recompile/reobfuscation、自动下载游戏 JAR 和库；Wiki 描述 `recompile`、`start client`、`start server` 与 side-specific libraries。
- `https://mcphackers.org/versionsV3/versions.json` 的只读快照含 132 条，SHA-256 `0513d84d885acbfcca81e820410bac8c8dbca90aa73e1b7434bd3c9ddd3a61fa`。它与上述 62 个精确目标按 Loader ID 与 Minecraft ID 匹配后，列出 39 个候选 target pairs：ModLoader 23/42、ModLoaderMP 16/20。
- 版本元数据的 JAR 下载字段含 URL、size 和 SHA-1；客户端/服务端可来自不同主机。SHA-1 用于完整性比对，不代表来源可信。RetroMCP 会自动下载文件，因此此候选目录本身不能开放下载或执行。

## 设计

1. 在仓库内保存不可变的上游快照元数据和精确候选 target pairs，记录上游仓库、固定 commit、版本 Registry URL、原始字节长度、SHA-256 与抓取时间。快照更新必须显式执行并产生可审查 diff；正常解析不得联网。
2. 增加纯本地 resolver，输入 Loader、Minecraft ID 和 catalog，按 Ordinal 精确匹配，并返回 `CataloguedOnly`、`automaticDownloadAllowed=false`、`automaticExecutionAllowed=false` 与来源证据。它不能把候选升级成 BuildPlan 或 Supported capability。
3. 缺失 target 返回明确的 `NoBackendCandidate`，不回退到相邻 Minecraft 版本、不模糊匹配、不推导不兼容。后续经来源/许可证/工具链审计的 MCP profile 可增加为独立 backend；一个 backend 的覆盖不能外推给其它 target。
4. ModLoaderMP 保留独立 Loader ID 与 target pair；将来提供 Client/Server profile 时分别要求证据，不从客户端记录推导服务端。
5. 当前 Ledger 不因候选目录而改变，BuildPlan、BuildJava、BuildVerified、LaunchPlan、Agent 等仍由各自的可验证实现和证据决定。原版 JAR、未知历史二进制和 HTTP-only artifact 不进入自动执行路径。

## 验收条件

- Catalog schema 与 SHA-256 / commit 格式验证通过；重复或 malformed target pair 被拒绝。
- 已知 exact pair 解析到固定 backend 和证据；`ModLoader@1.6.2` 等缺失 pair 返回 `NoBackendCandidate`，不得被相邻版本接管。
- ModLoader 与 ModLoaderMP 不发生跨 Loader 匹配；所有解析结果仍拒绝自动下载和执行。
- 对冻结 Universe 的矩阵审计结果为 ModLoader 23/42、ModLoaderMP 16/20、合计 39 个候选 pair；检查纯本地完成且不访问网络。
- 无任何 Build/Launch/Agent 支持状态从本目录自动生成。

## 后续工作边界

这只是完整 Goal 中历史 MCP 后端审计的第一步。之后继续寻找可信且可许可的 Legacy MCP profiles 覆盖未匹配 target，研究并实现真实 build/launch/runtime 与 Agent 能力，完成 JarMod 独立 patch/input integrity/output isolation 设计，再执行全量测试、四平台 CI 和最终门禁。未完成项持续保留在 PARTIAL Ledger / checkpoint 中。
