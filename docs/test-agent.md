# Test Agent 与实际支持矩阵

MMTL Test Agent 是单独构建、校验哈希并按 Loader/Minecraft 版本选择的开发测试组件。Agent 不进入用户 Mod 源码或 Mod JAR。只有存在有效 manifest、受支持版本、角色声明和匹配的 Provider artifact SHA-256 时，Agent 才显示 `Supported`。

## 当前 Agent 状态

| Loader | Minecraft | Agent Provider | 能力状态 | 当前证据 |
|---|---:|---|---|---|
| Forge | 1.20.1 | `forge-1.20.1` | Supported | manifest、JAR SHA-256、客户端/Host/Guest readiness 与 IntegratedLAN 真实 smoke |
| Fabric | 1.21.6 | 无 | Unsupported | 客户端可启动观察；Agent 事件/readiness 不可用 |
| NeoForge | 1.21.1 | 无 | Unsupported | 客户端启动 smoke 因项目 runClient 缺少 JEI compile classpath 失败 |

其它版本、Quilt、Dedicated Agent 角色均不因 Loader 可安装或项目可构建而自动视为 Agent 支持。运行 `--launch-check --json` 查看当前项目门禁。

## 状态含义

- **Project Detection**：项目结构与元数据可被探测。
- **Build**：项目 Gradle 构建在当前环境成功。
- **Launch**：当前平台的运行时 Java Binding 与 Launch Check 允许启动。
- **Agent**：存在版本匹配、完整性校验通过的 Agent Provider。
- **IntegratedLAN**：对应 Agent/协议下真实 Host/Guest loopback 联机通过。

这些能力彼此独立。Agent 不受支持时，MMTL 必须明确显示 Unsupported，不应伪造 readiness 或把静默等候当成 Agent 验证通过。
