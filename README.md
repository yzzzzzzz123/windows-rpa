# Windows RPA Skill：由 AI 驱动抖音评论流程

当前目录本身就是完整的 **windows-rpa Skill，版本 0.3.2**。AI 读取 `SKILL.md` 后理解任务、生成配置、调用执行器、读取状态并控制运行。底层使用 Windows PowerShell 5.1 + Win32 SendInput + Windows UI Automation；无需另接模型 API。

## 让 AI 使用

在支持本地 Skill 和 Windows 命令执行的 AI 会话中，直接指定本目录 `SKILL.md`，或者在技能已被发现后使用 `$windows-rpa`：

`scripts/Register-Skill.ps1` 可在用户技能目录建立指向本目录的链接，让 AI 自动发现；代码仍只在当前目录维护。

> 使用 $windows-rpa，围绕 AI 视频剪辑和无限画布预演一条，先不发布。

> 使用 $windows-rpa，按当前已确认的选题和评论持续运行，并检查状态。

> 使用 $windows-rpa，查看当前进度，然后暂停。

AI 的主入口是 `scripts/Invoke-DouyinSkill.ps1`，提供 Describe、Check、Start、Status、Pause、Resume、Stop、Monitor，返回 JSON。任务文件设置本次选题、评论、数量或持续方式；每次任务都有 JobId、配置快照、进程身份、日志和页面证据。详情见 `references/operations.md`。

```powershell
# 能力和实际数据位置
& .\scripts\Invoke-DouyinSkill.ps1 -Action Describe

# 启动不操作桌面的自检，然后按返回 JobId 查状态
& .\scripts\Invoke-DouyinSkill.ps1 -Action Check
& .\scripts\Invoke-DouyinSkill.ps1 -Action Status

# AI 写好任务 JSON 后执行
& .\scripts\Invoke-DouyinSkill.ps1 -Action Start -TaskFile .\config\task.preview.json
& .\scripts\Invoke-DouyinSkill.ps1 -Action Pause
& .\scripts\Invoke-DouyinSkill.ps1 -Action Resume
& .\scripts\Invoke-DouyinSkill.ps1 -Action Stop
```

默认任务数据位于 `evidence/skill`，去重继续使用现有 `evidence/douyin-state`。启动控制器隐藏自己的 PowerShell 窗口，Chrome 仍在当前桌面中被操作。持续运行由 RPA 进程执行，AI 会话负责读取和决策；不代表关闭对话后还有模型持续思考。

## 打包与验证

`scripts/Build-Skill.ps1` 生成独立的 `dist/windows-rpa-0.3.2.zip`，只包含运行所需的 Skill、源码与配置，不含历史评论、截图、登录态、工作目录或 Git 数据。解压后的 Skill 无需引用原项目代码。迁移时另行保留去重记录。

`tests/Verify-Skill.ps1` 验证后台启动、暂停确认、恢复、停止、旧任务控制拒绝、重复实例、PID 启动时间校验，以及迁移到中文和特殊字符路径后的运行。测试使用无桌面动作的执行夹具；真实页面预演另行记录。

下列原生入口保留供直接运行和排障使用；AI 默认使用上述任务接口。

## 运行入口

先在 Windows 桌面打开已登录的抖音 Chrome 窗口。需要唯一的抖音 Chrome 窗口，其他 Chrome 标签页可保留。

| 入口 | 行为 |
| --- | --- |
| `Preview-Douyin-RPA.cmd` | 自动发现并检查 1 条视频的评论区；不输入、不发送评论 |
| `Run-Douyin-RPA.cmd` | **真实发布，持续运行，无总条数上限**；同一视频最多提交一次 |
| `Inspect-Douyin.cmd` | 检查窗口、自动激活、读取控件并截图 |
| `Pause-RPA.cmd` | 请求在下一个检查点暂停 |
| `Resume-RPA.cmd` | 清除暂停和停止标记；已退出的程序需要重新启动 |
| `Stop-RPA.cmd` | 请求停止，等待期间也会响应 |
| `Monitor-RPA.cmd` | 打开每 2 秒刷新的监控窗口和托盘状态，不启动第二个发布进程 |
| `Check-Project.cmd` | 代码、配置、状态和输入保护检查；不操作桌面 |

持续模式会轮换搜索词，按配置间隔逐条处理新视频。没有新视频时等待再搜索；不会为凑数量重新给已记录的视频发送。程序重启后继续使用本地发送记录。运行期间会自动把 Chrome 切回前台，因此会占用鼠标和键盘焦点。

按住 **Escape** 也可停止。停止标记通常在 200 毫秒轮询中被发现，但正在执行的 UIA / 系统调用可能延迟响应。已经发出的提交不会被撤销。

## 配置

修改 `config/douyin.json`：

- `SearchTerms`：轮换搜索词，默认 AI 视频剪辑、AI 分镜创作、AI 无限画布。
- `MatchAny`：候选视频标题至少匹配一个词；用于过滤搜索结果。
- `Comment`：固定评论文本，默认使用本次任务指定内容。
- `Browser.AutoActivate`：是否自动切回已确认的 Chrome 窗口，默认开启。
- `Timing.CommentIntervalSeconds`：提交之间的固定间隔，默认 **10 秒**；重启也读取上次提交时间。
- `Timing.EmptyQueueWaitSeconds`：每轮搜索结束后的等待，默认 **300 秒**。
- 验证码等待不自动超时退出；用户完成验证后继续，等待期间仍响应暂停与停止。
- `Discovery.MaxScrollRounds`：每次搜索最多滚动次数，默认 3。
- `Discovery.MaxVideosPerSearch`：每个搜索词每轮最多收集 12 条未处理视频。
- `Selectors`：实测页面的 UIA 选择器；页面改版导致不匹配时停止，不猜测发送按钮。

配置修改在重新启动后生效。`MaxVideos=0` 表示无总条数上限；还需同时启用 `Continuous` 才会持续轮询。

## 命令行

在项目目录使用 64 位 Windows PowerShell 5.1：

```powershell
# 默认主流程：预演 1 条，不发布
powershell.exe -NoProfile -File .\scripts\Invoke-Rpa.ps1

# 真实发布，持续搜索新视频，不限制总条数
powershell.exe -NoProfile -File .\scripts\Invoke-Rpa.ps1 -Publish -Continuous -MaxVideos 0

# 有界运行：本次最多处理 3 条新视频
powershell.exe -NoProfile -File .\scripts\Invoke-Rpa.ps1 -Publish -MaxVideos 3

# 窗口检查
powershell.exe -NoProfile -File .\scripts\Invoke-Rpa.ps1 -Scenario DouyinInspect

# 代码和状态自检
powershell.exe -NoProfile -File .\tests\Verify-Project.ps1

# 最近一次运行
powershell.exe -NoProfile -File .\scripts\Get-LatestRun.ps1
```

`-ConfigPath`、`-EvidenceRoot`、`-StateRoot` 可以覆盖默认路径。使用自定义 `StateRoot` 时，控制脚本也要传同一路径。启动器不调整执行策略、安全设置或登录权限。

## 自动切回与提交记录

每次操作检查桌面、Chrome 进程、窗口归属、前台焦点和抖音地址。需要切回时先恢复窗口并调用标准激活；仍未取得焦点时，仅在实时命中测试确认属于该 Chrome 的可见标题栏上点击。仍被遮挡时使用该窗口暴露的 UIA WindowPattern 恢复窗口，原先最大化则还原最大化状态，随后重新核对前台句柄。不会点击被别的窗口遮住的坐标。无法激活则停止。

发布前同时核对地址栏和网页文档的视频编号，避免视频连播切换导致发错目标。评论使用原生 Unicode 键盘输入，输入后逐字回读；不以直接设置 Draft 编辑器的 UIA 值代替真实输入。

提交前用排他创建写入视频记录，然后只点击一次发送。发送动作返回后记录 `Submitted`，不刷新、不检查评论是否可见，按间隔继续下一条。Submitted 只表示执行过发送动作。出现单条异常时保留记录并跳过该视频，不自动重试，也不因此结束持续任务。

只有短信验证码、安全验证等验证码步骤触发等待人工处理，不自动获取、填写或绕过验证。验证完成后继续后续视频，不重复点击当前视频的发送按钮。浏览器暂不可用时等待恢复；输入前的窗口、焦点、网址和文字检查继续生效，用户手动停止也始终有效。

## 状态与证据

Skill 持续任务自动开启独立监控。窗口显示进程是否存活、运行器心跳、当前步骤、提交/跳过数、实际间隔和等待倒计时；验证码、异常退出、心跳超时会通过系统托盘提醒。窗口不置顶、不抢 Chrome 焦点，可以从任务栏或托盘打开；关闭窗口只是收起监控，不停止任务。双击 `Monitor-RPA.cmd` 可再次显示。监控持续写入 `evidence/skill/monitor/status.json` 与 `events.jsonl`，即使结束 AI 对话仍可运行。

`HeartbeatAt` 每约 2 秒在运行器检查点更新，等待间隔和暂停期间也会更新；`UpdatedAt` 保留步骤进展时间。进程存活但心跳超过 60 秒时明确显示可能卡住，不将其当作正常运行；监控只观察，不自动重启或重发。状态中的提交数属于当前 JobId，正常重启后重新计数，历史去重记录保留。

- `evidence/runs/<时间>-douyin-<进程号>/`：本次运行摘要、焦点记录及各视频的页面证据。
- `evidence/douyin-state/videos/<视频编号>.json`：跨运行去重记录，包含 `Submitting`、`Submitted`、`Published`、`NeedsVisualReview` 等状态。
- `evidence/douyin-state/runner.lock`：防止同一状态目录下同时运行多个实例。
- `evidence/douyin-state/control/`：暂停、停止标记。

所有已记录的视频都阻止自动重发，包括 `Submitting`、`Submitted` 和 `NeedsVisualReview`。不要通过删除状态文件来猜测是否发布成功。历史单次验证目录中的提交记录会自动导入；只有即时成功证据的旧记录导入为 `Submitted`。

`PreviewCompleted` 仅代表不发布预演完成；`Completed` 代表本次有界流程结束。持续模式通过停止入口结束为 `Stopped`。退出码：0 正常完成/停止；2 待人工处理或核验；1 阻塞或失败。

截图、评论和运行记录只存本地，已由 Git 忽略。它们会随运行增长，应按实际磁盘容量保留和归档。

## 源码结构与验证范围

- `scripts/Invoke-Rpa.ps1`：统一入口，默认抖音。
- `scripts/Invoke-DouyinRpa.ps1`：运行生命周期、互斥锁和结果状态。
- `src/core/Browser.ps1`：窗口归属、URL、焦点、UIA 和页面证据。
- `src/core/RpaState.ps1`：原子状态写入、去重、控制信号。
- `src/core/Douyin.Configuration.ps1`：配置与抖音 URL 校验。
- `src/workflows/Douyin.Comment.ps1`：搜索、评论、验证码等待与持续循环。
- `src/native/DingRpa.cs`：共享 Win32 接口；保留旧类型名称兼容已有流程。
- `tests/Verify-Douyin.ps1`：配置、恶意 URL、原子记录、重复提交、互斥和停止检查。

原钉钉入口及源码保留为兼容场景。主流程已完成真实页面预演、自动切回与单次提交验证。用户随后确认看到了评论，并明确取消提交后可见性检查。回归覆盖直接记录发送动作、验证码等待、截图失败继续以及单条异常后继续下一条。长时间无人值守运行尚未做耐久验证。
