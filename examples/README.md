# 示例 Profile

`single.example.json`、`integrated-lan.example.json` 与 `dedicated.example.json` 是独立 Profile 示例。导入你的 Mod 项目后，把每份文件的 `project` 更新为项目根目录，再复制到本机 `launcher.config.json` 的 `profiles` 对象中。

IntegratedLAN 用离线 Test Identities，并由匹配 Agent 限制为 loopback listener。Dedicated 示例的 `acceptEula` 必须继续保持 false，直到用户已经自行接受 EULA。
