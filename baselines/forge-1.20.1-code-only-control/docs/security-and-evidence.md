# 安全边界与验收证据

- 身份模式是本地离线测试身份；不读取认证凭据、不访问第三方服务器。
- Agent 和控制器使用 Session、角色、实例、Nonce、PID 身份校验来关联事件和受管进程。
- LAN 仅使用本机 loopback Integrated Server；代码不会修改系统防火墙。
- 原始 Session、游戏日志和世界数据仅保留在运行机器的本机运行目录，不随本目录发布。
- `evidence/acceptance-summary.*` 是根据归档验收报告制作的脱敏摘要。它省略用户名目录、Java/游戏绝对路径、PID、窗口句柄、日志内容和原始 Session ID；不会伪装成新一轮实机测试。
- `evidence/agent-provenance.json` 记录 Agent JAR 的构建任务、重复构建 SHA-256、运行清单校验，以及与历史 Session 内 31 个 JAR 条目的内容比较结果。
- 2026-10-22 九个启动场景中有一个真实三客户端登录超时。其余场景的 PASS 不会覆盖该失败；稳定性问题仍待后续定位。
