# MinecraftModTestLauncher（MMTL）

MMTL 是 Minecraft Java Edition 模组项目的跨平台 CLI、构建与运行准备工具。它识别 Gradle 模组项目，生成可复核的执行计划，检查 Build Java 和 Runtime Java，并管理隔离的测试 Session。

## 能力范围

| 平台 | 已提供能力 | 边界 |
|---|---|---|
| Windows | CLI、Gradle 构建、Windows 客户端运行准备、窗口与进程管理 | `LaunchReady` 只表示预检通过，不代表客户端实机验证 |
| Linux | CLI、Gradle 构建、Session 与进程管理 | 当前不声明 Minecraft GUI 启动能力 |
| macOS | CLI、Gradle 构建、Session 管理 | 窗口和进程管理能力仍为 `Unsupported`，直到 ARM64 与 Intel CI 验证完成 |

PowerShell 7 是 v2 的正式命令环境。Ubuntu、WSL/WSL2 和 GitHub Actions runner 都是验证环境信息，不是额外的产品平台。WSL 或托管 CI 的结果不能替代 Linux 桌面客户端实机验证。

## 常用命令

```powershell
./windows/launcher.ps1 --discover-projects <工作区或仓库> --json
./windows/launcher.ps1 --plan --json
./windows/launcher.ps1 --explain-java --json
./windows/launcher.ps1 --runtime-binding --json
./windows/launcher.ps1 --launch-check
./windows/launcher.ps1 --doctor --offline
./windows/launcher.ps1 --capabilities
./windows/launcher.ps1 --build
./windows/launcher.ps1 --coverage-report
./windows/launcher.ps1 --coverage-report --json
./windows/launcher.ps1 --coverage-gaps
./windows/launcher.ps1 --coverage-version 1.20.1
./windows/launcher.ps1 --observe-session <SessionID> --json
./windows/launcher.ps1 --session-events <SessionID> --json
```

`--catalog-offline` 与 `--loader-offline` 分别控制版本目录和 Loader 元数据的离线读取。覆盖报告表示候选与来源审计，不代表项目已构建或客户端已验证。Linux 和 macOS 分别使用 `linux/launcher.sh`、`macos/launcher.sh`。具体参数和输出见 [执行计划与 Launch Readiness](docs/execution-plan-session.md)。

## 安全与验证边界

- `--plan`、`--launch-check`、`--doctor` 和 `--capabilities` 用于读取配置、证据与环境状态，不会启动 Minecraft。
- Runtime Java binding 必须有可审计的 Adapter/Probe 证据；缺证据时保留 `Unknown`。
- `LaunchReady` 不等于 `CLIENT_LAUNCH_VERIFIED`。后者需要真实客户端达到规定的初始化标记。
- MMTL 不读取游戏账号凭据、不绕过认证、不自动接受 EULA，也不自动下载或安装 JDK。
- Doctor 只诊断，不安装软件、不登录、不改配置或 EULA。
- Dedicated Server 需要用户明确预先接受 EULA；本项目不会代为接受。

## 文档

- [v2 架构](docs/architecture-v2.md)
- [平台架构与能力](docs/platform-architecture.md)
- [Runtime Java Binding](docs/runtime-binding.md)
- [执行计划与 Launch Readiness](docs/execution-plan-session.md)
- [Session 生命周期与恢复](docs/session-lifecycle.md)
- [环境 Doctor](docs/doctor.md)
- [验证等级与证据](docs/validation.md)
- [运行时观察与事件](docs/runtime-observation.md)
- [人工实机验证计划](docs/human-validation.md)
- [配置与 Profile 字段审计](docs/config-profile-field-audit.md)
- [人工验证前发布门禁审计](docs/pre-human-validation-audit.md)
