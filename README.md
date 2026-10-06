# Minecraft Mod Test Launcher（MMTL）

MMTL 是面向 Minecraft Java Edition Mod 开发者的**测试启动器与场景编排工具**。它不是普通玩家启动器。你可以导入任意 Gradle Mod 项目，让 MMTL 识别项目与 Java 要求、生成可复核的执行计划、构建 Mod，并在隔离的 Session 中运行和观察单客户端或本机多人测试。

## 能做什么

- 导入通用 Gradle Mod 项目并发现 Minecraft、Loader、Mod ID 与入口元数据。
- 分别解析构建 Java 与游戏 Runtime Java；证据不足时显示阻塞原因。
- 用隔离的离线 Test Identity 启动多个本地客户端，不读取 Microsoft/Minecraft 账号凭据。
- 编排 Single、IntegratedLAN 与 Dedicated Session，统一停止由当前 Session 登记的进程。
- 收集分角色日志，保留原始证据，并提供 Mod-aware 规则分析。
- 在支持的 Loader 版本上使用独立 MMTL Test Agent 做就绪观察与 loopback IntegratedLAN 自动化。

## 平台能力

| 平台 | CLI / Build | Minecraft GUI | 说明 |
|---|---|---|---|
| Windows x64 | Native | Native | 进程、窗口管理与真实客户端能力按版本和 Adapter 状态分别校验 |
| Linux x64 | Native | 当前不声明 | CLI、Build、Session 管理；不等同于 Linux Desktop GUI 实机验证 |
| macOS x64 / ARM64 | Native | 当前不声明 | CLI、Build、Session 管理；窗口管理尚不支持 |

“项目可识别”“可构建”“Launch Ready”“Agent 支持”和“实机验证通过”是不同状态，不能互相推断。当前 Agent 版本矩阵见 [Test Agent 与版本支持](docs/test-agent.md)，机器可读的 Public Alpha 能力声明见 [public-capabilities.json](common/config/public-capabilities.json)。

## 首次运行

安装 PowerShell 7 与适合项目的 JDK 后，在 MMTL 目录执行：

```powershell
./windows/launcher.ps1 --init
```

初始化会创建本机配置、Runtime、空项目 Registry 与 Single、IntegratedLAN、Dedicated 示例 Profile。默认示例是 IntegratedLAN：它使用 MMTL 离线 Test Identities，只允许当前机器的 loopback 联机。Dedicated 示例的 `acceptEula` 保持为 `false`，需要用户自行明确接受 EULA 后修改本机 Profile。

然后导入项目，并把示例 Profile 中的 `project` 改为该项目的实际路径：

```powershell
./windows/launcher.ps1 --import-project "<项目根目录>" --json
./windows/launcher.ps1 --plan --json --profile single-example
./windows/launcher.ps1 --launch-check --json --profile single-example
./windows/launcher.ps1 --build --profile single-example
```

先阅读 [项目导入](docs/project-import.md) 与 [场景执行](docs/scenarios.md)。Linux/macOS 使用对应的 `linux/launcher.sh`、`macos/launcher.sh`。

## 文档

- [项目导入与识别边界](docs/project-import.md)
- [离线测试身份](docs/test-identities.md)
- [Test Agent 与实际支持矩阵](docs/test-agent.md)
- [Single、IntegratedLAN、Dedicated 场景](docs/scenarios.md)
- [离线本机多人安全模型](docs/offline-multiplayer.md)
- [日志收集与 Mod-aware 分析](docs/log-analysis.md)
- [Public Alpha、初始化与分发包](docs/public-alpha.md)
- [Alpha 本地就绪检查](docs/alpha-readiness-checklist.md)
- [v2 架构](docs/architecture-v2.md)
- [执行计划、Java 与 Launch Readiness](docs/execution-plan-session.md)
- [Runtime Java Binding](docs/runtime-binding.md)
- [Session 生命周期与恢复](docs/session-lifecycle.md)
- [Doctor 与平台能力](docs/doctor.md)
- [验证等级与证据](docs/validation.md)
- [运行时观察与事件](docs/runtime-observation.md)
- [人工实机验证准备](docs/human-validation.md)
- [Profile 字段审计](docs/config-profile-field-audit.md)

## 安全边界

- MMTL 不登录账号、不请求或保存账号凭据、不绕过认证去连接外部服务器。
- MMTL 不自动接受 Dedicated Server EULA，不自动安装 JDK，也不会修改已导入的 Mod 项目源码。
- IntegratedLAN 自动化仅适用于 MMTL 管理的 Session、离线测试身份与 loopback listener。
- `Launch Ready` 或无日志异常不代表 Mod 的所有功能正确；结论必须按实际运行证据解释。
- WSL 与托管 CI 的结果不能替代 Linux 桌面客户端实机验证。

## 覆盖审计 CLI

仓库维护者可用以下只读命令查看版本与功能覆盖：

| 命令 | 用途 |
|---|---|
| `--coverage-report [--json]` | 显示正式版覆盖摘要；`--json` 输出完整报告。 |
| `--coverage-gaps` | 显示尚未解决的不变量与提供器缺口。 |
| `--coverage-version <id>` | 显示指定 Minecraft 正式版本的覆盖情况。 |

离线运行可分别使用 `--catalog-offline`（仅影响 Mojang 版本目录）和 `--loader-offline`（仅影响加载器元数据）；它们不会改变 Gradle 离线模式。

## 许可与版本

当前分发通道为 **Public Alpha 0.1.0-alpha.1**。Alpha 包只包含 allowlist 中的启动器、运行模块、平台脚本、Agent Provider、文档和示例；没有用户项目、用户配置、Session、游戏世界、日志、JDK 或 Minecraft Runtime。详见 [Alpha 分发说明](docs/public-alpha.md)。
