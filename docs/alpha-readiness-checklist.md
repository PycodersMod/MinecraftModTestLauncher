# Public Alpha 本地就绪检查

- [x] `--init` 创建本机配置、Runtime、空 Registry、Session 根与三种示例 Profile。
- [x] 重复 `--init` 不覆盖既有配置或 Registry；损坏 Registry 会失败且保留原始内容。
- [x] 默认 Profile 为 IntegratedLAN 示例；离线 Test Identity 与 loopback 边界有明确说明。
- [x] Dedicated 示例 `acceptEula=false`，不生成或接受 EULA。
- [x] 分发包从显式 allowlist 构建，带版本、SHA-256 清单及 ZIP 哈希。
- [x] 双次分发构建 SHA-256 一致；解压后逐文件 SHA-256 smoke 通过。
- [x] Provider manifest 与 Forge Agent JAR 的 SHA-256 一致。
- [ ] 完成 Task 13 的全量 Pester、Agent 测试、平台 CI 与隐私复核后，才可将本地 Alpha package 视作候选交付。
- [x] 当前任务不创建 GitHub Release 或正式 tag。

当前本地验证包使用版本 `0.1.0-alpha.1`。Alpha readiness 不代表所有 Loader、平台 GUI 或 Agent 功能都受支持；查看 [实际支持矩阵](test-agent.md)。
