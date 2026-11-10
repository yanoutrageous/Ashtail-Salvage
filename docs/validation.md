# 验证记录

## R0

来源为 Game1 `ec4ae28b1da66e450ab42caab247520b0b37b156`，本机通过 Godot MCP 确认版本为 `4.6.3.stable.official.7d41c59c4`。

- 无界面资源导入已完成，退出码为 0。
- `g41_in_run_core_gameplay_runtime_runner.gd` 通过，覆盖 60Hz 模拟、30/60/144Hz 与卡顿调度、四类敌人及交互。
- `m7_content_runtime_runner.gd` 通过，覆盖 9 个地图配置各 100 个种子、交易与长期进度。
- `i1_save_reliability_runner.gd` 通过，覆盖原子替换、备份恢复、未来版本及长期视图回滚。
- Godot MCP 已正常启动主场景，使用 NVIDIA RTX 5070 的 Compatibility 渲染器。调试输出存在原工程的类型转换、变量遮蔽等脚本警告，当前启动记录未出现脚本运行错误。
- R0 保留导入时的二维游戏表现，体素改造从 R0 后续提交开始。

## 迁移边界

本次只复制 Godot 工程内的已跟踪内容。原仓库外部报告、用户存档、Lua/UE 工程和历史工作树保持在来源项目中。项目名与用户目录已调整，后续游戏数据写入 AshtailSalvage。
