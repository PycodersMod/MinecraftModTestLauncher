# 项目导入与识别边界

使用 `--import-project <path>` 只读扫描并登记任意 Gradle Mod 项目。导入不运行项目脚本、不构建项目、不改写项目文件。MMTL 发现 Gradle 根、Minecraft/Loader/toolchain、Mod ID、入口点、Mixin 与 package 候选，结果写入本机 Runtime 的 `project-registry.json`。

```powershell
./windows/launcher.ps1 --import-project "<项目根目录>" --json
./windows/launcher.ps1 --list-projects --json
./windows/launcher.ps1 --project-info <project-guid> --json
```

含多个 Mod ID 的项目需要在 Profile 中设置 `primaryModId` 或导入时传 `--primary-mod-id <id>`。未唯一确认主 Mod 时，Launch Check 应保留歧义阻塞。导入项目是用户拥有的输入；不要把项目脚本当作可信代码，也不要让 MMTL 自动改动项目。

“检测成功”不代表 Build 成功。先检查 Plan 和 Launch Check，再通过 `--build` 显式构建。完整边界见 [执行计划与 Launch Readiness](execution-plan-session.md)。
