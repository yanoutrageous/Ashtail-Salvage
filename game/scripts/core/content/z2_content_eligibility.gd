extends RefCounted
class_name Z2ContentEligibility

const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const MAPS_13 := ["classic_13x13_normal", "classic_13x13_hard", "classic_13x13_hell"]
const MATERIAL_RULES := {
	"mon_old_gear_set": [],
	"mon_overheated_core": MAPS_13,
	"mon_loader_black_box": ["classic_13x13_hell"],
}
const INHERITED_MATERIAL_CHANNELS := {
	"mon_broken_patrol_badge": ["monster"], "mon_abnormal_instruction": ["monster"],
	"sp_reset_spring": ["monster"], "sp_transit_lead_seal": ["chest", "recycle"],
	"sp_depressurized_valve_core": ["mechanism_success"], "sp_altar_residue": ["altar"],
	"sp_inspection_calibration_plate": ["recycle"],
}

# qualification only answers level/research ownership; it is NOT an acquisition channel.
# Actual channels: search, chest, altar, monster (ordinary actual combat), camp_shop,
# shop (in-run), mechanism_success, compression, recycle, research_craft,
# first_aid_cabinet, salvage_seal_cabinet, starter_claim.
# Extra drops must reuse the origin pool's actual channel; generic event/extra_drop and
# research products outside research_craft fail closed. This core never supplies probabilities.
static func freeze_profile(meta: Dictionary) -> Dictionary:
	var level: Variant = meta.get("profile_level", 0)
	var completed: Array[String] = []
	var raw_ids: Variant = meta.get("research_completed_ids", [])
	if raw_ids is Array:
		for id: Variant in raw_ids:
			if (id is String or id is StringName) and not str(id).is_empty() and not completed.has(str(id)):
				completed.append(str(id))
	return {
		"content_version": Items.CONTENT_VERSION,
		"profile_level": clampi(int(level), 0, 50) if level is int or level is float else 0,
		"research_completed_ids": completed,
	}


static func is_eligible(item_id: String, channel: String, frozen: Dictionary, map_id: String = "") -> bool:
	var level := int(frozen.get("profile_level", 0))
	# Research inputs stay outside the 72-item catalog and never alias a same-name collectible.
	if MATERIAL_RULES.has(item_id):
		if level < 1:
			return false
		if channel == "qualification":
			return true
		var maps: Array = MATERIAL_RULES[item_id]
		return channel == "monster" and (maps.is_empty() or maps.has(map_id))
	if INHERITED_MATERIAL_CHANNELS.has(item_id):
		var channels: Array = INHERITED_MATERIAL_CHANNELS[item_id]
		if channel == "recycle":
			return channels.has(channel)
		return level >= 1 and (channel == "qualification" or channels.has(channel))
	var item := Items.definition(item_id)
	if item.is_empty():
		return false
	var research_id := str(item.required_research_id)
	if not research_id.is_empty():
		# Crafting is the acquisition itself, not an unlock followed by random drops.
		if channel == "research_craft":
			return level >= 1
		if channel != "qualification":
			return false
		var completed: Variant = frozen.get("research_completed_ids", [])
		if not completed is Array or not completed.has(research_id):
			return false
	elif level < int(item.min_profile_level):
		return false
	if channel == "qualification":
		return true
	if str(item.item_type) == "collectible":
		var tier := int(item.collectible_level)
		if channel == "compression":
			return tier == 2
		# Current T07 authorization inherits the Z1 mechanism and five-stage altar
		# ranges, now selected by actual S5 tier instead of col_XX number ranges.
		if channel == "mechanism_success":
			return tier in [4, 5]
		if channel == "altar":
			return tier in [3, 4, 5, 6]
	if not item.channels.has(channel):
		return false
	# Supply shops appear at Lv7 on every formal map. A multi-source item's
	# map list applies to its field drop, independently of its shop offer.
	if channel == "shop":
		return level >= 7
	if channel == "starter_claim":
		return level >= 1
	var maps: Array = item.map_ids
	return maps.is_empty() or maps.has(map_id)


static func filter_pool(pool: Array, channel: String, frozen: Dictionary, map_id: String = "") -> Array:
	var result: Array = []
	for entry: Variant in pool:
		var id: Variant = ""
		if entry is String or entry is StringName:
			id = entry
		elif entry is Dictionary:
			id = entry.get("item_id", entry.get("definition_id", entry.get("id", "")))
		elif entry is Array and not entry.is_empty():
			id = entry[0]
		if (id is String or id is StringName) and is_eligible(str(id), channel, frozen, map_id):
			result.append(entry)
	# Empty stays empty: a mandatory-reward caller must reject before paying or drawing.
	# Retain entries, order, duplicates and weights. Probability normalization belongs to caller.
	return result


static func research_definitions() -> Array[Dictionary]:
	return [
		{
			"id": "research_hard_shell_patch", "display_name": "硬壳补片工艺",
			"unlock_item_id": "con_hard_shell_patch", "material_item_id": "mon_old_gear_set",
			"material_count": 1, "gold_cost": 40, "prerequisite": "",
			"channels": ["research_craft"], "channels_status": "confirmed", "repeatable": true, "output_count": 1,
			"material_channel": "monster", "material_min_profile_level": 1, "material_map_ids": [],
		},
		{
			"id": "research_red_battery", "display_name": "强化电源方案",
			"unlock_item_id": "con_red_battery", "material_item_id": "mon_overheated_core",
			"material_count": 1, "gold_cost": 60, "prerequisite": "",
			"channels": ["research_craft"], "channels_status": "confirmed", "repeatable": true, "output_count": 1,
			"material_channel": "monster", "material_min_profile_level": 1, "material_map_ids": MAPS_13.duplicate(),
		},
		{
			"id": "research_black_box_bell", "display_name": "黑盒铃校准",
			"unlock_item_id": "eq_black_box_bell", "material_item_id": "mon_loader_black_box",
			"material_count": 1, "gold_cost": 90, "prerequisite": "",
			"channels": ["research_craft"], "channels_status": "confirmed", "repeatable": true, "output_count": 1,
			"material_channel": "monster", "material_min_profile_level": 1, "material_map_ids": ["classic_13x13_hell"],
		},
	]
