# Forge 1.20.1 Windows 纯代码控制基线

本目录提供 Minecraft Java Edition 1.20.1、Forge 47.4.23、Java 17、Windows x64 的本机测试控制程序。它通过 BAT/PowerShell 直接启动真实 Minecraft Java 客户端，不依赖第三方启动器界面；Host 通过 Forge Agent 进入隔离世界并开放 Integrated LAN，Guest 在主菜单就绪后由 Agent 自动加入。

## 验收状态

2026-10-22 后续三循环验收归档记录 **9/9 个正式游戏场景通过**：每轮依次运行默认单窗口、命令行双窗口、配置文件三窗口；多人场景确认 Host 与 Guest 进入同一 Integrated LAN 世界，稳定至少 10 秒后由交付 BAT 安全停止。更早一组正式九场景记录为 **8 PASS / 1 FAIL**，其约 31.204 秒登录超时保留为历史失败，不由后续 9/9 覆盖。后续成功说明该测试环境重复运行通过，但不能证明先前故障的根因是电脑问题，也不能证明不会再次间歇发生。详见 [验收证据摘要](evidence/acceptance-summary.md)。

因此，这是一份可复用的 **Forge 1.20.1 技术基线候选**，不是“多窗口稳定性已完全通过”的声明，也不代表其他 Minecraft 版本、Loader 或 Windows 电脑已验证。

## 首次运行前必须填写的配置

编辑 `config/forge-1.20.1-default.json`；运行双人或三人示例前，也要在相应 JSON 中填写同样的本机字段。严格 JSON 不支持注释，因此示例值保持为空，说明集中放在本节。

### `javaPath`

填写本机 **JDK 17 的 `java.exe` 完整路径**，不能只填 JDK 安装目录。例如格式为 `<JDK 17 安装目录>\bin\java.exe`。在终端运行 `java -version`，确认显示 Java 17；如果机器上有多个 Java，请填写对应 JDK 17 的实际 `java.exe`。

### `minecraftRoot`

填写 Minecraft Java Edition 游戏根目录。该目录应包含 `versions`、`assets`、`libraries` 等子目录。不要填写 `versions` 下的某个版本目录，也不要填写游戏 JAR 文件路径。

### `versionDirectory`

填写 `minecraftRoot/versions/` 下实际存在的 Forge 1.20.1 版本目录**名称**，例如安装器生成的 Forge 版本目录名；不要填写绝对路径或加入 `versions/` 前缀。目录中应有同名版本 JSON 与 Forge 启动所需文件。启动前控制器会检查版本清单、主类、Forge 版本号、客户端 JAR、Libraries 和 Assets。

### 其他路径与默认值

- `runtimeRoot` 与 `reportRoot` 中的相对路径都以本目录（`Start-MMTL.ps1` 所在目录）为基准；默认运行数据位于 `runtime/`，报告位于 `runtime/reports/`。
- `ConfigPath` 的相对路径也以本目录为基准，不依赖当前终端所在目录。
- `javaPath` 与 `minecraftRoot` 是本机外部路径，示例留空，必须按上文填写。`versionDirectory` 也必须填写，但只填目录名。
- `clientCount`、玩家名称、世界设置、内存值和 loopback LAN 默认值可按需调整。单窗口默认不开放 LAN；两个或更多客户端必须启用 LAN。
- 本目录的 `runtime/`、世界、Session、日志和报告均由 `.gitignore` 排除，不应提交。

## 环境要求

- Windows x64；必须安装 PowerShell 7。BAT 只调用 `pwsh.exe`；找不到时会提示安装要求并以非零退出码返回，不回退到 Windows PowerShell 5.1。
- 已安装可运行的 Java 17 JDK，并在配置中指定 `java.exe`。
- Minecraft Java Edition 1.20.1 和 Forge 47.4.23 已安装在 `minecraftRoot` 指定的游戏数据树中；启动控制器不会替用户下载 Minecraft/Forge。
- 游戏数据树中需要对应版本 JSON/JAR、Forge Libraries 与 Assets。
- 运行多客户端时要有足够内存；控制器会检查资源门禁并为每个客户端使用独立实例目录。

## 启动方式

### 双击交互入口

双击 `Start-MMTL.bat`，终端显示三项菜单：

1. **临时启动配置**：输入窗口数量和可选玩家名。直接回车接受默认玩家名；Java、Minecraft 根目录和 Forge 版本目录仍须先在默认配置文件中填写，或通过命令行传入。
2. **读取配置文件**：从 `config/` 选择配置，也可输入配置文件路径。
3. **默认快速启动**：一个离线测试玩家进入隔离世界，不发布 LAN。

配置优先级为：**显式 PowerShell 参数 > 配置文件 > 程序默认值**。

### 命令行启动

在本目录打开 PowerShell：

```powershell
./Start-MMTL.ps1 -ValidateOnly
./Start-MMTL.ps1 -ClientCount 2 -PlayerNames Dev,Dev_1
./Start-MMTL.ps1 -ConfigPath config/forge-1.20.1-three-client.json
```

也可以双击 BAT 后附加同样参数，例如 `Start-MMTL.bat -ClientCount 2 -PlayerNames Dev,Dev_1`。先用 `-ValidateOnly` 检查配置；缺少三个本机字段时会分别给出明确配置错误。

`clientCount=1` 启动一个真实客户端，不启动 Guest、不开放 LAN。`clientCount=2` 使用一个 Host 和一个 Guest；`clientCount=3` 使用一个 Host 和两个 Guest。玩家身份必须唯一。更大的数量受参数上限、内存与端口等资源门禁约束。

## 自动 LAN 流程

1. Host 客户端进入或创建 MMTL 隔离世界。
2. Forge Agent 调用游戏内 Integrated Server 能力发布本地 LAN，并报告实际监听端口。
3. 控制器核验 loopback listener 后启动 Guest 客户端。
4. Guest 在主菜单就绪后由 `AgentAfterMainMenu` 路径加入 Host；不要求用户点击菜单、输入地址或复制端口。
5. Agent 事件用于确认世界加入和 Host 观察到的玩家。报告记录联机断言、客户端进程和安全停止结果。

仅测试 MMTL 管理的本地离线身份与本地 loopback LAN。程序不读取 Microsoft/Mojang 凭据、不生成真实账号令牌、不连接第三方服务器，也不自动修改防火墙。

## 状态、停止、日志与报告

交互运行时，在控制台输入 `Q` 后回车会请求客户端正常关闭并保存世界；只有身份核验通过的受管进程才可被进程树回退停止。

非交互启动会输出 Session ID。使用同一个运行根目录查询或停止：

```powershell
./Start-MMTL.ps1 -StatusSessionId <SessionId>
./Start-MMTL.ps1 -StopSessionId <SessionId>
```

默认 Session、Agent 事件、客户端游戏目录、日志与报告保存在 `runtime/sessions/` 和 `runtime/reports/`。若配置了自定义 `runtimeRoot`，查询或停止时要传入相同的 `-RuntimeRoot`。

## Agent 构建和产物

`common/agent/` 保留 Forge Agent 源码、Gradle Wrapper、构建配置及随附的 Forge 1.20.1 Agent JAR。可在本目录运行：

```powershell
./common/agent/gradlew.bat -p ./common/agent clean stageMmtlAgent
```

该任务验证 Agent JAR 中的 Manifest、Mixin 配置与 Refmap，并生成匹配 SHA-256 的 Provider Manifest。请先审阅构建输出；不要将 `.gradle/`、`build/`、测试运行目录或用户游戏文件加入提交。

## 测试

安装 Pester 5 后，在本目录运行：

```powershell
./Invoke-BaselineTests.ps1
```

该入口先注册基线自带的 Windows 平台 Provider，再执行 `common/tests/` 与 `windows/tests/` 中的 Pester 测试。自动化测试不代替真实 Minecraft GUI/LAN 验收。

## 已知边界

- 当前只覆盖 Minecraft 1.20.1 + Forge 47.4.23 + Java 17 + Windows；不推断其他版本或 Loader 能力。
- 离线身份只用于 MMTL 本地测试；不支持在线账号认证。
- 双窗口/三窗口 LAN 需要真实客户端窗口、内存和可用 loopback 端口。
- 2026-10-22 较早九项验收中的三窗口登录超时作为历史失败保留；后续三循环 9/9 结果单独记录，不能推导出根因或零故障保证。
- 本目录不含 Minecraft/Forge 下载包、Libraries、Assets、用户存档、原始 Session 日志或 JDK。
