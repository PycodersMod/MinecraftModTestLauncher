# 启动与 Session 生命周期

`Start-MMTL.bat` 使用自身所在目录定位 `Start-MMTL.ps1`；PowerShell 入口再以 `$PSScriptRoot` 解析模块、配置、Agent Provider 和相对运行路径。因此从桌面快捷方式、文件总管或其他当前目录启动时，内部路径保持一致。

每个客户端拥有独立离线身份、游戏目录、Agent 事件文件和 PID/窗口记录。Host 的 Integrated Server 只绑定 loopback；Guest 连接前，控制器等待 Host 报告实际端口并做监听校验。Guest 连接由 Forge Agent 在主菜单就绪后发起。

交互终端保持 Session 状态可见。`Q` 触发正常关闭，控制器收集 Agent 事件、写入 JSON/Markdown 报告并检查 LAN 端口释放；只有登记且身份核验通过的进程可进入回退停止流程。意外启动失败也会生成失败报告。

`runtime/` 保存本机运行数据，应作为临时产物管理。它可能包含游戏世界、事件流和本机路径；仓库 `.gitignore` 已将其排除。
