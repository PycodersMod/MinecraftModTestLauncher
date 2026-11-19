# Forge 1.20.1 三客户端复刻与无截图自动化交接

> 脱敏说明：原始本机目录已替换为调用者提供的隔离路径变量；测试结果、技术决策和未完成事项保留。原始运行脚本与证据不包含在此公开副本中。


日期：2026-10-20（北京时间）
目的：保存早间成功场景、复刻结果、启动代码及后续不依赖 AI 识图/鼠标控制的 MMTL 自动化方案。

## 结论

- 早间测试确实已通过；原始报告已保存在 `evidence/morning-success-report.md`。
- 本轮用相同 Minecraft 1.20.1、Forge 47.4.23、JDK 17、三个离线玩家、角色权限目标及 PowerShell 直接启动方法再次复刻。60/60 个有效样本全部通过。
- 启动游戏、打开 LAN、让 Guest 加入、调整模式/权限和读取状态均未使用截图识别、鼠标或键盘模拟。通过命令行 quick play、本地 JVM Attach 探针和 IntegratedServer 状态读取完成。
- 本次 Windows 监听查询返回地址 `::`，Guest 实际连接地址为 `127.0.0.1`。Guest 回环连接通过，但监听器是否严格限于 loopback 未验证；不能把本次当作网络隔离证明。
- MMTL 已有托管世界创建、Integrated LAN 发布、签名 Agent 动作队列和命令发送能力，是无截图自动化的产品化基础；本次复测使用独立测试探针，并非 MMTL 正式 Session 全流程验收。

## 工作区及 Git 状态

- 项目：`MinecraftModTestLauncher`
- 本次写入前分支：`main`
- 本次写入前 HEAD：`3d47bef579d6e9a57252a7cae5e89eeb72d412b2`
- 已有未提交改动：`common/agent/src/main/java/org/pycodersmod/mmtl/agent/MmtlForgeAgent.java`、`common/tests/AgentLanReadiness.Tests.ps1`。本次未覆盖、暂存、提交或推送这些改动。
- Goal checkpoint 显示 1,631 目标 Goal 处于暂停。本次没有恢复 Goal 或运行精确目标适配批次。
- 完整复测临时目录：`the caller-provided isolated replay root`。本工作区保存报告、启动/探针代码及必要证据，不复制 16 MB 的测试世界存档。

## 早间成功测试基线

早间正式报告记录：Minecraft 1.20.1 / Forge 47.4.23 / JDK 17；`Dev` 创造、权限 2，`Dev_1` 创造、权限 0，`Dev_2` 生存、权限 0；LAN cheats=true；60/60 样本通过，约 2 分 55 秒。游戏目录没有第三方 Mod，且未读取 Microsoft/Mojang 登录凭据。原始报告见 [`evidence/morning-success-report.md`](evidence/morning-success-report.md)。

## 本次复刻结果

| 项目 | 结果 |
|---|---|
| Minecraft / Forge | 1.20.1 / 47.4.23 |
| Java | `%JAVA_HOME%\bin\java.exe`，Oracle JDK 17 |
| 启动入口 | 隔离目录中的 `launch.ps1`，直接调用 `java.exe`；未使用 PCL/HMCL/Prism |
| 世界 | `MMTLLAN`；早间成功存档的隔离副本，原存档未改动 |
| 玩家 | `Dev` Host；`Dev_1`、`Dev_2` Guest；本地离线身份 |
| 进程 | Host PID 2584；Dev_1 PID 55368；Dev_2 PID 34340，三个独立 Java 进程 |
| Mod | 三个实例的 `mods` 目录均为 0 个文件 |
| 最终模式/权限 | Dev：CREATIVE/2；Dev_1：CREATIVE/0；Dev_2：SURVIVAL/0 |
| LAN cheats | true |
| 观测 | 60/60 通过；首末样本间隔 5 分 32 秒；最低可用物理内存约 1,776 MB |
| 连线 | 两个 Guest 的 TCP 连接持续存在，Guest 连接地址为 127.0.0.1 |
| 安全停止 | 先关闭 Guests，再关闭 Host；三个窗口正常退出、世界区块保存、25565 端口释放 |

采样开销高于早间运行，因此 60 个样本耗时更长。首次 2 GiB 内存门槛在采样开始前触发，未写入样本，也未终止游戏；之后按 1 GiB 保护线执行正式采样，60 个样本全部通过。Host 探针在世界尚未加载时记录过一次玩家不存在的暂态错误，加载后正常产生 `SERVER_STATE`。首次 Attach 传入相对 JAR 路径失败；改用绝对路径后加载成功，Host 没有重启。

## 复刻启动顺序

本目录 `code/` 保存本次实际复测使用的 `launch.ps1` 和 Attach 探针。Host 使用 `--quickPlaySingleplayer MMTLLAN` 进入世界；Guest 使用 `--quickPlayMultiplayer 127.0.0.1:25565` 加入。

本次复测实际采用的命令顺序如下（PID 是本次运行值，重跑时应使用启动命令的实际输出）：

```powershell
$root = $env:MMTL_REPLAY_ROOT
$java = Join-Path $env:JAVA_HOME 'bin/java.exe'

# 1. Host 进入隔离测试世界
& "$root\launch.ps1" -PlayerName Dev -SingleplayerWorld MMTLLAN

# 2. Host 世界就绪后，附加本地测试探针：发布 Integrated LAN 并观测服务器状态
& $java --add-modules jdk.attach -cp "$root\local-control" AttachProbe `
  2584 "$root\local-control\local-probe-publish.jar" "$root\local-control|Dev"

# 3. 设置 LAN cheats 并核对 Host/Guest 权限
& $java --add-modules jdk.attach -cp "$root\local-control" AttachProbe `
  2584 "$root\local-control\set-cheats-agent.jar" "$root\local-control\cheats-state.json"
& $java --add-modules jdk.attach -cp "$root\local-control" AttachProbe `
  2584 "$root\local-control\set-cheat-permissions-agent.jar" "$root\local-control\cheat-permissions-state.json"

# 4. 两个 Guest 以独立进程和目录加入
& "$root\launch.ps1" -PlayerName Dev_1 -ServerAddress '127.0.0.1:25565'
& "$root\launch.ps1" -PlayerName Dev_2 -ServerAddress '127.0.0.1:25565'

# 5. 检查 Host SERVER_STATE、角色/权限、三个 PID、监听器与两条 Guest TCP 连接
#    60 条正式样本见 evidence/replay/three-client-60s-monitor-valid.jsonl

# 6. 依次正常关闭两个 Guest 和 Host，等待世界保存、进程退出与端口释放
```

从 ZIP 重跑时，将解压后的 `code/` 作为 `$root`。需先建立 `instances/Dev/saves` 和三个隔离玩家目录，并把 `MMTLLAN` 世界副本及 `options.txt` 放入相应位置。JDK、Forge 版本文件、Minecraft libraries/assets 需在本机已存在；ZIP 不包含游戏资产或世界存档。`launch.ps1` 拒绝带有非空 `mods` 目录的实例。可复用的逐样本检查脚本为 `code/Monitor-60Samples.ps1`；它另外记录监听地址，wildcard bind 会显示 `listenerLoopbackOnly=false`。

## 无截图、无 AI 控制的实现方向

### 本次已实证的控制方式

1. PowerShell 直接调用 `java.exe`，通过 quick play 参数进入 Host 世界及 Guest 服务器；游戏 GUI 仍作为普通窗口显示。
2. 本地测试探针调用 Host 的 IntegratedServer `publishServer` API 发布 LAN；没有识别或点击“开放到局域网”按钮。
3. Host 侧服务器探针读取真实玩家、模式和权限；独立 TCP 与 PID 检查验证访客连接和进程状态。
4. 日志和逐样本 JSONL 是机器可读证据。整个控制闭环没有依赖截图理解或屏幕坐标。

这证明控制可由确定性的本地程序完成。本次探针通过 JVM Attach API 注入，并反射访问 Minecraft 1.20.1/Forge 47.4.23 的混淆方法名；它只适合作为 spike，不是客户发行组件。

### MMTL 当前可复用的产品代码

- `common/agent/.../MmtlForgeClientEvents.java`：托管 Host 可以程序化建立世界、写入名称/模式/难度/seed/cheats，并通过 `publishServer` API 发布 Integrated LAN。
- `common/agent/.../mixin/IntegratedServerLoopbackMixin.java`：受控发布可应用 loopback bind 策略并抑制 LAN multicast discovery。
- `common/agent/.../ManagedAgentActionProcessor.java`：消费 Session 内签名动作队列，通过已连接玩家的命令通道发送命令；截图只是可选动作。
- `common/src/Agent/AgentActions.psm1` 与 `common/src/Scenario/ScenarioOrchestrator.psm1`：检查 Session、PID 和角色，生成 HMAC 签名动作并等待 Agent 事件。`SEND_COMMAND` 需要显式授权，并拒绝多行及 `stop/op/deop/save-all/whitelist/ban/pardon` 等高风险命令。
- Agent 在没有有效 Session handshake 时不会控制普通游戏。Dedicated Server Agent 角色当前未声明支持。

### 尚未完成的产品化闭环

- 本次成功复刻没有通过 MMTL `--run-scenario` 正式 Session；前次错误配置指向 Facade，Host 在 Facade 配置初始化时报错。该失败不等于此次三客户端复刻失败，也不能反向证明 MMTL 正式 Session 已通过。
- 当前 `SEND_COMMAND` 的 `ACTION_COMPLETED` 表示命令已从客户端发出，不等于服务端已执行或游戏效果断言已通过；还需服务器侧状态读取和明确断言。
- `clientPermissionLevel` 目前是计划元数据，不会自动配置 OP 级别；安全策略又禁止原始 `op/deop` 命令。建议添加受限的结构化权限动作，绑定已管理玩家、允许级别、Host 角色和 Session，而不是放开任意管理命令。
- Integrated LAN Host 没有独立 RCON 控制台，应由可信 Host Agent 调用 IntegratedServer API/服务器 command dispatcher。Dedicated Server 可以使用受管标准输入，或 loopback 绑定的临时 RCON；两条路径需分开建模。
- 本次纯 Forge 复测查询到监听地址 `::`。产品“本机测试”必须实际验证 Agent loopback Mixin 的监听地址，不能只以访客从 `127.0.0.1` 连入作为网络隔离证明。
- Forge Agent Provider 当前声明 Forge 1.20.1。全版本扩展需要按真实 API/Loader/Mapping 技术族移植 Provider 能力；不支持的版本要明确 `Unsupported`，不能回退到截图机器人或猜测兼容。

### 建议实现顺序

1. 用干净 Forge 测试夹具验证正式 MMTL Session：自动建世界、loopback 发布、Guest quick play 加入、机器可读玩家/端口状态、正常停止。
2. 将原始命令升级为受限结构化动作：`CreateWorld`、`PublishLoopbackLan`、`SetGameMode`、`SetTestPermissionLevel`、`JoinHost`、`ReadWorldState`、`SafeStop`；只有观察到服务器端效果后才记录完成。
3. 在 Forge 1.20.1 完成不使用截图的真实端到端回归，包含角色权限、跨玩家共享状态断言、存档和端口释放。
4. 按 Loader/技术族迁移 Provider，逐个跑精确版本冒烟，再执行批次矩阵；能力逐项声明，不支持时 fail closed。
5. Dedicated 与 Integrated LAN 分开实现；历史版本缺少 Integrated LAN 时，使用受控本机 Dedicated Server 命令通道并标记历史等价路径。

本轮完成方法实证、已有代码核查与可恢复交接，没有修改 MMTL 产品源代码，也没有开始全版本适配实现。

## 证据文件

- 早间成功报告：`evidence/morning-success-report.md`
- 本轮逐样本 JSONL：`evidence/replay/three-client-60s-monitor-valid.jsonl`
- Host 自动观测事件：`evidence/replay/Dev-retest2-publish-probe.jsonl`
- cheats/权限读回：`evidence/replay/cheats-state.json`、`evidence/replay/cheat-permissions-state.json`
- 三玩家游戏日志、Java 标准输出与错误输出：`evidence/replay/players/`
- 最终运行摘要：`evidence/replay/execution-summary.json`
- 启动代码及 Attach 探针源码/JAR：`code/`
- MMTL 产品源快照：`product-code-snapshot/`
