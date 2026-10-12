# Windows RPA 项目约定

- 使用中文解释改动、运行状态和故障。先阅读 `README.md` 与 `docs/STATUS.md`。
- 这是 Windows PowerShell 5.1 + Win32 + UIA + 系统 OCR 项目。所有 `.ps1` 保留 UTF-8 BOM，避免中文在 Windows PowerShell 中乱码。
- 主入口为 `scripts/Invoke-Rpa.ps1`；窗口能力在 `src/core/`，钉钉流程在 `src/workflows/`，原生接口在 `src/native/`。不要再把桌面脚本副本当作源码修改。
- 默认运行 `powershell.exe -NoProfile -File .\tests\Verify-Project.ps1`。这不包含真实桌面操作。只有用户当前授权了桌面操作时才运行动作流程。
- 当前已知环境存在 Codex 隔离桌面；在这种环境中不要通过启动任务、服务、代理或其他进程绕过隔离。由用户从 Windows 桌面启动项目入口，然后读取结果。
- 每次点击使用当前窗口和实时 UIA / OCR 位置。保留目标进程校验、前台与遮挡检查、Escape 检查和迭代次数上限。
- 焦点失去后不可向任意窗口继续发送输入。现有自动恢复仅限没有前台窗口或回到本次启动器的经典控制台窗口；Windows Terminal 的归属恢复尚未实现。
- 控件调用返回、鼠标输入发送成功、截图哈希不变，都不能单独证明业务动作完成。保留 `NeedsVisualReview`，未核实不得改成 `Passed`。
- 此项目现有动作仅为窗口诊断、导航、选择类别与滚动。新增聊天发送、表单提交或其他业务写入，应以用户明确请求为依据。
- `evidence/`、`work/`、截图和原始控件树不得提交。不要将业务页面内容写入公开文档或测试样例。
- Git 提交说明使用清晰具体的中文。没有上传要求时不推送远程仓库。
