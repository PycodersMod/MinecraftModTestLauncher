# Forge 1.20.1 BAT 九场景历史验收摘要

- 日期：2026-10-22（北京时间）
- 目标：Minecraft 1.20.1 / Forge 47.4.23 / Java 17 / Windows
- 正式入口：`Start-MMTL.bat`
- 汇总：**8 PASS / 1 FAIL**。本摘要复用已归档的实机证据，不是本轮新启动的游戏测试。

| 循环 | 场景 | 结果 | 真实稳定观察 | 结果摘要 |
|---:|---|---|---:|---|
| 1 | 默认单窗口 | PASS | 10.032 秒 | 一个客户端进入隔离世界，安全停止 |
| 1 | 命令行双窗口 | PASS | 10.035 秒 | Host 与一个 Guest 进入同一 Integrated LAN 世界 |
| 1 | 配置文件三窗口 | FAIL | 未开始 | Host 成功发布 LAN；Guest 在连接约 31.204 秒后报告 `Guest Netty read timeout (disconnect.timeout): Timed out`；第二个 Guest 未启动 |
| 2 | 默认单窗口 | PASS | 10.037 秒 | 一个客户端进入隔离世界，安全停止 |
| 2 | 命令行双窗口 | PASS | 10.044 秒 | Host 与一个 Guest 进入同一 Integrated LAN 世界 |
| 2 | 配置文件三窗口 | PASS | 10.047 秒 | Host 与两个 Guest 均进入同一世界，Host 观察到三名玩家 |
| 3 | 默认单窗口 | PASS | 10.050 秒 | 一个客户端进入隔离世界，安全停止 |
| 3 | 命令行双窗口 | PASS | 10.033 秒 | Host 与一个 Guest 进入同一 Integrated LAN 世界 |
| 3 | 配置文件三窗口 | PASS | 10.052 秒 | Host 与两个 Guest 均进入同一世界，Host 观察到三名玩家 |

## 失败处理与解读

失败轮中，控制器记录阶段为等待 Guest 进入世界，Host 仅观察到 Host 玩家；控制器随后安全关闭已启动窗口并确认 LAN 端口释放。失败没有从统计中删除，也没有被后续成功覆盖。现有证据与约 31 秒登录时限现象相符，但不足以证明是 Windows/电脑本身故障，也不足以证明本问题已修复。

配置解析期间另修复了命令行客户端数覆盖单人 Profile 时默认玩家列表不足的问题。自动化结果为定向配置测试 5/5，仓库标准 Pester 491 passed / 0 failed / 2 skipped。该摘要不把配置测试当作游戏实测。

## 来源与隐私

本摘要根据本机归档记录整理。来源报告 SHA-256：

`8a57a82470cfc28e8a238ac233c15f952b470ee8d2677cd1c0d4fdb3f48b76fd`

原始 Session、游戏日志、事件 JSONL、绝对路径、PID、窗口句柄和用户数据均留在本机，没有复制到此公开摘要。机器可读数据见 [`acceptance-summary.json`](acceptance-summary.json)。
