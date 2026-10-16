# Windows 原生 RPA Skills

这是多个 Windows 原生 RPA Skill 的维护项目，当前版本 **0.4.0**。各 Skill 独立承载业务流程，共用 Win32 接口与截图函数；两个抖音 Skill 另共用 Chrome、URL、评论区控件和发送冷却函数。

| Skill | 能力 | AI 入口 |
| --- | --- | --- |
| [douyin-rpa](skills/douyin-rpa/SKILL.md) | 按选题发现抖音视频、评论预演与授权发布、持续运行、暂停恢复停止和监控 | `skills/douyin-rpa/scripts/Invoke-DouyinSkill.ps1` |
| [douyin-reply-rpa](skills/douyin-reply-rpa/SKILL.md) | 读取动漫评论区候选，宽容筛选找番、哪里看、求推荐及播放困难，生成提到漫映免费动漫资源分享的自然回复，支持预演、默认直接发布定向回复及暂停恢复停止 | `skills/douyin-reply-rpa/scripts/Invoke-DouyinReplySkill.ps1` |
| [dingtalk-rpa](skills/dingtalk-rpa/SKILL.md) | 应用中心 → 低代码平台 → 向下滚动 → 搜索框输入 test | `skills/dingtalk-rpa/scripts/Invoke-DingTalkRpa.ps1` |

## 目录归属

```text
windows-rpa/
├─ skills/
│  ├─ douyin-rpa/       # SKILL、agents、config、scripts、src、tests、launchers、references
│  ├─ douyin-reply-rpa/ # 独立评论区定向回复 Skill
│  └─ dingtalk-rpa/     # SKILL、agents、config、scripts、src、tests、launchers
├─ shared/             # Win32、截图函数、运行路径解析；douyin/ 为两个抖音 Skill 共用
├─ scripts/            # 项目级打包和发现链接注册
├─ tests/              # 统一验证与跨 Skill 结构验证
├─ docs/               # 项目状态、结构与版本变更
├─ data/               # 本地真实运行数据，不提交
│  ├─ douyin-rpa/      # jobs、state、monitor、runs 等
│  ├─ douyin-reply-rpa/ # jobs、候选评论、回复状态与证据
│  ├─ dingtalk-rpa/    # runs
│  └─ legacy/          # 保留的历史证据
└─ artifacts/          # 测试临时目录、ZIP、迁移备份，不提交
```

仅 `shared` 可以被多个 Skill 共用。各 Skill 的业务配置、发现与提交流程和控制接口独立维护；没有默认派发到某个平台的根目录运行器。项目 Skill 默认只保存在本项目 `skills` 下，不安装、复制或链接到全局 Skill 库。

## 使用

在 64 位 Windows PowerShell 5.1 中，从项目根目录执行：

```powershell
# 抖音能力、实际数据路径及现有任务（只读）
& .\skills\douyin-rpa\scripts\Invoke-DouyinSkill.ps1 -Action Describe
& .\skills\douyin-rpa\scripts\Invoke-DouyinSkill.ps1 -Action Status

# 定向回复能力与当前任务（只读）
& .\skills\douyin-reply-rpa\scripts\Invoke-DouyinReplySkill.ps1 -Action Describe
& .\skills\douyin-reply-rpa\scripts\Invoke-DouyinReplySkill.ps1 -Action Status

# 钉钉完整流程，会操作当前桌面
& .\skills\dingtalk-rpa\scripts\Invoke-DingTalkRpa.ps1

```

抖音任务 JSON、预演与发布授权、暂停恢复停止规则见 [运行协议](skills/douyin-rpa/references/operations.md)。真实发布必须显式选择 Publish 并提供评论；每次提交至少间隔 60 秒。Submitted 只表示执行过发送动作，不能当作平台可见性已确认。

定向回复采用 `Discover → 当前 AI 决策 → Preview/Publish`。Discover 按单视频有界读取真实评论，当前 AI 采用宽容口径筛选问哪里看、求番名、求推荐、想看想追或有来源与播放困难的用户，不要求明确提到免费，并逐条直接回应原问题、提到漫映；文案用短句，免费和资源多按需提，不复述提问或套品牌介绍。对外回复直接提“漫映Manying”，不写“公众号”等入口标签，不保证具体作品或全集可用。关键词只帮助缩小候选范围；后台 RPA 不调用模型，持续筛选由当前 AI 与用户明确要求的系统持久目标推进。回复任务引用同一数据目录中 Discover 生成的候选，绑定作者、原评论和具体回复文本。按用户设定，定向回复默认直接 Publish 并持续处理，无需逐次发送授权或文案确认；发送点击及成功后进入下一视频的最小间隔均为 10 秒，未指定数量时没有累计上限。用户明确指定数量、指定批次、只发现或预演时按该范围执行；单独维护、测试或构建不触发真实发送。持续进度保存在本 Skill 的 `state/persistent-goal.json`，接续沿用真实账本与下一视频截止时间。从 WSL/Windows 会话 0 调用定向回复 Start 时，默认经单次任务计划程序桥接到同账号已登录的活动会话；仍要求桌面解锁，取得回执后删除桥接任务。具体任务格式见 [回复 Skill](skills/douyin-reply-rpa/SKILL.md)。

原抖音评论和钉钉的手动双击入口在各自的 `launchers` 目录；定向回复通过 Skill 的 AI 控制入口使用。钉钉默认直接 Run；其搜索框只输入 test，不按回车。

## 验证与独立分发

```powershell
# 全部为离线验证，不操作应用、不发送评论
& .\tests\Verify-Project.ps1

# 各自生成自包含包，默认仅保留 ZIP
& .\scripts\Build-Skill.ps1 -Skill douyin-rpa
& .\scripts\Build-Skill.ps1 -Skill douyin-reply-rpa
& .\scripts\Build-Skill.ps1 -Skill dingtalk-rpa
```

ZIP 输出到 `artifacts/dist`，包含对应 Skill、按需复制的共享运行代码、版本及哈希清单，不携带 data、测试副本、登录态或历史记录。钉钉包不包含抖音共享代码。解压后的 Skill 可以独立运行；源码下的单个 Skill 目录依赖项目 shared，不能只拷源码目录迁移。离线验证中，原抖音与钉钉包执行无桌面自检，回复包通过只读 Describe 检查改名后的身份与路径；不以 Discover 代替自检。

项目内默认数据由路径解析器定位到 `data/<skill-name>`；独立 ZIP 使用 Skill 下的 `data`。回复 Skill 的任务、候选与回复账独立保存在 `data/douyin-reply-rpa`；项目内通过 `SharedSubmissionRoot` 与原抖音 Skill 共用发送互斥和冷却，避免同一浏览器并行发送。迁移时保留已有记录，通过 Describe 核对实际路径。独立包中共享发送状态位于包内的 state。

`scripts/Register-Skill.ps1` 保留为需要明确全局注册授权时才使用的维护工具，其默认集合仍为原来的抖音评论和钉钉，不自动包含新回复 Skill。普通创建、验证、打包和使用均不调用真实全局注册。

这次整理前的源码和数据路径备份保存在 `artifacts/backups`，迁移核验在 `artifacts/migration`。更多结构说明见 [目录与依赖](docs/LAYOUT.md)。
