extends RefCounted

const Catalog := preload("res://scripts/core/content/z1_event_catalog.gd")
const SurfaceModel := preload("res://scripts/ui/run_surface/run_surface_model.gd")
const UISkin := preload("res://scripts/presentation/art10_ui_skin_kit.gd")

const DEVICE_ACTIONS := [
	"翻阅便签", "操作领料台", "使用兑付机", "翻开路线台账", "查看封条柜",
	"检查断电柜", "打开取样盒", "到签收台交件", "操作消音阀", "查看急救柜",
	"办理托运", "查看扩容槽", "操作压缩机", "使用退料口", "查看抵押台",
	"检查检修口", "询问引路员", "操作拾料线圈", "查看起爆台", "查看打卡簿",
	"开启侦察台", "到博弈桌出拳", "查看减压服务", "查看围笼入口", "查看补给货槽",
]
const LEGACY_ACTIONS := {
	&"trader": "与旅商交易",
	&"dice": "查看骰桌",
	&"altar": "查看祭坛献祭",
	&"trap": "检查机关",
}
const LEGACY_NEAR_COPY := {
	&"trader": "可出售背包物资、治疗或购买路线情报。",
	&"dice": "用本局黑币下注，掷骰后立即结算。",
	&"altar": "献祭生命换取黑币与祭坛遗物。",
	&"trap": "可查看安全解除的战力门槛与材料方案。",
}
const EMPTY_ACTION_COPY := {
	1: "附近没有可核对的未知房间。",
	4: "附近没有可核对的未知房间。",
	8: "背包中没有可签收的材料。",
	11: "背包中没有可托运的藏品。",
	14: "背包中没有可退回的物资。",
	15: "背包中没有符合要求的抵押藏品。",
	16: "检修口没有可达的斜邻房。",
	19: "先在相邻房间插旗，才有可起爆的目标。",
	20: "请回盖开工章的房间签退。",
}
const HAND_NAMES := {&"rock": "石头", &"paper": "布", &"scissors": "剪刀"}
const ROUND_RESULTS := {&"win": "本回合胜", &"loss": "本回合负", &"draw": "平局"}


static func near_action(event_type: StringName) -> String:
	var number := Catalog.number(event_type)
	if number > 0:
		return DEVICE_ACTIONS[number - 1]
	return String(LEGACY_ACTIONS.get(event_type, "查看处理方式"))


static func near_summary(event_type: StringName, fallback: String) -> String:
	return String(LEGACY_NEAR_COPY.get(event_type, fallback))


static func choice_layout(event_type: StringName) -> StringName:
	match Catalog.number(event_type):
		1, 4, 16, 19:
			return &"targets"
		2, 23:
			return &"services"
		6, 8, 11, 13, 14, 15:
			return &"materials"
		21:
			return &"recon"
		22:
			return &"hands"
		25:
			return &"stock"
	return &"materials" if event_type in [&"altar", &"trap"] else &"list"


static func empty_action_text(event_type: StringName) -> String:
	return String(EMPTY_ACTION_COPY.get(Catalog.number(event_type), ""))


static func readout_text(event_type: StringName, event_state: Dictionary) -> String:
	match event_type:
		&"z1_event_e22":
			return "你 %d  比  %d 对手" % [int(event_state.get("wins", 0)), int(event_state.get("losses", 0))]
		&"z1_event_e20":
			var work: Dictionary = event_state.get("work_order", {})
			if bool(work.get("started", false)):
				return "已进入 %d/%d 个新房" % [int(work.get("visited", 0)), int(work.get("required", 0))]
		&"altar":
			if event_state.has("altar_stage"):
				return "第 %d/%d 阶献祭" % [int(event_state["altar_stage"]), int(event_state.get("altar_stage_total", 0))]
		&"trap":
			if event_state.has("trap_threshold") and not bool(event_state.get("completed", false)):
				return "安全解除需要 %d 战力" % int(event_state["trap_threshold"])
	return ""


static func round_text(round_state: Dictionary) -> String:
	var player := String(HAND_NAMES.get(StringName(round_state.get("player", &"")), ""))
	var opponent := String(HAND_NAMES.get(StringName(round_state.get("opponent", &"")), ""))
	var outcome := String(ROUND_RESULTS.get(StringName(round_state.get("result", &"")), ""))
	if player.is_empty() or opponent.is_empty() or outcome.is_empty():
		return ""
	return "你出%s · 对方出%s · %s" % [player, opponent, outcome]


static func result_text(event_type: StringName, result: Dictionary) -> String:
	if result.is_empty():
		return ""
	var player_copy := String(result.get("player_result_text", "")).strip_edges()
	if not player_copy.is_empty():
		return UISkin.sanitize_player_copy(player_copy)
	var message := String(result.get("message", "")).strip_edges()
	# The saved Z2 event record carries its response and player copy rather
	# than the transient command's success flag.
	if not result.has("ok") and result_succeeded(result):
		return UISkin.sanitize_player_copy(message)
	var number := Catalog.number(event_type)
	if number == 0:
		return SurfaceModel.event_result_feedback_text(result)

	var generic := message.is_empty() or message == "处理完成。"
	if not bool(result.get("ok", false)):
		return SurfaceModel.event_result_feedback_text(result) if generic else UISkin.sanitize_player_copy(message)
	if number == 25 and String(result.get("option_id", "")).begins_with("buy_"):
		var receipt := _received_item_text(result)
		if not receipt.is_empty():
			return receipt
	if not generic:
		var reward := int(result.get("black_coin_delta", 0))
		if number == 22 and reward > 0:
			message += " 获得%d黑币。" % reward
		return UISkin.sanitize_player_copy(message)

	match number:
		2, 5, 7, 10, 13:
			var receipt := _received_item_text(result)
			var pressure := _applied_delta(result, &"protocol_pressure_delta", "pressure")
			if pressure > 0:
				receipt += " 压力 +%d。" % pressure
			if not receipt.is_empty():
				return receipt.strip_edges()
		3:
			return "兑付完成，已锁定%d点安全收益。" % int(result.get("gold_coin_delta", 0))
		6:
			var hp := _applied_delta(result, &"hp_delta", "hp")
			return "柜门已打开，生命 %d。" % hp if hp < 0 else "柜门已安全打开。"
		9, 23:
			var pressure := _applied_delta(result, &"protocol_pressure_delta", "pressure")
			return "压力减少%d点。" % -pressure if pressure < 0 else "当前压力已归零。"
		11:
			return "托运已登记，终局送回仓库。"
		12:
			return "扩容已安装，本局继续生效。"
		14:
			return "退料完成，收到%d黑币。" % int(result.get("black_coin_delta", 0))
		15:
			return "抵押已登记，预支%d黑币。" % int(result.get("black_coin_delta", 0))
		16:
			return "已从检修口进入目标房间。"
		18:
			return "线圈已校准，等待下一次成功搜索普通房。"
		20:
			return "签退完成，收到%d黑币。" % int(result.get("black_coin_delta", 0))
	return SurfaceModel.event_result_feedback_text(result)


static func result_succeeded(result: Dictionary) -> bool:
	if result.has("ok"):
		return bool(result["ok"])
	return result.has("response_lines") and not str(result.get("message", "")).strip_edges().is_empty()


static func _applied_delta(result: Dictionary, effect_type: StringName, key: String) -> int:
	for effect in result.get("effect_results", []):
		if effect is Dictionary and StringName(effect.get("effect_type", &"")) == effect_type:
			var before: Dictionary = effect.get("before", {})
			var after: Dictionary = effect.get("after", {})
			if before.has(key) and after.has(key):
				return int(after[key]) - int(before[key])
	return int(result.get(key + "_delta", 0))


static func _received_item_text(result: Dictionary) -> String:
	var lines: Array[String] = []
	for location in ["inventory_items", "ground_items"]:
		for item in result.get(location, []):
			if item is Dictionary:
				var item_name := UISkin.sanitize_player_copy(String(item.get("display_name", "物资")))
				lines.append("%s已装入背包。" % item_name if location == "inventory_items" else "%s已放在附近地面。" % item_name)
	return " ".join(lines)
