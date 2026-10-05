# Minecraft 人工实机验证计划

`--human-validation-plan [--json]` 读取工作区的 `PycodersMod.projects.json`、当前可用的本机配置、项目 Gradle 元数据和已有本地 Phase I–K 记录，执行 LaunchCheck 计划计算并写出工作区级 `HANDOVER/manual-validation/` 包。此命令不运行 Gradle、不启动 Java/Minecraft、不创建 Session、不接受 EULA，也不执行账号认证。

人工验证包仅保存在本机，不能提交或上传。`human-validation-plan.json` 与 `matrix.json` 可能包含本机项目路径；其中历史构建状态与单次 clean build 结果只作为本地候选排序信号。一次历史构建不构成稳定性统计，历史 LaunchCheck 也不代表客户端已验证。

## 代表项目与顺序

首批代表目标按 Forge、Fabric、NeoForge 各选一个。排序考虑 LaunchCheck/BuildReady、同一目标已有的本地构建记录、依赖声明复杂度和 `SameAsBuildJvm` 绑定。实际历史客户端证据未自动提升，因此历史证据加分保持关闭。没有 build 历史的目标按未知处理。

Tier 顺序是硬门禁：先完成三个代表项目的 Single，再开放其它项目的 Single；全部项目 Single 完成后才开放代表项目 Dedicated；IntegratedLAN 还需要全部 Dedicated 阶段完成且认证准备已明确。当前证据中没有用户确认或真实游戏观察，因此 Dedicated 与 IntegratedLAN 当前关闭。Minecraft Portfolio 只有 Forge/Fabric/NeoForge 项目，不会伪造 Quilt 代表项目。

## 本地包

- `human-validation-plan.json`：目标、排序依据、Tier 状态和不可自动晋级边界。
- `matrix.json`：每个目标/模式的 LaunchCheck 状态及可复制的只读预检和显式人工启动命令。
- `checklist.md`：逐项核对配置、Doctor、LaunchCheck、clean build 与产物、手动启动、视觉检查、Safe Stop 和 Session 证据。
- `status.json`：空白的本地进度记录；所有行均从 `NOT_STARTED` 开始。
- `manual-validation-helper.ps1`：默认只显示计划；`-Preflight` 运行指定目标的 `--launch-check --json`；真实启动必须明确传入 `-Launch -ConfirmRealMinecraftLaunch -TargetId`。helper 不操作游戏菜单、世界、鼠标/键盘、认证或账号。

矩阵中的真实启动命令是未来交由用户本人执行的显式命令，本阶段不运行它。Dedicated 命令还必须带 `-ConfirmEulaAcceptance`；缺少该项会在创建临时配置和启动前拒绝执行。传入该项即由用户明确确认接受 EULA，helper 才会在隔离临时配置中设置 `acceptEula=true`。本阶段没有运行该命令，也没有创建或修改 `eula.txt`。用户不应将认证失败交给自动修复流程。

## 观察证据

真实启动后，MMTL 应由当前 Session 的 Observer 自动收集 Session v2、Execution Plan digest、当前 source/artifact hash、Runtime Java binding、登记进程身份、Observed Runtime Java、事件序列、Crash 分类、停止结果和适用的端口释放情况。用户只需亲自确认客户端窗口、主菜单及真实游戏行为，不需要从 `latest.log` 手工搜索 marker。进程身份、当前 Session marker 与明确事件缺一不可；人工目视陈述和 dummy rehearsal 不会单独生成 `CLIENT_LAUNCH_VERIFIED`、`SERVER_VERIFIED` 或 `INTEGRATION_VERIFIED`。

人工作业前确认目标、现有世界数据备份和 Runtime Root；使用生成的只读预检命令检查目标；只有用户准备好后才手动执行真实启动命令。退出时使用当前 Session 的安全停止操作，再检查 `--session-info`、`--session-validate` 和只读 Observer 输出。
