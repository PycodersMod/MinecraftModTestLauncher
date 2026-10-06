# 离线 Test Identities

非交互 Scenario 会为每个受管客户端生成确定性的本地离线身份、独立游戏目录、配置、日志、截图与世界路径。身份只作用于当前 MMTL Session，用于本机开发观察，不是正版账号，也不能用于加入公网服务器。

身份目录与 token 由 Session 管理；停止 Session 时仅停止其登记且身份校验一致的进程。不得把 Session token 写入命令行、公共报告或项目 Mod。

MMTL 不请求 Microsoft 登录、不读取启动器账号数据库、不保存凭据。手动交互启动仍由用户当前环境决定认证方式。
