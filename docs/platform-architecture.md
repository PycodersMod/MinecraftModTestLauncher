# MMTL 平台架构

## 目录职责

- `common/` 保存平台无关核心、通用契约、目录发现、版本与 Loader catalog、Java 需求、兼容性与覆盖审计、配置、Gradle 计划、schema、fixture 和通用测试。
- `windows/` 保存 Windows 入口、Windows 平台提供器、CIM 进程快照、窗口管理和 Windows 专属测试。
- `linux/` 保存 Linux 入口、Linux 平台提供器、WSL 环境元数据、`/proc` 进程快照和 Linux 专属测试。
- `macos/` 保存 macOS 入口、macOS 平台提供器与 macOS 系统查询；暂不支持的窗口和进程能力显式标记为 `Unsupported`。
- 根目录的 `docs/` 保存仓库级文档；`.github/` 保存 CI 与仓库基础设施。

## 依赖方向

```text
windows ──┐
          │
linux   ──┼──→ common
          │
macos   ──┘
```

唯一允许的平台实现依赖方向是 `OS → common`。`common → windows/linux/macos` 和任何 `OS → sibling OS` 依赖都禁止。多个系统可共用的实现必须放在 `common/`，不允许通过调用另一个平台目录复用。

## 入口与注入

每个 `windows/launcher.ps1`、`linux/launcher.ps1`、`macos/launcher.ps1` 都是 composition root：它从 `$PSScriptRoot` 推导仓库根，加载 `common/` 契约与本平台 provider，注册 provider，再调用 `common/src/Launcher.ps1`。common 只读取已注册的契约和回调，不探测操作系统后加载实现，也不保存平台模块路径。

Provider 声明平台身份、CPU 架构、运行目录、路径比较语义、Gradle wrapper、能力值和可选回调。进程快照/身份识别、内存查询、平台入口等通过回调注入。macOS 当前没有真实窗口管理或进程树实现，不会借用 Linux 或 Windows 实现。

所有引用 common 文件的路径均相对于平台模块的 `$PSScriptRoot` 或仓库根计算；不得使用开发机绝对路径。Linux/WSL 的 `IsWSL` 只作为 Linux 平台的验证环境元数据；Ubuntu、WSL/WSL2 和 GitHub runner 都不是独立产品平台。

## 测试

`.github/scripts/Invoke-MmtlPester.ps1` 按当前运行环境注册对应 provider，然后运行 `common/tests/` 与当前平台的专属测试。CI 分别验证 Windows、Ubuntu-hosted Linux、macOS ARM64 和 macOS Intel，并运行各平台的 CLI 安全 smoke。Windows 游戏 GUI 能力与 Linux/macOS CLI/构建能力分别报告，不以 hosted runner 或 WSL 冒充真实桌面游戏测试。
