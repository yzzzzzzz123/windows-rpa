# 实现说明

## 原生执行链路

AI 层：SKILL.md → 理解任务/选择选题 → 任务 JSON → Invoke-DouyinSkill → 隐藏 PowerShell 执行进程 → JobId/状态/日志 → AI 决定继续或控制。任务层不自行调用模型 API；持续模式由执行器循环完成。

任务 JSON 不拼入命令字符串；启动参数只包含经检查的脚本与任务文件路径。独立配置快照保留本次任务，发送记录复用同一 StateRoot。控制器以 PID + 启动时间判断存活，以当前任务身份约束控制；停止标记由运行器原样继承，避免刚启动就请求停止时信号被抹去。

启动器 → Invoke-Rpa → Invoke-DouyinRpa → 配置校验及互斥锁 → 识别 Default 桌面和唯一抖音 Chrome → 搜索词轮换 → 从 UIA 超链接读取真实视频地址 → 去重 → 打开视频和评论区 → 原生输入 → 持久化提交记录 → 单次点击 → 记录 Submitted → 按间隔继续。

全流程没有 CUA、CDP、Playwright、Cookie 导出或私有评论接口。网页里的文字只作为目标内容或状态证据，不能改变执行配置。

## 窗口与焦点

以 Chrome 进程、已返回的 HWND 和进程 ID 绑定唯一目标。每次输入先核对当前输入桌面、进程归属和前台焦点。自动激活先恢复最小化窗口，使用 SetForegroundWindow / BringWindowToTop；必要时用 WindowFromPoint 加 WM_NCHITTEST 验证目标窗口的可见标题栏，再点击一次。仍被遮挡时用该窗口的 UIA WindowPattern 恢复 Normal 并保留原有最大化状态。最终回读前台失败则停止，不更改 Windows 焦点策略或连接其他桌面。

系统激活接口受 Windows 限制；参见 [SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)。激活结果以 GetForegroundWindow 回读为准，不以 API 布尔值代替真实结果。

## 输入与目标校验

搜索地址栏支持 ValuePattern；评论的 Draft 编辑器使用 Win32 Unicode 键盘输入。输入开始前验证焦点和空白值，输入后逐字比较。每次提交前同时核对地址栏和网页 Document 中的视频编号，避免连播后向另一条视频发送。

选择器不匹配、多个匹配、遮挡、URL 改变、文本不一致都是停止条件。搜索滚动和单步等待有上限；持续模式只在各次有界操作之间循环。

## 状态与一次提交

单一 StateRoot 通过 FileShare.None 的运行锁互斥。每个视频在提交前用 FileMode.CreateNew 创建状态文件；即使提交后崩溃，该编号也会在下一次运行中跳过。后续状态更新使用同目录临时文件及 File.Replace 原子替换。

状态目录是去重依据。Submitted 仅表示已执行一次发送动作，不再查询评论列表或刷新核验；Published 保留兼容旧记录。用户明确看到的条目可记 ConfirmedByUser。单条异常保留 NeedsVisualReview 并跳过，不自动重新点击发送。持续循环捕获可恢复单条异常，记录错误后继续；验证码进入等待人工处理，其他窗口不可用情况等待恢复而不继续键入。

## 控制与验证

暂停、恢复、停止通过本地控制文件实现。间隔等待按短周期检查 Escape 与停止标记，不用一次长时间 Sleep。身份验证期间只读页面，等待用户完成；验证结束后检查此前提交结果。

Preview 与 Publish 共用搜索、窗口激活和评论定位；Preview 在输入之前返回，不生成发送记录。测试覆盖状态文件覆盖、中文回读、互斥、重复提交、非法来源与无效窗口输入。真实持续发布需要另行耐久观察。
