extends SceneTree

const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Progress = preload("res://scripts/core/progression/m7_progression_service.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")
const Start = preload("res://scripts/core/run/run_start_config.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var meta := Meta.new()
	meta.set_active_profile_path("user://z2_content_%d/meta.json" % Time.get_ticks_usec(), "content")
	meta.load_or_create_default()
	meta.initialize_z2_profile(Rules.CONTENT_VERSION)
	meta.data.tutorial_completed = true
	meta.data.profile_level = 1
	meta.data.talent_flags = ["z2_talent_01"]
	meta.data.talent_spent = 100
	meta.data.talent_points = 0
	meta.data.gold = 100
	meta.save()
	_check(not meta.purchase_item("eq_old_vest").get("ok", true), "Lv1 shop blocked")
	meta.data.profile_exp = 109
	meta.data.profile_level = 3
	meta.save()
	var pre_shop := meta.data.duplicate(true)
	for item_id in ["eq_old_vest", "eq_edge_opener", "eq_recovery_bag"]:
		_check(meta.purchase_item(item_id).get("status", "") == "locked", "Lv3 purchase rejected " + item_id)
	_check(meta.data == pre_shop, "locked camp purchases consume no gold or inventory")
	meta.data.profile_exp = 110
	meta.data.profile_level = 4
	_check(meta.save(), "Lv4 at 110 XP saves")
	var shop_ids: Array = meta.get_summary().shop_catalog.map(func(item: Dictionary) -> String: return item.item_id)
	shop_ids.sort()
	_check(shop_ids == ["eq_edge_opener", "eq_old_vest", "eq_recovery_bag"], "only the first three items list on the camp shelf")
	var bought: Dictionary = meta.purchase_item("eq_old_vest")
	_check(bought.get("ok", false), "Lv4 camp vest available")
	_check(meta.data.gold == 76, "vest uses approved24 price")
	_check(meta.data.warehouse_items.size() == 1 and meta.data.warehouse_items[0].weight == 10, "new equipment instance freezes catalog weight")
	_check(not meta.purchase_item("con_stabilizer").get("ok", true), "old camp item cannot bypass new channel gate")
	var start: Dictionary = Start.authorize_with_meta({"map_config_id": "classic_7x7_simple", "difficulty": "simple", "selected_objective_id": "commission_recover_supply"}, meta.get_summary())
	_check(start.get("ok", false), "eligible actual departure")
	_check(start.get("config", {}).get("profile_fields", {}).get("content_eligibility", {}).get("profile_level", -1) == 4, "departure freezes content eligibility")
	var fake := Z2ItemCatalog.definition("col_20")
	fake["instance_id"] = "same-name-collectible"
	meta.data.warehouse_items.append(fake)
	_check(not meta.complete_research("research_red_battery").get("ok", true), "collectible cannot substitute research material")
	Progress.add_item_instance(meta.data, "mon_old_gear_set", "test_fixture")
	meta.save()
	var research: Dictionary = meta.complete_research("research_hard_shell_patch")
	_check(research.get("ok", false), "approved research completes")
	_check(meta.data.gold == 36 and meta.data.research_completed_ids.has("research_hard_shell_patch"), "research deducts exact40 and records unlock")
	_check(not meta.data.warehouse_items.any(func(item: Dictionary) -> bool: return item.item_id == "mon_old_gear_set"), "research consumes material once")
	meta.complete_research("research_hard_shell_patch")
	meta.load_or_create_default()
	_check(meta.data.gold == 36 and meta.data.research_completed_ids.size() == 1, "research replay and restart do not recharge")
	for failure in failures:
		print("Z2_CONTENT_INTEGRATION_CASE_FAIL " + failure)
	print("Z2_CONTENT_INTEGRATION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
