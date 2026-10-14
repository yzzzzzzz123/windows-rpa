# 故障排查

先用 `Invoke-DouyinSkill.ps1 -Action Status` 获取 ReportPath；原生启动器的记录在 Describe 返回的 RunsRoot 下，再查看 `focus.jsonl` 和对应视频子目录的截图、控件树。不要只看“已点击”判断发布结果。

## 自动切回失败

`focus.jsonl` 记录切回前后窗口与所用方法。程序先使用标准窗口激活，必要时只点击实时确认属于 Chrome 的可见标题栏；失败后尝试该窗口的 UIA WindowPattern 恢复，成功记为 UIAWindowRestore。系统菜单、其他程序持续抢焦点或系统拒绝仍可能使流程失败；保留现场后停止，不把输入继续发给其他窗口。

请使用已登录、未锁定的 Windows 桌面，并只保留一个抖音 Chrome 窗口。程序不穿越 CodexSandboxDesktop 或安全桌面，也不修改 Windows 安全/焦点设置。

## 等待验证或发布结果不明

出现短信或安全验证码时在网页里手动处理。程序不读取短信、不自动填写验证码，等待不会自动超时；验证提示消失后继续后续视频，不重复提交当前视频。

Submitting、Submitted、ConfirmedByUser 或 NeedsVisualReview 都会阻止自动重发。Submitted 表示已执行发送动作；新流程不做可见性核验。普通单条异常记录在 recoverable-errors.jsonl，并继续下一条；窗口不可用时 Stage=WaitingForBrowser，等待恢复。不要删除记录后盲目重发。

## 评论输入没有正确生效

流程只向已聚焦且为空的评论框发送 Unicode 键盘输入。若用户输入或页面更新打断文字，逐字检查会停止。不要用 ValuePattern.SetValue 给 Draft 评论编辑器填值；该方式可能只改变表面文本而没有同步网站状态。

## 页面改变或视频连播

地址栏与 Document 的视频 ID 都必须等于当前目标。变化后停止，避免发错视频。播放器明确暴露暂停图标时会先暂停视频。

选择器在 `config/douyin.json`。定位不唯一、CSS 类名改变或发送按钮不可用时先用 `launchers/Inspect-Douyin.cmd` 保存新证据，确认真实控件再调整；不得放宽到所有按钮或固定屏幕坐标。

## 没有新视频

检查 SearchTerms 与 MatchAny。已记录的视频会被去重；持续模式等待 EmptyQueueWaitSeconds 后再次搜索，不会重复刷同一个视频。

## 程序提示已有实例

一个 StateRoot 只允许一个运行器。用 Stop-RPA.cmd 停止现有实例；进程退出会自动释放句柄锁。runner.lock 文件存在本身不代表进程仍在运行，不需要删除它。

## 自检与退出码

在完整项目根目录运行 Check-Project.cmd。它只编译和验证配置、状态、输入保护，不点击应用。

0：正常完成、预演完成、自检通过或响应停止。2：需要验证或视觉复核。1：窗口、页面、配置等阻塞/失败。是否真实发布还必须看 Publish、Published 及每个视频的记录。

钉钉有独立的 `dingtalk-rpa` Skill，其控件、配置、数据和测试不属于本 Skill。
