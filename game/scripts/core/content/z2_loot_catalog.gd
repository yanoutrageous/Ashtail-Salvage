extends RefCounted
class_name Z2LootCatalog

const Items := preload("res://scripts/core/content/z2_item_catalog.gd")
const Eligibility := preload("res://scripts/core/content/z2_content_eligibility.gd")
const Z1 := preload("res://scripts/core/content/z1_loot_catalog.gd")
const LegacyItems := preload("res://scripts/core/content/m3_item_catalog.gd")
const Maps := preload("res://scripts/core/content/m7_content_catalog.gd")
const ExclusiveDrop := preload("res://scripts/core/content/z2_exclusive_drop.gd")
const Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")
const CHANNELS := ["search", "chest", "monster", "mechanism_success", "compression", "recycle", "altar", "shop", "first_aid_cabinet", "salvage_seal_cabinet"]
const COLLECTIBLE_SHARES := [
	[0.72, 0.20, 0.06, 0.017, 0.0025, 0.0005],
	[0.60, 0.26, 0.10, 0.033, 0.006, 0.001],
	[0.48, 0.30, 0.15, 0.055, 0.0125, 0.0025],
	[0.34, 0.34, 0.20, 0.09, 0.024, 0.006],
]
const MONSTER_MATERIALS := ["mon_old_gear_set", "mon_broken_patrol_badge", "mon_overheated_core", "mon_loader_black_box", "mon_abnormal_instruction", "sp_reset_spring"]
# User-delegated Z2 trial rule, 2026-11-16: ordinary Monster clears only.
# Reset spring remains in the complement; this grants no map/level eligibility.
const EXCLUSIVE_MONSTER_IDS := ["mon_old_gear_set", "mon_broken_patrol_badge", "mon_overheated_core", "mon_loader_black_box", "mon_abnormal_instruction"]
const OTHER_MATERIALS := ["sp_transit_lead_seal", "sp_depressurized_valve_core", "sp_altar_residue", "sp_inspection_calibration_plate"]
# S3 E79/E98/E364 and Z1SupplyRuleService explicit exchanges/assistance.
# No name-based inference; unknown materials have no invented natural-use tags.
const MATERIAL_TAGS := {
	"con_tape_roll": ["insulation", "repair"],
	"sp_reset_spring": ["reset"], "sp_depressurized_valve_core": ["flow_control"],
	"mon_old_gear_set": ["mechanical_material"],
	"sp_inspection_calibration_plate": ["mechanical_material"],
	"sp_transit_lead_seal": ["anomalous_sample"],
}


static func definition(item_id: String) -> Dictionary:
	var current := Items.definition(item_id)
	if not current.is_empty():
		return current
	if not MONSTER_MATERIALS.has(item_id) and not OTHER_MATERIALS.has(item_id):
		return {}
	for original in LegacyItems.all_items():
		if str(original.item_id) == item_id:
			var material := original.duplicate(true)
			material["content_version"] = Items.CONTENT_VERSION
			material["inherited_definition_source"] = "z1_supply_catalog" if item_id.begins_with("sp_") and item_id != "sp_altar_residue" else "m3_item_catalog"
			return material
	return {}


static func candidates(channel: String, frozen: Dictionary, map_id: String, stage: int = 1, talent_profile: Dictionary = {}) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.assign(checked_pool(channel, frozen, map_id, stage, talent_profile).pool)
	return result


static func checked_pool(channel: String, frozen: Dictionary, map_id: String, stage: int = 1, talent_profile: Dictionary = {}) -> Dictionary:
	# Always start from the unmodified eligible pool, never an adjusted cached pool.
	var pool := _base_candidates(channel, frozen, map_id, stage)
	if pool.is_empty():
		return {"ok": false, "reason": "empty_eligible_pool", "pool": [], "applied": false}
	if channel != "monster":
		return {"ok": true, "reason": "", "pool": pool, "applied": false}
	if not talent_profile.is_empty() and not Talents.valid_profile(talent_profile):
		return {"ok": false, "reason": "invalid_frozen_talents", "pool": [], "applied": false}
	return ExclusiveDrop.adjust_exclusive_pool(pool, float(Talents.amount(talent_profile, "exclusive_drop_bonus_percent")), EXCLUSIVE_MONSTER_IDS, true)


static func frozen_talents(run_start_config: Dictionary) -> Dictionary:
	return Talents.run_profile(run_start_config.get("profile_fields", {}), run_start_config.get("active_talent_effects", []), bool(run_start_config.get("tutorial_map", false)))


static func preflight_config(run_start_config: Dictionary) -> Dictionary:
	return preflight("monster", run_start_config.get("profile_fields", {}).get("content_eligibility", {}), str(run_start_config.get("map_config_id", "")), 1, frozen_talents(run_start_config))


static func _base_candidates(channel: String, frozen: Dictionary, map_id: String, stage: int = 1) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var map := Maps.map_definition_exact(map_id)
	if not CHANNELS.has(channel) or map.is_empty() or frozen.get("content_version", "") != Items.CONTENT_VERSION:
		return result
	if channel == "altar" and (stage < 1 or stage > 5):
		return result
	var difficulty := str(map.get("difficulty", "normal"))
	var index := int({"simple": 0, "easy": 0, "normal": 1, "standard": 1, "hard": 2, "hell": 3}.get(difficulty, 1))
	var groups := _groups(channel, index, stage)
	var total := 0.0
	for group: Array in groups:
		# Remove ineligible definitions before within-group weights or category normalization.
		var eligible := Eligibility.filter_pool(group[0], channel, frozen, map_id)
		var within := 0.0
		for id in eligible:
			within += _weight(str(id), channel)
		if within <= 0.0:
			continue
		for id in eligible:
			var weight := float(group[1]) * _weight(str(id), channel) / within
			result.append({"item_id": str(id), "roll_weight": weight, "probability": 0.0})
			total += weight
	if total > 0.0:
		for entry in result:
			entry.probability = float(entry.roll_weight) / total
	return result


static func preflight(channel: String, frozen: Dictionary, map_id: String, stage: int = 1, talent_profile: Dictionary = {}) -> Dictionary:
	return checked_pool(channel, frozen, map_id, stage, talent_profile)


static func search_has_item(pos: Vector2i, seed_value: int, adjacent_mines: int) -> bool:
	# Original Balance.search / RunInventory.chooseItemId: nil through 35;
	# +10 to the 1..100 ticket for >=3 adjacent mines. Conditional item weights
	# are separately inherited from the confirmed Z1 probability workbook.
	var ticket := posmod(posmod(pos.x * 37 + pos.y * 53 + seed_value * 7, 100) + 17, 100) + 1
	if adjacent_mines >= 3:
		ticket = mini(100, ticket + 10)
	return ticket > 35


static func roll(channel: String, pos: Vector2i, seed_value: int, frozen: Dictionary, map_id: String, count: int = 1, stage: int = 1, adjacent_mines: int = -1, talent_profile: Dictionary = {}) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if count <= 0:
		return result
	var checked := checked_pool(channel, frozen, map_id, stage, talent_profile)
	if not checked.ok or (channel == "search" and not search_has_item(pos, seed_value, adjacent_mines)):
		return result
	var pool: Array = checked.pool
	var random := RandomNumberGenerator.new()
	random.seed = ("z2:%s:%d:%d:%d:%d" % [channel, pos.x, pos.y, seed_value, stage]).hash()
	for _index in range(count):
		var ticket := random.randf()
		var chosen := ""
		for entry in pool:
			if float(entry.probability) <= 0.0:
				continue
			chosen = entry.item_id
			ticket -= float(entry.probability)
			if ticket < 0.0:
				break
		var item := definition(chosen)
		item["drop_table_id"] = channel
		item["acquisition_channel"] = channel
		item["source"] = {"search": "search_drop", "chest": "chest_drop", "monster": "monster_drop", "mechanism_success": "event_drop", "altar": "altar_special_event"}.get(channel, channel)
		item["reward_location"] = &"room_floor"
		result.append(item)
	return result


static func economy_catalog(context: RunContext) -> Dictionary:
	var frozen := _frozen(context)
	var map_id := _map_id(context)
	return {
		"shop_pool": candidates("shop", frozen, map_id),
		"compression_pool": candidates("compression", frozen, map_id),
		"first_aid_pool": candidates("first_aid_cabinet", frozen, map_id),
		"seal_pool": candidates("salvage_seal_cabinet", frozen, map_id),
	}


static func process_rules(context: RunContext, stage: int = 1) -> Dictionary:
	var result := {"pools": {}, "definitions": {}, "material_tags": MATERIAL_TAGS.duplicate(true)}
	var frozen := _frozen(context)
	var map_id := _map_id(context)
	# Carried assistance/delivery materials need definitions even when this room
	# cannot generate them. Presence here grants no acquisition eligibility.
	for id in MONSTER_MATERIALS + OTHER_MATERIALS:
		result.definitions[id] = definition(id)
	for pair in [["mechanism", "mechanism_success"], ["electric", "mechanism_success"], ["recycle", "recycle"], ["altar", "altar"], ["normal_search", "search"]]:
		var pool := candidates(pair[1], frozen, map_id, stage)
		result.pools[pair[0]] = {"channel": pair[1], "items": pool}
		for entry in pool:
			result.definitions[entry.item_id] = definition(entry.item_id)
	return result


static func _frozen(context: RunContext) -> Dictionary:
	if context == null:
		return {}
	var profile: Dictionary = context.run_start_config.get("profile_fields", {})
	var frozen: Variant = profile.get("content_eligibility", {})
	return frozen.duplicate(true) if frozen is Dictionary else {}


static func _map_id(context: RunContext) -> String:
	return str(context.run_start_config.get("map_config_id", "")) if context != null else ""


static func _groups(channel: String, difficulty: int, stage: int) -> Array:
	if channel in ["search", "chest"]:
		var groups: Array = []
		for share: float in COLLECTIBLE_SHARES[difficulty]:
			groups.append([[], 0.70 * share])
		for item in Items.collectibles():
			groups[int(item.collectible_level) - 1][0].append(str(item.item_id))
		var consumables := _supplies(channel, "consumable")
		var equipment := _supplies(channel, "equipment")
		if channel == "search":
			return groups + [[consumables, 0.25], [equipment, 0.05]]
		consumables.append("sp_transit_lead_seal") # Z1 included S18 in this existing group.
		return groups + [[consumables, 0.20], [equipment, 0.10]]
	var shares: Array = Z1.HIGH_TIER_SHARES[difficulty]
	match channel:
		"monster":
			return [[MONSTER_MATERIALS, 0.65], [_supplies(channel, "consumable"), 0.25], [_supplies(channel, "equipment"), 0.10]]
		"mechanism_success":
			return [[_tier(4), 0.70 * (1.0 - shares[2])], [_tier(5), 0.70 * shares[2]], [["sp_depressurized_valve_core"], 0.20], [_supplies(channel, "equipment"), 0.10]]
		"compression":
			return [[_tier(2), 1.0]]
		"recycle":
			return [[["sp_inspection_calibration_plate", "sp_transit_lead_seal"], 1.0]]
		"shop":
			return [[_supplies(channel, "consumable") + _supplies(channel, "equipment"), 1.0]]
		"first_aid_cabinet": return [[["con_med_patch"], 1.0]]
		"salvage_seal_cabinet": return [[["con_salvage_seal"], 1.0]]
		"altar":
			match stage:
				1: return [[["sp_altar_residue"], 0.70], [["eq_recovery_bag"], 0.30]]
				2: return [[_tier(3), 1.0 - shares[3]], [_tier(4), shares[3]]]
				3: return [[_tier(4), 1.0 - shares[4]], [_tier(5), shares[4]]]
				4: return [[_tier(5), 1.0 - shares[5]], [_tier(6), shares[5]]]
				5: return [[_tier(6), 0.85], [["sp_altar_residue"], 0.10], [["eq_recovery_bag"], 0.05]]
	return []


static func _tier(tier: int) -> Array:
	var result: Array = []
	for item in Items.collectibles():
		if int(item.collectible_level) == tier:
			result.append(str(item.item_id))
	return result


static func _supplies(channel: String, kind: String) -> Array:
	var result: Array = []
	for item in Items.supplies():
		if str(item.item_type) == kind and item.channels.has(channel) and str(item.required_research_id).is_empty():
			result.append(str(item.item_id))
	return result


static func _weight(item_id: String, channel: String) -> float:
	if channel == "shop":
		return 1.0 # Existing Z1 shop selection is equal-weight, not physical weight.
	# Reuse weights by stable ID, never infer current tier from the number.
	if item_id.begins_with("col_") and item_id.trim_prefix("col_").is_valid_int():
		var index := int(item_id.trim_prefix("col_")) - 1
		if index >= 0 and index < Z1.COLLECTIBLE_WEIGHTS.size():
			return float(Z1.COLLECTIBLE_WEIGHTS[index])
	return float(Z1.ITEM_WEIGHTS.get(item_id, 100))
