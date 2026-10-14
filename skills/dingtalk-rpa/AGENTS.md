# 钉钉 Skill 维护约定

- 先读 SKILL.md。用户要求调用或开始时直接 Run；修改、整理、解释 Skill 不启动桌面操作。
- 钉钉配置、导航、OCR 搜索、启动器与测试只放本 Skill；Win32 和截图共用项目 shared。
- 保留唯一窗口、进程归属、默认桌面、焦点、唯一控件和精确 OCR 核验；不引入 CUA、CDP、固定坐标或抖音运行器。
- 搜索仅向已确认的空框输入 test，逐字核验，不回车；已有内容、失焦或结果不明停止，不重复输入。
- 默认数据为项目 data/dingtalk-rpa/runs；独立包为 Skill 的 data/runs。不得读取抖音任务状态或恢复抖音任务。
- NeedsVisualReview 保留原始状态，结合截图说明证据；不把点击、滚动或进程退出直接当成成功。
- PowerShell 5.1 脚本使用 UTF-8 BOM；tests 只运行无桌面回归，临时文件写到项目 artifacts/work。
