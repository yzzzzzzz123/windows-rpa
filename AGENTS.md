# Windows RPA 项目约定

- 使用中文解释变更、运行状态和故障。先阅读 README.md 与 docs/STATUS.md。
- 当前主流程为抖音评论 RPA，使用 Windows PowerShell 5.1 + Win32 + UI Automation；不使用 CUA、CDP、浏览器私有接口或固定屏幕坐标。所有 .ps1 保留 UTF-8 BOM。
- 当前目录本身就是 windows-rpa Skill；AI 入口为 SKILL.md 与 scripts/Invoke-DouyinSkill.ps1，不在其他嵌套项目维护第二份 Skill。原生入口 scripts/Invoke-Rpa.ps1 保留兼容。抖音业务在 src/workflows/Douyin.Comment.ps1，桌面能力在 src/core/Browser.ps1，原生接口在 src/native/DingRpa.cs。
- AI 通过任务 JSON 配置选题和精确评论，启动返回 JobId 的后台进程，再读取 JSON 状态进行控制。只请求封装、检查 Skill 不等于启动持续实发。不能把后台 RPA 进程存活描述成 AI 在对话外持续推理。
- Skill 默认任务数据为 evidence/skill，去重为 evidence/douyin-state。保持 PID 与进程启动时间联合校验、任务身份隔离、暂停确认及停止标记。新任务启动后不得清除刚收到的停止指令。
- 默认验证为 powershell.exe -NoProfile -File .\tests\Verify-Project.ps1；它包含 Skill 后台控制回归且不执行桌面输入。真实桌面动作需要用户当前授权。真实发布必须由明确的 Publish 模式或参数启动；默认原生命令只预演。
- 用户已选择持续轮询模式与自动切回 Chrome。外层循环可无总条数上限，但每次发现、滚动、等待、激活、输入和提交必须有明确边界。同一视频不得自动重复发送。
- 默认只操作已解锁的 Default 桌面；遇到隔离或安全桌面停止输入并等待恢复，不能通过服务、任务、代理或跨桌面进程绕过。
- 自动切回只针对已确认的 Chrome 进程与窗口；先正常激活，必要时仅点击经实时 WindowFromPoint/WM_NCHITTEST 确认为该窗口的可见标题栏。仍未激活时可用该窗口的 UIA WindowPattern 恢复到 Normal 后还原原有最大化状态。最终以前台句柄回读为准；仍失败即停止，不修改 Windows 焦点策略或安全设置。
- 输入前检查前台、进程归属、Escape 与当前 URL。评论提交前同时核对地址栏及 Document 视频编号。焦点中途丢失不能把输入发向任意窗口；结果未知不能盲目重试。
- 评论采用原生键盘输入并逐字回读。不要使用 ValuePattern.SetValue 给 Draft 编辑器赋值；地址栏可使用该模式。
- 单实例锁与提交前落盘记录必须保留。Submitting、Submitted、Published 和 NeedsVisualReview 都应阻止自动重发。不要为重跑测试删除真实提交记录。
- 用户明确要求发送后不刷新、不检查评论可见性；只有验证码/安全验证触发等待人工处理。验证完成后继续，不默认再点发送。普通单条异常记录并跳过，浏览器不可用则等待恢复；手动暂停、停止和 Escape 仍须响应。
- Submitted 表示已执行一次发送动作，不代表平台可见性已核验；新流程不自动生成 Published。用户明确表示看到了某条评论时可记 ConfirmedByUser。未知提交保留 NeedsVisualReview 并跳过，不结束整批任务、不自动重发。
- evidence/、work/、截图和原始控件树不得提交；业务页面内容只放本地证据，不写入公开文档或测试样例。
- Git 提交说明使用清晰具体的中文；没有上传要求时不推送远程仓库。
