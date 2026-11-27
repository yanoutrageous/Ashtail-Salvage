extends SceneTree

const CATALOG_PATH := "res://scripts/core/progression/z2_talent_catalog.gd"
# Independent expectations from S1 / 05 天赋树与节点, rows 11–49 (SHA db630e72...).
const EXPECTED := [
	["插旗标记", 100, []],
	["背包容量Ⅰ", 10, [1]],
	["初始战力Ⅰ", 10, [1]],
	["最大生命Ⅰ", 10, [1]],
	["首次增压豁免", 30, [2, 3]],
	["装备负重上限", 10, [5]],
	["普怪成长Ⅰ", 10, [5]],
	["失败抢救容量Ⅰ", 10, [4]],
	["物理减伤Ⅰ", 10, [8]],
	["首次致死保护", 30, [7, 9]],
	["移动速度Ⅰ", 10, [6]],
	["搜索速度Ⅰ", 10, [11]],
	["攻击速度Ⅰ", 10, [10]],
	["撤离收入Ⅰ", 10, [10]],
	["解锁第一批开局效果", 90, [12, 13, 14]],
	["搜索速度Ⅱ", 30, [15]],
	["攻击速度Ⅱ", 30, [15]],
	["撤离收入Ⅱ", 30, [15]],
	["消耗品保留", 50, [16, 17]],
	["物理减伤Ⅱ", 30, [18]],
	["移动速度Ⅱ", 30, [19]],
	["普怪成长Ⅱ", 30, [19]],
	["失败抢救容量Ⅱ", 30, [20]],
	["背包容量Ⅱ", 30, [21]],
	["暴击启用", 50, [22, 23]],
	["背包容量Ⅲ", 30, [24]],
	["初始战力Ⅱ", 30, [25]],
	["最大生命Ⅱ", 30, [25]],
	["解锁第二批开局效果", 90, [26, 27, 28]],
	["失败消耗品转换数量", 50, [29]],
	["暴击率提升", 50, [29]],
	["致死保护强化", 50, [29]],
	["消耗品减重", 50, [30]],
	["暴击伤害提升", 50, [31]],
	["低血恢复", 50, [32]],
	["单次增压上限", 70, [33]],
	["暴击溢出", 70, [34]],
	["专属回收", 70, [35]],
	["解锁第三批开局效果", 90, [36, 37, 38]],
]

var catalog: Script
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# A missing file/API is an assertion RED, not a preload/parser failure.
	if ResourceLoader.exists(CATALOG_PATH):
		catalog = load(CATALOG_PATH) as Script
	_expect(catalog != null, "missing_catalog: Z2TalentCatalog has not been implemented")
	if catalog == null:
		_finish()
		return
	for method in ["definitions", "definition", "projection", "active_effects", "summary", "unlock_evaluation", "sync_progress"]:
		_expect(catalog.has_method(method), "missing_api: %s" % method)
	if not failures.is_empty():
		_finish()
		return
	_test_source_graph_and_purchase_costs()
	_test_teaching_and_level_gates()
	_test_explicit_ledger_and_read_only_queries()
	_test_effect_payloads_and_legacy_isolation()
	_finish()


func _test_source_graph_and_purchase_costs() -> void:
	var nodes: Array = catalog.call("definitions")
	_expect(nodes.size() == 39, "source requires exactly 39 nodes")
	if nodes.size() != 39:
		return
	var meta := _meta(0, 1480, 0, [], false, true)
	var branches := {}
	for index in range(EXPECTED.size()):
		var number := index + 1
		var talent_id := _id(number)
		var expected: Array = EXPECTED[index]
		var node: Dictionary = catalog.call("definition", talent_id)
		var prerequisites: Array[String] = []
		for prerequisite in expected[2]:
			prerequisites.append(_id(int(prerequisite)))
		_expect(str(nodes[index].get("talent_id", "")) == talent_id, "stable row-based ID/order: %s" % talent_id)
		_expect(node.get("id") == talent_id and node.get("catalog_version") == 2, "public identity/version: %s" % talent_id)
		_expect(node.get("display_name") == expected[0], "source name: %s" % talent_id)
		_expect(node.get("cost") == expected[1], "source cost: %s" % talent_id)
		_expect(node.get("prerequisite_ids") == prerequisites, "source AND edges: %s" % talent_id)
		branches[node.get("branch_id", "")] = true
		if number > 1:
			meta.profile_level = 3
			meta.tutorial_completed = true
			meta.tutorial_purchase_available = false
			for prerequisite in prerequisites:
				var missing := meta.duplicate(true)
				missing.talent_flags.erase(prerequisite)
				var blocked: Dictionary = catalog.call("unlock_evaluation", missing, talent_id)
				_expect(not bool(blocked.get("ok", true)) and str(blocked.get("status")) == "prerequisite_missing", "every AND parent is mandatory: %s / %s" % [talent_id, prerequisite])
				_expect(blocked.get("missing_prerequisite_ids", []).has(prerequisite) and not str(blocked.get("reason", "")).is_empty(), "missing-parent explanation: %s" % talent_id)
		var poor := meta.duplicate(true)
		poor.talent_earned = int(poor.talent_spent) + int(expected[1]) - 1
		var insufficient: Dictionary = catalog.call("unlock_evaluation", poor, talent_id)
		_expect(not bool(insufficient.get("ok", true)) and str(insufficient.get("status")) == "insufficient_talent_points", "one point short must block: %s" % talent_id)
		var before := meta.duplicate(true)
		var purchase: Dictionary = catalog.call("unlock_evaluation", meta, talent_id)
		_expect(bool(purchase.get("ok", false)) and not bool(purchase.get("duplicate", false)) and int(purchase.get("cost", -1)) == int(expected[1]), "valid purchase quote: %s" % talent_id)
		_expect(meta == before, "evaluation must not purchase or debit: %s" % talent_id)
		# The caller owns the transaction. The catalog only quotes and projects it.
		meta.talent_flags.append(talent_id)
		meta.talent_spent = int(meta.talent_spent) + int(expected[1])
		catalog.call("sync_progress", meta)
		var duplicate_before := meta.duplicate(true)
		var duplicate: Dictionary = catalog.call("unlock_evaluation", meta, talent_id)
		_expect(bool(duplicate.get("ok", false)) and bool(duplicate.get("duplicate", false)) and str(duplicate.get("status")) == "talent_already_unlocked", "repeat purchase is idempotent: %s" % talent_id)
		_expect(meta == duplicate_before, "duplicate must not debit: %s" % talent_id)
		if number in [15, 29, 39]:
			var cumulative := {15: 360, 29: 880, 39: 1480}
			_expect(meta.talent_spent == cumulative[number], "source cumulative cost at %d" % number)
	var summary: Dictionary = catalog.call("summary", meta)
	_expect(meta.talent_points == 0 and meta.talent_spent == 1480, "formal tree 1380 plus teaching flag 100")
	_expect(summary.get("known_unlocked_count") == 39 and summary.get("available_count") == 0, "completed-tree summary")
	_expect(summary.get("node_count") == 39 and summary.get("branch_count") == branches.size(), "summary counts real catalog groups")
	_expect((catalog.call("definition", "unknown") as Dictionary).is_empty(), "unknown definition is empty")
	var unknown: Dictionary = catalog.call("unlock_evaluation", meta, "unknown")
	_expect(not bool(unknown.get("ok", true)) and str(unknown.get("status")) == "unknown_talent", "unknown purchase is refused")
	nodes[0]["display_name"] = "modified by caller"
	nodes[1]["prerequisite_ids"].clear()
	_expect((catalog.call("definition", _id(1)) as Dictionary).get("display_name") == "插旗标记", "definitions are detached copies")
	_expect((catalog.call("definition", _id(2)) as Dictionary).get("prerequisite_ids") == [_id(1)], "prerequisites are detached copies")


func _test_teaching_and_level_gates() -> void:
	var teaching := _meta(0, 100, 0, [], false, true)
	var quote: Dictionary = catalog.call("unlock_evaluation", teaching, _id(1))
	_expect(bool(quote.get("ok", false)) and quote.get("cost") == 100, "Lv0 tutorial can buy flag marking for 100")
	for overrides in [{"tutorial_purchase_available": false}, {"profile_level": 1}, {"profile_level": 3}, {"tutorial_completed": true}]:
		var locked := teaching.duplicate(true)
		locked.merge(overrides, true)
		_expect_blocked(locked, _id(1), "tutorial_purchase_required")
	var prior_ids: Array[String] = [_id(1)]
	for number in range(2, 40):
		_expect_blocked(_meta(3, 1860, 100, prior_ids, false, false), _id(number), "tutorial_required")
		for level in [1, 2]:
			var earned: Dictionary = catalog.call("unlock_evaluation", _meta(level, 1860, 100, prior_ids, true, false), _id(number))
			_expect(earned.get("ok", false), "post-teaching purchase depends on points and predecessors at Lv%d" % level)
		prior_ids.append(_id(number))
	var ready := _meta(3, 120, 100, [_id(1)], true, false)
	var projected: Array = catalog.call("projection", ready)
	_expect(projected[1].get("available") == true and projected[1].get("state") == &"available", "Lv3 normal node opens at exact cost")
	_expect(projected[0].get("unlocked") == true and projected[0].get("available") == false, "owned teaching node remains owned after tutorial")
	var summary: Dictionary = catalog.call("summary", ready)
	_expect(summary.get("available_count") == 3 and summary.get("known_unlocked_count") == 1, "three first normal choices available after teaching")
	var teaching_summary: Dictionary = catalog.call("summary", teaching)
	_expect(teaching_summary.get("profile_level") == 0 and teaching_summary.get("available_count") == 1, "summary preserves Lv0 tutorial")


func _test_explicit_ledger_and_read_only_queries() -> void:
	for level in [0, 1, 2, 3, 4, 6, 9, 30, 50]:
		var empty := _meta(level, 0, 0, [], true, false)
		empty.talent_points = 999
		empty.talent_budget_granted = 999
		catalog.call("sync_progress", empty)
		_expect(empty.talent_points == 0 and empty.talent_budget_granted == 0, "no free points or legacy top-up at level %d" % level)
	var historical := _meta(50, 500, 7, [_id(1)], true, false)
	historical.talent_points = 999
	catalog.call("sync_progress", historical)
	_expect(historical.talent_spent == 7 and historical.talent_earned == 500 and historical.talent_points == 493, "historical spent is not reconstructed from current node prices")
	_expect(historical.talent_catalog_version == 2, "sync stamps catalog version 2")
	var before := historical.duplicate(true)
	catalog.call("sync_progress", historical)
	_expect(historical == before, "sync is idempotent")
	for method in ["projection", "summary", "active_effects"]:
		catalog.call(method, historical)
		_expect(historical == before, "%s does not mutate stored data" % method)
	var summary: Dictionary = catalog.call("summary", historical)
	_expect(summary.get("budget_total") == 500 and summary.get("budget_granted") == 500 and summary.get("points_available") == 493, "summary uses earned/spent ledger")
	var invalid := _meta(3, 10, 11, [], true, false)
	var invalid_before := invalid.duplicate(true)
	catalog.call("sync_progress", invalid)
	_expect(invalid == invalid_before, "invalid ledger is not silently repaired")
	_expect_blocked(invalid, _id(2), "invalid_talent_ledger")
	var missing_ledger := _meta(50, 0, 0, [], true, false)
	missing_ledger.erase("talent_earned")
	_expect_blocked(missing_ledger, _id(2), "invalid_talent_ledger")


func _test_effect_payloads_and_legacy_isolation() -> void:
	var all_ids: Array[String] = []
	for number in range(1, 40):
		all_ids.append(_id(number))
	var meta := _meta(50, 1860, 1860, all_ids, true, false)
	var effects: Array = catalog.call("active_effects", meta)
	_expect(effects.size() == 39, "each purchased node yields one descriptor, including eligibility only")
	var by_id := {}
	for effect in effects:
		by_id[str(effect.get("talent_id", ""))] = effect
	var expected_effects := {
		1: ["flag_marking", 1], 2: ["backpack_capacity", 5], 3: ["initial_power", 2], 4: ["max_hp", 10],
		5: ["first_pressure_waiver", 1], 6: ["equipment_capacity", 3], 7: ["normal_combat_growth_cap", 3], 8: ["salvage_capacity", 3],
		9: ["physical_damage_reduction_percent", 5], 10: ["lethal_protection", 1], 11: ["movement_speed_percent", 2],
		12: ["search_speed_percent", 10], 13: ["attack_speed_percent", 2], 14: ["extraction_gold_percent", 5],
		15: ["opening_effect_batch_unlock", 1], 16: ["search_speed_percent", 20], 17: ["attack_speed_percent", 5],
		18: ["extraction_gold_percent", 10], 19: ["consumable_retention", 1], 20: ["physical_damage_reduction_percent", 10],
		21: ["movement_speed_percent", 3], 22: ["normal_combat_growth_cap", 5], 23: ["salvage_capacity", 5],
		24: ["backpack_capacity", 5], 25: ["critical_unlock", 5], 26: ["backpack_capacity", 5], 27: ["initial_power", 3],
		28: ["max_hp", 15], 29: ["opening_effect_batch_unlock", 2], 30: ["failure_consumable_conversion_count", 1],
		31: ["critical_chance_percent", 10], 32: ["lethal_protection_hp", 15], 33: ["consumable_weight_reduce", 2],
		34: ["critical_damage_percent", 20], 35: ["low_hp_healing_percent", 20], 36: ["pressure_increase_cap", 15],
		37: ["critical_overflow", 1], 38: ["exclusive_drop_bonus_percent", 20], 39: ["opening_effect_batch_unlock", 3],
	}
	for number in expected_effects:
		var effect: Dictionary = by_id.get(_id(number), {})
		_expect(str(effect.get("effect_kind")) == expected_effects[number][0] and effect.get("effect_amount") == expected_effects[number][1], "source effect mapping: %d" % number)
	for number in [15, 29, 39]:
		var effect: Dictionary = by_id.get(_id(number), {})
		_expect(str(effect.get("runtime_scope")) == "opening_effect_eligibility", "batch purchase only grants eligibility: %d" % number)
		_expect(not effect.has("opening_effect_ids"), "batch purchase must not invent concrete effects: %d" % number)
		if number > 15:
			_expect(effect.get("effect_params", {}).get("effects_pending") == true, "later batches explicitly pending: %d" % number)
	var expected_params := {
		1: {"confirm_flagged_entry": true}, 5: {"threshold": 10, "charges_per_run": 1},
		9: {"minimum_block": 1}, 10: {"charges_per_run": 1}, 19: {"salvage_weight": 10, "all_endings": true},
		20: {"minimum_block": 2}, 25: {"damage_percent": 150, "direct_attacks_only": true},
		32: {"clamp_to_max_hp": true}, 33: {"minimum_weight": 1},
		35: {"hp_threshold_percent": 30, "threshold_inclusive": true},
		37: {"chance_threshold_percent": 100, "damage_percent_per_chance_percent": 1}, 38: {"eligible_pools_only": true},
	}
	for number in expected_params:
		_expect(by_id.get(_id(number), {}).get("effect_params", {}) == expected_params[number], "compound effect parameters preserved: %d" % number)
	var mixed := _meta(3, 100, 100, [_id(1), _id(1), "talent_carry_rigging", "unknown"], true, false)
	_expect((catalog.call("active_effects", mixed) as Array).size() == 1, "legacy/unknown/duplicate flags cannot add effects")
	_expect((catalog.call("summary", mixed) as Dictionary).get("known_unlocked_count") == 1, "only distinct Z2 IDs count as owned")
	var legacy := {"profile_level": 50, "talent_points": 100, "talent_flags": all_ids, "talent_earned": 1860, "talent_spent": 100}
	var before := legacy.duplicate(true)
	catalog.call("sync_progress", legacy)
	_expect(legacy == before, "legacy profile must not migrate implicitly")
	_expect((catalog.call("active_effects", legacy) as Array).is_empty(), "Z2 IDs in a legacy profile must not activate")
	_expect_blocked(legacy, _id(2), "z2_profile_required")


func _meta(level: int, earned: int, spent: int, flags: Array, completed: bool, teaching_available: bool) -> Dictionary:
	return {
		"ruleset_id": "z2", "z2_progression_version": 1, "profile_level": level,
		"talent_earned": earned, "talent_spent": spent, "talent_flags": flags.duplicate(),
		"tutorial_completed": completed, "tutorial_purchase_available": teaching_available,
	}


func _id(number: int) -> String:
	return "z2_talent_%02d" % number


func _expect_blocked(meta: Dictionary, talent_id: String, reason: String) -> void:
	var quote: Dictionary = catalog.call("unlock_evaluation", meta, talent_id)
	_expect(not bool(quote.get("ok", true)) and str(quote.get("status")) == reason, "%s must block %s" % [reason, talent_id])
	_expect(not str(quote.get("reason", "")).is_empty(), "blocked quote has friendly reason: %s" % reason)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _finish() -> void:
	for failure in failures:
		print("ASSERT_FAIL: %s" % failure)
	print("Z2_TALENT_CATALOG=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
