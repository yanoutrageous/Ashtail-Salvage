extends RefCounted
class_name TutorialMapCatalog

const SupplyCatalog := preload("res://scripts/core/content/z1_supply_catalog.gd")
const MAP_ID := "tutorial_5x5"
const FIXED_SEED := 777
const EVENT_ROOMS := {Vector2i(0, 1): "information", Vector2i(0, 3): "first_aid",
	Vector2i(2, 4): "relief", Vector2i(3, 4): "recycle"}


static func definition() -> Dictionary:
	return {
		"id": MAP_ID,
		"mode": &"tutorial",
		"map_mode": &"tutorial_fixed",
		"display_name": "新手教程",
		"role": "固定 5×5 安全演练；可重复进入，不计入正式探索记录。",
		"width": 5,
		"height": 5,
		"mine_count": 4,
		"content_room_count": 4,
		"event_room_count": 4,
		"monster_room_count": 5,
		"chest_room_count": 4,
		"visible_exit_count": 1,
		"hidden_exit_count": 0,
		"visible_exit_position_known": true,
		"difficulty": &"tutorial",
		"difficulty_label": "教学",
		"success_exp": 0,
		"tutorial_map": true,
		"persistent_progression": false,
	}


static func runtime_config(run_start_config: Dictionary = {}) -> Dictionary:
	var sanitized_start := run_start_config.duplicate(true)
	sanitized_start["map_config_id"] = MAP_ID
	sanitized_start["map_display_name"] = "新手教程"
	sanitized_start["tutorial_map"] = true
	sanitized_start["persistence_policy"] = &"tutorial_completion_only"
	for key in [
		"selected_loadout", "carried_consumables", "selected_equipment_items",
		"selected_consumable_items", "selected_equipment_ids", "selected_consumable_ids",
		"commission_candidates", "equipment_effects", "talent_interface", "active_talent_effects",
	]:
		sanitized_start[key] = []
	sanitized_start["selected_objective_id"] = &""
	sanitized_start["selected_objective_label"] = "教学目标"
	sanitized_start["bag_limit"] = SupplyCatalog.BASE_BACKPACK_CAPACITY
	sanitized_start["backpack_capacity"] = SupplyCatalog.BASE_BACKPACK_CAPACITY
	sanitized_start["equipment_capacity"] = SupplyCatalog.BASE_EQUIPMENT_CAPACITY
	sanitized_start["failure_salvage_capacity"] = SupplyCatalog.BASE_FAILURE_SALVAGE_CAPACITY
	sanitized_start["mine_dmg_reduce"] = 0
	sanitized_start["protocol_pressure_reduce"] = 0
	sanitized_start["search_reward_bonus"] = 0
	sanitized_start["scan_hint_bonus"] = 0
	sanitized_start["max_hp"] = 100
	var teaching_profile: Dictionary = sanitized_start.get("profile_fields", {}).duplicate(true)
	for key in ["talent_directions", "active_talent_effects"]:
		teaching_profile[key] = []
	teaching_profile["max_hp"] = 100
	teaching_profile["equipment_capacity"] = SupplyCatalog.BASE_EQUIPMENT_CAPACITY
	teaching_profile["backpack_capacity"] = SupplyCatalog.BASE_BACKPACK_CAPACITY
	teaching_profile["failure_salvage_capacity"] = SupplyCatalog.BASE_FAILURE_SALVAGE_CAPACITY
	teaching_profile["consumable_weight_reduce"] = 0
	sanitized_start["profile_fields"] = teaching_profile
	var layout := manual_map()
	var guidance := triggers()
	# Pre-Z2 callers still use the four legacy services selected by position.
	if teaching_profile.get("ruleset_id") != "z2":
		layout["events"] = [Vector2i(0, 3), Vector2i(1, 2), Vector2i(2, 1), Vector2i(3, 0)]
		for key: String in ["1,2", "2,1", "3,0"]:
			guidance[key] = &"event_rule"
	return {
		"id": StringName(MAP_ID),
		"mode": &"tutorial",
		"map_config_id": MAP_ID,
		"map_display_name": "新手教程",
		"difficulty": &"tutorial",
		"difficulty_label": "教学",
		"width": 5,
		"height": 5,
		"seed": FIXED_SEED,
		"mine_count": 4,
		"event_room_count": 4,
		"monster_room_count": 5,
		"chest_room_count": 4,
		"random_exit_count": 0,
		"visible_exit_count": 1,
		"visible_exit_position_known": true,
		"mine_hits_are_fatal": false,
		"reveal_on_move": true,
		"move_requires_revealed": false,
		"backpack_capacity": SupplyCatalog.BASE_BACKPACK_CAPACITY,
		"equipment_capacity": SupplyCatalog.BASE_EQUIPMENT_CAPACITY,
		"failure_salvage_capacity": SupplyCatalog.BASE_FAILURE_SALVAGE_CAPACITY,
		"profile_fields": teaching_profile,
		"profile_level": int(sanitized_start.get("profile_level", 0)),
		"max_hp": 100,
		"talent_interface": [],
		"active_talent_effects": [],
		"mine_dmg_reduce": 0,
		"protocol_pressure_reduce": 0,
		"search_reward_bonus": 0,
		"scan_hint_bonus": 0,
		"black_to_gold_rate": 1.0,
		"use_loadout": false,
		"apply_meta_progress": false,
		"allow_warehouse_rewards": false,
		"allow_failure_rewards": false,
		"manual_map": layout,
		"tutorial_triggers": guidance,
		"run_start_config": sanitized_start,
	}


static func manual_map() -> Dictionary:
	return {
		"spawn": Vector2i(0, 0),
		"mines": [Vector2i(0, 2), Vector2i(1, 1), Vector2i(2, 0), Vector2i(3, 3)],
		"events": EVENT_ROOMS.keys(),
		"monsters": [Vector2i(0, 4), Vector2i(1, 3), Vector2i(2, 2), Vector2i(3, 1), Vector2i(4, 0)],
		"chests": [Vector2i(1, 4), Vector2i(2, 3), Vector2i(3, 2), Vector2i(4, 1)],
		"exits": [{"pos": Vector2i(4, 4), "exit_id": &"tutorial_exit", "random_exit": false}],
	}


static func triggers() -> Dictionary:
	return {
		"0,0": &"spawn_intro",
		"0,1": &"number_rule",
		"1,0": &"number_rule",
		"0,2": &"mine_rule",
		"1,1": &"mine_rule",
		"2,0": &"mine_rule",
		"0,3": &"event_rule",
		"0,4": &"monster_rule",
		"1,3": &"monster_rule",
		"2,2": &"monster_rule",
		"3,1": &"monster_rule",
		"4,0": &"monster_rule",
		"1,4": &"chest_rule",
		"2,3": &"chest_rule",
		"3,2": &"chest_rule",
		"4,1": &"chest_rule",
		"2,4": &"map_rule",
		"4,2": &"map_rule",
		"3,3": &"mine_review",
		"3,4": &"route_rule",
		"4,3": &"route_rule",
		"4,4": &"exit_goal",
	}
