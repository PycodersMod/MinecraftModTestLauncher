# MMTL Forge 控制程序（Windows）

当前产品化目标固定为 Minecraft 1.20.1、Forge 47.4.23、Java 17。启动器直接调用 Java，不依赖第三方 Minecraft 启动器。每个测试客户端使用独立的本地离线身份和游戏目录；不会读取 Microsoft 凭据或连接公网服务器。

## 双击启动

双击 `Start-MMTL.bat`，然后选择：

1. 临时配置：输入客户端数量及可选玩家名称；直接回车采用建议默认值。
2. 已有配置：从 `config` 下选择配置文件。
3. 默认快速启动：单窗口进入隔离测试世界，不开放 LAN。

现有配置包含单窗口默认项、双窗口和三窗口示例。多客户端默认使用首位玩家作为 Host，其余为 Guest；通过受控 Forge Agent 自动进入同一世界并发布回环 LAN。

Guest 默认等待 Minecraft 主菜单可用后，由 MMTL Forge Agent 调用游戏内连接 API 接入 Host 的回环 LAN。为对照诊断保留 `guestConnectionMode: "QuickPlay"`；该模式让 Minecraft 启动参数立即执行 QuickPlay，不建议用于稳定性验收。也可通过 `-GuestConnectionMode AgentAfterMainMenu` 或 `-GuestConnectionMode QuickPlay` 临时覆盖配置。

需要排查 Forge 登录握手时，可在配置中显式设置 `guestHandshakeDiagnostics: true`。该选项默认关闭，只让受管 Guest 将每个入站握手处理器及消息序号追加到该 Session 的 Agent JSONL；不会记录令牌，也不改变连接时序或超时。

## 命令行

PowerShell 可非交互式启动：

```powershell
pwsh -File .\windows\Start-MMTL.ps1 -ConfigPath .\windows\config\forge-1.20.1-three-client.json -NonInteractive
```

配置文件可通过 `ClientCount`、`PlayerNames`、`MinecraftRoot`、`JavaPath`、`MemoryMb`、`InstanceRoot`、`WorldName`、`LanEnabled`、`ReportRoot` 设置。显式 PowerShell 参数优先于配置文件，配置文件优先于内置默认值。

Forge 控制配置还可显式设置 `externalModJars`，值为 Mod JAR 路径数组。相对路径以所选配置文件所在目录为基准。MMTL 会将每个 JAR 安全复制到各测试玩家独立实例，并在 Session 的 `artifacts/mods-<Role>-<Player>.json` 记录文件名、大小和 SHA-256；不会把来源绝对路径写进该清单。默认配置为空，不会额外加载 Mod。

需要运行受控 Mod 测试自动化时，可在配置中提供 `testJvmProperties` JSON 对象；MMTL 会将每项转换为独立 Java `-Dname=value` 参数。参数名和标量值会校验，`mmtl.agent.*` Session 安全属性保留给控制器，不能从配置覆盖。此字段会随 Session 配置记录；不要放入令牌、密码或其他秘密。

控制已创建的 Session：

```powershell
pwsh -File .\windows\Start-MMTL.ps1 -StatusSessionId <SessionId>
pwsh -File .\windows\Start-MMTL.ps1 -StopSessionId <SessionId>
```

Session、PID 身份、Agent 事件、日志和 JSON/Markdown 报告默认保存在当前用户的 Local AppData 下 `MMTL/forge-control`。示例配置使用 `%JAVA_HOME%`、`%APPDATA%` 与 `%LOCALAPPDATA%`，不绑定某台电脑的安装路径；运行前需设置 `JAVA_HOME` 指向 JDK 17。停止操作先请求游戏窗口正常关闭并保存世界；超时后只对身份已核验的受管进程树执行回退停止。启动前会检查可用内存，LAN 使用事件报告的实际端口并验证回环监听。

这版不提供真实 Minecraft 账号认证，不连接外部多人服务器。`ClientCount=1` 时不启动 Guest、不开放 LAN；更高数量只表示请求的客户端数，仍受配置校验和可用内存门禁限制。
