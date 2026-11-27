extends RefCounted
class_name Z2ProgressionRules

const CONTENT_VERSION := "z2-system-20261116"
const VERSION := 1
const XP_CURVE_VERSION := 1
# Index 0 is Lv1 by tutorial graduation. Later entries are incremental XP.
const LEVEL_COSTS := [
	0, 30, 30, 50, 50,
	70, 70, 70, 70, 70,
	100, 100, 100, 100, 100,
	200, 200, 200, 200, 200,
	250, 250, 250, 250, 250,
	300, 300, 300, 300, 300,
	310, 320, 330, 340, 350, 360, 370, 380, 390, 400,
	410, 420, 430, 440, 450, 460, 470, 480, 490, 500,
]
# Original saved Z2 profiles have no curve version and store a level from this table.
const LEGACY_LEVEL_COSTS := [
	0, 30, 40, 50, 60, 70, 80, 90, 100, 110,
	125, 140, 150, 165, 175, 185, 200, 210, 225, 235,
	245, 260, 270, 285, 295, 300, 305, 310, 315, 320,
	325, 330, 335, 340, 345, 350, 355, 360, 365, 370,
	375, 375, 380, 380, 380, 385, 385, 390, 390, 390,
]
# level, predecessor, percent, XP cap, talent cap. Map shape stays in the existing catalog.
const MAP_RULES := {
	"tutorial_5x5": [0, "", 100, 0, 0],
	"classic_7x7_simple": [1, "", 100, 20, 50],
	"classic_7x7_normal": [3, "classic_7x7_simple", 100, 30, 50],
	"classic_10x10_easy": [3, "", 100, 50, 100],
	"classic_10x10_standard": [5, "classic_10x10_easy", 120, 70, 120],
	"classic_10x10_hard": [10, "classic_10x10_standard", 150, 100, 150],
	"classic_13x13_normal": [15, "", 150, 120, 200],
	"classic_13x13_hard": [20, "classic_13x13_normal", 180, 150, 250],
	"classic_13x13_hell": [25, "classic_13x13_hard", 200, 200, 300],
}


static func applies_to(meta: Dictionary) -> bool:
	return meta.get("ruleset_id", "") == "z2" and meta.get("z2_progression_version", 0) == VERSION


static func default_fields() -> Dictionary:
	var fields := {
		"z2_progression_version": VERSION, "z2_xp_curve_version": XP_CURVE_VERSION,
		"profile_level": 0, "profile_exp": 0,
		"warehouse_items": [], "starter_grant_version": 0,
		"talent_earned": 100, "talent_spent": 0, "talent_points": 100,
		"talent_flags": [], "talent_budget_granted": 100, "talent_catalog_version": 2,
		"tutorial_grant_receipt": {"id": "z2_teaching_points", "amount": 100},
		"tutorial_purchase_available": false, "tutorial_completed": false,
		"tutorial_completion_receipt": {}, "initial_supply_receipt": {},
		"unlocked_map_ids": ["tutorial_5x5"], "map_success_counts": {},
		"z2_fact_sequence": 0, "z2_quest_lobby_receipts": {}, "z2_quest_notices": {}, "z2_quest_departures": {},
		"task_states": {}, "achievement_states": {},
	}
	# Deferred load avoids catalog -> growth rules -> goal engine -> catalog.
	fields.merge(load("res://scripts/core/progression/z2_goals/goal_progression.gd").initial_state(), true)
	return fields


static func profile_error(meta: Dictionary) -> String:
	if not meta.has("z2_progression_version"):
		return "missing_z2_progression_version" if meta.get("content_version", "") == CONTENT_VERSION else ""
	if not applies_to(meta) or meta.get("content_version", "") != CONTENT_VERSION:
		return "unknown_z2_progression_version"
	for field in ["talent_earned", "talent_spent", "talent_points", "profile_exp", "profile_level"]:
		var value: Variant = meta.get(field)
		if not (value is int or value is float) or not is_finite(float(value)) or value < 0 or float(value) != floor(float(value)):
			return "invalid_" + field
	if meta.talent_spent > meta.talent_earned or meta.talent_points != meta.talent_earned - meta.talent_spent:
		return "invalid_talent_budget"
	if not meta.get("tutorial_completed") is bool or not meta.get("tutorial_purchase_available") is bool:
		return "invalid_tutorial_state"
	if not meta.get("talent_flags") is Array:
		return "invalid_talent_flags"
	var seen := {}
	for id in meta.talent_flags:
		if not id is String or not id.begins_with("z2_talent_") or id.length() != 12:
			return "invalid_talent_id"
		var number := int(id.substr(10))
		if number < 1 or number > 39 or seen.has(id):
			return "invalid_talent_id"
		seen[id] = true
	for field in ["tutorial_grant_receipt", "tutorial_completion_receipt", "initial_supply_receipt"]:
		if not meta.get(field) is Dictionary:
			return "invalid_" + field
	if meta.tutorial_grant_receipt.get("amount", 0) != 100 or meta.talent_earned < 100:
		return "invalid_tutorial_grant"
	var curve_version: Variant = meta.get("z2_xp_curve_version", 0)
	if curve_version != 0 and curve_version != XP_CURVE_VERSION:
		return "unknown_z2_xp_curve"
	var costs: Array = LEGACY_LEVEL_COSTS if curve_version == 0 else LEVEL_COSTS
	var expected_level := _level_for_exp(int(meta.profile_exp), costs) if meta.tutorial_completed else 0
	if meta.profile_level != expected_level:
		return "invalid_profile_level"
	return ""


static func exp_for_level(level: int) -> int:
	if level < 1 or level > 50:
		return -1
	var total := 0
	for index in range(level):
		total += int(LEVEL_COSTS[index])
	return total


static func level_for_exp(experience: int) -> int:
	return _level_for_exp(experience, LEVEL_COSTS)


static func _level_for_exp(experience: int, costs: Array) -> int:
	var total := 0
	for index in range(1, costs.size()):
		total += int(costs[index])
		if experience < total:
			return index
	return 50


static func map_overrides(map_id: String) -> Dictionary:
	if not MAP_RULES.has(map_id):
		return {}
	var rule: Array = MAP_RULES[map_id]
	return {"min_profile_level": rule[0], "required_clear_id": rule[1],
		"experience_percent": rule[2], "experience_cap": rule[3], "talent_cap": rule[4],
		"required_tutorial": map_id != "tutorial_5x5", "required_research_id": "", "required_achievement_id": ""}


static func map_blockers(meta: Dictionary, map_id: String) -> PackedStringArray:
	var blockers := PackedStringArray()
	if not MAP_RULES.has(map_id):
		return PackedStringArray(["未知地图"])
	var rule: Array = MAP_RULES[map_id]
	if map_id != "tutorial_5x5" and not bool(meta.get("tutorial_completed", false)):
		blockers.append("完成新手教程")
	if int(meta.get("profile_level", 0)) < int(rule[0]):
		blockers.append("达到 Lv.%d" % rule[0])
	if rule[1] != "" and int(meta.get("map_success_counts", {}).get(rule[1], 0)) < 1:
		blockers.append("前一难度成功撤离")
	return blockers


static func settle_scores(map_id: String, base_experience: int, base_talent: int, ending: String) -> Dictionary:
	if not MAP_RULES.has(map_id) or ending not in ["success", "failure", "abandon"]:
		return {"ok": false, "experience": 0, "talent_points": 0}
	var rule: Array = MAP_RULES[map_id]
	var ratio := 100 if ending == "success" else 50
	var experience := int(mini(maxi(0, base_experience) * int(rule[2]), int(rule[3]) * 100) * ratio / 10000.0)
	var talent := int(mini(maxi(0, base_talent) * int(rule[2]), int(rule[4]) * 100) * ratio / 10000.0)
	if ratio == 50 and base_talent > 0 and int(rule[4]) > 0:
		talent = maxi(1, talent)
	return {"ok": true, "experience": experience, "talent_points": talent,
		"base_experience": base_experience, "base_talent": base_talent, "ending_percent": ratio}


static func score_events(events: Array) -> Dictionary:
	var xp := 0
	var talent := 0
	var seen := {}
	var stage_xp := {}
	var stage_talent := {}
	var spawn := ""
	for raw_event in events:
		if not raw_event is Dictionary:
			continue
		var payload: Dictionary = raw_event.get("payload", {})
		var type := str(raw_event.get("event_type", ""))
		var room := str(payload.get("position", ""))
		if type == "run_started":
			spawn = room
			continue
		if room.is_empty() or str(raw_event.get("source", "")) == "debug_command":
			continue
		var xp_delta := 0
		var talent_delta := 0
		var key := type + ":" + room
		match type:
			"event_stage_completed":
				if payload.get("effective") != true:
					continue
				var xp_key := str(payload.get("xp_key", ""))
				var talent_key := str(payload.get("talent_key", ""))
				if not xp_key.is_empty() and not stage_xp.has(xp_key):
					stage_xp[xp_key] = true
					xp += maxi(0, int(payload.get("base_xp", 0)))
				if not talent_key.is_empty() and not stage_talent.has(talent_key):
					stage_talent[talent_key] = true
					talent += maxi(0, int(payload.get("base_talent", 0)))
				continue
			"room_entered":
				if room == spawn:
					continue
				xp_delta = 1
				talent_delta = 1
			"room_searched":
				xp_delta = 4 if payload.get("is_chest", false) else 0
				talent_delta = 2 if payload.get("is_chest", false) else 1
			"combat_resolved":
				if not payload.get("runtime", false) or payload.get("automatic", false) or payload.get("stage_authority", "") == "z2_event_runtime":
					continue
				var cage := bool(payload.get("cage", false))
				xp_delta = 10 if cage else 5
				talent_delta = 5 if cage else 3
			"event_option_selected":
				var result: Dictionary = payload.get("result", {})
				if result.get("ruleset_id", "") == "z2" or not result.get("ok", false) or not (result.get("progress_completed", false) or result.get("completed", false)) or payload.get("event_type", "") == "cage":
					continue
				xp_delta = 5
				talent_delta = 2
			_:
				continue
		if not seen.has(key):
			seen[key] = true
			xp += xp_delta
			talent += talent_delta
	return {"experience": xp, "talent_points": talent}
