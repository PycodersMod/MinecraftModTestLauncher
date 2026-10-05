# Launcher Profile 字段审计

本文按当前 `launcher.config.json` 示例 Profile 与 Launcher、Execution Planner、RunManager 的实际读写路径整理。标记“仅元数据”的字段不会被 MMTL 伪称为已应用；Plan 会发出稳定 warning。计划中的本机绝对路径仍属于本地解析信息，不作为跨目录语义身份。

| 字段 | 当前用途 | 状态与边界 |
|---|---|---|
| `project` | 项目发现、构建与启动目标 | 已消费；进入 Plan 的 repository/project locator。 |
| `linkedProjects` | 按配置顺序解析、兼容性检查、依序构建，并将产物注入每个实例 | 已消费；每个项目必须能解析出唯一 Mod JAR。任一 build 失败立即停止后续 build/Launch preparation；linked JAR 的构建 SHA-256 会在每个角色注入前再次核对。 |
| `mode` | 选择 Single、Dedicated 或 IntegratedLAN 编排 | 已消费；决定角色和运行路径。 |
| `players` | 计算角色数并限制最多 8 个本地实例 | 已消费；Single 固定 1；IntegratedLAN 包含 Host。 |
| `hostUsername` | Host/首个本地客户端用户名 | 已消费；校验 ASCII 字符与长度。 |
| `clientPrefix` | 后续本地客户端用户名 | 已消费；校验 ASCII 字符与长度。 |
| `hostCheats` | 写入 Plan/Session 元数据 | 仅元数据；不会自动进入世界创建界面或替用户开启 Open to LAN 命令权限，Plan warning：`PROFILE_FIELD_METADATA_ONLY`。 |
| `clientPermissionLevel` | Dedicated 模式按指定级别生成离线 ops 记录 | Dedicated 已消费；Single/IntegratedLAN 仅元数据，需在游戏内确认。 |
| `gameMode` | Dedicated `server.properties` | Dedicated 已消费；Single/IntegratedLAN 需用户在世界创建界面手动选择，并有 metadata-only warning。 |
| `difficulty` | Dedicated `server.properties` | Dedicated 已消费；Single/IntegratedLAN 需用户在世界创建界面手动选择，并有 metadata-only warning。 |
| `worldName` | Dedicated `level-name` | Dedicated 已消费；其他模式仅记录，世界名由用户在 GUI 创建/选择。 |
| `seed` | Dedicated `level-seed`，且限制为整数 | Dedicated 已消费；其他模式仅记录，需在 GUI 输入。 |
| `newWorld` | 记录用户意图 | 仅元数据；不会代替用户在 GUI 创建或选择世界，Plan warning：`PROFILE_FIELD_METADATA_ONLY`。 |
| `resetWorld` | 删除本次 Session 对应的世界目录 | 已消费但严格限定当前 Session；不遍历或删除其他 Session。新启动总是创建隔离 Session，不能用它清理旧 Session 的世界；Plan warning：`WORLD_RESET_SCOPED_TO_SESSION`。 |
| `port` | Dedicated 绑定 Auto/固定端口；IntegratedLAN 固定端口用于核对 Host 实际公布端口 | 已消费；Dedicated Auto 冲突最多重试 3 次，固定端口不会换号。 |
| `autoBuild` | 决定是否先构建 | 已消费；不构建时仍检查所需项目产物。 |
| `cleanBuild` | 传入 Gradle 构建的 clean 选项 | 已消费；只影响本 Profile 请求的构建。 |
| `acceptEula` | Dedicated Launch readiness 与启动前门禁 | 已消费为明确授权门禁；Plan 不改配置、不写 EULA。实际 Server 运行只会在用户预先设置 true 后创建 EULA 文件。 |
| `extraMods` | 解析 JAR 并逐实例复制到隔离 Runtime `mods/` | 已消费；拒绝路径越界、同名和相同内容重复项；复制后校验 SHA-256/长度，并在 Session `artifacts/mods-<role>-<username>.json` 记录不含来源绝对路径的 manifest。 |
| `memoryMb` | 各角色专用内存缺失/为 0 时的回退值 | 已消费；参与角色 Xmx 总量与物理内存 80% 预算。 |
| `hostMemoryMb` | Host Xmx | 已消费。 |
| `clientMemoryMb` | 每个客户端 Xmx | 已消费。 |
| `serverMemoryMb` | Dedicated Server Xmx | 已消费。 |
| `resolution` | 匹配 `宽x高` 时附加客户端 `--width/--height` | 已消费；`Auto` 不传固定尺寸。Dedicated Server 不使用。 |
| `guiScale` | 启动前写入该角色 Runtime 的 `options.txt` | 已消费；支持 `Auto` 或 0–4；Server 不写客户端选项。 |
| `windowLayout` | 调用平台窗口布局 provider | 已消费；受平台 capability 限制，失败记录降级状态；不会改动未登记窗口。 |
| `jvmArgs` | 传入对应 Gradle 运行任务的 JVM 参数 | 已消费；rehearsal fixture 已验证指定属性抵达子 JVM。 |
| `gameArgs` | 追加到游戏任务参数 | 已消费；rehearsal fixture 已验证参数抵达子进程。 |
| `runtimeJavaOverride` | 覆盖 Runtime Java major/component 要求，再按平台解析路径 | 已消费；路径只用于本机执行，不进入语义身份。 |

## 产物隔离与完整性

Mod JAR 来源可以是用户配置的本机文件或 `linkedProjects` 构建产物；复制目标必须留在当前角色 Session Runtime 的 `mods/` 目录。linked 项目按 Profile 顺序构建；某项失败会中止流水线，不会继续启动或生成可注入集合。每个 linked JAR 的当前 SHA-256 必须匹配 build result，再在每个角色注入前与相同预期哈希复核。复制通过临时文件完成，复制后的长度与 SHA-256 必须与来源一致；记录只包含文件名、长度、哈希、角色和用户名。任一输入校验或复制失败时，回滚本次已复制文件，不留下半份实例 Mod 集合。

独立验证构建还会对项目源文件生成 SHA-256 fingerprint（跳过 `.git`、`.gradle` 和 `build`），并在运行前后比较。源文件在构建期间发生变化时返回 `BUILD_SOURCE_CHANGED_DURING_RUN`。如果 Wrapper 成功但唯一 Mod JAR 相对运行前既未改变哈希也未更新写入时间，则返回 `ARTIFACT_STALE`；没有当前运行产生/刷新产物的证据时不会标为 `BUILD_VERIFIED`。结构化证据只保存 fingerprint、刷新判断、产物哈希和相对路径，不保存项目本机绝对路径。旧版 evidence schema 中新增的 `source` 字段是可选字段，旧记录仍可读取。

## 手动行为边界

Single/IntegratedLAN 中创建或选择世界、世界名/种子/模式/难度以及 LAN 开放与权限仍由用户在 Minecraft GUI 操作。Profile 值作为准备提示和 Session metadata 保存，不能视为游戏已应用这些值。真实 GUI 实机验证之前不得自动化这些步骤。
