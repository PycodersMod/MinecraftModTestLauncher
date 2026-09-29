# MinecraftModTestLauncher

Minecraft Java Edition 模组开发环境多实例测试启动器（MMTL），面向 Windows 10/11。支持 Forge、NeoForge、Fabric 的 Gradle 开发运行配置。

PowerShell 7 优先；未安装 PowerShell 7 时，批处理入口和 Gradle Runner 回退到 Windows PowerShell 5.1。

## 当前实现状态

- 已实现 Forge、NeoForge、Fabric 项目元数据识别、Java 主版本映射、Profile、兼容性预检和 build/run Gradle Wrapper 调用。
- 支持 Single、IntegratedLAN 引导式 Host/Client，以及 Dedicated Server 加本地客户端；多项目构建结果按 SHA-256 汇入独立 Session。
- IntegratedLAN 由用户在 Host 游戏中创建或打开世界并手动发布 LAN；Host 是否允许命令以游戏中创建/发布世界时的选项为准，启动器检测游戏日志端口后启动本地客户端，不模拟鼠标点击。
- Dedicated 默认拒绝启动。用户必须在本机 Profile 明确设置 `acceptEula: true`；Server 绑定 `127.0.0.1`，离线用户名只用于本地开发测试，不能连接需要正版认证的在线服务器。
- 每个 Session 保存运行目录、stdout/stderr、构建日志、进程登记和 Markdown 报告。停止操作只结束当前 Session 记录的进程树。
- 支持 Host、客户端、Dedicated Server 分别配置内存，并在启动前按同时运行进程的 Xmx 总和检查物理内存的 80% 上限；超限时拒绝启动。
- 首次运行或不传参数时提供交互向导和启动摘要。临时配置仅写入系统临时目录，持久配置 `launcher.config.json` 不纳入 Git。
- 客户端 Profile 可配置 `guiScale`（`Auto` 或 0 至 4）；启动时写入该玩家 Session 自己的 `options.txt`，不读取或修改 `%APPDATA%\.minecraft`。
- IntegratedLAN 开发客户端没有由 MMTL 获取的 Minecraft 认证会话；当前实机测试中的访客因 `Invalid session` 被拒绝。MMTL 不绕过身份验证，需先解决认证来源后才能把离线开发 Profile 用于 IntegratedLAN 多人连接。
- Windows 窗口布局只枚举本 Session 登记进程树中的 Minecraft 客户端；Auto 在多个客户端时平铺，Tile/Cascade 按配置排列，None 不调整。Reset World 仅能删除当前 Session 中指定玩家的世界，并拒绝越界或链接目录；跨 Session 导入/续玩、IntegratedLAN 自动创建世界暂未实现。

## 使用

复制 `launcher.config.example.json` 为本地 `launcher.config.json`，配置所需 Java 主版本路径和 Mod 项目路径。双击 `launcher.cmd` 进入菜单；命令行可用 `--validate`、`--dry-run`、`--build`、`--launch` 和 `--profile <名称>`。使用 `--list-sessions`、`--stop <Session ID>`、`--clean-session <Session ID>` 管理会话。

`--portable` 使用程序目录 `.runtime`；默认运行时使用 `%LOCALAPPDATA%\MinecraftModTestLauncher`。Fabric Loom 需要相对运行目录时，启动器会在项目忽略的 `.gradle` 下建立指向 Session Runtime 的临时目录联接，并在 Gradle 退出或停止会话后清除。

## 安全边界

- 不包含账号登录、认证绕过、凭据采集或在线服务器连接逻辑。
- 删除 Session 时必须限制在 Runtime Root 内，并拒绝 junction/symlink 路径。
- 不会调用 `taskkill /IM java.exe`、按进程名结束 Java 或操作 `.minecraft\saves`。Dedicated 客户端权限等级写入该 Session 的离线账号 `ops.json`；IntegratedLAN 客户端权限由 Host 在游戏中控制。
- 本项目与 Minecraft 发布平台无关。

## 测试

```powershell
Invoke-Pester ./tests
```

## License

MIT License，详见 [LICENSE](./LICENSE)。
