# 环境 Doctor 与平台能力

Doctor 汇总 MMTL、平台、Java、配置、项目、Gradle Wrapper、Runtime Root、Session、磁盘、内存、缓存和启动准备状态。结果由稳定的 `checks[]` 项组成，每项包含检查 ID、类别、状态、严重级别、中文说明和 remediation code。

## 只读行为

`--doctor` 默认不刷新网络元数据。`--doctor --offline` 明确跳过网络检查。Doctor 不构建项目、不启动进程、不安装或下载 Java、不登录、不修改配置，也不会改写 EULA。检查凭据或代理时仅报告是否存在，不输出值。

Doctor 的 `WARN` 代表可用性或缓存提醒；`FAIL` 代表当前检查到不可用或配置错误。它描述环境，不替用户自动修复问题。缺失可选缓存不等同于项目构建失败。

## Java Discovery

Java Discovery 只发现候选 JDK 并返回供应商、版本、架构、JDK Home、`java`/`javac` 路径、发现来源与排序。它不会修改 `JAVA_HOME`、PATH 或 Config，也不会递归扫描磁盘。Windows 只读检查受支持的标准目录、环境信息和注册表；Linux/macOS 检查标准安装目录及 PATH/JAVA_HOME。

Windows 与 Linux 是独立 Java 运行环境。WSL 中没有 Linux JDK 时，Windows JDK 不会自动成为 Linux Build Java。

## Capability

`--capabilities` 输出当前平台已声明的 Build、Launch、WindowManagement、ProcessManagement、JavaDiscovery、Doctor、RuntimeBinding 与 SessionManagement 能力。`Native` 表示该平台实现可用，不代表每个 Minecraft 版本、Loader 或项目均已通过验证。`Unsupported` 和 `BuildOnly` 必须如实保留，不能由另一个平台或 GUI 运行环境代替。

```powershell
./windows/launcher.ps1 --doctor --offline --json
./windows/launcher.ps1 --capabilities --json
./windows/launcher.ps1 --explain-java --json
```

`--explain-java` 分开展示 Build Java 与 Runtime Java 的 requirement 和本机解析，不会启动 Java 或 Gradle。
