extends SceneTree

const Config := preload("res://scripts/ui/deploy_prep/deploy_config.gd")
const Model := preload("res://scripts/ui/deploy_prep/deploy_prep_model.gd")
const Maps := preload("res://scripts/ui/deploy_prep/deploy_map_projection.gd")
const LongTerm := preload("res://scripts/ui/long_term/long_term_model.gd")
const ResultModel := preload("res://scripts/ui/result/result_presentation_model.gd")
const Catalog := preload("res://scripts/core/content/m7_content_catalog.gd")
const Rules := preload("res://scripts/core/progression/z2_progression_rules.gd")
const Shell := preload("res://scripts/ui/deploy_prep/deploy_prep_shell.gd")
const Meta := preload("res://scripts/core/save/meta_progress_adapter.gd")
const Runtime := preload("res://scripts/core/run/run_runtime_controller.gd")
const Start := preload("res://scripts/core/run/run_start_config.gd")
const Items := preload("res://scripts/core/content/z2_item_catalog.gd")

class FailingSave extends SaveAdapter:
	var fail_next := true

	func save_json(source: Dictionary, path: String = M1_META_PROGRESS_PATH, normalize_meta_progress: bool = true) -> bool:
		if fail_next:
			fail_next = false
			last_error = "z2_ui_test_save_failure"
			return false
		return super.save_json(source, path, normalize_meta_progress)

# Deliberately fictional UI fixtures, never the official initial supply contents.
const SUPPLY_FIXTURE := [
	{"item_id": "fixture_supply_a", "display_name": "夹具物资甲", "value": 17, "weight": 2},
	{"item_id": "fixture_supply_b", "display_name": "夹具物资乙", "value": 23, "weight": 3},
]
const MAP_GATES := {
	"classic_7x7_simple": 1, "classic_7x7_normal": 3, "classic_10x10_easy": 3,
	"classic_10x10_standard": 5, "classic_10x10_hard": 10,
	"classic_13x13_normal": 15, "classic_13x13_hard": 20, "classic_13x13_hell": 25,
}

var failures: Array[String] = []
var checks := 0
var emitted_actions: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_claim_projection()
	_test_map_boundaries()
	_test_levels_and_talents()
	_test_growth_feedback()
	_test_catalog_context()
	await _test_claim_controls()
	await _test_actual_summary_action()
	# Let queued Controls and their signal callables leave the stack before exit.
	for _frame in range(4):
		await process_frame
	for failure in failures:
		print("Z2_PROGRESSION_UI_CASE_FAIL " + failure)
	print("Z2_PROGRESSION_UI checks=%d failures=%d" % [checks, failures.size()])
	print("Z2_PROGRESSION_UI=%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _summary(level: int, completed: bool = true) -> Dictionary:
	var meta := {
		"ruleset_id": "z2", "z2_progression_version": 1,
		"profile_level": level, "profile_exp": maxi(0, Rules.exp_for_level(level)),
		"tutorial_completed": completed, "gold": 0, "warehouse_items": [],
		"initial_supply_items": SUPPLY_FIXTURE.duplicate(true), "initial_supply_receipt": {},
		"map_success_counts": {}, "unlocked_map_ids": [], "map_catalog": [],
		"talent_points": 100, "talent_earned": 100, "talent_spent": 0,
		"talent_flags": [], "talent_catalog": [],
		"talent_summary": {"points_available": 100, "budget_total": 100},
	}
	for map_id in MAP_GATES:
		meta.map_success_counts[map_id] = 1
	for definition in Catalog.map_definitions():
		var map: Dictionary = definition.duplicate(true)
		var map_id := str(map.id)
		map.merge(Rules.map_overrides(map_id), true)
		var blockers := Rules.map_blockers(meta, map_id)
		map["unlocked"] = blockers.is_empty()
		map["lock_reason"] = " · ".join(blockers)
		meta.map_catalog.append(map)
		if map.unlocked:
			meta.unlocked_map_ids.append(map_id)
	return meta


func _claim_model(meta: Dictionary, active: bool = false) -> Dictionary:
	return Model.model_with_tab(Model.build({"meta_progress_summary": meta, "run_active": active}), &"claim")


func _row(model: Dictionary, id: String) -> Dictionary:
	for candidate in model.get("selection_rows", []):
		if str(candidate.get("id", "")) == id:
			return candidate
	return {}


func _test_claim_projection() -> void:
	for level in [0, 1, 2]:
		var meta := _summary(level, level > 0)
		var before := meta.duplicate(true)
		var model := _claim_model(meta)
		var row := _row(model, "claim_initial_supplies")
		_check(not row.is_empty(), "initial supply card exists at Lv%d" % level)
		_check(_row(model, "claim_emergency_ration").is_empty(), "Z2 removes per-run free ration")
		_check(model.tabs.size() == 5, "keeps the original five tabs")
		_check(int(model.config.profile_level) == level, "deploy preserves Lv%d" % level)
		var action: Dictionary = row.get("actions", [{}])[0]
		_check(bool(action.get("enabled", false)) == (level > 0), "claim eligibility at Lv%d" % level)
		if not row.is_empty():
			var text := str(row.get("facts", []))
			_check(text.contains("夹具物资甲") and text.contains("17") and text.contains("2"), "first item name/value/weight come from summary")
			_check(text.contains("夹具物资乙") and text.contains("23") and text.contains("3"), "second item name/value/weight come from summary")
		var selected := Model.model_with_card(model, &"claim_initial_supplies")
		var submitted := Config.apply_card_action(selected.config, &"claim", &"claim_initial_supplies")
		_check(bool(submitted.get("changed", false)) == false, "claim submission never edits draft inventory")
		_check(submitted.get("config", {}) == selected.config, "claim leaves config unchanged")
		_check(not (submitted.get("meta_action", {}) as Dictionary).is_empty() == (level > 0), "only eligible claim emits intent")
		_check(meta == before, "projection and selection leave summary untouched")
		var legacy := Config.apply_card_action(model.config, &"claim", &"claim_emergency_ration")
		_check(legacy.get("config", {}) == model.config and not legacy.get("changed", false), "legacy ration cannot be injected into Z2 draft")
	for state in ["tutorial", "claimed", "active", "missing_items"]:
		var meta := _summary(1)
		if state == "tutorial":
			meta.tutorial_completed = false
		elif state == "claimed":
			meta.initial_supply_receipt = {"id": "fixture_receipt"}
		elif state == "missing_items":
			meta.erase("initial_supply_items")
		var model := _claim_model(meta, state == "active")
		var action: Dictionary = _row(model, "claim_initial_supplies").get("actions", [{}])[0]
		_check(not action.get("enabled", true), "claim locks for " + state)
		var submitted := Config.apply_card_action(model.config, &"claim", &"claim_initial_supplies")
		_check((submitted.get("meta_action", {}) as Dictionary).is_empty(), "locked claim rejects direct action for " + state)
	var legacy_model := _claim_model({"profile_level": 1})
	_check(not _row(legacy_model, "claim_emergency_ration").is_empty(), "legacy fixture retains legacy card")


func _test_map_boundaries() -> void:
	for map_id in MAP_GATES:
		var gate := int(MAP_GATES[map_id])
		for level in [gate - 1, gate]:
			var meta := _summary(level)
			var config := Config.default_config(1, meta)
			var view := Maps.project(config)
			var projected := _map_from(view, map_id)
			_check(projected.get("min_profile_level", -1) == gate, "map level gate " + map_id)
			for field in ["experience_percent", "experience_cap", "talent_cap"]:
				_check(projected.get(field) == Rules.map_overrides(map_id).get(field), "%s projects %s" % [map_id, field])
			_check(bool(projected.get("unlocked", false)) == (level >= gate), "map boundary " + map_id)
			var chosen := Config.select_map(config, map_id)
			_check(bool(chosen.get("ok", false)) == (level >= gate), "selection agrees with map gate " + map_id)
			var candidate := Config.build_run_start_config(chosen.get("config", config))
			candidate.map_config_id = map_id
			candidate.difficulty = Catalog.map_definition_exact(map_id).difficulty
			var authorized := Start.authorize_with_meta(candidate, meta)
			_check(authorized.get("ok", false) == (level >= gate), "actual departure authority agrees at %s Lv%d: %s" % [map_id, level, authorized.get("issues", [])])
			if level >= gate:
				_check(Config.config_validity(chosen.config).can_start, "departure preview accepts eligible map " + map_id)
				var run := Config.build_run_start_config(chosen.config)
				_check(run.profile_level == level, "departure preserves actual profile level")
	var stale := _summary(0, false)
	stale.unlocked_map_ids = ["tutorial_5x5"] + MAP_GATES.keys()
	stale.map_catalog = []
	var config := Config.default_config(1, stale)
	_check(config.map_config_id == "tutorial_5x5", "stale map IDs cannot bypass tutorial default")
	_check(not Config.select_map(config, "classic_10x10_easy").get("ok", false), "stale unlock list cannot bypass core gates")
	var blocked := _map_from(Maps.project(config), "classic_10x10_easy")
	_check(not blocked.get("unlocked", true) and not str(blocked.get("lock_reason", "")).is_empty(), "rules supply lock reason without map summary")
	var predecessor := _summary(25)
	predecessor.map_success_counts = {}
	predecessor.map_catalog = []
	var locked := Config.default_config(1, predecessor)
	_check(not Config.select_map(locked, "classic_13x13_hell").get("ok", false), "preceding difficulty clear is required")
	var forged := locked.duplicate(true)
	forged.map_config_id = "classic_13x13_hell"
	forged.difficulty = &"hell"
	forged.selected_difficulty = &"hell"
	_check(not Config.config_validity(forged).can_start, "preview rejects stale locked selection")


func _map_from(view: Dictionary, id: String) -> Dictionary:
	for group in view.get("scale_options", []):
		for map in group.get("maps", []):
			if str(map.get("map_config_id", "")) == id:
				return map
	return {}


func _test_levels_and_talents() -> void:
	for level in [0, 1, 2, 30, 49, 50]:
		var meta := _summary(level, level > 0)
		var before := meta.duplicate(true)
		var model := LongTerm.build_from_snapshot(&"profile", {"meta_progress_summary": meta})
		var panel: Dictionary = model.profile_runtime_panel
		_check(panel.profile_level == level, "profile preserves Lv%d" % level)
		_check(panel.next_level_exp == Rules.exp_for_level(level + 1), "profile uses Z2 next threshold Lv%d" % level)
		var qualification: Dictionary = model.m7_cards_by_group["profile/qualification_level"][0]
		_check(str(qualification.title).begins_with("Lv.%d" % level), "qualification preserves Lv%d" % level)
		_check(str(qualification.facts).contains("50") and str(qualification.facts).contains("30"), "actual cap and content boundary are distinct")
		var result := ResultModel.build({
			"outcome": "Extracted", "meta_progress_committed": true,
			"meta_progress_summary": meta,
			"meta_progress_commit": {"status": &"committed", "m7_progression_delta": {"exp_gained": 0}},
		})
		var xp := str(result.career_xp_text)
		_check(xp.contains("Lv.%d" % level), "result preserves Lv%d" % level)
		if level == 0:
			_check(xp.contains("教学") and not xp.contains("0 经验"), "Lv0 result explains teaching instead of XP unlock")
		elif level < 50:
			_check(xp.contains("距 Lv.%d %d 经验" % [level + 1, Rules.exp_for_level(level + 1) - int(meta.profile_exp)]), "result uses Z2 next threshold Lv%d" % level)
		else:
			_check(xp.contains("已满级") and not xp.contains("Lv.51"), "Lv50 has no invented next level")
		_check(meta == before, "career projections are read only")
	var meta := _summary(3)
	for index in range(39):
		meta.talent_catalog.append({
			"talent_id": "fixture_talent_%d" % index, "display_name": "夹具天赋%d" % index,
			"cost": 31 + index, "reason": "夹具核心条件%d" % index,
			"reason_code": &"prerequisite_missing", "available": index == 0,
			"prerequisite_ids": ["fixture_talent_0", "fixture_talent_1"] if index == 2 else [],
		})
	var model := LongTerm.build_from_snapshot(&"talent", {"meta_progress_summary": meta})
	var cards: Array = model.m7_cards_by_group["talent/tree"]
	_check(cards.size() == 39, "talents use all 39 supplied nodes")
	for index in range(cards.size()):
		_check(cards[index].cost == 31 + index and cards[index].description == "夹具核心条件%d" % index, "talent cost and reason stay authoritative")
	_check(model.talent_tree_contract.edge_count == 2, "tree represents both AND prerequisite edges")
	for index in [28, 38]:
		meta.talent_catalog[index].available = true
		meta.talent_catalog[index]["runtime_scope"] = &"opening_effect_eligibility"
		meta.talent_catalog[index]["effect_label"] = "选择资格；具体效果待定"
	model = LongTerm.build_from_snapshot(&"talent", {"meta_progress_summary": meta})
	cards = model.m7_cards_by_group["talent/tree"]
	for index in [28, 38]:
		_check(cards[index].get("action", {}).get("action") == &"unlock_talent", "future opening eligibility stays purchasable")
		_check(str(cards[index].facts).contains("选择资格") and not str(cards[index].facts).contains("生效范围：确认出发"), "future eligibility does not promise an implemented opening effect")


func _test_catalog_context() -> void:
	var meta := _summary(4)
	meta.gold = 48
	var item := Items.definition("eq_old_vest")
	# The UI must use supplied shop prices and the current item's description/weight.
	meta["shop_catalog"] = [{
		"item_id": "eq_old_vest", "display_name": item.display_name,
		"price": item.purchase_price, "unlocked": true,
	}]
	var before := meta.duplicate(true)
	var model := _claim_model(meta)
	var row := _row(model, "m7_shop_eq_old_vest")
	_check(row.get("detail", "") == item.short_description, "shop details use current Z2 item definition")
	_check(row.get("weight", -1) == item.weight and str(row.get("facts", [])).contains("重量 %d" % item.weight), "shop displays current Z2 weight")
	_check(row.get("unit_price", -1) == item.purchase_price, "shop retains authoritative summary price")
	var adjusted := Config.adjust_purchase_quantity(model.config, "eq_old_vest", 1)
	_check(Config.purchase_quantity(adjusted.config, "eq_old_vest") == 2, "purchase quantity uses Z2 price rather than legacy price")
	var capped := Config.adjust_purchase_quantity(adjusted.config, "eq_old_vest", 1)
	_check(Config.purchase_quantity(capped.config, "eq_old_vest") == 2, "Z2 purchase quantity stops at wallet budget")
	_check(meta == before, "catalog projection and quantity edits leave source summary untouched")
	meta.erase("shop_catalog")
	model = _claim_model(meta)
	_check(not _row(model, "m7_shop_eq_edge_opener").is_empty(), "shop fallback reads new camp catalog")
	_check(_row(model, "m7_shop_con_ration").is_empty(), "new camp catalog does not restore legacy ration sales")
	meta.gold = 2 * int(Items.definition("eq_edge_opener").purchase_price)
	var new_purchase := Config.adjust_purchase_quantity(Config.default_config(1, meta), "eq_edge_opener", 1)
	_check(Config.purchase_quantity(new_purchase.config, "eq_edge_opener") == 2, "quantity action resolves new-only camp item with current meta")
	var locked := _row(_claim_model(_summary(3)), "m7_shop_eq_old_vest")
	_check(not locked.get("unlocked", true), "new camp qualification respects level gate")
	_check(str(locked.get("unlock_text", "")).contains("4"), "locked shop row shows the actual Lv4 requirement")
	var research := LongTerm.build_from_snapshot(&"research", {"meta_progress_summary": meta})
	var research_cards: Array = research.m7_cards_by_group["research/unlock_interface"]
	_check(research_cards.size() == 3 and research_cards[0].id == "research_hard_shell_patch", "research fallback uses new research definitions")
	# This fixture exercises definition lookup, not a shipping research recipe.
	meta["research_catalog"] = [{
		"id": "fixture_research_lookup", "display_name": "夹具查询",
		"material_item_id": "col_word_swallowing_meter", "prerequisite": "research_red_battery",
		"gold_cost": 0, "has_material": false, "can_complete": false,
	}]
	research = LongTerm.build_from_snapshot(&"research", {"meta_progress_summary": meta})
	var card: Dictionary = research.m7_cards_by_group["research/unlock_interface"][0]
	_check(str(card.facts).contains(str(Items.definition("col_word_swallowing_meter").display_name)), "research material lookup receives current meta")
	_check(card.prerequisite_title == "强化电源方案", "research prerequisite fallback receives current meta")


func _test_growth_feedback() -> void:
	for ending in ["success", "failure", "abandon"]:
		var growth := Rules.settle_scores("classic_13x13_hard", 200, 300, ending)
		var result := ResultModel.build({
			"outcome": "Extracted" if ending == "success" else ("Failed" if ending == "failure" else "Abandoned"),
			"meta_progress_summary": _summary(20),
			"meta_progress_commit": {"status": &"committed", "m7_progression_delta": {
				"map_id": "classic_13x13_hard", "exp_gained": growth.experience,
				"talent_points_gained": growth.talent_points, "experience_breakdown": growth,
			}},
		})
		var tooltip := str(result.progression_tooltip)
		_check(tooltip.contains("难度 180%") and tooltip.contains("经验上限 150") and tooltip.contains("天赋上限 250"), "Z2 result uses authoritative map multiplier and both caps")
		_check(tooltip.contains("结算 %d%%" % growth.ending_percent), "Z2 result shows actual ending percentage for " + ending)
		_check(str(result.career_xp_text).contains("天赋点 +%d" % growth.talent_points), "Z2 result shows committed independent talent gain")


func _test_claim_controls() -> void:
	emitted_actions.clear()
	root.size = Vector2i(1280, 720)
	var shell := Shell.new()
	root.add_child(shell)
	shell.meta_action_requested.connect(_record_action)
	shell.build()
	shell.set_reduced_motion_enabled(true)
	var meta := _summary(1)
	shell.apply_snapshot({"meta_progress_summary": meta})
	shell.show_tab(&"claim")
	await process_frame
	var row := _row(shell.current_model, "claim_initial_supplies")
	_check(not row.is_empty(), "real shell constructs initial supply card")
	if not row.is_empty():
		var before: Dictionary = shell.current_model.config.duplicate(true)
		_check(emitted_actions.is_empty(), "opening claim tab emits no claim")
		shell.detail_primary_action_button.emit_signal("pressed")
		_check(emitted_actions.size() == 1, "explicit UI button emits one claim")
		if not emitted_actions.is_empty():
			var request: Dictionary = emitted_actions.back()
			_check(request.action == &"claim_initial_supplies" and request.target_id == "initial_supplies", "claim signal carries canonical action and target")
			_check(shell.current_model.config == before, "pending claim does not grant or carry anything")
			_check(shell.detail_primary_action_button.disabled, "pending button disables repeat claims")
			shell.detail_primary_action_button.emit_signal("pressed")
			_check(emitted_actions.size() == 1, "duplicate UI activation stays pending")
			var envelope: Dictionary = request.duplicate(true)
			envelope.merge({"ok": false, "status": &"save_failed"}, true)
			_check(shell.apply_meta_action_result(envelope), "matching failure is consumed")
			_check(str(shell.current_model.action_message).contains("重试"), "save failure visibly offers retry")
			_check(not shell.detail_primary_action_button.disabled, "save failure enables retry")
			_check(shell.current_model.config == before, "failed save never changes inventory")
			shell.detail_primary_action_button.emit_signal("pressed")
			_check(emitted_actions.size() == 2, "retry emits a new request")
			envelope = emitted_actions.back().duplicate(true)
			_check(envelope.request_id != request.request_id, "retry gets a fresh request identity")
			envelope.merge({"ok": true, "status": &"claimed"}, true)
			_check(shell.apply_meta_action_result(envelope), "matching success is consumed")
			_check(shell.current_model.config == before, "success envelope alone does not fabricate inventory")
			meta.initial_supply_receipt = {"id": "fixture_claim_saved"}
			meta.warehouse_items = [Catalog.item_definition("con_ration")]
			meta.warehouse_items[0]["instance_id"] = "fixture_saved_supply"
			shell.apply_snapshot({"meta_progress_summary": meta})
			_check(shell.detail_primary_action_button.disabled, "saved receipt locks repeated claim after summary refresh")
			_check(shell.current_model.config.selected_consumable_ids.is_empty(), "new warehouse items are not automatically carried")
			_check(shell.current_model.config.meta_progress_summary.warehouse_items == meta.warehouse_items, "refreshed warehouse comes only from summary")
			_check(not shell.apply_meta_action_result(envelope), "duplicate result cannot be consumed twice")
		var fresh := _summary(1)
		fresh.initial_supply_items[0].display_name = "刷新后的夹具物资"
		shell.apply_snapshot({"meta_progress_summary": fresh, "run_active": true})
		_check(shell.detail_primary_action_button.disabled, "active run locks initial claim UI")
		shell.apply_snapshot({"meta_progress_summary": fresh})
		_check(str(_row(shell.current_model, "claim_initial_supplies").facts).contains("刷新后的夹具物资"), "new summary refreshes supply display")
	shell.set_page_active(false)
	shell.queue_free()
	await process_frame
	await process_frame


func _test_actual_summary_action() -> void:
	emitted_actions.clear()
	var path := "user://tests/z2_ui_%d/meta.json" % Time.get_ticks_usec()
	var meta := Meta.new()
	meta.set_active_profile_path(path, "z2-ui-fixture")
	_check(meta.initialize_z2_profile(Rules.CONTENT_VERSION).get("ok", false), "integration creates isolated real Z2 profile")
	var shell := Shell.new()
	root.add_child(shell)
	shell.build()
	shell.set_reduced_motion_enabled(true)
	shell.meta_action_requested.connect(_record_action)
	var saved_before := FileAccess.get_file_as_bytes(path)
	shell.apply_snapshot({"meta_progress_summary": meta.get_summary()})
	shell.show_tab(&"claim")
	_check(shell.detail_primary_action_button.disabled, "actual Lv0 summary locks claim")
	_check(FileAccess.get_file_as_bytes(path) == saved_before and meta.data.warehouse_items.is_empty(), "viewing actual summary never saves or grants")
	_check(meta.begin_tutorial_training().get("ok", false), "integration opens tutorial purchase")
	_check(meta.unlock_talent("z2_talent_01").get("ok", false), "integration completes teaching purchase")
	_check(meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "z2-ui-teaching").get("ok", false), "integration saves teaching completion")
	var summary := meta.get_summary()
	shell.apply_snapshot({"meta_progress_summary": summary})
	var supply_row := _row(shell.current_model, "claim_initial_supplies")
	_check(summary.initial_supply_items.size() == 2 and not supply_row.is_empty(), "actual core supplies render one claim card")
	for item in summary.initial_supply_items:
		var fact_text := str(supply_row.get("facts", []))
		var value := str(item.get("value", item.get("purchase_price", "—")))
		_check(fact_text.contains(str(item.display_name)) and fact_text.contains("价值 %s 金币 · 重量 %s" % [value, item.weight]), "actual core item values are rendered without catalog fallback")
	var runtime := Runtime.new()
	runtime.bind_meta_progress_adapter(meta)
	meta.save_adapter = FailingSave.new()
	shell.detail_primary_action_button.emit_signal("pressed")
	_check(emitted_actions.size() == 1, "actual eligible UI emits one request")
	if not emitted_actions.is_empty():
		var failure := runtime.execute_meta_action(emitted_actions.back())
		_check(failure.status == &"save_failed" and not failure.ok, "runtime reports actual injected save failure")
		shell.apply_snapshot({"meta_progress_summary": failure.meta_progress_summary})
		_check(shell.apply_meta_action_result(failure), "UI accepts actual failure envelope")
		_check(meta.data.warehouse_items.is_empty() and meta.data.initial_supply_receipt.is_empty(), "failed claim rolls back actual warehouse and receipt")
		_check(not shell.detail_primary_action_button.disabled and str(shell.current_model.action_message).contains("重试"), "actual failure is visibly retryable")
		shell.detail_primary_action_button.emit_signal("pressed")
		_check(emitted_actions.size() == 2, "actual failure can be retried through button")
		var success := runtime.execute_meta_action(emitted_actions.back())
		_check(success.ok and success.status == &"claimed", "runtime saves actual first claim")
		shell.apply_snapshot({"meta_progress_summary": success.meta_progress_summary})
		_check(shell.apply_meta_action_result(success), "UI accepts actual success envelope")
		_check(meta.data.warehouse_items.size() == 2 and shell.detail_primary_action_button.disabled, "saved receipt disables claim and adds exactly two warehouse instances")
		_check(shell.current_model.config.selected_consumable_ids.is_empty(), "actual first claim does not auto carry")
		runtime.execute_meta_action(emitted_actions.back())
		_check(meta.data.warehouse_items.size() == 2, "duplicate actual request cannot grant again")
		meta.load_or_create_default()
		shell.apply_snapshot({"meta_progress_summary": meta.get_summary()})
		_check(shell.detail_primary_action_button.disabled and meta.data.warehouse_items.size() == 2, "reloaded receipt remains claimed")
	shell.set_page_active(false)
	shell.queue_free()
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.bind_runtime_controller(null)
	runtime.context = null
	runtime.in_run_runtime = null
	runtime.command_bus = null
	await process_frame
	await process_frame


func _record_action(action: Dictionary) -> void:
	emitted_actions.append(action.duplicate(true))


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
