extends SceneTree

# Focused production-input regression, NOT a natural Lv0 -> Lv50 journey.
# Tutorial uses a fresh-profile admission and the fixed teaching map. The
# ordinary 22-event, shortcut and voluntary cage cases use a Lv50 stage profile.
# Run only in the parent's disposable mirror and fresh isolated user directory.
const Events := preload("res://scripts/core/run/z2_event_runtime.gd")
const Hooks := preload("res://scripts/core/run/z2_run_hooks.gd")
const Service := preload("res://scripts/core/run/event_service.gd")
const Tutorial := preload("res://scripts/core/run/tutorial_map_catalog.gd")
const Growth := preload("res://scripts/core/progression/z2_progression_rules.gd")
const EXPECTED_EVENTS := ["shop", "savings", "seal", "relief", "first_aid", "consign", "expand", "compress", "trader", "pawn", "information", "shortcut", "demine", "recon", "mechanism", "recycle", "coil", "clock_in", "rps", "cage", "dice", "altar"]
const DIAGONALS := [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]

var checks := 0
var failures: Array[String] = []
var main: Node
var scene
var dismissals := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _check(_isolated_save_directory(), "requires fresh user data under Z2_EVENT_INPUT_QA_HOME"):
		_finish()
		return
	root.size = Vector2i(1280, 720)
	root.content_scale_size = root.size
	_test_level_pools()
	if await _open_main("event_input_tutorial"):
		await _test_tutorial_event_dialogue()
	await _close_main()
	if await _open_main("event_input_level2"):
		await _test_natural_level2_path()
	await _close_main()
	if await _open_main("event_input_stage50"):
		if _start_stage_run():
			await _test_22_event_closures()
			await _test_standard_error_rejection()
			await _test_global_event_cleanup()
			await _test_shortcut_cleanup(false)
			await _test_shortcut_cleanup(true)
	await _close_main()
	if await _open_main("event_input_cage") and _start_stage_run() and _fixture_event("cage"):
		if await _open_world_event(true, "voluntary cage") and await _choose_new("challenge", true, "voluntary cage"):
			_check(scene.in_run_runtime.has_active_combat() and not scene._is_runtime_modal_open(), "accepted cage starts combat and releases dialogue inputs")
			var refused: Dictionary = scene.in_run_runtime.request_flee()
			_check(not refused.get("ok", true) and scene.in_run_runtime.has_active_combat(), "accepted cage remains sealed during real combat")
	await _close_main()
	_finish()


func _isolated_save_directory() -> bool:
	var home := OS.get_environment("Z2_EVENT_INPUT_QA_HOME").simplify_path().replace("\\", "/").trim_suffix("/")
	var user_dir := OS.get_user_data_dir().simplify_path().replace("\\", "/")
	return home.is_absolute_path() and user_dir.to_lower().begins_with(home.to_lower() + "/") \
		and not FileAccess.file_exists("user://saves/manifest.json") \
		and not DirAccess.dir_exists_absolute("user://saves/profiles") \
		and not FileAccess.file_exists("user://graytail_m1_meta_progress.json")


func _test_level_pools() -> void:
	var expected_by_level := {
		6: ["information", "relief", "first_aid", "recycle", "demine"],
		7: ["information", "relief", "first_aid", "recycle", "demine", "shop"],
		26: EXPECTED_EVENTS, 50: EXPECTED_EVENTS,
	}
	for level: int in expected_by_level:
		var pool: Array = Events.event_pool({"profile_level": level})
		var expected: Array = expected_by_level[level]
		var ids: Array = []
		var total_weight := 0.0
		var total_probability := 0.0
		for entry: Dictionary in pool:
			ids.append(str(entry.get("event_type", "")))
			total_weight += float(entry.get("roll_weight", 0.0))
			total_probability += float(entry.get("probability", 0.0))
			_check(is_equal_approx(float(entry.get("roll_weight", 0.0)), 29.0 / expected.size()), "Lv%d equal normalized event weight: %s" % [level, entry.get("event_type", "")])
			_check(is_equal_approx(float(entry.get("probability", 0.0)), 1.0 / expected.size()), "Lv%d equal event probability: %s" % [level, entry.get("event_type", "")])
			if str(entry.get("event_type", "")) == "shop":
				_check(int(entry.get("min_level", 0)) == 7, "exploration shop advertises minimum Lv7")
		ids.sort()
		var sorted_expected := expected.duplicate()
		sorted_expected.sort()
		_check(ids == sorted_expected, "Lv%d exact unique event pool" % level)
		_check(is_equal_approx(total_weight, 29.0) and is_equal_approx(total_probability, 1.0), "Lv%d normalized total29/probability1" % level)
	_check(Events.event_pool({"profile_level": 0}).size() == 4, "Lv0 has four teaching events")
	# Real seeded assignment, not just a projected min-level label. This fixture
	# deliberately bypasses profile growth; it changes no shop goods/camp pool.
	for level in [6, 7]:
		var context := RunContext.new()
		var profile := {"ruleset_id": "z2", "z2_progression_version": 1, "content_eligibility": {"profile_level": level}}
		context.start_run({"id": "event_level_fixture", "width": 5, "height": 5, "profile_fields": profile,
			"run_start_config": {"profile_fields": profile}, "manual_map": {"spawn": Vector2i.ZERO}})
		var saw_shop := false
		for seed_pick in range(128):
			context.z1_event_rooms.clear()
			context.seed_value = seed_pick
			var assigned: Dictionary = Events.select_event(context, Vector2i(2, 2))
			_check(bool(assigned.get("ok", false)), "Lv%d actual event assignment seed%d" % [level, seed_pick])
			var is_shop := str(assigned.get("event_type", "")) == "shop"
			saw_shop = saw_shop or is_shop
			if level == 6:
				_check(not is_shop, "Lv6 cannot assign shop seed%d" % seed_pick)
		_check(saw_shop == (level == 7), "shop unreachable at Lv6 and reachable at Lv7: Lv%d" % level)


func _open_main(profile_id: String) -> bool:
	var manager := SaveManager.new()
	manager.load_manifest()
	if not _check(manager.switch_profile(profile_id).get("ok", false) and manager.save_manifest().get("ok", false), "select isolated regression profile " + profile_id):
		return false
	main = (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	current_scene = main
	scene = main.get_node("RunScene")
	# Only explicit production frame calls advance gameplay time in this runner.
	scene.set_process(false)
	await process_frame
	scene.z2_event_adapter.dismissed.connect(func() -> void: dismissals += 1)
	return _check(scene.runtime_controller.checkpoint_service != null and scene.runtime_controller.persistence_error.is_empty(), "real Main owns profile/checkpoint services " + profile_id)


func _close_main() -> void:
	if not is_instance_valid(main):
		return
	var streams: Array[WeakRef] = []
	for child in scene.player_feedback_service.get_children():
		if child is AudioStreamPlayer and child.stream != null:
			streams.append(weakref(child.stream))
			child.stop()
			child.stream = null
	scene.in_run_runtime.bind(null)
	scene.command_bus.bind_runtime_controller(null)
	main.queue_free()
	await process_frame
	await _until(func() -> bool: return streams.all(func(stream: WeakRef) -> bool: return stream.get_ref() == null), "feedback streams release on Main teardown")
	main = null
	scene = null


func _test_tutorial_event_dialogue() -> void:
	var start: Dictionary = _command(&"start_standard_run", {"run_start_config": {"map_config_id": Tutorial.MAP_ID, "difficulty": "tutorial"}})
	if not _check(start.get("ok", false) and scene.run_context.mode == &"tutorial" and scene._show_run_screen(), "actual fresh-profile tutorial admission; result=%s meta_error=%s" % [str(start), scene.meta_progress_adapter.last_error]):
		return
	var context: RunContext = scene.run_context
	_check(Events.applies_to(context) and not Hooks.applies_to(context), "teaching uses complete events with isolated growth and opening hooks")
	_check(_has_z2_profile(context.profile_fields) and _has_z2_profile(context.run_start_config.get("profile_fields", {})), "both teaching profiles preserve Z2 identity")
	_close_tutorial_prompt()
	var moved: Dictionary = _command(&"attempt_room_transition", {"direction": Vector2i.DOWN})
	if not _check(moved.get("ok", false) and context.event_state.get("event_type") == "information", "first event is the prepared teaching information desk"):
		return
	_close_tutorial_prompt()
	for mode in ["button", "escape", "leave"]:
		if await _open_world_event(true, "teaching information " + mode):
			await _close_open_event(mode, true, "teaching information " + mode)
	var invalid := Events.public_state(context, context.get_current_pos(), "invalid_event_id")
	scene._show_event_panel(invalid)
	_check(not scene._runtime_modal_is_top(&"event") and not scene.event_panel.visible, "an invalid Z2 projection never mounts a legacy teaching panel")
	if await _open_world_event(true, "teaching information actual operation"):
		if await _choose_new("mine_count", false, "teaching information"):
			_key(KEY_ESCAPE)
			await _assert_recovered("completed free teaching query")


func _has_z2_profile(profile: Dictionary) -> bool:
	return str(profile.get("ruleset_id", "")) == "z2" and int(profile.get("z2_progression_version", 0)) == 1


func _close_tutorial_prompt() -> void:
	if scene.run_context.tutorial_popup.is_empty():
		return
	var button := scene.tutorial_popup_panel.find_child("ConfirmButton", true, false) as Button
	if _check(button != null and button.is_visible_in_tree(), "actual tutorial guidance exposes its independent details control"):
		var meta_before: Dictionary = scene.meta_progress_adapter.data.duplicate(true)
		if not scene.tutorial_popup_panel.layout_snapshot().get("guidance_expanded", false):
			button.pressed.emit()
		button.pressed.emit()
		_check(scene.run_context.tutorial_popup.is_empty() and not scene.run_context.has_blocking_tutorial_popup() and scene.meta_progress_adapter.data == meta_before, "details expand/collapse dismisses guidance without purchasing")


func _test_natural_level2_path() -> void:
	print("Z2_EVENT_INPUT_FIXTURE=Lv2_saved_qualification_not_natural_growth;unaltered_seed7_map_and_event_bindings")
	var meta = scene.meta_progress_adapter
	meta.data.merge({"tutorial_completed": true, "run_count": 5, "profile_level": 2, "profile_exp": Growth.exp_for_level(2),
		"talent_flags": ["z2_talent_01"], "talent_earned": 100, "talent_spent": 100, "talent_points": 0,
		"unlocked_map_ids": ["tutorial_5x5", "classic_7x7_simple"]}, true)
	if not _check(meta.save(), "save validated Lv2 qualification; error=%s" % meta.last_error):
		return
	var start: Dictionary = _command(&"start_standard_run", {"run_start_config": {"map_config_id": "classic_7x7_simple", "difficulty": "simple", "seed_value": 7, "selected_objective_id": "commission_recover_supply"}})
	if not _check(start.get("ok", false) and scene._show_run_screen(), "admit actual seed7 Lv2 exploration"):
		return
	var context: RunContext = scene.run_context
	if not _check(context.seed_value == 7 and context.get_current_pos() == Vector2i(4, 2), "original natural reproduction seed and spawn are unchanged"):
		return
	var topology: Array[StringName] = []
	for y in range(context.truth_map.height):
		for x in range(context.truth_map.width):
			topology.append(context.truth_map.get_room_type(Vector2i(x, y)))
	for target: Vector2i in [Vector2i(4, 3), Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 4)]:
		var moved: Dictionary = _command(&"attempt_room_transition", {"direction": target - context.get_current_pos()})
		if not _check(moved.get("ok", false) and context.get_current_pos() == target, "natural seed7 path enters " + str(target)):
			return
		_check(context.current_room_type == context.truth_map.get_room_type(target), "committed room type agrees with actual map at " + str(target))
		if context.current_room_type == &"Event":
			var state: Dictionary = Service.get_event_state(context, target)
			_check(state.get("ok", false) and str(state.get("ruleset_id", "")) == "z2" and str(state.get("event_type", "")) != "shop", "natural Lv2 event is bound to an eligible non-shop at " + str(target))
			if not await _open_world_event(true, "natural seed7 " + str(target)):
				return
			await _close_open_event("button", true, "natural seed7 " + str(target))
	_check(context.current_room_type == &"Event" and context.z1_event_rooms.has("6,4"), "historically failing natural shop cell commits a complete eligible event")
	var after: Array[StringName] = []
	for y in range(context.truth_map.height):
		for x in range(context.truth_map.width):
			after.append(context.truth_map.get_room_type(Vector2i(x, y)))
	_check(after == topology, "natural regression never edits generated room types or target bindings")
	_check(scene.runtime_controller.persistence_error.is_empty(), "natural Lv2 route keeps durable storage healthy")


func _start_stage_run() -> bool:
	print("Z2_EVENT_INPUT_FIXTURE=Lv50_saved_stage_profile_not_natural_growth;22_atomic_room_presentations")
	var meta = scene.meta_progress_adapter
	meta.data.merge({"tutorial_completed": true, "profile_level": 50, "profile_exp": Growth.exp_for_level(50),
		"talent_flags": ["z2_talent_01"], "talent_earned": 100, "talent_spent": 100, "talent_points": 0,
		"unlocked_map_ids": ["tutorial_5x5", "classic_7x7_simple"]}, true)
	if not _check(meta.save(), "save explicit high-level stage fixture (not natural growth); error=%s" % meta.last_error):
		return false
	var result: Dictionary = _command(&"start_standard_run", {"run_start_config": {"map_config_id": "classic_7x7_simple", "difficulty": "simple", "seed_value": 3141, "selected_objective_id": "commission_recover_supply"}})
	return _check(result.get("ok", false) and scene.run_context.mode != &"tutorial" and Events.applies_to(scene.run_context) and scene._show_run_screen(), "actual ordinary Z2 admission consumes the stage profile")


func _fixture_event(event_id: String, target_kind: StringName = &"Normal") -> bool:
	var context: RunContext = scene.run_context
	var pos := context.get_current_pos()
	var key := context.cell_key(pos)
	var result: Dictionary = scene.runtime_controller.execute_atomic_operation(&"event_input_stage_fixture", {"event": event_id, "target_kind": target_kind}, func() -> Dictionary:
		context.truth_map.set_room_type(pos, &"Event")
		context.current_room_type = &"Event"
		context.phase = &"event"
		context.z1_event_rooms[key] = {"event_type": StringName(event_id)}
		context.interacted_cells.erase(key)
		context.tutorial_popup.clear()
		context.visited_cells[key] = true
		context.intel_map.reveal_cell(pos, context.truth_map)
		if event_id == "shortcut":
			for offset: Vector2i in DIAGONALS:
				if context.is_inside(pos + offset):
					context.truth_map.set_room_type(pos + offset, target_kind)
					context.interacted_cells.erase(context.cell_key(pos + offset))
		if context.asset_ledger.get_currency(&"black_coin") < 100:
			context.asset_ledger.add_currency(&"black_coin", 300, "event_input_stage_fixture")
		context.event_state = Service.get_event_state(context, pos)
		return {"ok": true}
	)
	scene._refresh_view_models()
	return _check(result.get("ok", false), "atomic room fixture " + event_id)


func _test_22_event_closures() -> void:
	var seen: Array[String] = []
	for index in EXPECTED_EVENTS.size():
		var event_id: String = EXPECTED_EVENTS[index]
		if not _fixture_event(event_id):
			return
		if not await _open_world_event(true, event_id):
			return
		seen.append(event_id)
		var mode: String = ["button", "escape", "leave"][index % 3]
		await _close_open_event(mode, true, "Z2 " + event_id + " " + mode)
	_check(seen == EXPECTED_EVENTS and seen.size() == 22, "all22 normal Z2 presentations exercise close -> movement -> actual Esc")


func _test_standard_error_rejection() -> void:
	if not _fixture_event("relief") or not _move_to_event():
		return
	var error_state: Dictionary = Events.public_state(scene.run_context, scene.run_context.get_current_pos(), "unsupported_stage_event")
	_check(error_state.get("ok") == false and not error_state.has("ruleset_id"), "real standard Z2 failure has no presentation ruleset")
	scene._show_event_panel(error_state)
	_check(scene.modal_controller.depth() == 0 and not scene.event_panel.visible and not scene.z2_event_adapter.visible, "standard Z2 error never falls through to legacy or pushes a modal")
	await _assert_recovered("standard Z2 error rejection")


func _test_global_event_cleanup() -> void:
	if not _fixture_event("relief") or not await _open_world_event(true, "global-hide"):
		return
	var before := dismissals
	scene._hide_runtime_popups()
	_check(dismissals == before + 1, "global popup cleanup dismisses the new presentation exactly once")
	await _assert_recovered("global popup cleanup")


func _test_shortcut_cleanup(combat: bool) -> void:
	var tag := "shortcut into combat" if combat else "shortcut across rooms"
	if not _fixture_event("shortcut", &"Monster" if combat else &"Normal") or not await _open_world_event(true, tag):
		return
	if not await _choose_new("prepare", false, tag) or not await _choose_new("preview_target", false, tag):
		return
	var origin: Vector2i = scene.run_context.get_current_pos()
	var state: Dictionary = Service.get_event_state(scene.run_context, origin)
	var target: Variant = state.get("preview", {}).get("target_pos")
	if not _check(target is Vector2i and target != origin, tag + " has an authoritative preview target"):
		return
	if not await _choose_new("travel", true, tag):
		return
	_check(scene.run_context.get_current_pos() == target and scene.run_context.get_current_pos() != origin, tag + " performs real command-driven room entry")
	_check(scene.in_run_runtime.has_active_combat() == combat, tag + " has the expected actual combat state")
	await _assert_recovered(tag)


func _move_to_event() -> bool:
	for entity: Node in scene.room_runtime_view.special_entities.values():
		if str(entity.interaction_kind) == "event":
			scene.player_controller.set_local_position(entity.local_pos)
			scene._process(0.0)
			return true
	return _check(false, "current real room has an event interaction marker")


func _open_world_event(modern: bool, tag: String) -> bool:
	if not _move_to_event():
		return false
	_key(KEY_E)
	if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"event"), tag + " E opens the real event modal"):
		return false
	return _check(scene.z2_event_adapter.is_visible_in_tree() == modern and scene.event_panel.is_visible_in_tree() != modern, tag + " selects exactly one presentation")


func _close_open_event(mode: String, modern: bool, tag: String) -> void:
	var before := dismissals
	if mode == "button":
		var button: Button = scene.z2_event_adapter.dialogue.get_node("%CloseDialogue") if modern else scene.event_choice_panel.find_child("CloseEventOptions", true, false)
		if not _check(button != null and button.is_visible_in_tree(), tag + " exposes its actual close button"):
			return
		button.grab_focus()
		_key(KEY_ENTER)
	elif mode == "escape":
		_key(KEY_ESCAPE)
	elif modern:
		if not await _choose_new("leave", true, tag):
			return
	else:
		if not _activate_legacy_option("leave"):
			return
	await _until(func() -> bool: return not scene._runtime_modal_is_top(&"event"), tag + " pops event")
	_check(dismissals == before + (1 if modern else 0), tag + " emits no recursive/duplicate dialogue dismissal")
	await _assert_recovered(tag)


func _activate_legacy_option(option_id: String) -> bool:
	var options: Array = scene.run_context.event_state.get("options", [])
	for index in options.size():
		if str(options[index].get("id", "")) == option_id:
			var button := scene.event_choice_panel.find_child("EventOption_%d" % index, true, false) as Button
			if not _check(button != null and button.is_visible_in_tree() and not button.disabled, "legacy option is actually actionable: " + option_id):
				return false
			button.grab_focus()
			_key(KEY_ENTER)
			return true
	return _check(false, "missing actual legacy option " + option_id)


func _choose_new(option_id: String, closes: bool, tag: String) -> bool:
	var adapter = scene.z2_event_adapter
	var dialogue = adapter.dialogue
	var steps: int = (dialogue.get("_lines") as Array).size() * 2 + 3
	for step in steps:
		if bool(dialogue.get("_choosing")):
			break
		_key(KEY_SPACE)
	var options: Array = adapter.get("_options")
	for index in options.size():
		if str(options[index].get("id", "")) != option_id:
			continue
		var button: Button = dialogue.get("_buttons")[index]
		if not _check(button.is_visible_in_tree() and not button.disabled, tag + " actual Z2 option " + option_id):
			return false
		button.grab_focus()
		_key(KEY_ENTER)
		var action_id: String = adapter.last_action_id
		_check(not action_id.is_empty() and scene.runtime_controller.action_receipts.has(action_id), tag + " " + option_id + " owns a real committed action receipt")
		if closes:
			_check(not dialogue.is_visible_in_tree() and not scene.event_panel.visible and not scene._runtime_modal_is_top(&"event"), tag + " closes synchronously before the deferred receipt")
			_check(not dialogue.get("_pending_by_room").is_empty(), tag + " preserves pending request until the deferred result releases it")
		if not await _until(func() -> bool: return dialogue.get("_pending_by_room").is_empty(), tag + " deferred " + option_id + " receipt releases request lock"):
			return false
		if closes:
			_check(not dialogue.visible and not adapter.visible, tag + " late receipt does not reopen the presentation")
		return _check(scene.last_command_result.get("ok", false), tag + " actual Z2 action succeeds: " + option_id)
	return _check(false, tag + " missing Z2 option " + option_id)


func _assert_recovered(tag: String) -> void:
	if not await _until(func() -> bool: return not scene._is_runtime_modal_open() and scene.modal_controller.depth() == 0, tag + " has no stale modal authority"):
		return
	_check(not scene.event_panel.visible and not scene.z2_event_adapter.visible and not scene.z2_event_adapter.dialogue.visible and not scene.event_modal_root.visible, tag + " hides both local visible flags, dialogue and modal root")
	var player = scene.player_controller
	var room: Vector2i = scene.run_context.get_current_pos()
	var floor_position: Vector2 = player.place_on_clear_floor(Vector2(0.50, 0.72))
	# Real InputMap movement reaches the production frame/controller; never set
	# input_enabled or the movement result to manufacture recovery.
	Input.action_press(&"move_right")
	scene._process(0.15)
	Input.action_release(&"move_right")
	_check(player.input_enabled and player.get_local_position().x > floor_position.x and scene.run_context.get_current_pos() == room, tag + " actual movement resumes on clear floor")
	_key(KEY_ESCAPE)
	if not await _until(func() -> bool: return scene._runtime_modal_is_top(&"pause"), tag + " actual Esc opens pause after event close"):
		return
	# A repeated/stale event close must not consume the new top modal.
	scene._cancel_event_modal(&"stale_event_close")
	_check(scene._runtime_modal_is_top(&"pause") and scene.modal_controller.depth() == 1, tag + " repeated close cannot double-pop the pause modal")
	_key(KEY_ESCAPE)
	await _until(func() -> bool: return scene.modal_controller.depth() == 0 and not scene.pause_panel.visible, tag + " second actual Esc closes pause once")
	_check(not scene.event_panel.visible and not scene.z2_event_adapter.visible and player.input_enabled, tag + " no event resurrection after Esc cycle")


func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		root.push_input(event, true)


func _command(command: StringName, payload: Dictionary = {}) -> Dictionary:
	return scene._dispatch_command(command, payload, false, false)


func _until(predicate: Callable, label: String, timeout_ms: int = 3000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not bool(predicate.call()) and Time.get_ticks_msec() < deadline:
		await process_frame
	return _check(bool(predicate.call()), label)


func _check(ok: bool, label: String) -> bool:
	checks += 1
	if not ok:
		failures.append(label)
		print("Z2_EVENT_INPUT_RECOVERY_FAIL " + label)
	return ok


func _finish() -> void:
	print("Z2_EVENT_INPUT_RECOVERY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
