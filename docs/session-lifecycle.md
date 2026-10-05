# Session 生命周期与安全恢复

每次 MMTL 运行使用独立 Session。Session v2 保存生命周期状态、Execution Plan 快照、Plan 摘要和工件哈希；旧版 Session 保持只读兼容，不会因列出或诊断而自动升级。

## 并发锁与原子写入

Session 创建与写入使用带 PID、进程启动身份、创建时间和 nonce 的锁元数据。进程身份同时比较 PID 与启动时间，避免 PID 复用误判为原 owner。重复或身份不匹配的 writer 会以稳定错误码被拒绝。

Manifest 与 Plan snapshot 先写入同目录唯一临时文件、刷新数据，再原子替换目标文件。损坏或部分写入的原始 manifest 会保留供检查，不会用猜测内容覆盖。

## 崩溃检测与恢复

合法状态包括 `Created`、`Preparing`、`Building`、`Launching`、`Running`、`Completed`、`Failed`、`Stopped` 和 `Abandoned`，状态跳转由生命周期契约校验。`--recover-sessions --dry-run --json` 只列出可执行的恢复计划；不带 dry-run 时也只修复身份可证明过期的锁或预期临时元数据。

恢复不会杀进程、删除 Session、清理项目目录或接管存活的 tracked child。仍有 tracked child 时报告 orphan 状态；PID owner 不存在但身份无法证明时采取保守跳过。恢复计划中的公开 JSON 不包含本机绝对路径。

## 进程所有权

停止操作只能针对 Session 登记并再次验证身份的进程。未登记的同级或子进程不受影响。Windows、Linux 与 macOS 的进程管理均按平台实现；macOS ARM64 与 Intel CI 已通过 dummy process-tree、PID identity/reuse 与 orphan recovery 测试，当前 `ProcessManagement=Native`。所有平台的窗口管理能力需独立声明。

```powershell
./windows/launcher.ps1 --list-sessions --json
./windows/launcher.ps1 --recover-sessions --dry-run --json
./windows/launcher.ps1 --session-info <Session-ID> --json
./windows/launcher.ps1 --session-validate <Session-ID>
```
