# Windows RPA 多 Skill 项目约定

- 使用中文解释变更、运行状态和故障。先阅读 README.md、docs/STATUS.md，再阅读目标 Skill 的 SKILL.md 与 AGENTS.md。
- 根目录只保留项目级说明、版本、Git 配置和统一检查入口。每个 Skill 的说明、agents、配置、启动器、实现、测试、参考文档归入 skills/<skill-name>。
- 抖音顶层评论为 skills/douyin-rpa，评论区定向回复为 skills/douyin-reply-rpa，钉钉为 skills/dingtalk-rpa。各 Skill 不调用其他 Skill 的业务代码或控制入口。新增能力也遵守此边界。
- shared 仅存确实被多个 Skill 使用的原生接口、截图函数、路径约定及同平台基础能力。两个抖音 Skill 共用 shared/douyin 的 URL、Chrome 身份/前台、评论区控件和发送冷却函数；候选筛选、回复路由和提交账仍归各自 Skill。不得复制两套共享实现；独立包按依赖复制 shared，钉钉包不包含 shared/douyin。
- scripts 只放项目级打包和注册工具，tests 只放跨 Skill 的结构与统一验证；专属测试放对应 Skill/tests。
- 真实数据按 Skill 存入 data；旧证据保存在 data/legacy。临时测试、构建、备份放 artifacts。data、artifacts、原始截图和控件树不提交。
- 移动代码或数据前检查运行实例；保留任务身份、发送账、冷却、关键词池、暂停停止标记与未知提交。不能因迁移改用空状态目录重复操作。
- 默认验证：powershell.exe -NoProfile -File .\tests\Verify-Project.ps1。该命令不操作真实桌面、不发送评论。维护和整理不代表启动业务任务。
- douyin-reply-rpa 分为 Discover、当前 AI 会话读取候选并决策、Preview/Publish。关键词匹配只作候选范围过滤，不能声称是 AI 筛选；后台执行器不调用模型。定向回复默认直接 Publish 并持续处理，未指定数量时无累计发送上限，发送及成功后进入下一视频的最小间隔均为 10 秒；用户明确要求持久目标时由系统目标驱动当前 AI 继续编排，不因单轮 Completed 或候选耗尽而结束。不再逐次请求发送授权或文案确认；用户指定数量、批次、只发现或预演时按该范围处理，维护测试不启动真实发送。逐条绑定原评论、作者和回复文案。新技能的任务、候选与回复记录放 data/douyin-reply-rpa，不迁移或清空旧技能真实记录。
- 使用 Windows PowerShell 5.1 + Win32 + UI Automation；所有 .ps1 保留 UTF-8 BOM。保留桌面、窗口、焦点和输入核验，不绕过 Windows 隔离或验证码。
- Skill 默认只保存在项目 skills 目录，不自动安装或链接到全局 Skill 库。只有用户明确要求全局注册时才运行 Register-Skill.ps1；不得把整个项目根目录注册为 Skill。默认构建只保留 ZIP，测试解包副本须清理。
- Git 提交说明使用清晰具体的中文。没有上传要求时不推送远程仓库。
