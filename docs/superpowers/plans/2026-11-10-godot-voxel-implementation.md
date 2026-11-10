# Ashtail-Salvage Godot 体素改造实施计划

## 目标与架构

以 Ashtail-Salvage main 上的 R0 为开发基线，复用 Godot 4.6.3 的玩法和界面状态，在 `game/` 中接入三维体素视图、双端操作与造化 Web 交付，形成 A1。

设计依据为 `docs/superpowers/specs/2026-11-10-ashtail-voxel-design.md`。按 executing-plans 直接执行，新增行为先编写失败测试，最终独立审阅。

## 全局约束

- 初始来源为 Game1 `ec4ae28b1da66e450ab42caab247520b0b37b156` 的 Godot 工程。
- R0 提交登记在本仓库 main，后续以标签 R0 定位精确基线。
- 现有规则、物品实例和结算仍是唯一状态来源。
- 体素视图通过只读快照构建，不写 HP、奖励或存档。
- 电脑键鼠与手机触控都进入既有动作接口。
- 引擎为本机 Godot 4.6.3，Web 使用 Compatibility 渲染器。

## 审阅重点

- 三维视图与真实碰撞位置一致。
- 暂停、切换房间与打开面板后正确释放输入。
- 宝箱、地面物品和敌人状态与既有实例一一对应。
- 主菜单、地图、背包和结算仍通过正常入口可达。
- Web 存档、加载与生命周期反馈使用真实状态。

## Task 1 建立可运行 R0

文件为 `game/` 的初始 Godot 运行工程、根 `.gitignore`、`README.md` 与来源记录。

- [x] 从固定 Game1 提交复制 Godot 工程内已跟踪文件。
- [x] 记录来源，修改项目名以隔离 Ashtail-Salvage 用户数据。
- [x] 运行无界面导入、核心玩法和资产/结算测试。
- [x] 用 Godot MCP 启动并检查调试输出。
- [ ] 提交至 main，核对远端提交并标记 R0。

## Task 2 三维体素视图

创建 `game/scripts/gameplay/runtime/voxel_room_renderer.gd` 与 `game/tests/voxel_room_renderer_runner.gd`，修改现有 `g41_room_runtime_view.gd` 的显示接入。

接口为 `configure_room(snapshot, world_projection)` 和 `sync_runtime(player_position, combat_snapshot, loot_state)`，由既有运行状态调用。

- [ ] 编写坐标映射、房间重建、实例复用和状态同步测试，确认失败。
- [ ] 以 SubViewport/Node3D、正交相机和体素网格实现角色、房间、障碍、宝箱、敌人、掉落与撤离点。
- [ ] 接入现有房间运行视图，保持交互和状态接口。
- [ ] 运行新增测试及既有核心回归，验证真实渲染。
- [ ] 提交体素视图。

## Task 3 双端输入

创建 `game/scripts/input/touch_controls.gd` 及对应测试，在现有 RunScene 接入。

- [ ] 先测试移动、攻击、交互、触点取消和面板暂停时的输入释放。
- [ ] 实现屏幕触控与键鼠共同消费既有 Godot InputMap。
- [ ] 检查地图、背包和结果的手机尺寸布局及可达性。
- [ ] 从正常入口完成探索、开箱、战斗、满包替换、撤离和再出发。
- [ ] 提交双端操作。

## Task 4 Web 与交付

创建 Web 导出配置，安装官方造化 Godot addon，使用托管 `build-web.cmd`。

- [ ] 核对并复用本机 Web 导出模板。
- [ ] 安装造化 SDK 并配置 Web 导出，验证加载、暂停与恢复。
- [ ] 运行相关测试、Web 构建和造化预览验证。
- [ ] 独立审阅本次改动，重要问题先补失败测试再修复。
- [ ] 记录测试、提交、产物和实际设备验收范围，交付可试玩版本。

## 执行记录

- 已删除早期天工专用本地工具目录，其下载缓存保持由包管理器管理。
- 用户将体素改造版本命名为 A1，R0 保留为 main 的初始可运行版本。
- Godot MCP 确认版本 `4.6.3.stable.official.7d41c59c4`。
- 远端仓库最初为空，用户指定的 R0 通过首次可运行 Godot 基线建立。
