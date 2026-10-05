# 人工实机验证前发布门禁审计

本文记录自动化准备与仍需人工/平台证据的事项。`Unsupported`、`Unknown` 和 `BuildOnly` 是能力状态，不代表待办实现失败；只有与真实目标平台和执行路径相关的证据才可提升状态。

## TODO 与范围分类

| 类别 | 结果 | 归属与处理 |
|---|---|---|
| A：人工验证前必须实现的 TODO/FIXME/NotImplemented | 产品源码、测试与正式文档中未发现未分类的实现占位 | 运行时观察、三种模式演练、端口、内存、产物校验、配置字段审计和人工验证包均有实现及自动测试。 |
| B：有意保留的平台限制 | Linux GUI Launch 为 `BuildOnly`；Linux/macOS WindowManagement 为 `Unsupported`；macOS FabricRuntimeLink 为 `Unsupported` | 各平台 Provider 负责声明能力。macOS ARM64 与 Intel runner 均通过进程身份、PID 重用、子树停止和 Session orphan 恢复合同测试，因此 ProcessManagement 为 `Native`；真实窗口控制仍需要对应平台实现与验证。 |
| C：必须由用户完成的真实游戏判断 | 真实客户端窗口、主菜单、世界交互、Open to LAN、真实多人/认证、EULA 接受 | 这些不是自动化 TODO。用户本人操作后由当前 Session Observer 采集证据；不得通过 dummy、历史日志或手工陈述晋级。 |
| D：未来可选扩展 | `--confirm-observation` 人工观察确认 CLI 未纳入本次必需范围 | 该 CLI 在规范中是可选项；本轮不依赖它，不影响只读 Observer 和现有人工验证流程。 |
| E：历史阶段或研究资料 | README/架构文档中的 Phase A–K、历史 Loader 与 `Unsupported` 引用属于阶段说明或数据契约 | 保留原阶段脉络；不将历史阶段标题当作当前实现缺口。 |

扫描范围覆盖 `common/src`、三平台源码与测试、README、正式 docs 和 CI 配置。Phase L–O 实施计划本身也列有待验收条目，不能把计划里的要求文本误判为源码 TODO。

## CLI 与文档对照

| CLI | 语义 | 自动验证位置 |
|---|---|---|
| `--observe-session <ID> [--timeout-seconds N] [--json]` | 只观察当前 Session 已登记状态 | `ObservationCli.Tests.ps1`、`ObservationSafety.Tests.ps1` |
| `--session-events <ID> [--json]` | 只读事件流 | `ObservationCli.Tests.ps1` |
| `--launch-rehearsal [--json]` | 按当前 Plan 运行安全合成演练，永不生成正式验证资格 | `RehearsalRunner.Tests.ps1`、CLI 集成测试 |
| `--human-validation-plan [--json]` | 生成本机人工验证包，不启动进程 | `HumanValidationPlan.Tests.ps1`、CLI 集成测试 |
| `--plan`、`--runtime-binding`、`--launch-check`、`--doctor`、`--capabilities` | 只读准备/诊断命令 | 对应 CLI、Plan、Binding、Doctor 与平台测试 |

帮助文本包含以上命令，JSON CLI 由自动测试确认输出为可解析结构；正式行为、退出码和安全边界以命令实现和对应测试为准。README、[运行时观察](runtime-observation.md)、[人工验证计划](human-validation.md) 与 [配置字段审计](config-profile-field-audit.md) 提供一致说明。

## 环境与证据边界

- WSL Ubuntu 可运行 Linux CLI 与 Build 工具链入口，但当前未安装 Linux JDK；Plan/Binding 可报告缺少 Build Java，Doctor 和 LaunchCheck 按阻塞状态返回。不得将 Windows JDK 误认为 WSL Linux JDK。
- macOS ProcessManagement 在 ARM64 和 Intel 必需 CI 的真实 runner 均通过身份、PID 重用、进程树安全停止及 orphan 恢复合同测试后升级为 `Native`；窗口管理不随之升级。
- WSLg、托管 CI、dummy Java、loopback server、synthetic log 和测试 fixture 均不代表真实桌面或 Minecraft 客户端验证。
- Public hygiene 检查覆盖公开文件中的本机路径、hostname、GitHub 凭据、代理端点与账户身份；local `HANDOVER/manual-validation/`、Session logs 和 build evidence 不得进入仓库。

## 架构边界

共同层只依赖平台 Provider contract；Windows、Linux、macOS Provider 不互相导入。`ProcessManagement`、`WindowManagement`、Build 与 Launch 是独立能力，不能由一个平台、一个 CI job 或 WSL 的结果推导另一个平台的实机支持。
