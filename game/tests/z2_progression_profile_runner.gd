extends SceneTree

const MetaScript := preload("res://scripts/core/save/meta_progress_adapter.gd")
const SaveScript := preload("res://scripts/core/save/save_adapter.gd")
const VERSION := "z2-system-20261116"
var failures: Array[String] = []
var checks := 0
var save_path := "user://z2_progression_%d/meta.json" % Time.get_ticks_usec()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var meta := MetaScript.new()
	meta.set_active_profile_path(save_path, "new-z2")
	meta.load_or_create_default()
	_check(meta.initialize_z2_profile(VERSION).get("ok", false), "new profile commits")
	_check(meta.data.profile_level == 0, "new player begins at Lv0")
	_check(meta.get_summary().profile_level == 0, "UI summary preserves Lv0")
	_check(meta.data.warehouse_items.is_empty(), "no automatic legacy starter pack")
	_check(meta.data.get("talent_earned", -1) == 100 and meta.data.get("talent_spent", -1) == 0, "teaching grant has explicit earned/spent ledger")
	_check(meta.data.talent_points == 100, "Lv0 gets exactly 100 teaching points")
	var reopened := MetaScript.new()
	reopened.set_active_profile_path(save_path, "new-z2")
	reopened.load_or_create_default()
	_check(reopened.data.profile_level == 0 and reopened.data.talent_points == 100, "reload neither raises level nor duplicates teaching points")
	_check(not reopened.initialize_z2_profile(VERSION).get("ok", true), "existing profile cannot be reinitialized")
	_check(not reopened.unlock_talent("z2_talent_01").get("ok", true), "teaching points cannot be spent outside tutorial")
	_check(reopened.has_method("begin_tutorial_training"), "tutorial purchase boundary exists")
	if reopened.has_method("begin_tutorial_training"):
		_check(reopened.begin_tutorial_training().get("ok", false), "tutorial opens teaching purchase")
		_check(reopened.unlock_talent("z2_talent_01").get("ok", false), "teaching flag node can be bought")
		_check(reopened.data.talent_points == 0 and reopened.data.talent_spent == 100, "teaching purchase consumes grant once")
		_check(reopened.unlock_talent("z2_talent_01").get("duplicate", false), "repeat purchase is a no-op")
		_check(not reopened.unlock_talent("z2_talent_02").get("ok", true), "ordinary talents remain unavailable in tutorial")
		var completed: Dictionary = reopened._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "teaching-1")
		_check(completed.get("ok", false), "tutorial completion saves")
		_check(reopened.data.profile_level == 1 and reopened.data.tutorial_completed, "tutorial completion reaches Lv1")
		reopened._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "teaching-replay")
		_check(reopened.data.talent_earned == 100 and reopened.data.talent_spent == 100, "tutorial replay cannot grant points")
		_check(reopened.has_method("claim_initial_supplies"), "first claim has an explicit action")
		if reopened.has_method("claim_initial_supplies"):
			var claim: Dictionary = reopened.claim_initial_supplies()
			_check(claim.get("ok", false), "Lv1 can claim the confirmed starter pack")
			_check(reopened.data.warehouse_items.size() == 2, "first claim grants exactly two instances")
			reopened.claim_initial_supplies()
			_check(reopened.data.warehouse_items.size() == 2, "repeat first claim grants nothing")
			reopened.load_or_create_default()
			reopened.claim_initial_supplies()
			_check(reopened.data.warehouse_items.size() == 2, "first claim receipt survives restart")
	var old_curve_path := save_path + ".old_curve"
	var old_curve := reopened.data.duplicate(true)
	old_curve["profile_exp"] = 110
	old_curve["profile_level"] = 3
	old_curve["gold"] = 42
	old_curve.erase("z2_xp_curve_version")
	var old_curve_file := FileAccess.open(old_curve_path, FileAccess.WRITE)
	old_curve_file.store_string(JSON.stringify(old_curve))
	old_curve_file.close()
	var upgraded := MetaScript.new()
	upgraded.set_active_profile_path(old_curve_path, "new-z2")
	_check(upgraded.get_summary().profile_level == 4 and upgraded.data.profile_exp == 110, "existing Z2 profile loads at revised threshold")
	_check(upgraded.data.gold == 42 and upgraded.data.warehouse_items.size() == 2, "curve migration preserves wallet and earned items")
	_check(upgraded.save(), "revised curve profile remains writable")
	upgraded.load_or_create_default()
	_check(upgraded.data.profile_level == 4 and upgraded.data.profile_exp == 110, "revised curve profile reloads")
	upgraded.data.profile_level = 3
	_check(not upgraded.save(), "current curve rejects an inconsistent stored level")
	var legacy_path := save_path + ".legacy"
	var adapter := SaveScript.new()
	var legacy: Dictionary = adapter.default_meta_progress()
	adapter.save_json(legacy, legacy_path)
	var bytes_before := FileAccess.get_file_as_bytes(legacy_path)
	var old := MetaScript.new()
	old.set_active_profile_path(legacy_path, "old")
	old.load_or_create_default()
	_check(not old.initialize_z2_profile(VERSION).get("ok", true), "legacy profile is not implicitly converted")
	_check(bytes_before == FileAccess.get_file_as_bytes(legacy_path), "opening old profile preserves saved bytes")
	_check(old.has_method("reset_as_current_z2_profile"), "explicit reset action exists")
	if old.has_method("reset_as_current_z2_profile"):
		_check(old.reset_as_current_z2_profile().get("ok", false), "authorized reset replaces old progress")
		_check(old.data.profile_level == 0 and old.data.warehouse_items.is_empty(), "old game profile is now a fresh Z2 profile")
		old.load_or_create_default()
		_check(old.data.talent_points == 100 and old.data.profile_level == 0, "reset new profile survives restart")
	print("Z2_PROGRESSION_PROFILE checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures:
		print("Z2_PROGRESSION_PROFILE_CASE_FAIL " + failure)
	print("Z2_PROGRESSION_PROFILE=%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
