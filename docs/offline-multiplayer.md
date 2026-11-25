# 离线本机多人安全模型

自动 IntegratedLAN 仅在 MMTL 管理的当前 Session 内运行。Host 与 Guest 使用独立、确定性的本地离线 Test Identity。Session nonce 只用于校验 Agent 事件归属；它不是 Minecraft 登录令牌，不得读取、导入、传递或保存 Microsoft/Mojang 凭据、账号令牌或官方启动器认证缓存。离线身份生成成功本身不代表该版本已能联机，必须按精确 Minecraft / Loader 目标验证 Host 发布、Guest 加入和共享世界断言。

Forge 1.20.1 Agent 的受控 LAN 能力只有在精确 manifest、Session 身份和运行事件都通过验证时才可使用。缺少 Agent capability、离线身份不被目标版本接受或 LAN 事件不足时，应记录该精确目标的能力限制；不得将其改写为要求用户提供在线账号，也不得静默切换认证路径。

自动 LAN listener 绑定 `127.0.0.1`，Guest 只连接同一台机器的 loopback 地址；不得广播到公网、连接第三方服务器或改变非 MMTL 管理实例的认证策略。停止操作仅作用于当前 Session 注册并通过进程身份复核的进程。

手动 Profile、其他 Loader 或缺少 Agent Provider 的项目不应推断具有上述自动化边界。看见 `Unsupported` 时，将它作为能力限制记录。1.3.1 之前的版本不具备现代原版 Integrated LAN 路径；只有精确可信 Catalog 中存在 Loader-ready 本机服务端制品并通过历史路径门禁时，才可报告 `HistoricalDedicatedEquivalent`。它不能标记为 `NativeIntegratedLAN=PASS`。没有 Loader-ready 固定制品时必须失败关闭，不隐式下载或运行原版基础服务端。
