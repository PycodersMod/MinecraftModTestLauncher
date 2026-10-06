# Scenario 场景

MMTL Profile 支持 `Single`、`IntegratedLAN` 与 `Dedicated`。先用 `--scenario-plan --json` 检查角色与步骤，再执行 `--run-scenario`。每个非交互 Scenario 都有观察时长与 `stopPolicy=Always`，结束后由 MMTL 停止本 Session 登记的进程、导入日志并生成报告。

## Single

启动一个本地客户端，可使用新建隔离世界。它适用于启动、Mod 初始化与崩溃信号观察，不自动证明游戏内功能完整。

## IntegratedLAN

先启动 Agent 支持的 Host，等待当前 Session 的 world join 与 loopback 发布证据，再启动 Guest 并等待 Guest join。默认身份为离线 Test Identity，listener 限制在 `127.0.0.1`。没有匹配 Agent 的 Loader 不得声称自动多人测试通过。

## Dedicated

Dedicated 模式要求用户预先在本机配置中明确接受对应 Minecraft EULA。默认示例 `acceptEula=false`；MMTL 不会替用户写 EULA 文件或自动接受条款。

常用操作见 [离线本机多人安全模型](offline-multiplayer.md)。
