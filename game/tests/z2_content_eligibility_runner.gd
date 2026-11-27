extends SceneTree

const CATALOG_PATH := "res://scripts/core/content/z2_item_catalog.gd"
const ELIGIBILITY_PATH := "res://scripts/core/content/z2_content_eligibility.gd"
const ACQUISITION_CHANNELS := [
	"search", "chest", "altar", "monster", "shop", "camp_shop",
	"mechanism_success", "first_aid_cabinet", "salvage_seal_cabinet", "starter_claim",
	"compression", "recycle", "event", "research", "extra_drop",
]
const COLLECTIBLE_CHANNELS := [
	["search", "chest"], ["search", "chest", "compression"], ["search", "chest", "altar"],
	["search", "chest", "altar", "mechanism_success"], ["search", "chest", "altar", "mechanism_success"], ["search", "chest", "altar"],
]
const COLLECTIBLE_BATCHES := {
	2: ["col_04", "col_missing_shift_roster", "col_06", "col_17", "col_16", "col_missing_tooth_counter", "col_clockwork_copper_dial", "col_10", "col_folded_price_board"],
	12: ["col_self_stitching_envelope", "col_double_shadow_rivet", "col_delayed_bell", "col_self_winding_spool", "col_20", "col_windless_vane", "col_reverse_counter"],
	28: ["col_unspoken_seal_roll", "col_backward_ledger", "col_24", "col_word_swallowing_meter", "col_negative_floor_plate", "col_23", "col_borrowed_shadow_doll", "col_13", "col_bottomless_ballast_canister"],
}
const MAP_10_STANDARD := ["classic_10x10_standard", "classic_10x10_hard"]
const MAP_10_HARD := ["classic_10x10_hard"]
const MAP_13 := ["classic_13x13_normal", "classic_13x13_hard", "classic_13x13_hell"]
const MAP_13_HARD := ["classic_13x13_hard", "classic_13x13_hell"]
const MAP_HELL := ["classic_13x13_hell"]
const LEVEL_SUPPLIES := [
	["con_ration", 0, ["search"], []],
	["con_tape_roll", 0, ["search"], []],
	["con_range_powder", 0, ["search"], []],
	["con_med_patch", 0, ["first_aid_cabinet"], []],
	["eq_old_vest", 4, ["camp_shop"], []],
	["eq_edge_opener", 4, ["camp_shop"], []],
	["eq_recovery_bag", 4, ["camp_shop"], []],
	["con_calm_candy", 7, ["shop"], []],
	["eq_goggles", 5, ["chest"], MAP_10_STANDARD],
	["con_scan_pin", 5, ["chest"], MAP_10_STANDARD],
	["eq_debris_brow_guard", 10, ["chest"], MAP_10_HARD],
	["eq_pressure_relief_wrench", 10, ["chest"], MAP_10_HARD],
	["eq_buffer_buckle", 10, ["chest"], MAP_10_HARD],
	["eq_seam_finder_pendant", 10, ["search"], MAP_10_HARD],
	["eq_insulated_sleeve", 15, ["search"], MAP_13],
	["con_ledger_seal_paper", 15, ["search"], MAP_13],
	["con_hemostatic_clasp", 15, ["chest"], MAP_13],
	["con_cooling_patch", 15, ["chest"], MAP_13],
	["con_stabilizer", 15, ["monster"], MAP_13],
	["eq_etched_sleeve", 20, ["chest"], MAP_13_HARD],
	["eq_folding_shovel", 20, ["chest"], MAP_13_HARD],
	["eq_strapped_backplate", 20, ["monster"], MAP_13_HARD],
	["eq_signal_pin", 20, ["mechanism_success"], MAP_13_HARD],
	["con_waiver_medicine", 20, ["chest"], MAP_13_HARD],
	["con_salvage_seal", 21, ["salvage_seal_cabinet"], []],
	["eq_old_work_badge", 25, ["mechanism_success"], MAP_HELL],
	["con_countdown_pill", 25, ["chest"], MAP_HELL],
]
const RESEARCH_CASES := [
	["research_hard_shell_patch", "con_hard_shell_patch", "mon_old_gear_set", 40],
	["research_red_battery", "con_red_battery", "mon_overheated_core", 60],
	["research_black_box_bell", "eq_black_box_bell", "mon_loader_black_box", 90],
]

var checks := 0
var failures: Array[String] = []
var catalog: Script
var eligibility: Script


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(FileAccess.file_exists(CATALOG_PATH), "72-item catalog exists")
	_check(FileAccess.file_exists(ELIGIBILITY_PATH), "shared eligibility core exists")
	if failures.is_empty():
		catalog = load(CATALOG_PATH)
		eligibility = load(ELIGIBILITY_PATH)
		_check(catalog != null and catalog.can_instantiate(), "catalog compiles")
		_check(eligibility != null and eligibility.can_instantiate(), "eligibility compiles")
		if failures.is_empty():
			_catalog_contract()
			_initial_and_level_boundaries()
			_supply_channels()
			_map_restrictions()
			_research_and_materials()
			_frozen_snapshot_and_pool()
			if OS.get_cmdline_user_args().has("--export-contract"):
				var output := FileAccess.open("user://z2_content_contract.json", FileAccess.WRITE)
				_check(output != null, "contract export opens in isolated user directory")
				if output != null:
					output.store_string(JSON.stringify({"items": catalog.all_items(), "research": eligibility.research_definitions()}, "\t"))
					output.close()
	print("Z2_CONTENT_ELIGIBILITY checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures:
		print("Z2_CONTENT_ELIGIBILITY_CASE_FAIL " + failure)
	print("Z2_CONTENT_ELIGIBILITY=%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _catalog_contract() -> void:
	var items: Array = catalog.all_items()
	_check(items.size() == 72, "catalog has exactly 72 definitions")
	_check(catalog.collectibles().size() == 42, "42 collectibles exclude materials")
	_check(catalog.supplies().size() == 30, "30 supplies")
	var ids := {}
	var tiers := [0, 0, 0, 0, 0, 0]
	var kinds := {"collectible": 0, "equipment": 0, "consumable": 0}
	var runtime_icons := 0
	var candidates := 0
	var required := ["item_id", "display_name", "item_type", "main_type", "rarity", "collectible_level", "tier", "weight", "base_value", "purchase_price", "can_equip", "can_consume", "can_sell", "can_store", "is_unique", "source_id", "source_sheet", "source_row", "source_hash", "icon_path", "short_description", "effect_kind", "effect_amount", "equipment_slot", "content_version"]
	for item: Dictionary in items:
		var id := str(item.get("item_id", ""))
		_check(not ids.has(id) and not id.is_empty(), "unique stable ID " + id)
		ids[id] = true
		for field in required:
			_check(item.has(field), "%s includes %s" % [id, field])
		_check(item.get("content_version") == "z2-system-20261116", "frozen definition version " + id)
		_check(int(item.get("weight", 0)) > 0, "positive source weight " + id)
		var kind := str(item.get("item_type", ""))
		_check(kinds.has(kind), "recognized item kind " + id)
		if not kinds.has(kind):
			continue
		kinds[kind] += 1
		var tier := int(item.get("tier", 0))
		_check(tier >= 1 and tier <= 6, "legal explicit tier " + id)
		_check(str(item.get("rarity")) == "tier_%d" % tier, "rarity agrees with explicit tier " + id)
		if kind == "collectible" and tier >= 1 and tier <= 6:
			tiers[tier - 1] += 1
			_check(item.collectible_level == tier and item.base_value > 0 and item.can_sell, "collectible economy " + id)
		else:
			_check(item.purchase_price > 0 and item.base_value == -1 and not item.can_sell, "purchase price is not unapproved resale value " + id)
			_check(not str(item.effect_kind).is_empty() and item.get("effect_params") is Dictionary, "typed effect contract " + id)
		var path := str(item.get("icon_path", ""))
		if not path.is_empty():
			runtime_icons += 1
			_check(path.begins_with("res://") and FileAccess.file_exists(path), "real runtime icon " + id)
			if FileAccess.file_exists(path):
				_check(load(path) is Texture2D, "runtime icon decodes as texture " + id)
		else:
			candidates += 1
			_check(item.get("art_status") == "candidate_unimported" and item.get("candidate_id") == id, "unimported icon is explicit " + id)
	_check(tiers == [7, 10, 6, 6, 6, 7], "exact S5 tier counts, independent of old numeric IDs")
	_check(kinds == {"collectible": 42, "equipment": 15, "consumable": 15}, "exact content types")
	_check(runtime_icons == 72 and candidates == 0, "all72 icons passed audited source import and bind at runtime")
	for id in ["eq_folding_shovel", "eq_old_work_badge", "eq_black_box_bell", "con_red_battery", "con_waiver_medicine", "con_countdown_pill"]:
		var supplied: Dictionary = catalog.definition(id)
		var visual: Dictionary = Art24ItemVisualCatalog.resolve(supplied)
		_check(not visual.get("fallback_used", true), "new supplied icon never falls back " + id)
		_check(Art24ItemVisualCatalog.texture_path(supplied) == str(supplied.icon_path) and not str(supplied.icon_path).is_empty(), "inventory/deploy resolve same audited supplied icon " + id)
		_check(FileAccess.get_sha256(str(supplied.icon_path)).to_upper() == str(supplied.get("candidate_sha256", "")).to_upper(), "runtime icon equals audited artist candidate " + id)
	_check(catalog.definition("not_an_item").is_empty(), "unknown ID has no fallback definition")
	_check(catalog.definition("mon_overheated_core").is_empty(), "material not counted as a collectible")
	_check(catalog.definition("col_20").collectible_level == 3, "same-name collectible retains explicit tier 3")
	for row in [["con_ration", 8, 4, "heal", 10], ["con_tape_roll", 10, 4, "physical_reduction_once", 10], ["eq_folding_shovel", 260, 24, "combat_power", 30], ["con_red_battery", 35, 5, "next_supply_base_bonus_percent", 100], ["con_ledger_seal_paper", 20, 5, "black_to_safe_gold_percent", 80]]:
		var item: Dictionary = catalog.definition(row[0])
		_check(item.get("purchase_price") == row[1] and item.get("weight") == row[2] and item.get("effect_kind") == row[3] and item.get("effect_amount") == row[4], "source numerical contract " + row[0])
	_check(catalog.definition("eq_folding_shovel").effect_params.get("ordinary_clear_pressure") == 4, "shovel pressure cost")
	_check(catalog.definition("eq_seam_finder_pendant").effect_params.get("value_basis") == "new_output_base_value", "pendant uses new output base value")
	_check(catalog.definition("eq_seam_finder_pendant").effect_params.get("reward_cap") == -1, "pendant has no reward amount cap")
	_check(catalog.definition("con_red_battery").effect_params.get("pressure_cost") == 5, "red battery pressure cost")
	_check(catalog.definition("con_ledger_seal_paper").effect_params.get("max_black_currency") == 100, "ledger exchange cap")
	for row in [["eq_debris_brow_guard", 10], ["eq_pressure_relief_wrench", 10], ["eq_seam_finder_pendant", 10], ["eq_etched_sleeve", 10], ["eq_insulated_sleeve", 5], ["eq_buffer_buckle", 3], ["eq_signal_pin", 2], ["eq_strapped_backplate", 5], ["eq_old_work_badge", 3], ["eq_black_box_bell", 1]]:
		_check(catalog.definition(row[0]).effect_params.get("max_uses") == row[1], "instance use limit " + row[0])
	var edited: Dictionary = catalog.definition("con_ration")
	edited["weight"] = 999
	edited.effect_params["blocked_when_full"] = false
	_check(catalog.definition("con_ration").weight == 4 and catalog.definition("con_ration").effect_params.blocked_when_full, "callers cannot mutate static definitions")


func _initial_and_level_boundaries() -> void:
	var initial := [["col_05", "col_01", "col_02", "col_03"], ["col_09", "col_15", "col_22", "col_08"], ["col_14", "col_07", "col_18"], ["col_12", "col_11"], ["col_19", "col_reverse_growing_comb"], ["col_absent_person_frame", "col_21"]]
	var frozen: Dictionary = eligibility.freeze_profile({"profile_level": 0})
	for channel in ["search", "chest"]:
		for tier_index in range(6):
			var found: Array = []
			for item: Dictionary in catalog.collectibles():
				if int(item.collectible_level) == tier_index + 1 and eligibility.is_eligible(item.item_id, channel, frozen):
					found.append(item.item_id)
			found.sort()
			var expected: Array = initial[tier_index].duplicate()
			expected.sort()
			_check(found == expected, "Lv0 exact %s pool for tier %d" % [channel, tier_index + 1])
	for level in COLLECTIBLE_BATCHES:
		var below: Dictionary = eligibility.freeze_profile({"profile_level": level - 1})
		var at: Dictionary = eligibility.freeze_profile({"profile_level": level})
		for id in COLLECTIBLE_BATCHES[level]:
			for channel in ["qualification", "search", "chest"]:
				_check(not eligibility.is_eligible(id, channel, below), "before batch " + id + channel)
				_check(eligibility.is_eligible(id, channel, at), "at batch " + id + channel)
	for level in [0, 1, 2, 3, 11, 12, 27, 28, 50]:
		var profile: Dictionary = eligibility.freeze_profile({"profile_level": level})
		for item: Dictionary in catalog.collectibles():
			var unlocked: bool = eligibility.is_eligible(item.item_id, "qualification", profile)
			var expected_channels: Array = COLLECTIBLE_CHANNELS[int(item.collectible_level) - 1]
			var actual_channels: Array = []
			for channel in ACQUISITION_CHANNELS:
				var allowed: bool = eligibility.is_eligible(item.item_id, channel, profile)
				_check(allowed == (unlocked and expected_channels.has(channel)), "collectible channel Lv%d %s %s" % [level, item.item_id, channel])
				if allowed:
					actual_channels.append(channel)
			var expected_set: Array = expected_channels.duplicate() if unlocked else []
			actual_channels.sort()
			expected_set.sort()
			_check(actual_channels == expected_set, "exact collectible channel set Lv%d %s" % [level, item.item_id])


func _supply_channels() -> void:
	var maps := ["", "unknown_13x13_hell", "tutorial_5x5", "classic_7x7_simple", "classic_7x7_normal", "classic_10x10_easy", "classic_10x10_standard", "classic_10x10_hard"] + MAP_13
	var high: Dictionary = eligibility.freeze_profile({"profile_level": 50})
	for row in LEVEL_SUPPLIES:
		var below: Dictionary = eligibility.freeze_profile({"profile_level": row[1] - 1})
		var at: Dictionary = eligibility.freeze_profile({"profile_level": row[1]})
		for channel in ACQUISITION_CHANNELS:
			for map_id in maps:
				if (row[0] == "con_scan_pin" and channel == "shop") or (row[0] in ["con_ration", "con_tape_roll"] and channel == "starter_claim"):
					continue
				var allowed: bool = row[2].has(channel) and (row[3].is_empty() or row[3].has(map_id))
				_check(row[1] == 0 or not eligibility.is_eligible(row[0], channel, below, map_id), "below supply level %s %s %s" % [row[0], channel, map_id])
				_check(eligibility.is_eligible(row[0], channel, at, map_id) == allowed, "first supply source %s %s %s" % [row[0], channel, map_id])
				_check(eligibility.is_eligible(row[0], channel, high, map_id) == allowed, "late supply source %s %s %s" % [row[0], channel, map_id])
	_check(not eligibility.is_eligible("unknown", "search", high), "unknown item fails closed")
	_check(not eligibility.is_eligible("con_ration", "typo", high), "unknown channel fails closed")


func _map_restrictions() -> void:
	var before: Dictionary = eligibility.freeze_profile({"profile_level": 6})
	var at: Dictionary = eligibility.freeze_profile({"profile_level": 7})
	for map_id in ["classic_7x7_simple", "classic_10x10_standard", "classic_13x13_hell"]:
		_check(not eligibility.is_eligible("con_scan_pin", "shop", before, map_id), "scan pin shop locked before event " + map_id)
		_check(eligibility.is_eligible("con_scan_pin", "shop", at, map_id), "scan pin shop ignores chest map whitelist " + map_id)
	var tutorial: Dictionary = eligibility.freeze_profile({"profile_level": 0})
	var graduated: Dictionary = eligibility.freeze_profile({"profile_level": 1})
	for id in ["con_ration", "con_tape_roll"]:
		_check(not eligibility.is_eligible(id, "starter_claim", tutorial), "claim remains a graduation benefit " + id)
		_check(eligibility.is_eligible(id, "starter_claim", graduated), "graduate can claim " + id)
	for id in ["sp_transit_lead_seal", "sp_inspection_calibration_plate"]:
		_check(eligibility.is_eligible(id, "recycle", tutorial, "tutorial_5x5"), "recycle teaching material " + id)
		_check(not eligibility.is_eligible(id, "chest", tutorial, "tutorial_5x5"), "recycle teaching availability is channel-specific " + id)


func _research_and_materials() -> void:
	var definitions: Array = eligibility.research_definitions()
	_check(definitions.size() == 3, "exactly three approved researches")
	for row in RESEARCH_CASES:
		var matches: Array = definitions.filter(func(value: Dictionary) -> bool: return value.get("id") == row[0])
		_check(matches.size() == 1, "stable research ID " + row[0])
		if matches.size() != 1:
			continue
		var definition: Dictionary = matches[0]
		_check(definition.get("unlock_item_id") == row[1] and definition.get("material_item_id") == row[2] and definition.get("material_count") == 1 and definition.get("gold_cost") == row[3], "exact research payment and product " + row[0])
		_check(definition.get("channels_status") == "confirmed" and definition.get("channels") == ["research_craft"] and definition.get("repeatable", false), "user-approved repeatable research-only production " + row[0])
		var high: Dictionary = eligibility.freeze_profile({"profile_level": 50})
		var low_completed: Dictionary = eligibility.freeze_profile({"profile_level": 0, "research_completed_ids": [row[0]]})
		var high_completed: Dictionary = eligibility.freeze_profile({"profile_level": 50, "research_completed_ids": [row[0]]})
		_check(not eligibility.is_eligible(row[1], "qualification", high), "level cannot bypass research " + row[1])
		_check(eligibility.is_eligible(row[1], "qualification", low_completed), "research replaces level requirement " + row[1])
		for channel in ACQUISITION_CHANNELS:
			_check(not eligibility.is_eligible(row[1], channel, high, "classic_13x13_hell"), "unresearched all entrances denied " + row[1] + " " + channel)
			_check(not eligibility.is_eligible(row[1], channel, low_completed, "classic_13x13_hell"), "research product stays excluded from normal acquisition " + row[1] + " " + channel)
			_check(not eligibility.is_eligible(row[1], channel, high_completed, "classic_13x13_hell"), "maximum level plus completed research cannot widen channels " + row[1] + " " + channel)
		_check(eligibility.is_eligible(row[1], "research_craft", eligibility.freeze_profile({"profile_level": 1})), "first research craft is possible " + row[1])
		_check(eligibility.is_eligible(row[1], "research_craft", high_completed), "completed research permits repeated craft only " + row[1])
		_check(not eligibility.is_eligible(row[1], "research_craft", low_completed), "Lv0 does not grant research output " + row[1])
	var frozen: Dictionary = eligibility.freeze_profile({"profile_level": 1})
	_check(eligibility.is_eligible("mon_old_gear_set", "monster", frozen, "classic_7x7_simple"), "research material old gear available from Lv1 combat")
	_check(not eligibility.is_eligible("mon_old_gear_set", "monster", eligibility.freeze_profile({"profile_level": 0}), "classic_7x7_simple"), "material source starts at Lv1")
	for map_id in ["classic_7x7_normal", "classic_10x10_hard", "classic_13x13_normal", "classic_13x13_hard", "classic_13x13_hell", "", "pretend_13x13_hell"]:
		_check(eligibility.is_eligible("mon_overheated_core", "monster", frozen, map_id) == ["classic_13x13_normal", "classic_13x13_hard", "classic_13x13_hell"].has(map_id), "overheated material map restriction " + map_id)
		_check(eligibility.is_eligible("mon_loader_black_box", "monster", frozen, map_id) == (map_id == "classic_13x13_hell"), "black box material hell only " + map_id)
	_check(not eligibility.is_eligible("col_20", "monster", eligibility.freeze_profile({"profile_level": 50}), "classic_13x13_hell"), "same-name collectible cannot substitute for combat material")
	_check(not eligibility.is_eligible("mon_overheated_core", "chest", frozen, "classic_13x13_hell"), "material does not leak into collectible channel")


func _frozen_snapshot_and_pool() -> void:
	var meta := {"profile_level": 1, "research_completed_ids": []}
	var frozen: Dictionary = eligibility.freeze_profile(meta)
	meta.profile_level = 50
	meta.research_completed_ids.append("research_red_battery")
	_check(frozen.profile_level == 1 and frozen.research_completed_ids.is_empty(), "departure snapshot detached from live profile and nested IDs")
	_check(not eligibility.is_eligible("col_04", "search", frozen), "level gains cannot affect frozen pool")
	_check(not eligibility.is_eligible("con_red_battery", "qualification", frozen), "research gains cannot affect frozen pool")
	var next_run: Dictionary = eligibility.freeze_profile(meta)
	_check(eligibility.is_eligible("col_04", "search", next_run) and eligibility.is_eligible("con_red_battery", "qualification", next_run), "next departure sees changed profile")
	meta.research_completed_ids.clear()
	_check(eligibility.is_eligible("con_red_battery", "qualification", next_run), "live research removal also cannot change snapshot")
	var restored: Dictionary = JSON.parse_string(JSON.stringify(next_run))
	_check(eligibility.is_eligible("con_red_battery", "qualification", restored), "frozen eligibility survives checkpoint JSON roundtrip")
	var pool: Array = [
		{"item_id": "col_04", "weight": 999, "probability": 0.9},
		{"item_id": "col_05", "weight": 7, "probability": 0.03, "nested": {"source": "unchanged"}},
		"col_01", ["col_02", 19], {"definition_id": "con_ration", "pool_weight": 13},
		{"item_id": "unknown", "weight": 500}, {"weight": 888}, 12,
	]
	var before: Array = pool.duplicate(true)
	var filtered: Array = eligibility.filter_pool(pool, "search", frozen)
	_check(filtered == [pool[1], pool[2], pool[3], pool[4]], "filter preserves heterogeneous entries, order and original weights")
	_check(pool == before, "filter does not mutate input or normalize probabilities")
	_check(eligibility.filter_pool(["col_04", "unknown"], "search", frozen).is_empty(), "mandatory pool empty returns empty with no fallback")
	_check(eligibility.filter_pool([], "chest", frozen).is_empty(), "empty normal chest pool reports absence to caller")
	# This core has no transaction dependency: parent must reject payment before drawing.
	# Do not fake that integration with a local gold counter.
	_check(eligibility.filter_pool([{"item_id": "col_05", "weight": 2}, {"item_id": "col_05", "weight": 5}], "search", frozen).size() == 2, "duplicate pool entries are not coalesced")
	var invalid: Dictionary = eligibility.freeze_profile({"profile_level": -8, "research_completed_ids": {"research_red_battery": true}})
	_check(invalid.profile_level == 0 and invalid.research_completed_ids.is_empty(), "malformed profile fails closed")


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
