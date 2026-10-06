# 离线本机多人安全模型

自动 IntegratedLAN 仅在 MMTL 管理的当前 Session 内运行。Host 与 Guest 使用独立、确定性的离线 Test Identity；Session token 通过受保护的会话文件传递，日志事件只包含 nonce hash。Forge 1.20.1 Agent 在完成 Session 校验后才允许该 Host 使用离线认证并发布 LAN。

自动 LAN listener 绑定 `127.0.0.1`，Guest 只连接同一台机器的 loopback 地址；不得广播到公网、连接第三方服务器或改变非 MMTL 管理实例的认证策略。停止操作仅作用于当前 Session 注册并通过进程身份复核的进程。

手动 Profile、其他 Loader 或缺少 Agent Provider 的项目不应推断具有上述自动化边界。看见 `Unsupported` 时，将它作为能力限制记录。
