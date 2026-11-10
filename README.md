# Ashtail Salvage

Godot 4.6.3 游戏工程位于 `game/`。以本仓库 main 上的 R0 为初始开发基线，后续体素表现与双端改造版本命名为 A1。

## R0 来源

初始运行工程取自 Game1 的 `ec4ae28b1da66e450ab42caab247520b0b37b156`，导入范围为 `Godot/GraytailGodot/` 内已跟踪的运行文件、资源和测试。项目名及用户数据目录调整为 Ashtail Salvage，保存位置为 Godot 用户目录中的 `AshtailSalvage`。

[Game1 来源提交](https://github.com/yanoutrageous/Game1/tree/ec4ae28b1da66e450ab42caab247520b0b37b156)

## 运行

使用 Godot 4.6.3 打开 `game/project.godot`，运行主场景。当前机器也可通过 Godot MCP 的 `run_project` 指向该目录。

```powershell
& 'D:/Godot/editor/Godot_v4_6_3_stable_win64/Godot_v4.6.3-stable_win64_console.exe' --path ./game
```

## 基线验证

```powershell
godot --headless --path ./game --editor --import --quit
godot --headless --path ./game --script res://tests/g41_in_run_core_gameplay_runtime_runner.gd
```

`godot` 为本机 4.6.3 可执行文件的路径或别名。更多验证记录见 `docs/validation.md`。
