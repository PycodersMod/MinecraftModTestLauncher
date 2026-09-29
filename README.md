# MinecraftModTestLauncher

Minecraft Java Edition 模组开发环境多实例自动测试启动器（MMTL），面向 Windows 10/11。当前版本提供 Gradle 项目识别、配置校验、Java 路径解析、兼容性预检及 dry-run 命令预览。

## 当前实现状态

- 已实现 Forge、NeoForge、Fabric 项目元数据识别。
- 已实现配置读取、Profile 校验、Java 路径校验、Gradle Wrapper 命令预览和多项目基础兼容性检查。
- 已实现显式 `--build` clean/build 流程，输出和构建报告归入 LocalAppData Session，并记录 Git SHA 与构建 Jar SHA-256。
- Integrated LAN、Dedicated、真实 Minecraft 客户端启动、多实例进程编排、自动窗口平铺和完整 Session 管理尚未实现。当前程序会明确提示，不会假装启动成功。
- Integrated LAN 的目标是优先使用 Loader 能力；不具备可靠自动化时采用用户打开 LAN、启动器从日志检测端口的引导流程。屏幕坐标点击不在设计内。

## 使用

复制 `launcher.config.example.json` 为本地 `launcher.config.json`，配置所需 Java 主版本路径和 Mod 项目路径。运行 `launcher.cmd --validate` 检查配置与环境；运行 `launcher.cmd --dry-run` 查看计划命令；运行 `launcher.cmd --build` 显式构建项目；使用 `--list-sessions`、`--stop <Session ID>` 与 `--clean-session <Session ID>` 管理会话。缺少配置时会进入临时项目识别流程。

`--portable` 运行时路径预留为程序目录 `.runtime`；默认配置使用 `%LOCALAPPDATA%\MinecraftModTestLauncher`。当前 dry-run 不写入 Mod 项目或工作区日志。

## 安全边界

- 不包含账号登录、认证绕过、凭据采集或在线服务器连接逻辑。
- 删除 Session 时必须限制在 Runtime Root 内，并拒绝 junction/symlink 路径。
- 停止进程和世界重置尚未实现，因此不会调用 `taskkill`、结束通用 `java.exe` 或操作 `.minecraft\saves`。
- 本项目与 Minecraft 发布平台无关。

## 测试

```powershell
Invoke-Pester ./tests
```

## License

MIT License，详见 [LICENSE](./LICENSE)。
