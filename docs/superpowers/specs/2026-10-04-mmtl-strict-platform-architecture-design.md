# MMTL 严格跨平台架构、中文规范与 Mod README 链接设计

## 目标

在不进入 Phase H、不新增 Mod 功能、不改变 Mod 游戏行为、不改写历史提交的前提下，将 PycodersMod 当前 12 个仓库的 first-party 自然语言规范统一为中文；纠正 10 个 Mod README 的支持目标目录链接和模板泄漏；将 MMTL 根级工程代码拆分为 `common/`、`windows/`、`linux/`、`macos/`，并用自动测试冻结平台依赖方向。

## 当前基线与缺陷

- 12 个仓库的本地 `main`、`origin/main` 和 GitHub `main` SHA 相同，工作树干净；本地新提交使用已验证的主账号 noreply 身份。
- 10 个 Mod README 的 Loader 与 Minecraft 目标目前链接到外部官网；模板表达式泄漏到 10 个 README 的项目说明与构建命令中。未发现生成这些 README 的受跟踪 generator。
- 10 个 `introduction.md` 当前均为中文单语，需改为先完整英文、后完整中文，内容依据源码和现有公开文档，不补写未实现功能。
- MMTL 当前 `src/`、`tests/`、`schemas/`、`fixtures/` 与三个 launcher 位于根部；`src/Platform/Platform.psm1` 混合检测 OS、路径行为、Runtime Root、内存查询和能力声明，ProcessManager/RuntimeManager 直接选择 OS 模块；common 核心还包含 WSL 检测和 OS-specific 实现分支。
- `.github` 的治理文档、README、组织 profile 和工作流仍有 first-party 英文说明；需加入持久语言政策与 README 目录链接政策。

## 目标结构与依赖

```text
MinecraftModTestLauncher/
├── common/                  # 平台无关核心、通用 schema/fixture/test
│   ├── src/
│   ├── tests/
│   ├── schemas/
│   ├── fixtures/
│   └── config/
├── windows/                 # Windows 入口、Provider、专属实现与测试
├── linux/                   # Linux/WSL 入口、Provider、专属实现与测试
├── macos/                   # macOS 入口、Provider、专属实现与测试
├── docs/                    # 仓库级文档
└── .github/                 # CI 与仓库基础设施
```

唯一允许的代码依赖是 `windows/`、`linux/`、`macos/` → `common/`。common 不检测 OS 来加载实现，不引用 OS 子目录；平台入口作为 composition root，发现仓库根、加载 common contract、加载当前平台 provider、注入 provider 后调用 common CLI。每个平台只保留薄入口；CLI 参数解析、业务编排、配置/schema/目录发现/Java 要求/Loader 与版本 catalog/审计/验证/Gradle 计划等共享逻辑留在 common。

Common contract 通过显式注册的 provider 描述 OS identity、架构、WSL validation metadata、路径语义、默认 Runtime Root、工具名与 capability，并提供由入口注入的系统操作回调。具体进程发现/停止、Java 安装发现、OS 内存查询、Windows 窗口管理和 Windows Runtime link 行为由对应平台实现。通用逻辑基于 contract/capability 工作，不依靠 `common` 动态导入平台模块。macOS 独立 provider 不复制 Linux/Windows 源码；目前不支持的能力明确返回 Unsupported。

## Mod README 与发布介绍

每个 Mod 的“支持目标”HTML 表格为当前仓库的目录导航：Loader href 为 `<loader>/`，Minecraft href 为 `<loader>/<compatibility-line>/`。外链只能放在单独的上游/相关链接章节。自动审计解析标题下的 HTML 表格、检查两列语义、相对路径、真实目标目录、Loader 顺序、Minecraft release chronology、未解析模板表达式，并统计表格外链。规则写入 `.github` 长期治理文档，审计脚本支持单仓库与本机 10 仓库 workspace。

10 个 Mod 的 README 说明和构建指引改为中文。`introduction.md` 固定使用 English 全文在前、中文全文在后的结构，双语语义一致，只陈述实际功能；既有 changelog 如存在则采用英语全文再中文全文，不存在时不伪造。

## 语言与隐私

所有 12 仓库 first-party 面向人的自然语言默认中文，包括文档、README、注释、help/error/log、贡献与治理说明、workflow display name/step 描述、仓库 description 和新 commit 标题/正文。代码标识、API/schema/JSON 字段、enum、CLI 参数、Loader/工具名称、标准状态码、第三方 license/NOTICE、上游生成内容和固定协议内容保持原样。历史英文 commit 不改写；已有 86 项旧历史隐私发现不处理。隐私扫描、既有 GitHub rulesets 和 main 保护保持不变。

## 验收与交付

- 新增 README target link regression audit，10/10 Mod README 的 Loader/Minecraft href 均映射到现存仓库目录，支持目标表外链为 0，模板表达式泄漏为 0。
- 新增 common/平台专属架构边界测试和 root layout 测试；审计 common 的 OS 检测/系统 API；比较平台 first-party source，报告源文件数和无法抽取重复项及原因。
- MMTL 完整 Pester 至少 226 passed、0 failed；Project Discovery 10/10；Windows/Linux 入口本机安全 smoke，macOS 两 runner hosted CI smoke；保留四平台 CI，并分别运行 common + 当前平台 tests。
- 10 个 Mod Windows clean build 通过；12/12 hygiene 通过；规则集只读审计通过；不 force push；新提交均中文；各仓库最终 main/remote/GitHub 一致且无临时分支/worktree。
- 生成本地、不得提交的 `HANDOVER/PycodersMod_MMTL_Platform_Architecture_And_Language_Normalization_Report.md`，记录任务要求的 SHA、映射、计数、审计与剩余差距。

## 范围外

不开始 Phase H；不增加 Mod 功能；不改动配方、游戏玩法、协议或数据语义；不发布 CurseForge/Modrinth；不重写历史提交；不 force push；不重跑完整 Phase G。
