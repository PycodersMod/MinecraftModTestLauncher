# MMTL 可配置离线多客户端与 Integrated LAN 测试设计

- 状态：供用户审阅的设计修订稿（按离线多客户端方向纠正）
- 日期：2026-10-17（Asia/Shanghai）
- 范围：仅修订多客户端正式设计文档；不实现多客户端产品代码。兼容性 Goal 独立持续推进，设计修订与 Goal 的构建 / 测试分别记录
- 延续：全 1,631 个精确 Loader × Minecraft 目标的兼容性 Goal 保持原验收要求
- 方向纠正：本稿取代此前“两个独立认证玩家 / 在线认证启动器”方向。测试身份固定为 MMTL 本地离线身份；不得为满足多窗口联机而读取或传递 Microsoft/Mojang 凭据、真实账号令牌或登录缓存。

## 1. 设计目标与硬约束

MMTL 使用仅服务于 MMTL 管理的本机测试环境的离线玩家身份。启动与联机测试不得读取 Microsoft/Mojang 凭据、账号令牌或登录缓存，不得将本地测试客户端连接到未经授权的第三方服务器，也不得把身份生成成功当成联机兼容证据。

客户端窗口数量由配置文件或 PowerShell 启动参数决定，默认严格为一个客户端。一个客户端只运行单人功能测试；只有用户配置了至少两个客户端并启用 LAN 场景时，才执行多人联机测试。原 1,631 目标 Goal 的验收批次必须显式提供多人测试配置，日常默认值仍为单人。

现代版本的多人路径由 Host 客户端进入受控单人世界并通过原版 Integrated Server / Open to LAN 提供世界，Guest 客户端连接该 Host。Host 同时是一个真实 Minecraft GUI 客户端和 Integrated Server 宿主，不启动额外 Dedicated Server。历史版本没有 Integrated LAN 能力时，报告原生能力限制；经过可信性核验的本机历史 Dedicated 等价路径单独标注，不能伪称原生 LAN。

## 2. 与当前 MMTL 实现的关系

本设计复用当前已有的 PowerShell Launcher、Config/Profile、ExecutionPlan、SessionManager / SessionLifecycle / SessionRecovery、PID 登记与安全停止、TestIdentity、ScenarioOrchestrator、AgentProvider / AgentEvents、WindowPairProof、SharedWorldAssertion、Session report 和现有 Adapter/Loader 启动计划。不得新建一套平行启动器或绕过这些受管生命周期。完整兼容性 Goal 保持 active；这份设计稿的审阅不会暂停、重置或缩减 Goal。

当前工作树中可复用的基础能力和接口边界如下：

| 项目 | 当前已存在 | 本设计要求补齐或核实 |
|---|---|---|
| 离线测试身份 | `common/src/TestIdentity.psm1` 可按名称生成离线 UUID，生成 Host/Guest 角色计划、隔离游戏目录及身份记录，并检查名称冲突 | 按精确 Minecraft 版本核验名称 / UUID 规则，并把每个身份与对应客户端进程绑定；不调用 Microsoft/Mojang 登录，不读取令牌或启动器认证缓存 |
| Session | `SessionManager` 将测试身份和玩家目录写入 Session 元数据；生命周期、恢复、PID 登记和安全停止已有实现 | 使 N 个客户端的身份、独立目录、PID、日志、窗口证据和报告稳定一一对应 |
| 配置 | `common/config/launcher.config.example.json` 为 Config v2；Profiles 使用 `mode`、`players`、`hostUsername`、`clientPrefix`。Config 读取器当前接受 v1/v2 | 新配置提案使用 `clientCount` 作为客户端窗口总数；明确其与旧 `players` 的按运行模式迁移关系，保留显式 Dedicated 模式 |
| PowerShell CLI | 当前有 `--config-file`、`--profile`、`--scenario-plan`、`--run-scenario` 等入口 | 当前没有多客户端数量和身份模板覆盖参数；拟议的 CLI 参数只作为未来接口，不表示当前已实现 |
| Scenario / Agent | `ScenarioOrchestrator` 有 Single、IntegratedLAN、Dedicated 计划以及 Host/Guest 流程；Agent、窗口证明和共享世界断言已有接口或数据结构，部分 Loader Agent 有受管 LAN 发布入口 | 自动 Open to LAN、自动加入、精确端口证据、每玩家报告及真实跨玩家断言仍须按 Family 验证；接口存在不等于能力已通过 |

### 与现有认证门禁文档的冲突

当前 `docs/execution-plan-session.md` 将 IntegratedLAN Guest 描述为 `AUTH_REQUIRED`，`docs/offline-multiplayer.md` 则提到 Session token 与 Forge 1.20.1 Agent 的离线认证动作。这些旧记录不能作为要求用户提供在线账号或读取真实登录凭据的依据。IntegratedLAN 门禁应验证该精确 Minecraft / Loader 目标能否安全使用 MMTL 离线测试身份；内部 Session nonce 仅用于 MMTL Agent 与 Session 事件的归属验证，必须与 Minecraft 登录令牌区分，不能充当或伪造在线凭据。Task 7 已按此语义更新人工验证计划、操作文档和验证说明；目标拒绝离线身份时归类为 `OfflineIdentityUnsupported` 或对应能力阻塞，不请求真实账号。

这些现存代码只是可复用起点，不表示本设计已落地或所有版本可用。后续须逐项核实精确 Loader / Minecraft Family。验证主题是离线玩家身份在该版本中的实际会话行为、Host 自动 Open to LAN、Guest 自动加入和共享交互，不是在线账号认证；如果某版本不接受这种本地离线测试身份，应如实记为该版本的兼容限制，不得改用令牌、真实账号或第三方认证服务绕过。

当前示例配置确实把 `integrated-lan-example` 设为默认 Profile，和日常默认单客户端要求冲突。未来新建配置及仓库示例应默认 `single-example` 或等价单客户端配置；不得静默改写已有配置的运行语义。完整矩阵专用配置必须显式写入 `clientCount: 2`，以明确要求 Host + Guest。配置迁移在获准实现前不执行。

## 3. 配置结构与解析优先级

继续使用现有 `launcher.config.json`、Config Schema、Profile 选择及 `--config-file`，不另建启动器。以下是未来 schema 的建议形状，不是当前受支持的配置：当前示例 schema 版本为 2，现有 `players` 尚未替换为 `clientCount`，当前 schema 也没有 `identity` / `multiplayer` 字段。实现时需提出新 schema 版本并按显式、可审计的迁移规则兼容旧配置：

```json
{
  "configVersion": 3,
  "defaultProfile": "single",
  "profiles": {
    "single": {
      "clientCount": 1,
      "identity": {
        "kind": "Offline",
        "hostName": "MMTL_Host",
        "guestNamePattern": "MMTL_G{index}"
      },
      "multiplayer": { "transport": "Auto" }
    },
    "matrix-lan": {
      "clientCount": 2,
      "identity": {
        "kind": "Offline",
        "hostName": "MMTL_Host",
        "guestNamePattern": "MMTL_G{index}"
      },
      "multiplayer": {
        "transport": "Auto",
        "bindAddress": "127.0.0.1",
        "port": "Auto",
        "worldPolicy": "CreateOrLoadManagedWorld"
      }
    }
  }
}
```

字段约定：

- `clientCount` 是真实 Minecraft 客户端 JVM 与 GUI 窗口总数，不包含运行在 Host 客户端 JVM 内的 Integrated Server。默认值为 1；值为 1 时执行单人测试，多人状态为 `NotRequested`。值为 N≥2 时解析为一个 Host 和 N−1 个 Guest，并默认请求 Integrated LAN；不得仅因缺少额外开关而启动 N 个互不相关的单人客户端。
- `multiplayer.transport=Auto` 是默认选择：`clientCount=1` 解析为 `None`；`clientCount>=2` 时，若该精确 Minecraft 目标支持 Integrated LAN，则解析为 `IntegratedLAN`。若不支持，返回明确的版本能力结果；不得静默切换至 Dedicated。历史 Dedicated 等价路径必须由对应历史测试计划明确指定。
- 若用户显式选择 `multiplayer.transport=None`，则只允许 `clientCount=1`；`clientCount>=2` 与 `None` 冲突，必须在创建 Session 或进程前拒绝。Dedicated 是独立、显式选择的运行路径，不由客户端数量隐式触发；显式 Dedicated 模式下 `clientCount` 表示连接 Dedicated Server 的 GUI 客户端数，服务器进程另计，现有 EULA 门禁继续适用。现代 Integrated LAN 测试不需要 Dedicated EULA。
- `identity.kind` 仅接受 `Offline`。不得提供会读取现有官方启动器凭据的隐式模式。
- `bindAddress` 默认限于 loopback。若将来支持其他本机网络地址，需有明确配置、能力检查和范围约束；不得默认开放公网监听。
- 新 schema 以 `clientCount` 表达 GUI 客户端窗口总数；`multiplayer.transport=Dedicated` 是显式服务器测试选择，`clientCount` 仅统计连接服务器的客户端，Dedicated Server 单独计入 Session。旧 Config v1/v2 的 `players` 含义受旧 `mode` 影响；迁移必须按原 `mode` 保留语义并生成可审阅的迁移结果。存在歧义的旧配置应要求用户选择，不能猜测、静默降为单人或扩大窗口数。

有效配置解析优先级固定为：

1. PowerShell / Launcher 命令行中显式传入的参数；
2. `--config-file` 指定的配置文件中，按 `--profile` 或配置的 `defaultProfile` 选择的 Profile；
3. 内置安全默认值：`clientCount=1`、离线身份、`multiplayer.transport=Auto`（解析为单人运行及 `NotRequested`）。

配置文件未提供某个字段时才回退到内置默认值。每次 Plan 和 Session 都记录配置文件标识 / 摘要、原始 Profile 标识、命令行覆盖项、最终生效值及配置摘要。秘密材料不属于此配置模型，也不得写入 Plan 或报告。

不带任何配置文件、Profile 或多客户端命令行覆盖的新配置 / 首次运行必须解析为单客户端 Single。显式设置 `clientCount=N` 且 N≥2 时，即使未额外传 `--multiplayer`，也应解析为 Host + N−1 Guest 的 Integrated LAN 请求；目标不支持 LAN 时在启动前报告能力限制。已有配置中明确保存的多人 Profile 属于用户配置，迁移时不得静默改成单人或扩大客户端数；应先生成可审阅迁移结果并显示最终窗口数量与运行路径。

## 4. PowerShell CLI 覆盖

沿用现有 `windows/launcher.cmd` → `windows/launcher.ps1` → `common/src/Launcher.ps1` 参数透传，以及现有 `--config-file`、`--profile` 入口。当前 CLI 已提供场景计划 / 执行命令，但下列多客户端覆盖参数都尚未实现，是待审阅的接口提案：

```powershell
.\launcher.cmd --run-scenario --profile matrix-lan `
  --client-count 2 --multiplayer integrated-lan

.\launcher.cmd --run-scenario --config-file .\matrix.json `
  --profile matrix-lan --client-count 4

.\launcher.cmd --run-scenario --client-count 1 --multiplayer none
```

建议参数：

- `--client-count <N>`：临时覆盖客户端窗口总数；解析为正整数。N=1 解析为单人；N≥2 默认请求一个 Host + N−1 Guest 的 Integrated LAN。
- `--multiplayer auto|none|integrated-lan|dedicated|historical-dedicated-equivalent`：可选地显式覆盖测试路径。`auto` 按客户端数和精确版本能力解析；`none` 只允许一个客户端；`integrated-lan` 至少要求两个客户端；`dedicated` 是单独的服务器测试；历史 Dedicated 等价路径只能由被批准的历史测试计划显式指定。冲突必须在创建 Session 前拒绝。
- `--host-name <name>` 与 `--guest-name-pattern <pattern>`：临时覆盖离线测试名称模板；模式只允许 `{index}` 一个占位符。
- `--world <managed-name>`：可选地选择受管世界；路径只能解析到当前 Session 的 Host 游戏目录之下。

现有 CLI 实现目前没有这些覆盖项；配置文件仍通过现有 `--config-file` 与 `--profile` 选择。示例中的 `--client-count 2` 单独即可表达双客户端 LAN 请求，`--multiplayer` 仅在需要覆盖自动选择时使用。实现覆盖解析时只允许明确参数，拒绝未知 / 重复 / 冲突参数，并把 Profile 原值、命令行覆盖项、解析后的模式和最终客户端数写入 Plan。参数解析须先于 Session 创建和任何游戏进程启动。CLI 示例是目标接口示意，不能当作当前可执行用法。

参数校验在创建 Session 或启动进程前完成。矛盾参数、身份冲突、不支持的版本能力、平台或实测资源无法承载所请求窗口数量、不安全路径都使 Plan 失败，不得降级后继续启动。不得直接沿用现有场景规划器的固定 8 玩家限制作为产品上限；未来实现须根据可用内存、平台进程能力及每客户端资源预算执行资源预检，并通过受控并发逐个启动 Guest。

## 5. 离线身份分配和隔离

身份计划必须在 Session 创建前一次性生成，并将结果绑定到每个实例。每个客户端至少记录：`role`、`username`、适用版本身份类型 / UUID（若该版本使用）、`identityId`、`gameDir`、`instanceId`、Runtime Java 绑定、PID、日志位置、Loader / Minecraft 精确版本和启动参数摘要。

身份规则：

- Host 使用 `hostName`；Guest 序号为 1 至 N−1，按 `guestNamePattern` 生成名字。
- 依照 Minecraft 玩家名规则校验长度、字符集和不区分大小写的唯一性；任何冲突均在启动前报错，不通过临时改名静默掩盖。
- 对使用离线 UUID 的版本，用准确的版本策略生成并记录 UUID；不使用 UUID 的历史版本则记录该版本实际采用的名称身份。离线 UUID 不是在线账号身份，不得宣称经 Mojang 验证。
- 离线身份策略按 Loader / Minecraft Family 选择该版本真实支持的本地启动身份参数或受控启动路径；不得读取官方 Launcher 的登录缓存、会话令牌或账号数据库，也不得把虚构令牌传给客户端。某版本若要求在线认证、拒绝离线身份或无法安全注入离线身份，必须在该精确目标上记录实测结果与证据，不得推断其支持，也不得静默切换认证方式。
- 不需要在线认证账号；不得读取、导入、复制、刷新或记录 Microsoft/Mojang 登录凭据、真实账号令牌及官方启动器认证缓存。“离线身份不可用”表示该目标的本地测试路径尚未实现或被游戏行为拒绝；这不是请求用户登录真实账号或绕过账号安全边界的理由。
- 每个客户端使用独立、位于当前受管 Session 根目录内的 `gameDir`，包含各自的 `logs`、`config`、`screenshots`、`crash-reports` 和玩家本地配置；Host 世界存档只属于 Host 的目录。Guest 不得复用 Host 的 `gameDir`。
- 每个客户端作为独立进程启动并登记于 Session `pids.json` / Session manifest；报告把 PID 和身份一一对应。进程启动后再核验 PID、进程映像及进程树属于该 Session。
- 不把凭据或认证令牌注入 JVM 参数、环境变量、Agent 属性、日志或报告。离线身份只在 MMTL 的本地测试 Session 范围内有效。

## 6. Integrated LAN Host / Guest 生命周期

Integrated LAN Scenario 的建议可恢复状态顺序如下：

`PlanValidated → Building → SessionReady → HostStarting → HostReady → WorldReady → LanPublishing → LanReady → GuestsStarting → GuestsReady → Asserting → Observing → Stopping → Completed`

失败时转入 `Failed → Stopping → Stopped`，保留证据并按 Session 登记逐进程安全回收。状态转换与事件追加沿用 ScenarioOrchestrator 的追加式事件记录和 Session 锁。

执行流程：

1. 解析并冻结配置 / ExecutionPlan，验证精确目标的 `single`、`integratedLan`、Agent 和 Java 能力；生成 Host 与 Guest 身份及独立目录。
2. 启动唯一 Host 客户端，等待有界时长内出现真实客户端 PID、GUI 和进入受管单人世界的就绪观测。Host 尚未开放 LAN 时，先执行该精确目标要求的单人 Mod 场景断言；单人断言失败则不进入多人阶段。
3. 仅当配置明确请求多人时，Host 再通过该版本经验证的原版“开放到局域网”动作启动 Integrated Server。优先复用 Loader Agent 的受管 action / bridge，并保留动作来源和成功事件。若某 Family 只能人工点击，可在交互式诊断中标记 `ManualStepRequired`；该状态不满足 1,631 目标批量验收，不能当成自动化 PASS。
4. 读取本次 Integrated Server 实际绑定的监听端口，并以 Host Agent 事件、进程 / socket 观测及连接探测交叉验证端口归属和存活。禁止仅凭请求端口或日志中的孤立数字认定端口已就绪。自动端口由系统选择；固定端口冲突必须失败并安全退出。
5. 对每个 Guest 顺序启动独立真实客户端，使用精确版本支持的受控自动加入方式连向 `127.0.0.1:<实际端口>`；待 Agent 确认 `WORLD_JOINED` 和世界标识一致后再启动下一个 Guest，避免无测量地同时打开多窗口。
6. 多人场景要求所有 Guest 加入同一 Host 世界，并通过 SharedWorldAssertion 验证一个有因果关联的跨玩家状态变化或交互。窗口存在、客户端 Ready、端口开放和模拟事件都不能替代游戏内断言。
7. 记录逐角色事件、PID、窗口证据、真实端口、世界 / 维度标识、断言输入输出及日志哈希；完成后先停 Guest，再关闭 Host 世界和 Host 客户端，最后确认整个 Session 进程树已停止、端口释放。

Host 始终是 GUI 客户端中的 Integrated Server。`IntegratedLAN` 报告不得新增一个“Server PID”来暗示启动了 Dedicated Server。

## 7. 单人、多人与完整 Goal 的状态语义

- `clientCount=1` 且多人关闭：启动一个客户端；先完成单人功能场景。`Multiplayer=NotRequested`。该状态既非失败，也非 Multiplayer PASS，不影响单人能力判定。
- `clientCount>=2` 且多人模式为 `integrated-lan`：必须完成真实 Host/Guest 加入、世界一致性和跨玩家断言。仅启动多个窗口不通过。
- 配置选择多人但版本不支持 Integrated LAN：返回 `UnsupportedByMinecraftVersion`，并解释该原生能力边界；不能静默切换 Dedicated 或标为通过。
- 完整 1,631 目标 Goal：专用批次配置必须显式指定 `clientCount=2`，该值解析为两个真实离线客户端窗口：一个 Host 与一个 Guest。先完成 Host 单人断言，再进入多人路径。现代版本使用 Integrated LAN；早于原生 Integrated LAN 的目标走第 9 节已批准的历史等价路径。`NotRequested` 不满足完整 Goal 验收。完整 Goal 原有的 Dedicated 适用性、Agent Build / Injection 及其他适用能力门禁继续有效，不因日常 Profile 默认单客户端而省略。

报告至少拆分 `SingleplayerAssertion`、`ClientWindowReady`、`IntegratedLanPublished`、`GuestJoined`、`SharedWorldAssertion`、`Multiplayer`、`SafeStop`，并保留 `NotRequested`、`PASS`、`FAIL`、`BLOCKED`、`UNSUPPORTED` 等非混淆状态。总体 PASS 由必需维度推导，不允许单项 PASS 覆盖必需项未完成。

## 8. Agent、报告与 Session 安全

复用受控 Agent handshake、一次性 Session nonce、允许角色、事件 sink 路径约束、玩家动作策略和 Agent capability gate。离线身份配置不得扩展 Agent 的文件 / 命令权限。身份数据是 MMTL 本地测试用的玩家名与适用版本身份标识，不是在线账号凭据。系统不得读取或缓存 Microsoft / Mojang 登录信息，不得把令牌放进配置、Session、JVM 参数、环境变量、Agent 属性、日志或报告。LAN 发布授权限定为当前 MMTL Session、Host 角色、当前世界及配置的本机绑定地址；Guest 只能加入当前 Session 的目标端口。

每个目标生成独立 JSON 与 Markdown 报告，至少包含最终生效配置和摘要、精确目标 / Family / Adapter / Batch、每位玩家身份与角色（不含令牌）、游戏目录、进程 PID / Java / 窗口就绪证据、LAN 实际地址与端口、Agent 事件、各断言证据、单人 / 多人状态、开始结束时间、失败分类和安全停止结果。每个原始事件追加写入 JSONL 并及时 flush；失败重试不能覆盖先前尝试。

停止操作只能作用于已登记并通过进程身份验证的 Session 进程；关闭失败时保留 Session、PID、日志和端口证据供恢复，不误杀用户其他 Java 或 Minecraft 进程。

## 9. 历史版本边界

对原版没有 Integrated LAN 的早期 Minecraft 精确版本（特别是 1.3.1 之前），能力矩阵记录 `NativeIntegratedLAN=UnsupportedByMinecraftVersion`，并说明这是游戏版本能力边界。若该目标已有可信、精确匹配的历史独立服务器制品和受控 Build / Runtime 工作流，可按原 Goal 已批准的本机历史等价方案执行：启动至少两个真实离线测试客户端窗口，分别使用独立玩家身份和游戏目录，连接同一台本机历史 Dedicated Server，验证共享世界交互。其证据必须标记 `HistoricalDedicatedEquivalent`，并附服务器制品来源 / 哈希、版本匹配、离线身份实际加入证据及 Session 进程信息；这既不是云服务器，也不是 `NativeIntegratedLAN=PASS`。不得因为 Integrated LAN 不可用就自动下载或运行未经审计的历史服务器。

历史服务器构建和运行不得执行未经审计的下载制品或不受信任脚本。若没有可信制品或精确的历史工作流，该目标保留为内部未完成或有证据的外部阻塞，不能用模拟替代实机联机。

## 10. 设计验收与后续实现门禁

设计获用户审阅后，才继续为此方向编写实现计划；该审阅不会自动批准超出原 Goal 边界的新外部副作用。后续获准实现应先针对 Config、CLI 解析、identity-to-process 绑定、Session 生命周期、Lan port 观测、Agent 事件与断言状态编写失败测试，再共享实现和精确版本实机验证。

最低验收样例：

1. 无额外参数的新建 / 默认配置解析为单一离线客户端；无 Guest 启动；多人状态为 `NotRequested`。
2. CLI `--client-count 2` 单独覆盖 Profile 时，Plan 摘要显示 2 个客户端、Host + Guest 及 Integrated LAN 请求；`--client-count 1` 得到单人及 `NotRequested`。Profile 未覆盖字段使用内置默认；矛盾覆盖在 Session / 进程创建前拒绝。
3. 2 个和 N 个客户端分别产生 1 Host + 1 / N−1 Guest、唯一玩家身份、唯一 GameDir 和独立 PID 记录。
4. Integrated LAN 只在 Host 的受管单人世界启动；Host、实际端口、每个 Guest 加入和共享世界断言均有真实证据。
5. 端口超时、冲突、身份冲突、Host 提前退出、Guest 无法加入、Agent 缺失和断言失败时，报告如实记录并安全回收 Session。
6. 1,631 目标矩阵配置显式启用每个目标所需的多人验收，默认启动两个真实 GUI 客户端，分别对应独立 JVM/PID 和离线身份；目标专用计划可以显式配置更多客户端。历史无 Integrated LAN 目标只能用独立标注的可信历史等价路径。
7. 全程确认没有读取、传递或落盘 Microsoft / Mojang 令牌，没有修改用户原始 Mod 工程。

本稿明确了日常默认单人、`clientCount=N` 对应的窗口与 Host/Guest 数量、配置和命令行优先级、离线身份、Host 内置 Integrated Server、Guest 独立客户端、历史版本边界，以及现有接口与待实现提案的区别。本文本轮仅为设计修订：没有修改产品代码，也没有执行多客户端专项 Pester 或真实游戏验证。完整 1,631 目标 Goal 的多窗口验收由专用配置显式指定 `clientCount=2`；日常默认 `clientCount=1` 不会降低该 Goal 的验收要求。本文现供用户审阅；在你审阅批准设计前，不开始该多客户端方向的产品实现。完整兼容性 Goal 保持 active。
