# 灰尾回收 · Ashtail Salvage

**M1.5** 修复了事件房关闭对话后无法移动、Esc 无法暂停，以及进房准备失败却提交新坐标的问题。教学地图使用原有的机关、骰局、祭坛和旅商。普通探索从 Lv3 起才可能抽到补给商店。关闭教学说明后可以继续走动，学习插旗仍需单独支付 100 点。[M1.5 验证记录](docs/validation.md#m15)

**M1** 是主线首个体素联调里程碑。在 A2 的 Z2 玩法基础上，接入 [B 组的 22 间体素事件房](https://github.com/yanoutrageous/Ashtail-Salvage/pull/2)、[C 组的人物、怪物、武器和战斗特效](https://github.com/yanoutrageous/Ashtail-Salvage/pull/1)及组内 UI 联调版本。M1 包含移动、交互、存档和宝箱房摆设的修复，默认启用主音量和音效。

## 开始试玩

试玩 M1.5 时，使用 Godot **4.6.3** 打开本仓库的 `game/project.godot`，在编辑器中按 F5 运行。此前组内分发的 M1 Windows 包对应旧版本。运行该包时，完整解压后双击 `Start_Game.cmd`，等待首次资源导入完成。

Windows 完整包将存档与临时文件写入解压目录下的 `player-data`。正常退出时保存，异常终止后可恢复最后的检查点。离线不扣生命或药效时间。更新试玩包时保留 `player-data`。游戏使用 Z2 新档规则。

## A2 玩法基础

[A2 Windows 历史发布包](https://github.com/yanoutrageous/Ashtail-Salvage/releases/tag/A2)完成 Z2 接入计划 T00—T16。此前通过检查的基础进度保留在 [A1](https://github.com/yanoutrageous/Ashtail-Salvage/tree/A1)。

- 新档 Lv0 教学、Lv1 首包、角色成长与 39 个天赋；角色上限 50，Demo 内容投放至 30。
- 42 件藏品、30 件装备与消耗品、三项可重复研究合成；研究成品只通过研究获得。
- 22 类事件、首批 9 种开局效果、15 主线／10 支线／25 成就。
- 搜索、战斗、交易、托运、撤退、成功／死亡／放弃结算及跨进程续局。
- 五件怪物专属材料的原掉率 ×1.20；保留等级与地图限制，不增加抽取次数。
- 参考“UI改造”的底部对白、姓名牌、右侧费用选项，以及探索分类背包和短说明板；支持窗口适配与 100%—150% 界面字号。

第二、三批开局天赋目前可购买后续效果资格，尚无未定义效果。物理手柄、手机、声音听感和长期经济平衡没有作为本次已通过项目。同步耐久保存仍有峰值停顿，不承诺所有设备稳定 60 FPS。

## 验证与开发

源候选 `960306b566a8feeb6f8e24a9a75c2df87af32605` 的完整回归共 183 个 runner 全部接受；旧测试的精确退出清理诊断单列，详见 [来源验证](docs/A2_SOURCE_VALIDATION.json)。移植只保留本仓库的应用名称和独立存档目录，实际压缩包 Main 新建／保存／重启恢复另行通过，见 [导入验证](docs/A2_IMPORT_VALIDATION.json)。

使用 Godot **4.6.3** 打开 `game/project.godot`。压缩脚本包的复现步骤见 [构建说明](tools/z2/README.md)。试玩规则见 [Z2 合同](docs/20_product/Z2_SYSTEM_INTEGRATION_CONTRACT.md)及[投放与研究清单](docs/20_product/Z2_CONTENT_DISTRIBUTION_DRAFT.md)；其中历史工程文档引用保留来源语境，不代表目标仓库另行包含原工程历史。

Godot 引擎与第三方许可随 Windows 包提供；本仓库原有许可及 A1 历史保留。
