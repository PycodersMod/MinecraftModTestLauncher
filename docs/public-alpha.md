# Public Alpha 0.1.0-alpha.1

MMTL 当前以本地可复现源代码包形式提供 Public Alpha。此阶段不创建 GitHub Release 或正式 tag。Alpha 状态表示产品接口和 Loader Agent 矩阵仍在扩充中。

## 初始化

```powershell
./windows/launcher.ps1 --init
```

初始化只在目标文件不存在时创建配置与 Registry；重复执行不覆盖已有用户配置或 Registry。默认 Profile 指向 IntegratedLAN 示例，但其项目路径为空，必须先导入项目并设置路径。示例使用离线测试身份和本机 loopback。Dedicated 示例将 `acceptEula` 保持为 false。

可通过 `--config-file <path>` 指定本机配置路径；`--portable` 将 Runtime 放在 MMTL 程序目录下。请勿把生成的 `launcher.config.json`、Runtime/Registry、Session、游戏世界或日志提交到公开仓库。

## Package 再生成

在仓库根目录执行：

```powershell
./tools/Build-PublicAlpha.ps1
```

脚本按 `tools/public-alpha-allowlist.json` 构造内容，生成版本目录、SHA-256 清单与固定文件顺序/时间戳的 ZIP。构建输出默认在 `artifacts/public-alpha/`；它仅为本地交付文件，不自动上传。

allowlist 排除 Git 元数据、本机配置、Registry、运行目录、世界、日志、JDK/Minecraft Runtime、测试结果和用户 Mod 工程。修改 allowlist 后，需重新审查并解压 smoke 测试。

## 支持声明

请根据 [Test Agent 与实际支持矩阵](test-agent.md) 区分项目检测、Build、Launch、Agent 和 IntegratedLAN 证据。未经验证的 Loader 版本不得标为 Supported。CI 与 WSL 结果也不能替代 Linux GUI 客户端实机验证。

本地 Alpha 候选的门禁状态见 [Alpha readiness checklist](alpha-readiness-checklist.md)。

机器可读的版本、平台能力、Agent Provider 与已知边界见 [`common/config/public-capabilities.json`](../common/config/public-capabilities.json)。分发构建会核对该声明与 `VERSION` 及实际 Agent Provider manifest。
