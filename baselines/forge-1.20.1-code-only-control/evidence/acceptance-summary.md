# Forge 1.20.1 BAT 验收摘要

- 目标：Minecraft 1.20.1 / Forge 47.4.23 / Java 17 / Windows。
- 最新正式验收：**三轮九场，9 PASS / 0 FAIL**。
- 场景顺序：每轮依次为默认单窗口、命令行双窗口、配置文件三窗口。
- 每场均经交付的 `Start-MMTL.bat` 启动。报告记录真实客户端、世界加入与受控停止；多人场景另记录 Host 玩家列表、Integrated LAN 和端口释放。全部场景至少稳定 10 秒。
- 验收归档 SHA-256：`da8f2fe3307fc296669d6d59b62760b8d086a092051cb4611d2d811c1d192960`。
- 归档总报告 JSON SHA-256：`d9f89617eb931f3d09087aff582d0f41b0300d88ffa9b0275ec9078d4a484160`。
- 原始 ZIP 未纳入公开仓库：其中包含本机路径、PID、窗口句柄等机器专属字段。公开内容仅保留脱敏摘要和哈希。

| 循环 | 场景 | 客户端数 | Session | 稳定秒数 | 核心断言 | 结果 |
|---:|---|---:|---|---:|---|---|
| 1 | 默认单窗口 | 1 | `20261022T080619Z_forge-control_a34c3308` | 68.09 | 客户端进入隔离单人世界，安全停止 | PASS |
| 1 | 命令行双窗口 | 2 | `20261022T080850Z_forge-control_22970b76` | 240.24 | Host 与 Guest 同处 Integrated LAN 世界；端口释放 | PASS |
| 1 | 配置文件三窗口 | 3 | `20261022T081650Z_forge-control_63a60b21` | 10.02 | Host、Dev_1、Dev_2 加入同一世界；安全停止、端口释放 | PASS |
| 2 | 默认单窗口 | 1 | `20261022T081906Z_forge-control_eb1e07cd` | 10.04 | 客户端进入隔离单人世界，安全停止 | PASS |
| 2 | 命令行双窗口 | 2 | `20261022T082622Z_forge-control_14cb7b05` | 10.02 | Host 与 Guest 同处 Integrated LAN 世界；端口释放 | PASS |
| 2 | 配置文件三窗口 | 3 | `20261022T082806Z_forge-control_395ff5b8` | 10.01 | Host、Dev_1、Dev_2 加入同一世界；安全停止、端口释放 | PASS |
| 3 | 默认单窗口 | 1 | `20261022T083032Z_forge-control_c4851cef` | 10.02 | 客户端进入隔离单人世界，安全停止 | PASS |
| 3 | 命令行双窗口 | 2 | `20261022T083148Z_forge-control_7cc75cc2` | 10.02 | Host 与 Guest 同处 Integrated LAN 世界；端口释放 | PASS |
| 3 | 配置文件三窗口 | 3 | `20261022T083328Z_forge-control_1309dff8` | 10.02 | Host、Dev_1、Dev_2 加入同一世界；安全停止、端口释放 | PASS |

## 前置调用

两次命令行双窗口参数预检因调用参数格式错误而未通过配置校验；它们没有启动游戏进程，不计入九个正式 Session。随后修正调用并完成命令行双窗口实测。

## 历史失败记录

较早的一组独立九场景验收为 **8 PASS / 1 FAIL**，原摘要来源 SHA-256 为 `8a57a82470cfc28e8a238ac233c15f952b470ee8d2677cd1c0d4fdb3f48b76fd`。失败发生在第一轮配置文件三窗口场景：Guest 在连接约 31.204 秒后报告 `Guest Netty read timeout (disconnect.timeout): Timed out`；Host 只观察到 Dev，第二个 Guest 未启动。已启动窗口安全关闭，端口释放。该失败保留为历史记录，不由后续 9/9 覆盖或删除。

## 结论边界

最新 9/9 表明该目标和本机环境在这次连续多样化验收中可重复运行成功。它不能证明早先间歇性超时由电脑自身故障引起，也不能保证未来不会再次发生。结果仅适用于本摘要列出的 Minecraft、Forge、Java、Windows 和测试配置；本轮仓库审查没有重新启动游戏。
