extends SceneTree

const Runtime = preload("res://scripts/core/run/run_runtime_controller.gd")
const Meta = preload("res://scripts/core/save/meta_progress_adapter.gd")
const Rules = preload("res://scripts/core/progression/z2_progression_rules.gd")

class CutSave extends SaveAdapter:
	var cut := false
	func _rename_file(source: String, target: String) -> bool:
		if cut and source.ends_with(ATOMIC_TEMP_SUFFIX):
			cut = false
			return false
		return super._rename_file(source, target)
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var meta := Meta.new()
	meta.set_active_profile_path("user://z2_teaching_%d/meta.json" % Time.get_ticks_usec(), "teaching")
	meta.load_or_create_default()
	_check(meta.initialize_z2_profile(Rules.CONTENT_VERSION).get("ok", false), "new profile")
	var runtime := Runtime.new()
	runtime.bind_meta_progress_adapter(meta)
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
	var started: Dictionary = runtime.command_bus.dispatch(&"start_standard_run", {"run_start_config": {"map_config_id": "tutorial_5x5", "difficulty": &"tutorial"}})
	_check(started.get("ok", false), "actual tutorial route starts")
	if not started.get("ok", false):
		print("Z2_TUTORIAL_START_REJECTED ", started)
		_release(runtime)
		quit(1)
		return
	_check(runtime.context.mode == &"tutorial", "tutorial mode")
	_check(runtime.context.profile_fields.get("ruleset_id", "") == "z2", "authoritative ruleset reaches run")
	_check(not runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(1, 0)}).get("ok", true), "flag locked before learning")
	_check(runtime.context.asset_ledger.get_currency(&"black_coin") == 20, "teaching practice balance")
	for old_event_pos: Vector2i in [Vector2i(1, 2), Vector2i(2, 1), Vector2i(3, 0)]:
		_check(runtime.context.truth_map.get_room_type(old_event_pos) == &"Normal", "vacated teaching event becomes a normal room")
	var before: Dictionary = meta.data.duplicate(true)
	_check(not runtime.context.has_blocking_tutorial_popup(), "opening guidance does not lock the run")
	runtime.command_bus.dispatch(&"learn_tutorial_flag", {"preview": true})
	_check(meta.data == before and not runtime.context.profile_fields.get("flag_unlocked", false), "learning preview neither spends nor grants")
	_check(runtime.command_bus.dispatch(&"confirm_tutorial_popup", {"action_id": "dismiss-opening"}).get("ok", false), "guidance can be dismissed independently")
	_check(meta.data == before and not runtime.context.profile_fields.get("flag_unlocked", false), "closing opening text is not a purchase")
	_check(runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.DOWN}).get("ok", false), "unlearned player may leave spawn")
	_check(runtime.context.get_current_pos() == Vector2i(0, 1), "first room remains explorable before learning")
	_check(runtime.context.event_state.get("event_type") == "information" and not runtime.context.event_state.get("requires_prepare", true), "first lesson is complete information encounter")
	for direction: Vector2i in [Vector2i.RIGHT, Vector2i.RIGHT, Vector2i.RIGHT]:
		_check(runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": direction}).get("ok", false), "reach alternate chest route")
	var chest := {"direction": Vector2i.RIGHT, "action_id": "enter-first-chest"}
	runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.RIGHT, "preview": true})
	_check(meta.data == before and runtime.context.get_current_pos() == Vector2i(3, 1), "chest preview has no entitlement or move")
	var confirmed: Dictionary = runtime.command_bus.dispatch(&"attempt_room_transition", chest)
	_check(runtime.context.profile_fields.get("flag_unlocked", false) and runtime.context.get_current_pos() == Vector2i(4, 1), "first real chest entry learns before opening chest")
	_check(confirmed.get("ok", false), "first committed chest move grants learning")
	_check(meta.data.talent_flags.has("z2_talent_01") and meta.data.talent_spent == 100 and meta.data.talent_points == 0, "learning spends exactly 100")
	runtime.command_bus.dispatch(&"attempt_room_transition", chest)
	_check(runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.LEFT}).get("ok", false), "leave first chest room")
	_check(runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.RIGHT}).get("ok", false) and runtime.context.get_current_pos() == Vector2i(4, 1) and meta.data.talent_spent == 100, "distinct committed return to chest preserves first learning receipt")
	for step in range(4):
		runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.LEFT})
	_check(meta.data.talent_spent == 100, "learning retry does not spend again")
	_check(runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.UP}).get("ok", false) and runtime.context.get_current_pos() == Vector2i.ZERO, "learned player returns without a guidance gate")
	_check(runtime.context.active_talent_effects.is_empty() and runtime.context.max_hp == 100, "tutorial excludes ordinary bonuses")
	if runtime.context.intel_map.is_flagged(Vector2i(1, 0)):
		runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(1, 0)})
	_check(runtime.command_bus.dispatch(&"toggle_flag_cell", {"pos": Vector2i(1, 0)}).get("ok", false), "learned flag can be placed")
	var origin: Vector2i = runtime.context.get_current_pos()
	var asked: Dictionary = runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.RIGHT, "entry_position": Vector2(0.4, 0.5)})
	_check(asked.get("ok", false) and runtime.context.get_current_pos() == origin, "flagged entry requests confirmation without moving")
	_check(str(runtime.context.tutorial_popup.get("id", "")) == "flag_entry_confirm", "explicit flag decision is visible")
	var held: Dictionary = runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.RIGHT})
	_check(not held.get("ok", true) and runtime.context.get_current_pos() == origin, "held movement cannot confirm")
	_check(runtime.command_bus.dispatch(&"cancel_flag_entry").get("ok", false), "flag decision can be cancelled")
	_check(runtime.context.get_current_pos() == origin and runtime.context.tutorial_popup.is_empty(), "cancel has no movement")
	runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": Vector2i.RIGHT, "entry_position": Vector2(0.4, 0.5)})
	var resumed := Runtime.new()
	resumed.bind_meta_progress_adapter(meta)
	resumed.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
	_check(resumed.install_authoritative_state(runtime.capture_authoritative_state()).get("ok", false), "pending decision survives checkpoint reconstruction")
	var entered: Dictionary = resumed.command_bus.dispatch(&"confirm_tutorial_popup")
	_check(entered.get("ok", false) and resumed.context.get_current_pos() == Vector2i(1, 0), "explicit confirmation enters exact pending room")
	_check(resumed.context.intel_map.is_flagged(Vector2i(1, 0)), "entry preserves manual flag")
	_check(resumed.get_restored_local_position(Vector2.ZERO).is_equal_approx(Vector2(0.4, 0.5)), "entry restores room-local position")
	_release(resumed)
	_release(runtime)
	_check_purchase_failures()
	for failure in failures:
		print("Z2_TUTORIAL_CASE_FAIL " + failure)
	print("Z2_TUTORIAL_PROGRESSION=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check_purchase_failures() -> void:
	for scenario in ["stale_conditions", "action_conflict", "meta_save_failure", "checkpoint_failure"]:
		var meta := Meta.new()
		meta.set_active_profile_path("user://z2_teaching_fault_%d/meta.json" % Time.get_ticks_usec(), scenario)
		meta.initialize_z2_profile(Rules.CONTENT_VERSION)
		var runtime := Runtime.new()
		runtime.bind_meta_progress_adapter(meta)
		runtime.checkpoint_writer = func(_state: Dictionary) -> Dictionary: return {"ok": true}
		var started: Dictionary = runtime.command_bus.dispatch(&"start_standard_run", {"action_id": "fault-start", "run_start_config": {"map_config_id": "tutorial_5x5", "difficulty": &"tutorial"}})
		_check(started.get("ok", false), scenario + " tutorial starts")
		var before: Dictionary = meta.data.duplicate(true)
		for direction: Vector2i in [Vector2i.DOWN, Vector2i.RIGHT, Vector2i.RIGHT, Vector2i.RIGHT]:
			runtime.command_bus.dispatch(&"attempt_room_transition", {"direction": direction})
		var payload := {"direction": Vector2i.RIGHT, "action_id": "fault-learn"}
		if scenario == "stale_conditions":
			payload["expected_conditions"] = "outdated"
		elif scenario == "action_conflict":
			payload.action_id = "fault-start"
		elif scenario == "meta_save_failure":
			var cutter := CutSave.new()
			cutter.cut = true
			meta.save_adapter = cutter
		else:
			runtime.checkpoint_writer = func(_state: Dictionary) -> Dictionary: return {"ok": false, "error": "test_cut"}
		var rejected: Dictionary = runtime.command_bus.dispatch(&"attempt_room_transition", payload)
		_check(not rejected.get("ok", true), scenario + " rejects action")
		_check(meta.data == before, scenario + " failed attempt never charged meta")
		var expected_pos := Vector2i(4, 1) if scenario == "meta_save_failure" else Vector2i(3, 1)
		_check(runtime.context.get_current_pos() == expected_pos, scenario + " committed room location")
		if scenario in ["meta_save_failure", "checkpoint_failure"]:
			runtime.checkpoint_writer = func(_state: Dictionary) -> Dictionary: return {"ok": true}
			_check(runtime.retry_persistence().get("ok", false), "storage retry available")
			_check(runtime.command_bus.dispatch(&"attempt_room_transition", payload).get("ok", false), "chest retry settles exactly once")
			meta.load_or_create_default()
			_check(meta.data.talent_spent == 100 and meta.data.talent_points == 0, "retry and reload preserve one teaching payment")
		_release(runtime)

func _release(runtime) -> void:
	runtime.command_bus.runtime_controller = null
	runtime.command_bus.room_resolver.bind_runtime_controller(null)
	runtime.in_run_runtime.bind(null)

func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
