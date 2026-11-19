extends RefCounted
class_name ResultPresentationModel

const ItemRarityDescriptorScript := preload("res://scripts/presentation/item_rarity_descriptor.gd")
const M7ContentCatalogScript := preload("res://scripts/core/content/m7_content_catalog.gd")
const Z2Rules := preload("res://scripts/core/progression/z2_progression_rules.gd")
const RunUIViewModelScript := preload("res://scripts/ui/shell/run_ui_view_model.gd")
const SaveProfileManifestScript := preload("res://scripts/core/save/save_profile_manifest.gd")

# Read-only projection for the production result panel.  Currency, item
# movement, failure reason, persistence and salvage state are copied only from
# the terminal RunResult/display snapshot; this model never settles or saves.


static func build(snapshot: Dictionary) -> Dictionary:
	var settlement := _dictionary(snapshot.get("settlement", {}))
	var result_state := _result_state(
		String(snapshot.get("outcome", "Running")),
		String(settlement.get("outcome", snapshot.get("settlement_outcome", "")))
	)
	var reason_code := StringName(snapshot.get("terminal_reason_code", &""))
	var reason_text := reason_text_for(result_state, reason_code)
	var awaiting_salvage := (
		bool(settlement.get("requires_salvage_selection", false))
		and not bool(settlement.get("finalized", false))
	)
	var persistence_state := _persistence_state(snapshot, awaiting_salvage)
	var normal_exit_allowed := bool(snapshot.get(
		"normal_exit_allowed",
		persistence_state in [&"committed", &"duplicate_ignored"]
	))
	var retry_save_allowed := bool(snapshot.get(
		"retry_save_allowed",
		not awaiting_salvage and not normal_exit_allowed
	))
	var discard_unsaved_allowed := bool(snapshot.get(
		"discard_unsaved_allowed",
		not awaiting_salvage and not normal_exit_allowed
	))
	# Salvage selection is the only legal next step while pending.  Ignore any
	# stale action flags carried by a legacy display snapshot.
	if awaiting_salvage or persistence_state == &"debug_tainted_production_profile_blocked":
		normal_exit_allowed = false
		retry_save_allowed = false
		discard_unsaved_allowed = false
	var consequence_text := _consequence_text(result_state, settlement, awaiting_salvage)
	var career := {}
	if persistence_state == &"committed":
		var commit := _dictionary(snapshot.get("meta_progress_commit", {}))
		var progression := _dictionary(commit.get("m7_progression_delta", {}))
		if progression.has("exp_gained"):
			var raw_meta: Variant = snapshot.get("meta_progress_summary", commit.get("summary", {}))
			var meta: Dictionary = raw_meta if raw_meta is Dictionary else {}
			var show_follow_up := (
				normal_exit_allowed
				and result_state in [&"success", &"failure"]
				and not bool(snapshot.get("debug_used", false))
				and str(meta.get("profile_id", "")) != SaveProfileManifestScript.DEBUG_SANDBOX_PROFILE_ID
			)
			career = _career_feedback(progression, meta, show_follow_up)
	return {
		"presentation_contract": &"i3.result.read_only.v1",
		"title": _title(result_state),
		"summary": "%s\n%s" % [reason_text, consequence_text],
		"result_state": result_state,
		"reason_text": reason_text,
		"consequence_text": consequence_text,
		"terminal_reason_code": reason_code,
		"currency_metrics": _currency_metrics(result_state, settlement),
		"item_sections": _item_sections(result_state, settlement),
		"awaiting_salvage": awaiting_salvage,
		"salvage_candidates": _item_models(_array(settlement.get("settlement_pool", []))),
		"salvage_capacity": int(settlement.get("salvage_capacity", 0)),
		"persistence_state": persistence_state,
		"persistence_text": career.get("text", _persistence_text(persistence_state)),
		"career_xp_text": career.get("xp_text", ""),
		"career_map_text": career.get("map_text", ""),
		"progression_tooltip": career.get("tooltip", ""),
		"career_follow_up": career.get("follow_up", {}),
		"normal_exit_allowed": normal_exit_allowed,
		"retry_save_allowed": retry_save_allowed,
		"discard_unsaved_allowed": discard_unsaved_allowed,
		"discard_unsaved_confirmation_count": int(snapshot.get("discard_unsaved_confirmation_count", 2)),
		"read_only": true,
		"authority": &"RunResult",
		"ui_recalculation_allowed": false,
	}


static func _result_state(outcome: String, settlement_outcome: String) -> StringName:
	if outcome in ["Extracted", "Training Complete"] or settlement_outcome == "success":
		return &"success"
	if outcome == "Failed" or settlement_outcome == "failure":
		return &"failure"
	if outcome == "Abandoned" or settlement_outcome == "abandon":
		return &"abandon"
	return &"unknown"


static func _title(result_state: StringName) -> String:
	match result_state:
		&"success":
			return "撤离成功"
		&"failure":
			return "探索失败"
		&"abandon":
			return "已放弃探索"
	return "探索结算"


static func reason_text_for(result_state: StringName, reason_code: StringName) -> String:
	if result_state == &"success":
		return "你已抵达撤离信标，本次探索完成。"
	if result_state == &"abandon":
		return "你主动结束了本次探索。"
	var reason := String(reason_code)
	if reason in ["mine", "fatal_mine", "mine_triggered"]:
		return "你在雷区受到致命伤害，未能完成撤离。"
	if reason == "hp_depleted":
		return "生命值归零，未能完成撤离。"
	if reason == "monster" or reason == "runtime_combat_defeat" or reason.begins_with("runtime_combat_"):
		return "你在与异常体的交战中失去行动能力。"
	if reason.begins_with("event_"):
		return "事件造成致命后果，本次探索中断。"
	return "探索信号中断，未能完成撤离。"


static func _consequence_text(result_state: StringName, settlement: Dictionary, awaiting_salvage: bool) -> String:
	var warehouse_count := _array(settlement.get("warehouse_items", [])).size()
	var event_delivery := _dictionary(settlement.get("event_item_delivery", {}))
	var consigned := _array(event_delivery.get("delivered", []))
	var forfeited := _array(event_delivery.get("forfeited", []))
	var salvaged_count := _without_instances(_array(settlement.get("salvaged_items", [])), consigned).size() + consigned.size()
	var lost_count := _without_instances(_array(settlement.get("lost_items", [])), forfeited).size() + forfeited.size()
	var floor_count := _array(settlement.get("room_floor_lost_items", [])).size()
	var cleared_count := _array(settlement.get("cleared_consumables", [])).size()
	if awaiting_salvage:
		var candidate_count := _array(settlement.get("settlement_pool", [])).size()
		if result_state == &"success":
			return "可保留 %d 件未用消耗品，每件占10点回收容量；容量不足时可取消部分战利品。穿戴装备和托运物资照常带回。" % int(settlement.get("retention_limit", 0))
		return "黑资损失 %d，已锁定收益保留 %d；从 %d 件候选物资中选择可保全内容。" % [
			int(settlement.get("black_coin_lost", 0)),
			int(settlement.get("safe_yield_retained", settlement.get("safe_yield", 0))),
			candidate_count,
		]
	if result_state == &"success":
		var summary := "带回 %d 件物资；现场遗留 %d 件，消耗或清除 %d 件。" % [warehouse_count, floor_count, cleared_count]
		if not forfeited.is_empty():
			summary += "抵押抵账 %d 件。" % forfeited.size()
		return summary
	return "保全 %d 件；未能带回 %d 件，现场遗留 %d 件，消耗或清除 %d 件。" % [
		salvaged_count,
		lost_count,
		floor_count,
		cleared_count,
	]


static func _currency_metrics(result_state: StringName, settlement: Dictionary) -> Array[Dictionary]:
	if result_state == &"success":
		return [
			{"label": "黑资转化", "value": int(settlement.get("black_coin_converted", 0)), "tone": &"positive"},
			{"label": "已锁定收益", "value": int(settlement.get("safe_yield_retained", settlement.get("safe_yield", 0))), "tone": &"positive"},
			{"label": "结算收益", "value": int(settlement.get("gold_coin_gained", 0)), "tone": &"positive"},
		]
	return [
		{"label": "黑资损失", "value": int(settlement.get("black_coin_lost", 0)), "tone": &"negative"},
		{"label": "已锁定收益", "value": int(settlement.get("safe_yield_retained", settlement.get("safe_yield", 0))), "tone": &"positive"},
		{"label": "实际保留", "value": int(settlement.get("gold_coin_gained", settlement.get("safe_yield", 0))), "tone": &"positive"},
	]


static func _item_sections(result_state: StringName, settlement: Dictionary) -> Array[Dictionary]:
	var sections: Array[Dictionary] = []
	var event_delivery := _dictionary(settlement.get("event_item_delivery", {}))
	var forfeited := _array(event_delivery.get("forfeited", []))
	if result_state == &"success":
		sections.append(_item_section(&"warehouse_items", "带回仓库", _array(settlement.get("warehouse_items", []))))
	else:
		var consigned := _array(event_delivery.get("delivered", []))
		var salvaged := _without_instances(_array(settlement.get("salvaged_items", [])), consigned)
		var lost := _without_instances(_array(settlement.get("lost_items", [])), forfeited)
		sections.append(_item_section(&"salvaged_items", "已保全", salvaged))
		if not consigned.is_empty():
			sections.append(_item_section(&"event_consigned_items", "已托运", consigned))
		sections.append(_item_section(&"lost_items", "未能带回", lost))
	if not forfeited.is_empty():
		sections.append(_item_section(&"event_forfeited_items", "抵押抵账", forfeited))
	sections.append(_item_section(&"room_floor_lost_items", "遗留在现场", _array(settlement.get("room_floor_lost_items", []))))
	sections.append(_item_section(&"cleared_consumables", "已消耗或清除", _array(settlement.get("cleared_consumables", []))))
	return sections


static func _without_instances(items: Array, excluded: Array) -> Array:
	if excluded.is_empty():
		return items
	var excluded_ids := {}
	for item in excluded:
		if item is Dictionary:
			var instance_id := String(item.get("instance_id", ""))
			if not instance_id.is_empty():
				excluded_ids[instance_id] = true
	var result: Array = []
	for item in items:
		if item is Dictionary and not excluded_ids.has(String(item.get("instance_id", ""))):
			result.append(item)
	return result


static func _item_section(section_id: StringName, title: String, items: Array) -> Dictionary:
	return {
		"section_id": section_id,
		"title": title,
		"items": _item_models(items),
		"count": items.size(),
	}


static func _item_models(items: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_item in items:
		if not raw_item is Dictionary:
			continue
		var item := raw_item as Dictionary
		var presentation := RunUIViewModelScript.item_presentation(item)
		result.append({
			"instance_id": String(item.get("instance_id", "")),
			"item_id": String(item.get("item_id", "")),
			"item_type": String(item.get("item_type", item.get("category", ""))),
			"display_name": String(presentation.get("display_name", "未命名物资")),
			"short_description": String(presentation.get("short_description", "")),
			"weight": maxi(0, int(presentation.get("weight", 1))),
			"rarity": (presentation.get("rarity", ItemRarityDescriptorScript.describe(&"unknown")) as Dictionary).duplicate(true),
			"collectible_level": maxi(0, int(presentation.get("collectible_level", 0))),
			"collectible_level_text": String(presentation.get("collectible_level_text", "")),
			"detail_text": String(presentation.get("detail_text", "")),
		})
	return result


static func _persistence_state(snapshot: Dictionary, awaiting_salvage: bool) -> StringName:
	if awaiting_salvage:
		return &"awaiting_salvage_confirmation"
	var explicit := StringName(snapshot.get("persistence_state", &""))
	if explicit != &"":
		return explicit
	var commit := _dictionary(snapshot.get("meta_progress_commit", {}))
	var status := StringName(commit.get("status", &""))
	if status in [
		&"committed",
		&"duplicate_ignored",
		&"save_failed",
		&"write_blocked",
		&"debug_tainted_production_profile_blocked",
		&"meta_progress_adapter_missing",
		&"discarded_unsaved",
		&"tutorial_completed",
		&"tutorial_replay_complete",
		&"tutorial_incomplete_no_write",
	]:
		return status
	return &"missing"


static func _career_feedback(progression: Dictionary, meta: Dictionary, show_follow_up: bool) -> Dictionary:
	var level := int(progression.get("profile_level_after", meta.get("profile_level", 1)))
	var leveled_up := level > int(progression.get("profile_level_before", level))
	var text := "进度已保存 · 资历经验 +%d" % int(progression.get("exp_gained", 0))
	if Z2Rules.applies_to(meta) and progression.has("talent_points_gained"):
		text += " · 天赋点 +%d" % int(progression["talent_points_gained"])
	if leveled_up or meta.has("profile_exp"):
		text += (" · 升至 Lv.%d" if leveled_up else " · Lv.%d") % level
	if meta.has("profile_exp"):
		var next_exp := M7ContentCatalogScript.profile_exp_for_level(level + 1, meta)
		if Z2Rules.applies_to(meta) and level == 0:
			text += " · 完成教学后升至 Lv.1"
		elif next_exp >= 0:
			text += " · 距 Lv.%d %d 经验" % [level + 1, maxi(0, next_exp - int(meta["profile_exp"]))]
		else:
			text += " · 已满级"
	var details := PackedStringArray()
	var breakdown := _dictionary(progression.get("experience_breakdown", {}))
	if not breakdown.is_empty() and Z2Rules.applies_to(meta):
		details.append("基础经验 %d · 基础天赋点 %d" % [int(breakdown.get("base_experience", 0)), int(breakdown.get("base_talent", 0))])
		var map_rules := Z2Rules.map_overrides(str(progression.get("map_id", "")))
		if not map_rules.is_empty() and breakdown.has("ending_percent"):
			details.append("难度 %d%% · 经验上限 %d · 天赋上限 %d · 结算 %d%%" % [
				int(map_rules["experience_percent"]), int(map_rules["experience_cap"]),
				int(map_rules["talent_cap"]), int(breakdown["ending_percent"]),
			])
	elif not breakdown.is_empty():
		details.append("房间 +%d · 开箱 +%d · 战斗 +%d · 事件 +%d · 委托 +%d" % [
			int(breakdown.get("room_exp", 0)), int(breakdown.get("chest_exp", 0)),
			int(breakdown.get("combat_exp", 0)), int(breakdown.get("event_exp", 0)), int(breakdown.get("commission_exp", 0)),
		])
		details.append("难度 %d%% · 单局上限 %d · 结算 %d%%" % [
			int(breakdown.get("difficulty_percent", 100)), int(breakdown.get("cap", 0)), int(breakdown.get("outcome_percent", 0)),
		])
	var map_cue := _career_map_cue(_array(progression.get("new_unlock_ids", [])), meta) if show_follow_up else {}
	var map_text := str(map_cue.get("text", ""))
	if not map_cue.is_empty():
		details.append(str(map_cue["tooltip"]))
	return {
		"text": text + "\n" + map_text if not map_text.is_empty() else text,
		"xp_text": text,
		"map_text": map_text,
		"tooltip": "\n".join(details),
		"follow_up": _career_follow_up(progression, meta) if show_follow_up else {},
	}


static func _career_map_cue(new_unlock_ids: Array, meta: Dictionary) -> Dictionary:
	var opened := PackedStringArray()
	for map_id in new_unlock_ids:
		var definition := M7ContentCatalogScript.map_definition_exact(str(map_id))
		if not definition.is_empty():
			opened.append(str(definition["display_name"]))
	if not opened.is_empty():
		var text := "新开放 %s" % opened[0]
		if opened.size() > 1:
			text += " 等 %d 档" % opened.size()
		return {"text": text, "tooltip": "新开放 %s" % "、".join(opened)}
	for raw_map in _array(meta.get("map_catalog", [])):
		var map := _dictionary(raw_map)
		if map.is_empty() or bool(map.get("unlocked", true)):
			continue
		var name := "下一档 %s" % str(map.get("display_name", ""))
		var requirements := str(map.get("lock_reason", ""))
		var blockers := requirements.split(" · ", false)
		var text := name if blockers.is_empty() else "%s · %s" % [name, blockers[0]]
		var tooltip := name if requirements.is_empty() else "%s · %s" % [name, requirements]
		var required_exp := M7ContentCatalogScript.profile_exp_for_level(int(map.get("min_profile_level", 1)), meta)
		if meta.has("profile_exp") and required_exp > int(meta["profile_exp"]):
			tooltip += " · 还差 %d 经验" % (required_exp - int(meta["profile_exp"]))
		return {"text": text, "tooltip": tooltip}
	return {}


static func _career_follow_up(progression: Dictionary, meta: Dictionary) -> Dictionary:
	var achievements := _dictionary(meta.get("achievement_states", {}))
	var first_return := _dictionary(achievements.get("achievement_first_return", {}))
	if str(first_return.get("status", "")) == "claimable":
		return {"label": "查看首撤奖励", "module_id": &"task_archive", "secondary_id": &"achievement", "card_id": "achievement_first_return"}
	var dots := _dictionary(meta.get("red_dot_state", {}))
	var talent_available := int(dots.get("talent_available", 0)) > 0
	var rewards_available := int(dots.get("claimable_rewards", 0)) > 0
	if talent_available and (int(progression.get("talent_points_gained", 0)) > 0 or not rewards_available):
		return {"label": "查看可用天赋", "module_id": &"talent"}
	if rewards_available:
		return {"label": "查看待领奖励", "module_id": &"task_archive"}
	return {}


static func _persistence_text(state: StringName) -> String:
	match state:
		&"committed":
			return "进度已保存。"
		&"duplicate_ignored":
			return "本次结果此前已保存，没有重复结算。"
		&"awaiting_salvage_confirmation":
			return "确认保全后才会保存本次结果。"
		&"save_failed", &"write_blocked":
			return "档案暂时无法写入；请重试保存，或明确放弃这份未保存结果。"
		&"debug_tainted_production_profile_blocked":
			return "此局含有调试记录，只能在试玩档案中结算。本局记录已保留。"
		&"meta_progress_adapter_missing":
			return "暂时无法连接进度存储；本次结果尚未保存。"
		&"discarded_unsaved":
			return "你已确认放弃这份未保存结果；本次进度不会写入档案。"
		&"tutorial_completed":
			return "教程完成状态已保存；训练收益不会写入正式档案。"
		&"tutorial_replay_complete":
			return "教程重播已完成；正式档案没有重复结算。"
		&"tutorial_incomplete_no_write":
			return "教程未完成；按训练规则未写入正式档案。"
	return "本次结果尚未保存，请重试。"


static func _array(value: Variant) -> Array:
	return (value as Array).duplicate(true) if value is Array else []


static func _dictionary(value: Variant) -> Dictionary:
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}
