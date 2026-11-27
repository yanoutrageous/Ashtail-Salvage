extends RefCounted
class_name M7ContentCatalog

const M3ItemCatalogScript := preload("res://scripts/core/content/m3_item_catalog.gd")
const Z1SupplyCatalogScript := preload("res://scripts/core/content/z1_supply_catalog.gd")
const TutorialMapCatalogScript := preload("res://scripts/core/run/tutorial_map_catalog.gd")
const Z1EventCatalogScript := preload("res://scripts/core/content/z1_event_catalog.gd")
const Z1MonsterCatalogScript := preload("res://scripts/gameplay/combat/z1_monster_catalog.gd")
const Z2Rules := preload("res://scripts/core/progression/z2_progression_rules.gd")
const Z2Quests := preload("res://scripts/core/progression/z2_quest_catalog.gd")

const DEFAULT_UNLOCKED_MAPS := [
	"tutorial_5x5",
]
const LEGACY_I5_DEFAULT_UNLOCKED_MAPS := [
	"tutorial_5x5",
	"classic_7x7_simple",
	"classic_7x7_normal",
	"classic_10x10_easy",
	"classic_10x10_standard",
]
const COMMISSION_EXPLORATION_EXP := 8
# Z1 Demo cumulative experience from Lv.1 to Lv.30, in level order.
const PROFILE_EXP_THRESHOLDS: Array[int] = [
	0, 30, 70, 120, 180, 250, 330, 420, 520, 630,
	755, 892, 1041, 1202, 1375, 1560, 1757, 1966, 2187, 2420,
	2665, 2922, 3191, 3472, 3765, 4065, 4370, 4680, 4995, 5315,
]


static func map_definitions() -> Array[Dictionary]:
	return [
		_tutorial_map(),
		_map("classic_7x7_simple", "7×7 简单", "教学 / 低压入门", 7, 10, 5, 1, 0, true, {
			"min_profile_level": 1, "experience_percent": 100, "experience_cap": 45,
			"required_tutorial": true,
		}),
		_map("classic_7x7_normal", "7×7 普通", "入门正式局", 7, 10, 5, 0, 1, false, {
			"min_profile_level": 3, "experience_percent": 108, "experience_cap": 55,
			"required_clear_id": "classic_7x7_simple",
		}),
		_map("classic_10x10_easy", "10×10 简单", "低压标准局", 10, 20, 10, 0, 3, false, {
			"min_profile_level": 5, "experience_percent": 100, "experience_cap": 60,
		}),
		_map("classic_10x10_standard", "10×10 标准", "主展示标准局", 10, 20, 10, 0, 2, false, {
			"min_profile_level": 8, "experience_percent": 112, "experience_cap": 75,
			"required_clear_id": "classic_10x10_easy",
		}),
		_map("classic_10x10_hard", "10×10 困难", "高压标准局", 10, 20, 10, 0, 1, false, {
			"min_profile_level": 12, "experience_percent": 122, "experience_cap": 85,
			"required_clear_id": "classic_10x10_standard",
		}),
		_map("classic_13x13_normal", "13×13 普通", "大图普通", 13, 34, 17, 0, 4, false, {
			"min_profile_level": 15, "experience_percent": 108, "experience_cap": 85,
		}),
		_map("classic_13x13_hard", "13×13 困难", "大图高压", 13, 34, 17, 0, 2, false, {
			"min_profile_level": 21, "experience_percent": 122, "experience_cap": 95,
			"required_clear_id": "classic_13x13_normal",
			"required_research_id": "research_extraction_signal",
		}),
		_map("classic_13x13_hell", "13×13 地狱", "高失败挑战", 13, 34, 17, 0, 1, false, {
			"min_profile_level": 26, "experience_percent": 135, "experience_cap": 100,
			"required_clear_id": "classic_13x13_hard", "required_achievement_id": "achievement_critical_return",
		}),
	]


static func map_definition(map_id: String) -> Dictionary:
	var exact := map_definition_exact(map_id)
	if not exact.is_empty():
		return exact
	# Historical callers rely on the 10x10 standard fallback. New selection and
	# projection paths must use map_definition_exact() so an unknown id cannot be
	# presented as another playable map.
	return map_definition_exact("classic_10x10_standard")


static func map_definition_exact(map_id: String) -> Dictionary:
	for definition in map_definitions():
		if str(definition.get("id", "")) == map_id:
			return definition.duplicate(true)
	return {}


static func map_runtime_config(map_id: String, seed_value: int, run_start_config: Dictionary = {}) -> Dictionary:
	if map_id == TutorialMapCatalogScript.MAP_ID:
		return TutorialMapCatalogScript.runtime_config(run_start_config)
	var definition := map_definition(map_id)
	return {
		"id": StringName(map_id),
		"mode": StringName(definition.get("mode", &"standard")),
		"map_config_id": map_id,
		"map_display_name": str(definition.get("display_name", map_id)),
		"difficulty": StringName(definition.get("difficulty", &"normal")),
		"difficulty_label": str(definition.get("difficulty_label", "普通")),
		"width": int(definition.get("width", 10)),
		"height": int(definition.get("height", 10)),
		"seed": seed_value,
		"mine_count": int(definition.get("mine_count", 20)),
		"event_room_count": int(definition.get("content_room_count", 10)),
		"monster_room_count": int(definition.get("content_room_count", 10)),
		"chest_room_count": int(definition.get("content_room_count", 10)),
		"visible_exit_count": int(definition.get("visible_exit_count", 0)),
		"random_exit_count": int(definition.get("hidden_exit_count", 2)),
		"visible_exit_position_known": bool(definition.get("visible_exit_position_known", false)),
		"mine_hits_are_fatal": false,
		"reveal_on_move": true,
		"move_requires_revealed": false,
		"backpack_capacity": 10,
		"failure_salvage_capacity": 4,
		"black_to_gold_rate": 1.0,
		"run_start_config": run_start_config.duplicate(true),
	}


static func commission_definitions() -> Array[Dictionary]:
	return [
		_commission("commission_recover_supply", "回收补给箱", "成功撤离时带回至少 2 件非消耗品。", &"recover_non_consumables", 2, 25),
		_commission("commission_route_survey", "路线勘察", "本局探索 12 个不同房间。", &"unique_rooms", 12, 20),
		_commission("commission_anomaly_cleanup", "异常清理", "击败 2 个怪物遭遇。", &"monsters_defeated", 2, 30),
		_commission("commission_open_crates", "开箱记录", "打开 2 个宝箱。", &"chests_opened", 2, 25),
		_commission("commission_event_evidence", "事件取证", "完成 2 个事件。", &"events_completed", 2, 25),
		_commission("commission_critical_extract", "临界协议撤离", "在协议阶段 1 时成功撤离。", &"critical_extract", 1, 45, ["classic_10x10_hard", "classic_13x13_normal", "classic_13x13_hard", "classic_13x13_hell"]),
	]


static func commission_definition(commission_id: String) -> Dictionary:
	for definition in commission_definitions():
		if str(definition.get("id", "")) == commission_id:
			return definition.duplicate(true)
	return commission_definitions()[0].duplicate(true)


static func commission_candidates(map_id: String, seed_value: int, count: int = 3) -> Array[Dictionary]:
	if map_id == "tutorial_5x5":
		return []
	if map_id == "classic_7x7_simple":
		return [commission_definition("commission_recover_supply")]
	var legal: Array[Dictionary] = []
	for definition in commission_definitions():
		var map_ids: Array = definition.get("map_ids", [])
		if map_ids.is_empty() or map_ids.has(map_id):
			legal.append(definition.duplicate(true))
	var result: Array[Dictionary] = []
	var pool := legal.duplicate(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	while not pool.is_empty() and result.size() < maxi(1, count):
		var index := rng.randi_range(0, pool.size() - 1)
		result.append(pool[index].duplicate(true))
		pool.remove_at(index)
	return result


static func commission_offer_seed(map_id: String, run_count: int) -> int:
	var seed := 17
	for byte_value in map_id.to_utf8_buffer():
		seed = (seed * 31 + int(byte_value)) % 2147483647
	seed = (seed + maxi(0, run_count) * 1009) % 2147483647
	return maxi(1, seed)


static func commission_offer_candidates(map_id: String, run_count: int, count: int = 3) -> Array[Dictionary]:
	return commission_candidates(map_id, commission_offer_seed(map_id, run_count), count)


static func task_definitions(meta: Dictionary = {}) -> Array[Dictionary]:
	return Z2Quests.definitions("main") if meta.is_empty() or Z2Rules.applies_to(meta) else legacy_task_definitions()


static func optional_task_definitions(meta: Dictionary = {}) -> Array[Dictionary]:
	return Z2Quests.definitions("side") if meta.is_empty() or Z2Rules.applies_to(meta) else legacy_optional_task_definitions()


static func achievement_definitions(meta: Dictionary = {}) -> Array[Dictionary]:
	if not meta.is_empty() and not Z2Rules.applies_to(meta):
		return legacy_achievement_definitions()
	var definitions := Z2Quests.definitions("achievement")
	for definition in definitions:
		var state: Dictionary = meta.get("achievement_states", {}).get(definition.id, {})
		definition["total_reward"] = definition.reward.duplicate(true)
		for step in definition.reward_steps:
			if not state.get("claimed_tiers", []).has(int(step.tier)):
				definition.reward = step.reward.duplicate(true)
				definition.target = int(step.target)
				definition.tier = int(step.tier)
				break
	return definitions


static func legacy_task_definitions() -> Array[Dictionary]:
	return [
		_goal("task_first_survey", "第一次踏勘", "打开小地图并探索 3 个不同房间。", {"gold": 20, "exp": 20}),
		_goal("task_risk_mark", "风险标记", "标记任意 1 个未探索房间。", {"items": ["con_scan_pin"], "exp": 15}),
		_goal("task_supply_recovery", "物资回收", "打开 1 个宝箱并拾取 1 件物品。", {"items": ["con_med_patch"], "exp": 20}),
		_goal("task_clear_anomaly", "清理异常", "击败 1 个怪物遭遇。", {"gold": 30, "exp": 25}),
		_goal("task_complete_commission", "完整委托", "完成本局委托并成功撤离。", {"gold": 40, "exp": 35}),
		_goal("task_prepared_deploy", "有备出勤", "购买 1 件物品，并把该实例带入之后的一局。", {"items": ["con_tape_roll"], "exp": 30}),
		_goal("task_sample_research", "样本研究", "带回 1 件怪物样本并完成任意研究。", {"gold": 60, "exp": 50}),
	]


static func legacy_optional_task_definitions() -> Array[Dictionary]:
	return [
		_goal("task_failure_salvage", "失败抢救", "失败后手动抢救至少 1 件物品并确认。", {"gold": 20, "exp": 20}),
	]


static func legacy_achievement_definitions() -> Array[Dictionary]:
	return [
		_goal("achievement_first_return", "首次归来", "第一次成功撤离。", {"gold": 30, "exp": 30}),
		_goal("achievement_clean_route", "清洁路线", "成功撤离且本局未触发雷房。", {"gold": 40, "exp": 35}),
		_goal("achievement_critical_return", "临界归来", "在协议阶段 1 成功撤离。", {"gold": 60, "exp": 50}),
		_goal("achievement_low_hp_return", "残血归来", "以不高于 10 生命成功撤离。", {"gold": 50, "exp": 45}),
		_goal("achievement_chest_expert", "开箱专家", "单局打开至少 4 个宝箱并成功撤离。", {"gold": 45, "exp": 40}),
		_goal("achievement_anomaly_sweep", "异常清扫", "单局击败至少 4 个怪物遭遇并成功撤离。", {"gold": 55, "exp": 45}),
		_goal("achievement_measured_greed", "贪而有度", "发现撤离点后继续探索至少 8 个新房间，再成功撤离。", {"gold": 55, "exp": 45}),
		_goal("achievement_four_events", "四类见证", "累计完成旅商、骰子局、祭坛、机关各 1 次。", {"gold": 70, "exp": 60}),
	]


static func research_definitions(meta: Dictionary = {}) -> Array[Dictionary]:
	if Z2Rules.applies_to(meta):
		var recipes := Z2ContentEligibility.research_definitions()
		for recipe in recipes:
			var product := Z2ItemCatalog.definition(str(recipe.unlock_item_id))
			recipe["effect"] = "合成%s×1，存入仓库；可重复进行，成品仅由研究获得。" % str(product.get("display_name", "物资"))
		return recipes
	return [
		_research("research_anomaly_structure", "异常结构分析", "", 40, "mon_old_gear_set", "开放稳定剂购买，并显示完整怪物档案。"),
		_research("research_protocol_formula", "协议稳定配方", "research_anomaly_structure", 60, "sp_altar_residue", "开放镇静糖购买，并显示协议压力规则详情。"),
		_research("research_extraction_signal", "撤离信号校准", "research_protocol_formula", 90, "mon_loader_black_box", "显示撤离权规则详情，并满足 13×13 困难的一项开放条件。"),
	]


static func research_definition(research_id: String, meta: Dictionary = {}) -> Dictionary:
	for definition in research_definitions(meta):
		if str(definition.get("id", "")) == research_id:
			return definition.duplicate(true)
	return {}


static func shop_definitions(meta: Dictionary = {}) -> Array[Dictionary]:
	if Z2Rules.applies_to(meta):
		var result: Array[Dictionary] = []
		for item in Z2ItemCatalog.supplies():
			if item.channels.has("camp_shop"):
				result.append({"item_id": str(item.item_id), "display_name": str(item.display_name), "price": int(item.purchase_price), "unlock_kind": "z2_qualification", "unlock_value": str(item.min_profile_level)})
		return result
	return [
		_shop("con_ration", 12),
		_shop("con_tape_roll", 16),
		_shop("con_scan_pin", 14),
		_shop("con_med_patch", 18),
		_shop("con_calm_candy", 20, "research", "research_protocol_formula"),
		_shop("con_stabilizer", 22, "research", "research_anomaly_structure"),
		_shop("eq_goggles", 36, "profile", "2"),
		_shop("eq_insulated_sleeve", 32, "profile", "2"),
		_shop("eq_old_vest", 42, "profile", "3"),
		_shop("eq_recovery_bag", 48, "profile", "4"),
	]


static func shop_definition(item_id: String, meta: Dictionary = {}) -> Dictionary:
	for definition in shop_definitions(meta):
		if str(definition.get("item_id", "")) == item_id:
			return definition.duplicate(true)
	return {}


static func item_definition(item_id: String, meta: Dictionary = {}) -> Dictionary:
	if Z2Rules.applies_to(meta):
		var current := Z2ItemCatalog.definition(item_id)
		if not current.is_empty():
			return current
		if not Z2ContentEligibility.MATERIAL_RULES.has(item_id):
			return {}
	for definition in M3ItemCatalogScript.all_items():
		if str(definition.get("item_id", "")) == item_id:
			return definition.duplicate(true)
	return {}


static func profile_levels() -> Array[Dictionary]:
	return [
		{"level": 1, "exp": profile_exp_for_level(1), "title": "新进回收员"},
		{"level": 2, "exp": profile_exp_for_level(2), "title": "初级回收员"},
		{"level": 3, "exp": profile_exp_for_level(3), "title": "异常处理员", "badge": "异常处理员徽章"},
		{"level": 4, "exp": profile_exp_for_level(4), "title": "高压路线回收员"},
		{"level": 5, "exp": profile_exp_for_level(5), "title": "灰尾资深回收员", "badge": "阶段资历徽章"},
	]


static func profile_level_for_exp(exp_value: int) -> int:
	for index in range(PROFILE_EXP_THRESHOLDS.size() - 1, 0, -1):
		if exp_value >= PROFILE_EXP_THRESHOLDS[index]:
			return index + 1
	return 1


static func profile_exp_for_level(level: int, meta: Dictionary = {}) -> int:
	if Z2Rules.applies_to(meta):
		return Z2Rules.exp_for_level(level)
	return PROFILE_EXP_THRESHOLDS[level - 1] if level >= 1 and level <= PROFILE_EXP_THRESHOLDS.size() else -1


static func collection_sets() -> Array[Dictionary]:
	return [
		{"id": "collection_old_work", "display_name": "旧作业痕迹", "item_ids": _collectible_ids(1, 8)},
		{"id": "collection_anomaly_machine", "display_name": "异常机械记录", "item_ids": _collectible_ids(9, 16)},
		{"id": "collection_deep_protocol", "display_name": "深层协议遗物", "item_ids": _collectible_ids(17, 24)},
	]


static func initial_codex_discoveries() -> Array[String]:
	return [
		"item:eq_goggles",
		"item:eq_insulated_sleeve",
		"item:con_ration",
		"item:con_tape_roll",
		"item:con_scan_pin",
		"rule:mines_and_movement",
		"rule:backpack_and_salvage",
		"rule:settlement_outcomes",
	]


static func all_codex_entry_ids() -> Array[String]:
	var result: Array[String] = []
	for definition in map_definitions():
		result.append("map:%s" % str(definition.get("id", "")))
	for monster_id in ["slime", "slimeling", "bat", "drone"]:
		result.append("monster:%s" % monster_id)
	for event_id in ["trader", "dice", "altar", "trap"]:
		result.append("event:%s" % event_id)
	for monster_id in Z1MonsterCatalogScript.all_runtime_types():
		result.append("monster:%s" % monster_id)
	for event_id in Z1EventCatalogScript.event_ids():
		result.append("event:%s" % event_id)
	for item in M3ItemCatalogScript.all_items():
		if not bool(item.get("is_virtual_record", false)):
			result.append("item:%s" % str(item.get("item_id", "")))
	for rule_id in ["mines_and_movement", "extraction_right", "protocol_pressure", "backpack_and_salvage", "settlement_outcomes"]:
		result.append("rule:%s" % rule_id)
	result.append("unique:locked_placeholder")
	return result


static func codex_subject(entry_id: String) -> Dictionary:
	var subject_id := StringName(entry_id.get_slice(":", 1))
	if entry_id.begins_with("event:"):
		var event := Z1EventCatalogScript.definition(subject_id)
		if not event.is_empty():
			return {
				"display_name": event["player_title"],
				"asset_id": StringName("z1.event.%s" % String(event["source_id"]).to_lower()),
			}
	if entry_id.begins_with("monster:"):
		var monster := Z1MonsterCatalogScript.definition(subject_id)
		if not monster.is_empty():
			return {"display_name": monster["display_name"], "asset_id": monster["visual_key"]}
	return {}


static func is_shop_unlocked(definition: Dictionary, meta: Dictionary) -> bool:
	if Z2Rules.applies_to(meta):
		return Z2ContentEligibility.is_eligible(str(definition.get("item_id", "")), "camp_shop", Z2ContentEligibility.freeze_profile(meta))
	match str(definition.get("unlock_kind", "default")):
		"research":
			return _array(meta.get("research_completed_ids", [])).has(str(definition.get("unlock_value", "")))
		"profile":
			return int(meta.get("profile_level", 1)) >= int(str(definition.get("unlock_value", "1")))
		_:
			return true


static func _map(id: String, display_name: String, role: String, size: int, mines: int, content_count: int, visible_exits: int, hidden_exits: int, visible_position_known: bool, progression: Dictionary) -> Dictionary:
	var difficulty := id.get_slice("_", id.get_slice_count("_") - 1)
	var labels := {"simple": "简单", "normal": "普通", "easy": "简单", "standard": "标准", "hard": "困难", "hell": "地狱"}
	var definition := {
		"id": id,
		"display_name": display_name,
		"role": role,
		"width": size,
		"height": size,
		"mine_count": mines,
		"content_room_count": content_count,
		"visible_exit_count": visible_exits,
		"hidden_exit_count": hidden_exits,
		"visible_exit_position_known": visible_position_known,
		"difficulty": StringName(difficulty),
		"difficulty_label": str(labels.get(difficulty, difficulty)),
	}
	definition.merge(progression)
	return definition


static func _tutorial_map() -> Dictionary:
	return TutorialMapCatalogScript.definition()


static func _commission(id: String, display_name: String, description: String, metric: StringName, target: int, gold: int, map_ids: Array = []) -> Dictionary:
	return {"id": id, "display_name": display_name, "description": description, "metric": metric, "target": target, "reward": {"gold": gold, "exp": COMMISSION_EXPLORATION_EXP}, "map_ids": map_ids.duplicate()}


static func _goal(id: String, display_name: String, description: String, reward: Dictionary) -> Dictionary:
	return {"id": id, "display_name": display_name, "description": description, "reward": reward.duplicate(true)}


static func _research(id: String, display_name: String, prerequisite: String, gold: int, material_item_id: String, effect: String) -> Dictionary:
	return {"id": id, "display_name": display_name, "prerequisite": prerequisite, "gold_cost": gold, "material_item_id": material_item_id, "material_count": 1, "effect": effect}


static func _shop(item_id: String, price: int, unlock_kind: String = "default", unlock_value: String = "") -> Dictionary:
	var item := item_definition(item_id)
	var approved_price := Z1SupplyCatalogScript.out_of_run_price(item_id)
	if approved_price >= 0:
		price = approved_price
	return {"item_id": item_id, "display_name": str(item.get("display_name", item_id)), "price": price, "unlock_kind": unlock_kind, "unlock_value": unlock_value}


static func _collectible_ids(start_index: int, end_index: int) -> Array[String]:
	var result: Array[String] = []
	for index in range(start_index, end_index + 1):
		result.append("col_%02d" % index)
	return result


static func _array(value: Variant) -> Array:
	return value.duplicate(true) if value is Array else []
