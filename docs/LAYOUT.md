# 目录与依赖

## 源码边界

- `skills/douyin-rpa/scripts`：任务控制器、后台 worker、监控、原生抖音运行器及手动控制。`src/core`：配置、状态账和关键词池；`src/workflows`：顶层评论发现、准备和提交流程。
- `skills/douyin-reply-rpa/scripts`：独立任务控制器与后台执行入口。`src/core` 和 `src/workflows`：候选评论、作者与原评论绑定、定向回复及回复账；`tests`：配置/控制、UI 路由和工作流离线验证。当前 AI 会话读取 Discover 候选并产生精确回复任务，后台运行器只执行已确定的任务。
- `skills/dingtalk-rpa/scripts`：默认 Run 的独立入口、路径解析与钉钉原生运行器。`src/core`：钉钉配置、导航、窗口与 OCR；`src/workflows`：应用中心及搜索流程。
- `shared/native/DingRpa.cs`：Win32 / UIA 原生接口，保留旧类型名以兼容调用。`shared/core/Screenshot.ps1`：各 Skill 共用的截图函数。`shared/Runtime.ps1`：项目与独立包的版本、共享代码及数据路径。
- `shared/douyin/Urls.ps1`：抖音 HTTPS 来源和视频编号解析；`Browser.ps1`：Chrome 身份、前台、UIA、输入与证据函数；`Comments.ps1`：评论区控件与发送冷却。只被两个抖音 Skill 引用，不依赖任一 Skill 的业务入口；取消、状态和等待接口由各运行器提供。
- 各 Skill 的测试、配置、启动器与说明和业务代码放在同一目录。根目录脚本仅处理项目维护；钉钉不再经过带有抖音默认分支的统一运行器。

## 数据路径迁移

| 旧位置 | 新位置 |
| --- | --- |
| `evidence/skill` | `data/douyin-rpa` |
| `evidence/douyin-state` | `data/douyin-rpa/state` |
| `evidence/runs` 中抖音运行 | `data/douyin-rpa/runs` |
| `evidence/dingtalk/runs` 与原钉钉运行 | `data/dingtalk-rpa/runs` |
| 其他历史 evidence | `data/legacy` |
| `work`、`dist` | `artifacts/work`、`artifacts/dist` |

历史任务 JSON 的运行目录、证据目录和控制目录引用随迁移更新，原发送账、关键词池、控制信号逐文件核验保持不变。源码备份和 JSON 原件保存在 artifacts/backups。截图与原始证据保留；不把历史任务状态改成已成功，不重启任务。

新增回复 Skill 使用 `data/douyin-reply-rpa` 存放任务、候选、回复账和证据，独立维护 `state`。项目内 `SharedSubmissionRoot` 指向原抖音发送状态目录，仅用于两个抖音执行器的互斥与发送冷却；不把回复账合并到旧视频评论账，不清空旧记录。独立包使用包内状态。以各入口 Describe 回读路径为准。

## 独立包

Build-Skill 必须明确指定 `douyin-rpa`、`douyin-reply-rpa` 或 `dingtalk-rpa`，只打包该 Skill 的运行资源与所需 shared，不携带其他 Skill。共同依赖为 `Runtime.ps1`、`native`、`core`；两个抖音包额外包含 `shared/douyin`，钉钉包不包含。独立包内 bundle.json 声明身份并提供逐文件 SHA256；因此解压目录改名或包含中文、空格、单引号、&、$ 仍使用自身配置与数据。版本来自项目 VERSION，构建时复制到包中。

默认只留 ZIP；KeepExpanded 仅供受控测试，测试结束清理副本，避免技能扫描把构建产物识别为多份 Skill。

结构测试在临时目录验证三个包。原抖音评论与钉钉运行无桌面自检；回复包只调用 Describe 检查独立身份、路径和依赖，不启动 Discover、Preview 或 Publish。原注册工具的默认集合保持两项，测试注册只在 `artifacts/work` 的临时发现目录进行，不触碰用户全局 Skill 库。
