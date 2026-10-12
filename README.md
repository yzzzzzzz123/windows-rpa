# Windows RPA

一个可在 Windows 桌面独立运行、在 Codex 中维护的本地 RPA 项目。首个流程是钉钉「应用中心 → 低代码平台 → 向下滚动」。

当前版本：`0.1.0`，由已在桌面运行的 `20261012.2` 脚本整理而来。项目使用 Windows PowerShell 5.1、Win32、UI Automation 和系统 OCR，不需要浏览器调试连接或额外 Python / Node 环境。

## 当前进度

- 已有桌面证据：定位和激活钉钉、截图、读取导航控件、点击应用中心、OCR 精确识别并点击低代码平台。
- 最新桌面运行在后续截图或滚动过程中因焦点离开钉钉而停止。不能据此确认低代码页已选中或已滚动到底。
- 项目化版本已通过脚本解析、原生接口编译、配置异常校验及无桌面输入的自检；重构后的完整桌面流程仍待实测。

详见 [运行状态](docs/STATUS.md) 和 [故障排查](docs/TROUBLESHOOTING.md)。

## 快速开始

1. 在已登录的 Windows 桌面打开钉钉主窗口。
2. 双击项目根目录的 `Run-DingTalk-RPA.cmd`。
3. 运行期间保持钉钉在前台，避免切换应用或操作鼠标。
4. 完成后查看命令窗口中的最终状态及结果目录。

只检查窗口、截图和控件，可双击 `Inspect-DingTalk.cmd`。只检查代码与依赖，可双击 `Check-Project.cmd`；这个入口不会激活或点击桌面应用。

脚本在输入前检查 Escape。需要停止时按住 Escape，等待下一次检查；它不是全局实时热键，UI Automation 调用期间可能延迟响应。

若系统执行策略阻止脚本，记录实际错误再处理。项目启动器不更改执行策略、安全设置或权限。

## 命令行

在项目根目录使用 **64 位 Windows PowerShell 5.1**：

```powershell
# 无桌面输入的编译和环境自检
powershell.exe -NoProfile -File .\scripts\Invoke-Rpa.ps1 -SelfTest

# 窗口诊断：会激活钉钉并截图，不点击导航
powershell.exe -NoProfile -File .\scripts\Invoke-Rpa.ps1 -Scenario Inspect

# 运行钉钉流程
powershell.exe -NoProfile -File .\scripts\Invoke-Rpa.ps1 -Scenario AppCenterLowCode -WaitForKey

# 查看最新运行摘要
powershell.exe -NoProfile -File .\scripts\Get-LatestRun.ps1

# 验证项目
powershell.exe -NoProfile -File .\tests\Verify-Project.ps1
```

`-ConfigPath` 可指定配置文件，`-EvidenceRoot` 可指定结果目录。默认使用 `config/dingtalk.json` 和 `evidence/runs/`。

## 项目结构

```text
windows-rpa/
  Run-DingTalk-RPA.cmd             钉钉流程启动器
  Inspect-DingTalk.cmd             窗口诊断入口
  Check-Project.cmd                无桌面输入的验证入口
  AGENTS.md                       后续 Codex 任务的项目约定
  config/dingtalk.json             选择器、等待时间、滚动次数上限
  src/native/DingRpa.cs            Win32 窗口、点击、滚轮接口
  src/core/Desktop.ps1             窗口归属、焦点、UIA、OCR、截图
  src/core/Configuration.ps1       配置加载与校验
  src/workflows/DingTalk.AppCenter.ps1
  scripts/Invoke-Rpa.ps1           统一运行入口与结果状态
  scripts/Get-LatestRun.ps1        运行结果摘要
  tests/Verify-Project.ps1         代码、配置及原生编译验证
  docs/                           使用与排障上下文
  evidence/runs/                  新运行结果，Git 忽略
  evidence/imported/desktop/       导入的原始桌面记录，Git 忽略
  work/                           自检临时文件，Git 忽略
```

## 结果判定

| 状态 | 退出码 | 含义 |
| --- | --- | --- |
| `Passed` | 0 | 选中状态与滚动百分比均通过控件确认 |
| `Inspected` | 0 | 窗口诊断完成，不表示业务流程完成 |
| `SelfTestPassed` | 0 | 依赖和编译自检完成，没有桌面输入 |
| `NeedsVisualReview` | 2 | 操作已执行，但选中状态或底部状态需要截图复核 |
| `Blocked` | 1 | 窗口、焦点、识别或输入检查失败，流程停止 |

初始化或配置错误会在流程开始前报错，可能没有 `result.json`。运行中的错误会保存 `result.json`、`error.txt` 和尽可能完整的焦点记录。

## 在 Codex 中继续维护

将本项目根目录作为 Codex 的独立本地项目。后续任务先阅读 `AGENTS.md` 和 `docs/STATUS.md`，再根据实际运行记录继续。Codex 官方文档说明，本地项目可以关联本机文件夹，并从主目录发现 `AGENTS.md`：[Projects and chats](https://learn.chatgpt.com/docs/projects)。

当前环境中，Codex 的普通命令运行在 `CodexSandboxDesktop-*`，用户桌面为 `Default`。因此 Codex 负责编辑、编译、自检和读取结果，桌面动作通过用户在自己的桌面启动脚本完成。该限制已由现场运行记录确认。

运行证据可能包含聊天内容或内部页面截图，仅在本地保留，已通过 `.gitignore` 排除。源码发布包不包含这些证据。
