# MinecraftModTestLauncher

Minecraft Java Edition 模组开发环境多实例测试启动器（MMTL），提供 Windows 游戏运行能力，以及 Linux/macOS CLI 与 Gradle 构建基础能力。阶段 D 为 Forge、Fabric、NeoForge、Quilt 提供官方上游元数据查询与项目适配器基础；上游可用性不代表 MMTL 构建、专用服务器、客户端或集成测试已经验证。

## 平台支持与验证环境

| 产品平台 | 当前能力边界 | 验证来源 |
|---|---|---|
| Windows | CLI、Gradle 构建与 Windows Minecraft 游戏运行 | 本地 Windows 和 Windows CI |
| Linux | CLI、Gradle 构建基础；Minecraft GUI 实机能力未声明 | Ubuntu GitHub-hosted CI、WSL2 本地 CLI/构建 |
| macOS | CLI、Gradle 构建基础；Minecraft GUI 实机能力未声明 | macOS ARM64 与 Intel GitHub-hosted CI |

`PlatformContext.OS` 的代码枚举值为 `Windows`、`Linux`、`MacOS`，面向用户的名称分别显示为 Windows、Linux、macOS；CPU 架构是独立字段。Ubuntu 是 Linux 发行版元数据，WSL/WSL2 是 Linux 运行环境元数据，GitHub Actions runner 是验证来源，三者都不是额外产品平台。WSL/WSLg 与 CI fixture 均不构成真实 Ubuntu 桌面环境或 Minecraft 图形客户端实机证据。

MMTL v2 的正式运行基线为 PowerShell 7。现有 Windows PowerShell 5.1 备用入口保留为旧版兼容前端（尽力兼容）；新增 v2 架构能力不保证与 5.1 完全兼容。

## v2 架构演进状态

**已实现（Phase A）：**集中架构契约、平台/架构身份、Capability 与 Validation Level、Artifact Trust、Loader/Toolchain/Build System identity、LoaderStack、BuildJava/RuntimeJava 需求模型、provenance、Compatibility Matrix v1、Exception Registry schema 与 Config v2 foundation。

**已实现（Phase B）：**Windows/Linux/macOS 平台 Provider 基础、平台 Runtime Root 与路径安全、按平台选择 Java 和 Gradle Wrapper、`windows/launcher.ps1`、`linux/launcher.sh` 和 `macos/launcher.sh`、Session 平台元数据、Linux `/proc` 进程身份和安全停止。Linux 与 macOS 的 `--help`、`--validate`、`--dry-run`、`--build` 不依赖 Windows 窗口或 Minecraft GUI；跨平台游戏启动尚不支持。

Ubuntu 托管 CI 覆盖 Linux 平台、路径、Java/Wrapper fixture 和 Linux 受控进程测试；macOS ARM64 与 Intel CI 覆盖平台和构建路径 fixture，并运行 macOS 入口。本机 WSL2 已验证 Linux CLI 与代表性 Mod 构建。WSL 构建证据不代表真实 Ubuntu Desktop、Minecraft GUI、IntegratedLAN 或 Dedicated Server 实机验证。上游 Loader 元数据可用性也不等于 MMTL 已完成对应版本/系统的构建、服务端或客户端验证。

## 当前实现状态

Phase C 增加 Mojang 官方 Version Manifest release Catalog，从 Java Edition 1.0 动态覆盖到 CurrentStable，并提供 24 小时缓存、惰性 version metadata、SHA-1 校验与 Runtime Java 来源解析。CLI 提供 --list-minecraft-versions、--minecraft-info <id|CurrentStable>、--refresh-catalog 与 --catalog-offline。CATALOGUED 只表示版本在 Mojang 目录中，不代表 Loader supported、Build verified、Dedicated Server verified 或 Client verified。Runtime Java metadata 不决定 Mod 工程的 Build Java，旧 JavaMajor 构建行为保留。

Phase D 的 loader metadata 独立缓存于 Runtime Root，CLI 默认只显示 Forge、Fabric、NeoForge、Quilt。`--include-historical` 可显式显示历史生态，`--loader-info <id> <loader>` 可查询历史候选，`--provider-status <loader>` 可检查来源和覆盖状态；`--loader-offline` 只影响 Loader metadata。Provider 会保留来源与缓存状态，不会把查询结果提升为 Compatibility Matrix 的验证级别。

### 阶段 E — 历史与扩展生态

当前已加入 Legacy Fabric、Ornithe Loader、LiteLoader、Rift、Risugami ModLoader、ModLoaderMP 与 JarMod Manual Mode。Legacy Fabric 与 Ornithe 使用官方 HTTPS metadata 和独立缓存；Ornithe 按官方 v2 metadata 建模为独立 Loader identity，使用 Ploceus toolchain 并保留 Calamus mapping context。LiteLoader 的 HTTPS manifest 与 HTTP-only artifact repository 分开标记，MD5 仅用于损坏检测，不能授权执行。Rift 原始项目与 Rift Community Port 分别标识。ModLoader/MP 的 MCArchive 数据按具体版本、作者、文件名和 SHA-256 记录；JarMod 只在提供本地 artifact 后生成 Manual candidate，不执行 patch。

历史候选或 `Available` 只表示来源目录/归档证据发现了候选；本地 fixtures 的 provider 解析与项目 Resolve 才分别记作 `CATALOGUED` / `RESOLVED`。所有历史构建需看逐项兼容性证据；不宣称这些生态均可在现代系统构建、启动客户端或运行服务端。用户显式请求历史范围时运行 `windows/launcher.ps1 --list-loaders 1.7.10 --include-historical`；历史来源可通过 `--loader-info 1.13 Rift` 和 `--provider-status OrnitheLoader` 检查。

### 阶段 F — 全版本覆盖审计

Phase F 已完成全 Mojang release coverage audit。它按正式 release 逐版记录 Forge、Fabric、NeoForge、Quilt、Legacy Fabric、Ornithe Loader、LiteLoader、Rift、ModLoader、ModLoaderMP 与 JarMod Manual mode 的可用状态、reason code、来源/缓存/信任 provenance，并单独记录 Mojang Runtime Java 与实际 validation evidence。全版本 coverage 不等于每个组合都已 Resolve、Build、启动 Dedicated Server 或启动 GUI Client；构建最低 Java、实际使用 JDK 与编译目标是不同字段。

```powershell
./windows/launcher.ps1 --coverage-report
./windows/launcher.ps1 --coverage-report --json
./windows/launcher.ps1 --coverage-gaps
./windows/launcher.ps1 --coverage-version 1.20.1
```

`--coverage-report` 默认输出简明汇总，`--json` 输出完整审计对象；`--coverage-gaps` 输出 provider 与不变量 gap，`--coverage-version <id>` 只接受 Mojang 正式 release ID。`--catalog-offline` 与 `--loader-offline` 分别控制 Mojang Catalog 与 Loader metadata 缓存。每个 Provider 指标还包含首末 Available release、连续区间和按状态分组的 gap ranges。Live coverage 输出放在 Runtime Root 或本地 HANDOVER，不提交版本化的全量快照。

### 阶段 G — 基于证据的深度验证

Phase G 增加独立的 validation matrix 与 immutable per-run evidence schema，区分 `CATALOGUED`、`RESOLVED`、`BUILD_VERIFIED`、`SERVER_VERIFIED`、`CLIENT_LAUNCH_VERIFIED` 与 `INTEGRATION_VERIFIED`。每个结论只适用于完全一致的 fixture、Minecraft、Loader、Java、OS 与架构；单独启动 Gradle `runClient` 或 Java 进程不构成客户端/服务端通过。官方 fixture 必须固定 commit、记录 license 与信任等级，并限制 Gradle task。详见 [docs/validation.md](docs/validation.md)。

```powershell
./windows/launcher.ps1 --validation-matrix ./my-validation-targets.json --validation-output ./validation-matrix.json
```

深度 fixture 构建通过 GitHub Actions 手动或半月调度运行，不成为每个 PR 的必需大型 build。每份成功构建证据含主产物 SHA-256；客户端与服务端等级还需要对应真实运行 marker 和进程/端口证据。

### 阶段 H — 可复现执行计划与 Session 生命周期

Phase H 增加规范化 Execution Plan、Build Java/Runtime Java 双轨解析和 Session Manifest v2。`--plan` / `--explain-java` 默认离线读取 Mojang 缓存；不会运行 Java/Gradle、创建 Session 或分配 Auto 端口。Plan 的语义 SHA-256 摘要不依赖工作区和 JDK 安装路径。没有可审计的 Adapter Runtime Java 绑定证据时，Launch gate 保持关闭，Build 仍可独立判断。Session v2 绑定创建时的 Plan 摘要和文件哈希，保留 v1 文件供旧 Session 只读兼容。详见 [docs/execution-plan-session.md](docs/execution-plan-session.md)。

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

复制 `common/config/launcher.config.example.json` 为本地 `launcher.config.json`，配置当前平台的 Java 主版本路径和 Mod 项目路径。Windows 使用 `windows/launcher.cmd`，Linux 使用 `./linux/launcher.sh`，macOS 使用 `./macos/launcher.sh`。CLI 可用 `--help`、`--validate`、`--dry-run`、`--build` 和 `--profile <名称>`；`--launch`、游戏 Session 菜单与窗口管理保持 Windows 运行能力范围。

`runtimeRoot` 显式配置优先；未配置时 Windows 使用 LocalAppData，Linux 使用 `$XDG_DATA_HOME` 或 `~/.local/share`，macOS 使用 `~/Library/Application Support`。`--portable` 使用程序目录 `.runtime`。Fabric Loom 的 Windows Junction 兼容处理仅用于 Windows 游戏运行路径；Linux/macOS 构建不依赖该目录链接。

## 安全边界

- 不包含账号登录、认证绕过、凭据采集或在线服务器连接逻辑。
- 删除 Session 时必须限制在 Runtime Root 内，并拒绝 junction/symlink 路径。
- 不会调用 `taskkill /IM java.exe`、按进程名结束 Java 或操作 `.minecraft\saves`。Dedicated 客户端权限等级写入该 Session 的离线账号 `ops.json`；IntegratedLAN 客户端权限由 Host 在游戏中控制。
- 本项目与 Minecraft 发布平台无关。

## 测试

```powershell
./.github/scripts/Invoke-MmtlPester.ps1
```

## 许可证

MIT License，详见 [LICENSE](./LICENSE)。
