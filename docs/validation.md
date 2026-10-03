# 深度验证

Mojang 正式版本目录与 Loader availability 审计只描述元数据，不代表项目已解析、编译、启动 Dedicated Server 或初始化客户端。MMTL 按目标保存这些验证结论及其证据。

## 验证等级

| 等级 | 所需证据 |
| --- | --- |
| `CATALOGUED` | Minecraft 正式版本存在于官方版本目录。 |
| `RESOLVED` | 项目检测器与 Adapter 识别项目组合并生成安全构建计划。 |
| `BUILD_VERIFIED` | Gradle wrapper 成功退出，生成且仅生成一个主 Mod JAR，并记录其 SHA-256。 |
| `SERVER_VERIFIED` | 观察到真实就绪标记且对应进程仍在运行，服务器端口正在监听；向服务器发送受支持的停止命令后，进程与端口均已退出。 |
| `CLIENT_LAUNCH_VERIFIED` | 从对应客户端进程观察到 Minecraft 初始化标记。仅启动 `runClient` 不足以通过。 |
| `INTEGRATION_VERIFIED` | 指定的端到端场景完成，且明确列出的断言均通过。 |

证据仅适用于完全一致的 fixture、Minecraft 版本、Loader/toolchain、Java、操作系统和 CPU 架构。构建结果不得套用到其它平台或版本。证据审计会拒绝缺少支持的高等级结论。

## 平台和环境来源

MMTL 产品操作系统为 Windows、Linux 和 macOS（内部枚举为 `MacOS`）；CPU 架构单独记录。Ubuntu 是 Linux 发行版，WSL/WSL2 是 Linux 运行环境，GitHub-hosted runner 说明证据的生成位置。这些来源字段不会增加产品平台。WSL/WSLg 和托管 CI 不能作为真实 Ubuntu Desktop 或 Minecraft GUI 客户端验证。

## 运行受限的官方 fixture 矩阵

`common/fixtures/deep-validation/fixtures.json` 将可信上游仓库固定到不可变 commit，记录许可证和 Java 要求，并只允许 `clean` 与 `build` 两种 Gradle task。工作流在 Windows、Ubuntu 托管 Linux、macOS ARM64 和 macOS Intel 上运行小型矩阵。它可手动触发，也会每月运行两次；它不是 Pull Request 的必需检查。Runner 名称表示验证环境，不表示产品操作系统。

```text
GitHub Actions → MMTL 深度验证 → 运行工作流
```

选择 `P0` 或 `CurrentStable`。工作流仅上传短期保留的构建日志和通过 schema 校验、带产物/日志哈希的证据，不上传 Minecraft 发行文件或 Gradle 缓存。本仓库的 CurrentStable fixture 固定到 Phase G 执行时解析到的最新正式版本 26.3；本地 `--validation-plan` 则从 Mojang 实时或缓存目录解析 CurrentStable。

## 矩阵和本地证据

Schema 位于 `common/schemas/validation-matrix.schema.json` 和 `common/schemas/validation-evidence.schema.json`。Runtime 运行记录不可变，保存在 `<RuntimeRoot>/validation/<targetId>/<runId>/result.json` 下；日志内容在哈希和存储前会进行脱敏。

要汇总 exact-target 证据，先准备一个符合矩阵 schema 的目标定义 JSON 数组，再执行：

```powershell
./windows/launcher.ps1 --validation-matrix ./my-validation-targets.json --validation-output ./validation-matrix.json
```

CLI 从已配置的 Runtime Root 读取运行记录。它会拒绝不在目标定义中的 target ID 证据，并单独报告无效证据。`ValidationRunner` PowerShell 模块为可信 fixture 与用户项目提供受限的 `Invoke-MmtlValidationBuild` API；不接受任意 shell 命令或未列入允许清单的 Gradle task。

## Dedicated Server 与客户端安全

`runServer` 证据需要真实就绪标记、进程身份、端口监听/释放以及安全停止。不得为了让测试通过而创建或更改 EULA 接受值。如果缺少当前任务明确授权或配置前置条件，应记录 `SKIPPED_EULA_NOT_PREAUTHORIZED`。

客户端验证必须从真实 Minecraft 进程观察到初始化标记。Gradle task 启动、未认证的占位会话、WSLg 或仅构建的 runner 都不能作为客户端验证。如果需要 Microsoft 身份验证，应记录 `AUTH_REQUIRED` 并继续处理其它目标。

## Fixture 信任

官方 fixture 必须使用允许清单内 Loader 组织的 HTTPS GitHub 来源、精确 commit、明确许可证和 `TrustedOfficial` provenance。用户项目按 `UserOwned` 接受并保留在原仓库中。历史二进制、仅 HTTP 来源、未知所有者仓库，以及由元数据任意生成的 shell 命令都会被拒绝。
