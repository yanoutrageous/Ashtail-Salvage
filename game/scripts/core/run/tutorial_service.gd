extends RefCounted
class_name TutorialService

const SemanticActionHintScript := preload("res://scripts/core/input/semantic_action_hint.gd")

const POPUP_DEFS := {
	&"spawn_intro": {
		"title": "先走到门边",
		"message_template": "向右（{move_right}）或向下（{move_down}）穿过门。\n\n这次演练的目标是到达撤离信标。右上角三角形是你，出口图标是撤离点。",
		"blocking": false,
		"once": true,
		"room_scoped": false,
		"confirm_text": "开始作业",
		"confirm_action": &"ui_accept",
		"action_ids": [&"move_right", &"move_down"],
	},
	&"number_rule": {
		"title": "看数字，再选门",
		"message_template": "看右上角。房间右下角的数字是周围 8 格的雷险数。\n\n例如数字 2 表示周围有 2 格雷险，具体位置需要结合其他房间的数字判断。用 {open_map} 展开地图。学会插旗后，点未知格可以标记疑点。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"open_map"],
	},
	&"mine_rule": {
		"title": "刚刚触发了雷险",
		"message_template": "看左上角：触雷扣生命、升高压力。\n\n这格雷险已经触发。看右上角地图，再决定是继续探索还是返回已走过的路线。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"show_after_room_effect": true,
		"action_ids": [],
	},
	&"event_rule": {
		"title": "狐狸旅商",
		"message_template": "旅商可以将异常回收物折价出售为已锁定收益。已锁定收益即使作业失败也会保留。\n\n使用 {interact} 查看当前事件选项。\n\n调度台 A-7：公司不会知道，大概。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"interact"],
	},
	&"dice_rule": {
		"title": "赌徒",
		"message_template": "赌徒会用一局骰子赌你的待结算收益。押注赢了能翻倍入账，输了则折损一部分。\n\n使用 {interact} 查看当前事件选项。\n\n调度台 A-7：公司不参与赌博。公司只统计结果。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"interact"],
	},
	&"altar_rule": {
		"title": "异常祭坛",
		"message_template": "祭坛可以献祭生命值，换取已锁定收益。献祭不会让你当场倒下，但每献一次都更贵。\n\n使用 {interact} 查看当前事件选项。\n\n调度台 A-7：虔诚也是一种成本。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"interact"],
	},
	&"trap_rule": {
		"title": "机关装置",
		"message_template": "机关需要你动手拆解。战斗力足够时拆解成功，能拿到奖励；失败会受伤并升压。\n\n使用 {interact} 查看当前事件选项。\n\n调度台 A-7：拆解手册第一页写着：先确认值不值。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"interact"],
	},
	&"monster_rule": {
		"title": "异常体区域",
		"message_template": "异常体区域可以绕行，也可以清理。靠近后使用 {attack} 攻击。清理异常体会获得奖励，但也会提高封锁压力。\n\n调度台 A-7：高收益区和高事故区通常是同一个地方。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"attack"],
	},
	&"chest_rule": {
		"title": "第一次搜箱",
		"message_template": "走到箱子旁，看到提示后按 {interact} 搜索。\n\n若地面有掉落，按 {open_ground_loot} 查看并拾取。用 {open_inventory} 查看作业包。正式探索中，回收物需要撤离才能带回。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"interact", &"open_ground_loot", &"open_inventory"],
	},
	&"map_rule": {
		"title": "标记风险房间",
		"message_template": "按 {open_map} 展开地图。点未知格可标记疑点。\n\n插旗只是你的判断。已经探索、带回传标记的安全格可点选回传。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"open_map"],
	},
	&"mine_review": {
		"title": "雷险复查",
		"message_template": "再次遇到雷险时，先观察周围数字。如果路线风险过高，可以使用 {open_map} 重新规划，或回传到已探索且可回传的安全格。\n\n调度台 A-7：第二次踩中同类风险时，系统会将其归类为经验不足。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"show_after_room_effect": true,
		"action_ids": [&"open_map"],
	},
	&"route_rule": {
		"title": "接近出口",
		"message_template": "在右上角找出口图标，朝它所在方向走。\n\n路线不顺时，按 {open_map} 查看全图。已走过且可回传的安全格能帮你调整路线。",
		"blocking": false,
		"once": false,
		"room_scoped": true,
		"action_ids": [&"open_map"],
	},
	&"exit_goal": {
		"title": "完成演练",
		"message_template": "靠近撤离信标后，按 {request_extract} 并确认。\n\n本次演练只记录教学完成。回到营地后领取首次物资，再开始正式探索。",
		"blocking": false,
		"once": true,
		"room_scoped": false,
		"confirm_text": "我知道了",
		"confirm_action": &"ui_accept",
		"action_ids": [&"request_extract"],
	},
}

const EVENT_POPUP_IDS := {
	&"trader": &"event_rule",
	&"dice": &"dice_rule",
	&"altar": &"altar_rule",
	&"trap": &"trap_rule",
}


static func is_guidance_popup(popup: Dictionary) -> bool:
	var popup_id := StringName(popup.get("id", &""))
	return popup_id == &"tutorial_objective" or POPUP_DEFS.has(popup_id)


static func is_blocking_popup(popup: Dictionary) -> bool:
	if popup.is_empty() or is_guidance_popup(popup):
		return false
	# The legacy checkpoint field is retained for compatibility, but this is
	# a business risk decision in both standard and tutorial runs, not a lesson.
	return str(popup.get("id", "")) == "flag_entry_confirm" or bool(popup.get("blocking", false))


static func normalized_popup(popup: Dictionary) -> Dictionary:
	var normalized := popup.duplicate(true)
	if is_guidance_popup(normalized):
		normalized["blocking"] = false
		normalized["presentation_kind"] = &"guidance"
	elif str(normalized.get("id", "")) == "flag_entry_confirm":
		normalized["blocking"] = true
		normalized["presentation_kind"] = &"risk_confirmation"
	return normalized


static func popup_definitions() -> Dictionary:
	return POPUP_DEFS.duplicate(true)


static func popup_definition(popup_id: StringName) -> Dictionary:
	return (POPUP_DEFS.get(popup_id, {}) as Dictionary).duplicate(true)


static func trigger_for(context: RunContext, pos: Vector2i) -> StringName:
	if context == null or context.mode != &"tutorial":
		return &""
	var trigger_id := StringName(context.tutorial_triggers.get(context.cell_key(pos), &""))
	if trigger_id == &"event_rule":
		var event_type := StringName(context.event_state.get("event_type", &"trader"))
		trigger_id = StringName(EVENT_POPUP_IDS.get(event_type, &"event_rule"))
	if trigger_id == &"":
		context.tutorial_popup = {}
		return &""
	if context.tutorial_shown.has(String(trigger_id)):
		context.tutorial_popup = {}
		return &""
	var popup_def := popup_definition(trigger_id)
	if popup_def.is_empty():
		context.tutorial_popup = {}
		return &""
	var action_ids: Array[StringName] = []
	for raw_action_id in popup_def.get("action_ids", []):
		action_ids.append(StringName(raw_action_id))
	var confirm_action := StringName(popup_def.get("confirm_action", &"ui_accept"))
	context.tutorial_popup = {
		"id": trigger_id,
		"title": str(popup_def.get("title", String(trigger_id))),
		"blocking": bool(popup_def.get("blocking", false)),
		"once": bool(popup_def.get("once", false)),
		"room_scoped": bool(popup_def.get("room_scoped", true)),
		"show_after_room_effect": bool(popup_def.get("show_after_room_effect", false)),
		"message": SemanticActionHintScript.replace_tokens_compact(str(popup_def.get("message_template", "")), action_ids),
		"action_hints": _action_hints(action_ids),
		"confirm_text": str(popup_def.get("confirm_text", "继续")),
		"confirm_action": confirm_action,
		"confirm_action_hint": SemanticActionHintScript.descriptor(confirm_action),
	}
	if trigger_id == &"spawn_intro" and context.profile_fields.get("z2_progression_version") == 1 and not context.profile_fields.get("flag_unlocked", false):
		context.tutorial_popup["message"] += "\n\n有100点教学天赋点可用。先走出起点、看懂房间数字，再用“100点 · 学习插旗”学习标记。撤离前完成学习即可。"
		context.tutorial_popup["confirm_text"] = "收起说明"
	return trigger_id


static func confirm_popup(context: RunContext) -> void:
	if context == null:
		return
	var popup_id := String(context.tutorial_popup.get("id", ""))
	if popup_id != "" and bool(context.tutorial_popup.get("once", false)):
		context.tutorial_shown[popup_id] = true
	context.tutorial_popup = {}


static func _action_hints(action_ids: Array[StringName]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for action_id in action_ids:
		result.append(SemanticActionHintScript.descriptor(action_id))
	return result
