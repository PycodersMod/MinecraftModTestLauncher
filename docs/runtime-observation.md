# 运行时观察与事件

MMTL 的运行时观察只读取指定 Session 已登记的进程、日志和状态文件。观察器不会重新解析项目或 Java，不会启动、停止或修复 Minecraft。

## 命令

```powershell
./windows/launcher.ps1 --observe-session <SessionID> [--timeout-seconds N] [--json]
./windows/launcher.ps1 --session-events <SessionID> [--json]
```

`--observe-session` 汇总已登记进程、客户端与服务器标记、认证分类、崩溃分类、LAN 端口、观察到的 Java 元数据及事件数量。`--session-events` 只读 `events.jsonl`。两条命令都不会运行项目发现、构建或 Minecraft。

`--json` 模式只输出 JSON 数据。只读观察不改变 Session 的验证等级；是否具备真实验证资格仍受进程身份、当前 Session 标记、计划中的 Java 路径和非演练状态共同约束。

## 事件契约

事件以 UTF-8 JSON Lines 追加在当前 Session 的 `events.jsonl`。每条记录包含 schema 版本、Session ID、角色、PID、进程身份、UTC 时间、来源类型、英文事件码、中文摘要和经过字段白名单过滤的元数据。追加时使用独占文件锁和重试；读取时可跳过格式错误的行。

观察器只使用 Session 登记的进程 PID 与启动身份，不按 `java.exe` 名称扫描系统。日志路径必须位于当前 Session RuntimeDirectory，链接和越界路径会被拒绝。摘要会清理常见令牌和本机用户目录；原始日志不写进事件。

## 客户端状态与证据

`CLIENT_INIT_DETECTED` 表示观察到 Loader 提供的客户端初始化标记；`CLIENT_MAIN_MENU_DETECTED` 是独立标记，不由初始化状态推断。早退、认证提示和崩溃分别分类。观察到初始化不代表用户确认窗口可见，也不代表已到达主菜单。

客户端验证候选要求当前 Session 登记身份有效、进程树中存在 Minecraft Java 主类、实际 Java 路径与 Execution Plan 一致、Session marker 匹配，并观察到初始化标记。演练进程始终不具备正式验证资格。观察器本身不把候选提升为人工已验证证据。

## 服务器、LAN 与 Java

Dedicated Server 观察只检查当前 Session 的 server 角色、ready 日志、loopback 端口和进程身份。LAN 观察只解析当前 Host RuntimeDirectory 的日志。认证观察只做错误分类，不读取账号凭据、不尝试登录或修复会话。

Java 观察只检查已登记进程树里的 Minecraft 客户端/服务器 Java 子进程。可读取 JDK `release` 元数据并记录可执行文件摘要；本地 `java.home` 和绝对路径不进入事件。演练 Java 结果标记为 synthetic。

## 安全边界

本命令不会启动真实 Minecraft、真实 Dedicated Server、GUI、世界或认证流程，也不会接受或修改 EULA。Dummy/Rehearsal 结果不能作为 `CLIENT_LAUNCH_VERIFIED`、`SERVER_VERIFIED` 或 `INTEGRATION_VERIFIED`。人工观察所需的 GUI 可见性、主菜单/世界交互、真实认证及用户授权仍须由用户本人完成。

## Launch Rehearsal

`--launch-rehearsal [--json]` 根据当前 Execution Plan 的模式运行合成流程：Single 使用 dummy client；Dedicated 先启动仅绑定 `127.0.0.1` 的 dummy server，Observer 确认 ready 与 listener 后才启动 clients；IntegratedLAN 先启动 dummy Host 并观察 LAN 端口，再启动 Guest。所有角色复用正式 Session、进程登记和 Observer；安全停止后检查 loopback 端口释放。

Rehearsal 不调用真实 Minecraft、Loader 或 Gradle，也不创建或修改 `eula.txt`。Session/evidence 固定标记 `rehearsal=true`、`validationEligible=false`。自动演练只能证明编排、进程生命周期、端口和 Observer 管线工作，不能作为真实客户端、服务器或联机验证。
