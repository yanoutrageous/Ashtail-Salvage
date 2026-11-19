extends SceneTree

const CombatSimulation := preload("res://scripts/gameplay/combat/g41_combat_simulation.gd")
const InRunRuntime := preload("res://scripts/core/run/g41_in_run_runtime.gd")
const RuntimeController := preload("res://scripts/core/run/run_runtime_controller.gd")

class TransitionDiskAdapter extends SaveAdapter:
	var checkpoint_writes := 0
	var fail_on_write := 0
	func save_json(data: Dictionary, path: String = M1_META_PROGRESS_PATH, normalize_meta_progress: bool = true) -> bool:
		if path.ends_with("/run_checkpoint.json"):
			checkpoint_writes += 1
		return super.save_json(data, path, normalize_meta_progress)
	func _rename_file(source_path: String, target_path: String) -> bool:
		if checkpoint_writes == fail_on_write and source_path.ends_with("/run_checkpoint.json.tmp"):
			return false
		return super._rename_file(source_path, target_path)

var failures: Array[String] = []
var checks: int = 0
var fail_writes: bool = false
var write_attempts: Array[Dictionary] = []
var state_signals: int = 0
var result_signals: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if "--async-hit-disk-only" in OS.get_cmdline_user_args():
		await _test_axe_hit_disk_rollback(true)
		_finish()
		return
	if "--hit-disk-only" in OS.get_cmdline_user_args():
		await _test_axe_hit_disk_rollback()
		_finish()
		return
	if "--flee-position-only" in OS.get_cmdline_user_args():
		root.size = Vector2i(1280, 720)
		await _test_flee_position_handoff()
		_finish()
		return
	if "--transition-disk-only" in OS.get_cmdline_user_args():
		await _test_transition_disk_boundaries()
		_finish()
		return
	var simulation = CombatSimulation.new()
	var bridge = InRunRuntime.new()
	var simulation_ready: bool = simulation.has_method("export_transaction_state") and simulation.has_method("import_transaction_state")
	var bridge_ready: bool = bridge.has_method("export_transaction_state") and bridge.has_method("import_transaction_state")
	_check(simulation_ready, "simulation must expose complete transaction restore, not a display snapshot")
	_check(bridge_ready, "bridge must restore null/live encounter state and sequences")
	if simulation_ready:
		_test_simulation_roundtrip()
		_test_restore_replays_future()
	_test_inactive_catchup_stops()
	_test_same_step_terminal_priority()
	if simulation_ready and bridge_ready:
		_test_bridge_roundtrip()
		_test_malformed_checkpoint_rejection()
		_test_live_snapshot_validation()
	if not "--snapshot-only" in OS.get_cmdline_user_args():
		var runtime = RuntimeController.new()
		_check(runtime.has_method("execute_atomic_operation"), "parent real atomic runtime API required for save rollback")
		_check(runtime.has_method("apply_combat_hit"), "parent immediate hit resolver API required for shield/life-save")
		var parent_ready: bool = runtime.has_method("execute_atomic_operation") and runtime.has_method("apply_combat_hit")
		var atomic_ready: bool = runtime.has_method("execute_atomic_operation")
		_release(runtime)
		if atomic_ready and simulation_ready and bridge_ready:
			_test_attack_step_rollback()
			_test_empty_step_does_not_save()
			_test_duplicate_tick_receipt()
		if parent_ready and simulation_ready and bridge_ready:
			_test_save_failure_rollback_and_retry()
			_test_catchup_equivalence()
			_test_shield_and_single_survival()
			_test_terminal_runtime_priority()
			_test_terminal_step_rollback()
			_test_status_time_inside_step()
			_test_waiting_status_starts_on_attack()
			_test_lethal_status_precedes_physics()
		await _test_transition_disk_boundaries()
	_finish()


func _test_transition_disk_boundaries() -> void:
	root.size = Vector2i(1280, 720)
	_test_limited_transition_runtime()
	await _test_flee_then_transition_disk_failure()
	await _test_first_transition_checkpoint(&"Normal", Vector2i.RIGHT)
	await _test_first_transition_checkpoint(&"Monster", Vector2i.DOWN)
	await _test_shortcut_transition_checkpoint(&"select_event_option")
	await _test_shortcut_transition_checkpoint(&"interact_current_room")
	await _test_shortcut_transition_checkpoint(&"interact_current_room", false, &"Normal")
	await _test_shortcut_transition_checkpoint(&"select_event_option", true, &"Normal")
	await _test_shortcut_transition_checkpoint(&"select_event_option", true, &"Monster")
	await _test_flee_position_handoff()
	await _test_axe_hit_disk_rollback()


func _test_axe_hit_disk_rollback(background := false) -> void:
	_new_transition_profile("axe_hit_rollback")
	var main := await _open_transition_scene()
	var scene = main.get_node("RunScene")
	_prepare_transition_scene(scene, &"Monster", &"Normal", Vector2i.RIGHT)
	var runtime = scene.runtime_controller
	if background:
		_check("background_axe_checkpoints" in runtime, "disk axe: production can queue an asynchronous checkpoint")
		if not "background_axe_checkpoints" in runtime:
			_discard_transition_scene(main)
			return
		runtime.background_axe_checkpoints = true
	var bridge = runtime.in_run_runtime
	var sim: G41CombatSimulation = bridge.simulation
	sim.player["pos"] = Vector2(0.35, 0.77)
	sim.player["invulnerability"] = 3.0
	sim.previous_player_pos = sim.player["pos"]
	sim.enemies[0]["pos"] = Vector2(0.50, 0.77)
	sim.enemies[0]["entry_grace_remaining"] = 3.0
	sim.enemies[0]["hp"] = 900
	sim.enemies[0]["max_hp"] = 900
	_check(bool(bridge.request_attack(Vector2.RIGHT).get("ok", false)), "disk axe: windup accepted")
	for attempt in 20:
		if sim.player.get("state") == &"attack_active":
			var elapsed_next := (sim.tick_index - int(sim.active_player_attack.get("active_started_tick", sim.tick_index)) + 2) * CombatSimulation.FIXED_STEP
			if elapsed_next + CombatSimulation.EPSILON >= sim._attack_seconds(CombatSimulation.PLAYER_ATTACK_IMPACT_SECONDS):
				break
		bridge.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	_check(sim.player.get("state") == &"attack_active" and not sim.active_player_attack.get("resolved", false), "disk axe: positioned before first contact")
	sim.accumulator = CombatSimulation.FIXED_STEP
	var before: Dictionary = runtime.capture_authoritative_state()
	var checkpoint: String = runtime.checkpoint_service.checkpoint_path
	var previous_bytes := FileAccess.get_file_as_bytes(checkpoint)
	var blocker := ProjectSettings.globalize_path(checkpoint + ".tmp")
	_check(DirAccess.make_dir_absolute(blocker) == OK, "disk axe: real temporary-write failure armed")
	state_signals = 0
	runtime.command_bus.state_changed.connect(func(_snapshot): state_signals += 1)
	var failed: Dictionary = bridge._commit_fixed_step(sim)
	if background:
		_check(failed.get("status") == &"checkpoint_pending" and runtime.has_pending_combat_save(),
			"disk axe: hit yields to the caller while the worker writes")
		_check(runtime.capture_authoritative_state() == before and state_signals == 0,
			"disk axe: pending hit does not publish or mutate authority")
		var competing: Dictionary = runtime.execute_atomic_operation(&"other", {}, func(): return {"ok": true})
		_check(competing.get("status") == &"checkpoint_pending", "disk axe: concurrent command cannot overwrite the pending revision")
		failed = runtime.finish_pending_combat_save(true)
	_check(failed.get("status") == &"save_failed" and not runtime.persistence_error.is_empty(), "disk axe: real writer rejects the hit")
	_check(runtime.capture_authoritative_state() == before and state_signals == 0, "disk axe: failed hit rolls back with no published frame")
	_check(FileAccess.get_file_as_bytes(checkpoint) == previous_bytes, "disk axe: previous checkpoint is byte-identical after failed hit")
	_check(DirAccess.remove_absolute(blocker) == OK, "disk axe: clear temporary-write failure")
	var retried: Dictionary = runtime.retry_persistence()
	_check(bool(retried.get("ok", false)), "disk axe: recovery allows retry")
	var old_revision: int = runtime.transaction_revision
	state_signals = 0
	var committed: Dictionary = bridge._commit_fixed_step(sim)
	if background:
		_check(committed.get("status") == &"checkpoint_pending", "disk axe: retry uses the background writer")
		committed = runtime.save_current_checkpoint()
	_check(bool(committed.get("ok", false)) and runtime.transaction_revision == old_revision + 1 and state_signals == 1,
		"disk axe: retry commits exactly one revision and publishes once")
	var hp := int(sim.enemies[0]["hp"])
	_check(hp < 900 and _count_events(bridge.recent_domain_events, &"enemy_damaged") == 1, "disk axe: damage applied exactly once")
	var completed: Dictionary = runtime.capture_authoritative_state()
	_discard_transition_scene(main)
	main = await _open_transition_scene()
	var restored = main.get_node("RunScene").runtime_controller
	_check(restored.persistence_error.is_empty() and restored.in_run_runtime.has_active_combat(), "disk axe: committed checkpoint reloads")
	if restored.in_run_runtime.has_active_combat():
		_check(int(restored.in_run_runtime.simulation.enemies[0]["hp"]) == hp, "disk axe: reload preserves the exact damaged HP")
		_check(restored.capture_authoritative_state() == completed, "disk axe: every authoritative field matches disk after live commit")
	_discard_transition_scene(main)


func _test_limited_transition_runtime() -> void:
	var bus := CommandBus.new()
	bus.context = RunContext.new()
	bus.context.start_run({"id": "limited_transition", "seed": 348, "width": 5, "height": 5,
		"manual_map": {"spawn": Vector2i.ZERO, "monsters": [Vector2i(1, 0)], "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit"}]}})
	bus.runtime_controller = RefCounted.new() # Deliberately has no optional room/combat API.
	_check(bool(bus.dispatch(&"move_by", {"delta": Vector2i.RIGHT}).get("ok", false)), "limited runtime remains compatible with room movement")
	bus.context.asset_ledger.add_currency(&"black_coin", 100)
	for index in range(32):
		bus.context.asset_ledger.create_item_instance(M3RItemUsabilityModel.item_definition("col_01"), &"inventory")
	_check(bool(bus.dispatch(&"flee_runtime_combat", {"source": "g41_in_run_runtime"}).get("ok", false)), "limited runtime remains compatible with legacy flee resolution")
	_check(bus.context.asset_ledger.get_currency(&"black_coin") == 90, "legacy flee compatibility retains exactly one ten-coin charge")
	_check(not bus.context.asset_ledger.get_room_floor_items(Vector2i(1, 0)).is_empty(), "legacy flee compatibility still exercises actual instance drops")


func _new_transition_profile(label: String) -> void:
	var manager := SaveManager.new()
	manager.switch_profile("transition_%s_%d" % [label, Time.get_ticks_usec()])
	var meta := MetaProgressAdapter.new()
	manager.configure_meta_adapter(meta)
	_check(bool(meta.initialize_z2_profile(RuntimeController.Z2_CONTENT_VERSION).get("ok", false)), label + ": real profile created")
	_check(meta.begin_tutorial_training().get("ok", false), label + ": teaching eligibility begins")
	_check(meta.purchase_tutorial_flag().get("ok", false), label + ": teaching purchase persists")
	_check(meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "transition-teaching-" + label).get("ok", false), label + ": legal teaching qualification persists")
	_check(bool(manager.save_manifest().get("ok", false)), label + ": profile selected on disk")


func _open_transition_scene() -> Node:
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.get_node("RunScene").set_process(false)
	await process_frame
	return main


func _discard_transition_scene(main: Node) -> void:
	var runtime = main.get_node("RunScene").runtime_controller
	main.free() # Abrupt teardown: deliberately no close/save callback.
	_release(runtime)


func _prepare_transition_scene(scene, source_type: StringName, target_type: StringName, direction: Vector2i) -> void:
	var config := RunStartConfig.default_config()
	config.merge({"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": 71}, true)
	config.selected_objective_id = M7ContentCatalog.commission_offer_candidates("classic_7x7_simple", 0)[0].id
	_check(bool(scene.command_bus.dispatch(&"start_standard_run", {"run_start_config": config}).get("ok", false)), "transition fixture: real standard admission")
	var context = scene.run_context
	var source := Vector2i(2, 2)
	context.tutorial_popup.clear()
	context.truth_map.set_room_type(source, source_type)
	context.truth_map.set_room_type(source + direction, target_type)
	context.player_pos = source
	context.current_pos = source
	context.intel_map.reveal_cell(source, context.truth_map)
	context.intel_map.reveal_cell(source + direction, context.truth_map)
	scene.command_bus.room_resolver.enter_room(context)
	var exit_position := Vector2(0.93, 0.5) if direction == Vector2i.RIGHT else Vector2(0.5, 0.93)
	scene.player_controller.set_local_position(exit_position)
	scene.runtime_controller.update_player_location(exit_position)
	scene.in_run_runtime.sync_room(exit_position)
	scene._show_run_screen()
	scene._reset_transition_rejection_debounce()
	_check(bool(scene.runtime_controller.save_current_checkpoint().get("ok", false)), "transition fixture: pre-action disk checkpoint")


func _read_transition_checkpoint(runtime, label: String) -> Dictionary:
	var loaded: Dictionary = runtime.checkpoint_service.load_checkpoint()
	_check(bool(loaded.get("ok", false)), label + ": actual checkpoint service reads disk")
	if not bool(loaded.get("ok", false)):
		return {}
	var decoded := RunStateSnapshot.unpack_checkpoint(loaded["snapshot"]["state"])
	_check(bool(decoded.get("ok", false)), label + ": actual checkpoint decodes")
	var proof_path: String = runtime.checkpoint_service.checkpoint_path.get_base_dir().path_join(label + "-proof.json")
	var proof := FileAccess.open(proof_path, FileAccess.WRITE)
	proof.store_string(FileAccess.get_file_as_string(runtime.checkpoint_service.checkpoint_path))
	proof.close()
	print("Z2_TRANSITION_DISK_PROOF=" + ProjectSettings.globalize_path(proof_path))
	return decoded.get("state", {})


func _test_flee_then_transition_disk_failure() -> void:
	_new_transition_profile("flee")
	var main := await _open_transition_scene()
	var scene = main.get_node("RunScene")
	_prepare_transition_scene(scene, &"Monster", &"Normal", Vector2i.RIGHT)
	var runtime = scene.runtime_controller
	var context = runtime.context
	context.asset_ledger.add_currency(&"black_coin", 100 - context.asset_ledger.get_currency(&"black_coin"), "transition_fixture")
	for index in range(16):
		context.asset_ledger.create_item_instance(M3RItemUsabilityModel.item_definition("col_01"), &"inventory")
	context.asset_ledger.sync_compat_fields(context)
	_check(bool(runtime.save_current_checkpoint().get("ok", false)), "flee fixture: coins/items saved before either action")
	var disk := TransitionDiskAdapter.new()
	disk.fail_on_write = 2
	runtime.checkpoint_service.save_adapter = disk
	var fled: Dictionary = scene.in_run_runtime.request_flee()
	_check(bool(fled.get("ok", false)) and disk.checkpoint_writes == 1, "flee: first real checkpoint succeeds")
	var first := _read_transition_checkpoint(runtime, "flee-success")
	_check(first.get("bridge", {}).get("flee_authorized", false) and first.get("bridge", {}).get("simulation") == null, "flee: first checkpoint includes authorization and cleared simulation")
	_check(context.asset_ledger.get_currency(&"black_coin") == 100, "flee: Z2 ordinary flee preserves all 100 coins")
	var items: Dictionary = context.asset_ledger.item_instances.duplicate(true)
	var floor_items: Dictionary = context.asset_ledger.room_floor_items.duplicate(true)
	_check(context.asset_ledger.get_room_floor_items(Vector2i(2, 2)).is_empty() and context.asset_ledger.get_items_by_location(&"inventory").size() == 16, "Z2 flee retains all sixteen instances without floor drops")
	var first_bytes := FileAccess.get_file_as_bytes(runtime.checkpoint_service.checkpoint_path)
	var authorized: Dictionary = runtime.capture_authoritative_state()
	scene._attempt_room_transition(Vector2i.RIGHT)
	_check(disk.checkpoint_writes == 2 and not runtime.persistence_error.is_empty(), "flee: cut the second actual checkpoint rename")
	_check(runtime.capture_authoritative_state() == authorized, "flee: failed crossing rolls back to committed authorization")
	_check(FileAccess.get_file_as_bytes(runtime.checkpoint_service.checkpoint_path) == first_bytes, "flee: failed crossing leaves first checkpoint byte-identical")
	_discard_transition_scene(main)
	main = await _open_transition_scene()
	scene = main.get_node("RunScene")
	runtime = scene.runtime_controller
	_check(runtime.persistence_error.is_empty() and scene.in_run_runtime.flee_authorized and not scene.in_run_runtime.has_active_combat(), "flee: disk-only restart retains authorization without restarting combat")
	_check(runtime.context.asset_ledger.get_currency(&"black_coin") == 100 and runtime.context.asset_ledger.item_instances == items and runtime.context.asset_ledger.room_floor_items == floor_items, "flee: restart preserves coins and each instance location")
	scene._show_run_screen()
	scene._attempt_room_transition(Vector2i.RIGHT)
	_check(runtime.context.get_current_pos() == Vector2i(3, 2), "flee: restarted authorized run crosses without another flee")
	_check(runtime.context.asset_ledger.get_currency(&"black_coin") == 100 and runtime.context.asset_ledger.item_instances == items and runtime.context.asset_ledger.room_floor_items == floor_items, "flee: retry crossing cannot duplicate fees or instances")
	var completed := _read_transition_checkpoint(runtime, "flee-crossed")
	_check(completed.get("bridge", {}).get("current_room_key", "") == "3,2" and not completed.get("bridge", {}).get("flee_authorized", true), "flee: successful crossing durably consumes room-specific authorization")
	_discard_transition_scene(main)


func _test_flee_position_handoff() -> void:
	_new_transition_profile("flee_position")
	var main := await _open_transition_scene()
	var scene = main.get_node("RunScene")
	_prepare_transition_scene(scene, &"Normal", &"Monster", Vector2i.RIGHT)
	var runtime = scene.runtime_controller
	var context = runtime.context
	var combat_room := Vector2i(3, 2)
	var next_room := Vector2i(3, 1)
	context.truth_map.set_room_type(next_room, &"Normal")
	context.intel_map.reveal_cell(next_room, context.truth_map)
	context.asset_ledger.add_currency(&"black_coin", 100 - context.asset_ledger.get_currency(&"black_coin"), "flee_position_fixture")
	for index in range(16):
		context.asset_ledger.create_item_instance(M3RItemUsabilityModel.item_definition("col_01"), &"inventory")
	context.asset_ledger.sync_compat_fields(context)
	scene._attempt_room_transition(Vector2i.RIGHT)
	_check(context.get_current_pos() == combat_room and scene.in_run_runtime.has_active_combat(), "flee position: actual door entry starts combat")
	var entry_a: Vector2 = runtime.capture_authoritative_state()["local_position"]
	_check(entry_a == scene.in_run_runtime.get_player_local_position(Vector2.ZERO), "flee position: runtime and combat initially share entrance A")
	context.tutorial_popup.clear()
	scene._show_run_screen()
	for enemy in scene.in_run_runtime.simulation.enemies:
		enemy["entry_grace_remaining"] = 60.0
	# Walk around the altar through real fixed-step movement. Never assign the
	# simulation position or update runtime's local position to the exit B.
	for waypoint: Vector2 in [Vector2(entry_a.x, 0.26), Vector2(0.50, 0.26), Vector2(0.50, 0.075)]:
		for step in range(240):
			var offset: Vector2 = waypoint - scene.in_run_runtime.get_player_local_position(entry_a)
			if offset.length() <= 0.005:
				break
			scene.in_run_runtime.advance_frame(CombatSimulation.FIXED_STEP, offset.normalized(), offset.normalized())
		_check(scene.in_run_runtime.get_player_local_position(entry_a).distance_to(waypoint) <= 0.005, "flee position: real combat movement reaches waypoint " + str(waypoint))
	var exit_b: Vector2 = scene.in_run_runtime.get_player_local_position(entry_a)
	print("Z2_FLEE_POSITION entry_a=%s combat_b=%s cached_runtime=%s tick=%d" % [entry_a, exit_b, runtime.capture_authoritative_state()["local_position"], scene.in_run_runtime.simulation.tick_index])
	scene.player_controller.set_local_position(exit_b) # Read-only combat projection, as Scene does.
	_check(exit_b.distance_to(entry_a) > 0.3 and scene.player_controller.requested_transition(Vector2.UP) == Vector2i.UP, "flee position: B is a different valid door reached by combat movement")
	_check(runtime.capture_authoritative_state()["local_position"] == entry_a, "flee position: fixture retains stale runtime A until the handoff")
	_check(runtime.persistence_error.is_empty() and scene.in_run_runtime.simulation.tick_index > 0, "flee position: actual atomic combat steps completed before either tested action")
	var disk := TransitionDiskAdapter.new()
	disk.fail_on_write = 2
	runtime.checkpoint_service.save_adapter = disk
	var fled: Dictionary = scene.in_run_runtime.request_flee()
	_check(bool(fled.get("ok", false)) and disk.checkpoint_writes == 1, "flee position: original flee action saves once")
	var checkpoint := _read_transition_checkpoint(runtime, "flee-position-success")
	_check(checkpoint.get("local_position") == exit_b and checkpoint.get("bridge", {}).get("simulation") == null, "flee position: first disk snapshot hands B off before clearing simulation")
	_check(checkpoint.get("bridge", {}).get("flee_authorized", false) and context.asset_ledger.get_currency(&"black_coin") == 100, "flee position: authorization and unchanged wallet share the checkpoint")
	var items: Dictionary = context.asset_ledger.item_instances.duplicate(true)
	var floor_items: Dictionary = context.asset_ledger.room_floor_items.duplicate(true)
	_check(context.asset_ledger.get_room_floor_items(combat_room).is_empty() and context.asset_ledger.get_items_by_location(&"inventory").size() == 16, "flee position: Z2 preserves all sixteen inventory instances")
	var first_bytes := FileAccess.get_file_as_bytes(runtime.checkpoint_service.checkpoint_path)
	scene._attempt_room_transition(Vector2i.UP)
	_check(disk.checkpoint_writes == 2 and not runtime.persistence_error.is_empty() and context.get_current_pos() == combat_room, "flee position: precisely the following crossing save fails")
	_check(FileAccess.get_file_as_bytes(runtime.checkpoint_service.checkpoint_path) == first_bytes, "flee position: failed crossing preserves first checkpoint bytes")
	_check(scene.persistence_controller.present_error(), "flee position: real retry UI presents the storage failure")
	scene.persistence_controller.persistence_retry_button.pressed.emit()
	_check(runtime.persistence_error.is_empty() and not scene.persistence_controller.persistence_error_panel.visible, "flee position: real retry button recovers in the same process")
	_check(scene.player_controller.get_local_position() == exit_b and runtime.get_restored_local_position(Vector2.ZERO) == exit_b, "flee position: same-process retry restores B, not entrance A")
	_check(scene.in_run_runtime.flee_authorized and not scene.in_run_runtime.has_active_combat() and context.asset_ledger.get_currency(&"black_coin") == 100 and context.asset_ledger.item_instances == items and context.asset_ledger.room_floor_items == floor_items, "flee position: retry preserves authorization, unchanged wallet and exact instance locations")
	_check(disk.checkpoint_writes == 2 and FileAccess.get_file_as_bytes(runtime.checkpoint_service.checkpoint_path) == first_bytes, "flee position: retry did not repair position with an extra save")
	_discard_transition_scene(main)
	main = await _open_transition_scene()
	scene = main.get_node("RunScene")
	runtime = scene.runtime_controller
	_check(runtime.persistence_error.is_empty() and scene.run_context.get_current_pos() == combat_room, "flee position: immediate Main restart recovers the same room")
	_check(scene.player_controller.get_local_position() == exit_b and runtime.get_restored_local_position(Vector2.ZERO) == exit_b, "flee position: disk-only restart restores B, not entrance A")
	_check(scene.in_run_runtime.flee_authorized and not scene.in_run_runtime.has_active_combat() and runtime.context.asset_ledger.get_currency(&"black_coin") == 100 and runtime.context.asset_ledger.item_instances == items and runtime.context.asset_ledger.room_floor_items == floor_items, "flee position: restart preserves permission and all coins exactly")
	scene._show_run_screen()
	scene._attempt_room_transition(Vector2i.UP)
	_check(runtime.context.get_current_pos() == next_room and runtime.context.asset_ledger.get_currency(&"black_coin") == 100 and runtime.context.asset_ledger.item_instances == items and runtime.context.asset_ledger.room_floor_items == floor_items, "flee position: restarted run crosses without another fee or item loss")
	var sounds: Array[WeakRef] = []
	for child in scene.player_feedback_service.get_children():
		if child is AudioStreamPlayer and child.stream != null:
			sounds.append(weakref(child.stream))
			child.stop()
			child.stream = null
	_discard_transition_scene(main)
	# The final successful crossing starts click audio. Let the audio thread
	# release its playback after teardown; no Scene or save remains alive.
	var deadline := Time.get_ticks_msec() + 1000
	while sounds.any(func(sound: WeakRef) -> bool: return sound.get_ref() != null) and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not sounds.any(func(sound: WeakRef) -> bool: return sound.get_ref() != null), "flee position: final Scene audio teardown completes")


func _test_first_transition_checkpoint(target_type: StringName, direction: Vector2i) -> void:
	var label := "entry_" + String(target_type).to_lower()
	_new_transition_profile(label)
	var main := await _open_transition_scene()
	var scene = main.get_node("RunScene")
	_prepare_transition_scene(scene, &"Normal", target_type, direction)
	var runtime = scene.runtime_controller
	var before_revision: int = runtime.transaction_revision
	var disk := TransitionDiskAdapter.new()
	runtime.checkpoint_service.save_adapter = disk
	scene._attempt_room_transition(direction)
	var target := Vector2i(2, 2) + direction
	_check(bool(scene.last_command_result.get("ok", false)) and runtime.context.get_current_pos() == target, label + ": formal Scene transition succeeds")
	_check(disk.checkpoint_writes == 1 and runtime.transaction_revision == before_revision + 1, label + ": exactly one original action checkpoint, no follow-up save")
	var position: Vector2 = scene.player_controller.get_local_position()
	_check(position.x < 0.4 if direction.x > 0 else position.y < 0.4, label + ": player lands at the destination entrance")
	var checkpoint := _read_transition_checkpoint(runtime, label)
	_check(checkpoint.get("context", {}).get("data", {}).get("current_pos") == target and checkpoint.get("local_position") == position, label + ": first disk checkpoint pairs new room with its actual entry position")
	var bridge_state: Dictionary = checkpoint.get("bridge", {})
	_check(bridge_state.get("current_room_key", "") == runtime.context.cell_key(target), label + ": first disk checkpoint contains destination bridge")
	if target_type == &"Monster":
		var combat: Variant = bridge_state.get("simulation")
		_check(combat is Dictionary and combat.get("player", {}).get("pos") == position and combat.get("tick_index", -1) == 0, label + ": first disk checkpoint contains initialized destination encounter at entry")
		_check(bridge_state.get("encounter_ordinals", {}).get(runtime.context.cell_key(target), 0) == 1, label + ": first encounter identity saved once")
	else:
		_check(bridge_state.get("simulation") == null, label + ": ordinary destination has no stale combat")
	_discard_transition_scene(main)
	main = await _open_transition_scene()
	scene = main.get_node("RunScene")
	_check(scene.runtime_controller.persistence_error.is_empty() and scene.run_context.get_current_pos() == target and scene.player_controller.get_local_position() == position, label + ": immediate disk-only restart recovers destination entrance")
	_check(scene.in_run_runtime.export_transaction_state() == bridge_state, label + ": restart does not rebuild a different bridge or encounter")
	_discard_transition_scene(main)


func _test_shortcut_transition_checkpoint(command: StringName, via_ui: bool = false, target_type: StringName = &"Monster") -> void:
	var label := String(command) + ("_ui_" if via_ui else "_") + String(target_type)
	_new_transition_profile(label)
	var main := await _open_transition_scene()
	var scene = main.get_node("RunScene")
	_prepare_transition_scene(scene, &"Event", &"Normal", Vector2i.RIGHT)
	var runtime = scene.runtime_controller
	var context = runtime.context
	context.z1_event_rooms[context.cell_key(context.get_current_pos())] = {"event_type": &"z1_event_e16"}
	context.asset_ledger.add_currency(&"black_coin", 100, "shortcut_fixture")
	context.asset_ledger.sync_compat_fields(context)
	var prepared: Dictionary = scene._dispatch_command(command) if command == &"interact_current_room" else scene.command_bus.dispatch(&"select_event_option", {"option_id": &"prepare"})
	_check(prepared.get("ok", false), label + ": real shortcut quote prepared through its original entry route")
	var options: Array = EventService.get_event_state(context, context.get_current_pos()).get("options", [])
	var preview: Dictionary = options.filter(func(option: Dictionary) -> bool: return option.id == &"preview_target")[0]
	var target: Vector2i = preview.payload.target_pos
	context.truth_map.set_room_type(target, target_type)
	var preview_payload: Dictionary = preview.payload.duplicate(true)
	preview_payload["option_id"] = &"preview_target"
	_check(scene.command_bus.dispatch(&"select_event_option", preview_payload).get("ok", false), label + ": actual target preview precedes travel")
	options = EventService.get_event_state(context, context.get_current_pos()).get("options", [])
	var travel: Dictionary = options.filter(func(option: Dictionary) -> bool: return option.id == &"travel")[0]
	var travel_payload: Dictionary = travel.payload.duplicate(true)
	travel_payload["option_id"] = &"travel"
	if via_ui:
		scene._apply_full_view_models()
		var projection := G41WorldObjectProjection.build(context.get_status_snapshot())
		for object: Dictionary in projection["world_objects"]:
			if StringName(object.get("interaction_kind", &"")) == &"event":
				scene.player_controller.set_local_position(Vector2(object["local_pos"]))
				runtime.update_player_location(scene.player_controller.get_local_position())
	_check(bool(runtime.save_current_checkpoint().get("ok", false)), "shortcut fixture: disk state before action")
	var disk := TransitionDiskAdapter.new()
	runtime.checkpoint_service.save_adapter = disk
	var result: Dictionary
	if via_ui:
		scene._show_event_panel(EventService.get_event_state(context, context.get_current_pos()))
		_check(scene._runtime_modal_is_top(&"event"), label + ": actual event modal opens within interaction range")
		var dialogue: Control = scene.z2_event_adapter.dialogue
		for advance in range(16):
			if dialogue.get_node("%ChoicesFrame").visible:
				break
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			dialogue.get_node("%DialogueText").gui_input.emit(click)
		var button := dialogue.find_child("Option_%d" % options.find(travel), true, false) as Button
		_check(button != null and button.is_visible_in_tree() and not button.disabled, label + ": actual Z2 travel button enabled")
		if button != null:
			button.pressed.emit()
		result = scene.last_command_result
	elif command == &"interact_current_room":
		# Z2 interact prepares the service; the explicitly selected quoted action travels.
		result = scene._dispatch_command(&"select_event_option", travel_payload)
	else:
		result = scene.command_bus.dispatch(command, travel_payload)
	_check(bool(result.get("ok", false)) and context.get_current_pos() == target and disk.checkpoint_writes == 1, label + ": shortcut changes room in one real disk commit")
	var checkpoint := _read_transition_checkpoint(runtime, label)
	var bridge_state: Dictionary = checkpoint.get("bridge", {})
	_check(bridge_state.get("current_room_key", "") == context.cell_key(target), label + ": shortcut checkpoint already switches bridge")
	var combat: Variant = bridge_state.get("simulation")
	if target_type == &"Monster":
		_check(combat is Dictionary and combat.get("player", {}).get("pos") == checkpoint.get("local_position") and combat.get("tick_index", -1) == 0, label + ": shortcut checkpoint contains destination entry and initial encounter")
	else:
		_check(combat == null, label + ": ordinary shortcut destination has no combat")
	if via_ui or command == &"interact_current_room":
		_check(scene.player_controller.get_local_position() == checkpoint.get("local_position") and scene.in_run_runtime.export_transaction_state() == bridge_state, label + ": post-submit UI only projects committed state")
		scene._process(0.0)
		_check(runtime.get_restored_local_position(Vector2.ZERO) == checkpoint.get("local_position") and disk.checkpoint_writes == 1, label + ": next frame cannot overwrite the committed landing or add a repair save")
	_discard_transition_scene(main)
	main = await _open_transition_scene()
	scene = main.get_node("RunScene")
	_check(scene.runtime_controller.persistence_error.is_empty() and scene.run_context.get_current_pos() == target and scene.in_run_runtime.export_transaction_state() == bridge_state, label + ": immediate restart restores shortcut destination without a second save")
	_discard_transition_scene(main)


func _test_simulation_roundtrip() -> void:
	var simulation = _busy_simulation()
	var snapshot: Dictionary = simulation.call("export_transaction_state")
	if simulation.has_method("validate_transaction_state"):
		_check(bool(simulation.call("validate_transaction_state", snapshot)), "busy simulation with projectiles, lasers, hazards and buffered attack validates")
	var restored = CombatSimulation.new()
	restored.call("import_transaction_state", snapshot)
	_check(restored.rng.state == 2147483646, "RNG restore must not normalize an already valid state")
	_check(_data_fields(restored) == _data_fields(simulation), "every mutable simulation field must roundtrip exactly")
	simulation.player["hp"] = 2
	simulation.enemies[0]["hp"] = 1
	simulation.pending_events.clear()
	simulation.projectiles.clear()
	simulation.hazards.clear()
	_check(int(restored.player["hp"]) == 77 and int(restored.enemies[0]["hp"]) > 1, "snapshot must not alias live actor dictionaries")
	_check(not restored.pending_events.is_empty() and not restored.projectiles.is_empty() and not restored.hazards.is_empty(), "snapshot must own its event/entity queues")
	restored.player["hp"] = 3
	var another = CombatSimulation.new()
	another.call("import_transaction_state", snapshot)
	_check(int(another.player["hp"]) == 77, "import must not alias the rollback snapshot")
	var empty = CombatSimulation.new()
	restored.call("import_transaction_state", empty.call("export_transaction_state"))
	_check(restored.rng == null and restored.player.is_empty() and restored.pending_events.is_empty(), "empty simulation restores null RNG and clears old state")
	for flag in ["paused", "cleared", "defeated", "reward_emitted"]:
		another.set(flag, true)
	restored.call("import_transaction_state", another.call("export_transaction_state"))
	_check(_data_fields(restored) == _data_fields(another), "terminal and paused state must restore without invoking pause side effects")


func _test_restore_replays_future() -> void:
	var original = _busy_simulation()
	var restored = CombatSimulation.new()
	restored.call("import_transaction_state", original.call("export_transaction_state"))
	for index in range(150):
		var direction := Vector2.RIGHT if index < 75 else Vector2.DOWN
		original.set_player_input(direction, Vector2.LEFT)
		restored.set_player_input(direction, Vector2.LEFT)
		if index % 30 == 0:
			original.queue_player_attack()
			restored.queue_player_attack()
		original.advance_frame(CombatSimulation.FIXED_STEP)
		restored.advance_frame(CombatSimulation.FIXED_STEP)
	_check(_data_fields(original) == _data_fields(restored), "restored simulation must reproduce future RNG, collisions, queues, counters and transforms")
	_check(original.drain_events() == restored.drain_events(), "restored simulation must reproduce ordered future facts")


func _test_inactive_catchup_stops() -> void:
	var simulation = CombatSimulation.new()
	simulation.start({"monster_types": []})
	simulation.drain_events()
	var advanced: int = simulation.advance_frame(0.25)
	_check(advanced == 1 and simulation.tick_index == 1, "catch-up must stop on the terminal step rather than advancing inactive ticks")
	_check(simulation.drain_events().size() == 1, "clear must emit exactly one terminal fact")


func _test_same_step_terminal_priority() -> void:
	var simulation = CombatSimulation.new()
	_prepare_last_enemy_step(simulation, 1)
	simulation.advance_frame(0.25)
	var events: Array = simulation.drain_events()
	_check(int(simulation.enemies[0]["hp"]) == 0 and int(simulation.player["hp"]) == 0, "one complete step retains both last-enemy and player casualties")
	_check(simulation.defeated and not simulation.cleared and simulation.tick_index == 1, "actual death wins over clear and stops catch-up")
	_check(_count_events(events, &"enemy_defeated") == 1 and _count_events(events, &"player_defeated") == 1, "same-step terminal retains both resolved defeat facts")
	_check(_count_events(events, &"combat_cleared") == 0, "simultaneous death must not emit ordinary clear/reward intent")
	var order: Array = events.map(func(event: Dictionary): return event["event_type"])
	_check(order.find(&"enemy_defeated") < order.find(&"player_damaged"), "fixed-step order stays player then enemies then projectiles")


func _prepare_last_enemy_step(simulation, hp: int) -> void:
	var encounter_id: String = simulation.get("encounter_id") if simulation.get("encounter_id") != null else "terminal_fixture"
	simulation.start({"seed": 37, "encounter_id": encounter_id, "monster_types": [&"bat"],
		"player_pos": Vector2(0.3, 0.5), "player_hp": hp, "player_max_hp": 100, "player_power": 100})
	simulation.enemies[0]["pos"] = Vector2(0.4, 0.5)
	simulation.enemies[0]["hp"] = 1
	simulation.enemies[0]["entry_grace_remaining"] = 20.0
	simulation.player["state"] = &"attack_active"
	simulation.player["state_timer"] = 0.1
	simulation.player["attack_cooldown"] = 0.8
	simulation.active_player_attack = simulation.call("_create_player_attack_contract", Vector2.RIGHT)
	simulation.active_player_attack["active_started_tick"] = -10
	simulation.call("_spawn_projectile", String(simulation.enemies[0]["enemy_id"]), simulation.player["pos"], Vector2.LEFT, 10, {"velocity": Vector2.ZERO})
	simulation.drain_events()


func _test_bridge_roundtrip() -> void:
	var runtime = RuntimeController.new()
	var bridge = runtime.in_run_runtime
	bridge.simulation = _busy_simulation()
	bridge.current_room_key = "2,3"
	bridge.encounter_ordinals = {"2,3": 4, "1,0": 2}
	bridge.recent_domain_events.assign(bridge.simulation.pending_events.duplicate(true))
	bridge.paused = true
	bridge.flee_authorized = true
	var context_ref = bridge.context
	var command_bus_ref = bridge.command_bus
	var snapshot: Dictionary = bridge.call("export_transaction_state")
	bridge.reset()
	bridge.call("import_transaction_state", snapshot)
	_check(bridge.call("export_transaction_state") == snapshot, "bridge restores live simulation, room, pause, flee, event history and encounter ordinals")
	_check(bridge.context == context_ref and bridge.command_bus == command_bus_ref and bridge.runtime_controller == runtime, "bridge restore preserves authority bindings")
	var simulation_ref = bridge.simulation
	bridge.call("import_transaction_state", snapshot)
	_check(bridge.simulation == simulation_ref, "bridge rollback preserves existing simulation identity when live")
	if runtime.has_method("encode_checkpoint_state"):
		var authoritative: Dictionary = runtime.call("capture_authoritative_state")
		var encoded: Variant = runtime.call("encode_checkpoint_state", authoritative)
		var wire: Variant = JSON.parse_string(JSON.stringify(encoded, "", true, true))
		bridge.reset()
		var installed: Dictionary = runtime.call("restore_checkpoint_state", wire)
		_check(bool(installed.get("ok", false)), "real runtime codec installs the complete bridge from JSON")
		_check(bridge.call("export_transaction_state") == snapshot, "untyped checkpoint arrays restore typed simulation fields and exact RNG/transform data: " + _first_difference(bridge.call("export_transaction_state"), snapshot))
	bridge.simulation = null
	var absent: Dictionary = bridge.call("export_transaction_state")
	bridge.call("import_transaction_state", snapshot)
	bridge.call("import_transaction_state", absent)
	_check(bridge.simulation == null and bridge.current_room_key == "2,3", "null simulation must roundtrip without starting a new encounter")
	_release(runtime)


func _test_malformed_checkpoint_rejection() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	var ready: bool = bridge.has_method("validate_transaction_state")
	_check(ready, "bridge must validate a complete untrusted snapshot before installing context")
	if not ready:
		_release(runtime)
		return
	bridge.simulation = _busy_simulation()
	bridge.bind(runtime)
	runtime.context.hp = 77
	runtime.context.max_hp = 101
	runtime.context.power = 9
	var before: Dictionary = runtime.call("capture_authoritative_state")
	_check(bool(bridge.call("validate_transaction_state", before["bridge"])), "real live combat checkpoint is structurally valid")
	for invalid in ["zero_rng", "entity_reference", "missing_field", "nonfinite_transform", "duplicate_entity", "invalid_event_reference", "invalid_hazard_geometry", "living_zero_hp", "empty_simulation_history"]:
		var changed := before.duplicate(true)
		changed["context"]["data"]["hp"] = 1
		var state: Dictionary = changed["bridge"]["simulation"]
		match invalid:
			"zero_rng":
				state["rng_state"] = "0"
			"entity_reference":
				state["projectiles"][0]["owner_id"] = "missing_enemy"
			"missing_field":
				state.erase("attack_buffer_remaining")
			"nonfinite_transform":
				state["previous_player_pos"] = Vector2(INF, 0.0)
			"duplicate_entity":
				state["enemies"].append(state["enemies"][0].duplicate(true))
			"invalid_event_reference":
				state["event_index"] += 1
				state["pending_events"].append({"event_type": &"enemy_damaged", "event_index": state["event_index"], "tick": 0, "enemy_id": "missing_enemy"})
			"invalid_hazard_geometry":
				state["hazards"][0]["radius"] = Vector2.ONE
			"living_zero_hp":
				state["player"]["hp"] = 0
			"empty_simulation_history":
				state = CombatSimulation.new().export_transaction_state()
				state["player_position_history"] = ["invalid_vector"]
				changed["bridge"]["simulation"] = state
		_check(not bool(bridge.call("validate_transaction_state", changed["bridge"])), "validator rejects malformed " + invalid)
		var encoded: Variant = runtime.call("encode_checkpoint_state", changed)
		var restored: Dictionary = runtime.call("restore_checkpoint_state", encoded)
		_check(not bool(restored.get("ok", false)), "parent restore rejects legally encoded malformed " + invalid)
		_check(runtime.call("capture_authoritative_state") == before, "malformed " + invalid + " cannot partially install context/bridge")
	_release(runtime)


func _test_live_snapshot_validation() -> void:
	var simulation = CombatSimulation.new()
	if not simulation.has_method("validate_transaction_state"):
		return
	var types: Array[StringName] = [&"slime", &"bat", &"drone"]
	for index in range(1, 15):
		types.append(StringName("z1_monster_m%02d" % index))
	for monster_type in types:
		simulation.start({"seed": 619, "monster_types": [monster_type], "player_hp": 1000000, "player_max_hp": 1000000, "player_power": 1})
		for sample in range(8):
			simulation.advance_ticks(30)
			_check(bool(simulation.call("validate_transaction_state", simulation.call("export_transaction_state"))), "live snapshot validates across " + String(monster_type) + " sample " + str(sample))


func _test_save_failure_rollback_and_retry() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	var simulation = bridge.simulation
	_add_colliding_projectiles(simulation, 4)
	simulation.accumulator = CombatSimulation.FIXED_STEP * 3.0
	var before: Dictionary = runtime.call("capture_authoritative_state")
	var before_bridge: Dictionary = bridge.call("export_transaction_state")
	fail_writes = true
	write_attempts.clear()
	runtime.checkpoint_writer = Callable(self, "_write_checkpoint")
	state_signals = 0
	result_signals = 0
	runtime.command_bus.state_changed.connect(func(_snapshot): state_signals += 1)
	runtime.command_bus.result_available.connect(func(_result): result_signals += 1)
	bridge.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(write_attempts.size() == 1, "failed persistence must stop before later catch-up steps")
	_check(bridge.call("export_transaction_state") == before_bridge, "failed save restores whole bridge including accumulator, RNG, attacks, entities and pending facts")
	_check(runtime.call("capture_authoritative_state") == before, "failed save restores context, rule charges, receipts and full simulation")
	_check(state_signals == 0 and result_signals == 0, "failed step must publish no state or terminal signals")
	_check(int(runtime.context.hp) == 100 and simulation.tick_index == 0, "failed hit must not leave HP loss or an advanced tick")
	bridge.advance_frame(0.25, Vector2.LEFT, Vector2.LEFT)
	_check(bridge.call("export_transaction_state") == before_bridge and write_attempts.size() == 1, "storage error freezes later frames including their accumulator/input")
	fail_writes = false
	var retried: Dictionary = runtime.call("retry_persistence")
	_check(bool(retried.get("ok", false)), "real parent persistence retry reopens the fixed-step boundary")
	bridge.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(simulation.tick_index == 3 and int(runtime.context.hp) == 96, "retry executes restored hit exactly once then catches up")
	_check(write_attempts.size() == 3, "after parent recovery save, retry saves the effectful step once; subsequent empty steps do not persist")
	if write_attempts.size() >= 3:
		_check(write_attempts[0]["facts"] == write_attempts[2]["facts"], "retry reproduces stable hit IDs and ordered facts")
		var hit := _find_event(write_attempts[2]["facts"], &"player_damaged")
		_check(int(hit.get("damage", -1)) == 4 and int(hit.get("actual_hp_loss", -1)) == 4, "hit facts distinguish requested damage and actual HP loss")
		_check(int(hit.get("absorbed", -1)) == 0 and int(hit.get("hp", -1)) == 96, "hit facts contain authoritative shield absorption and HP")
		_check(String(hit.get("hit_id", "")).contains(String(runtime.context.run_id)) and int(hit.get("combat_tick", -1)) == 1, "hit identity includes run/encounter and the committed tick")
		_check(_count_events(write_attempts[2]["facts"], &"player_damaged") == 1, "same-step collisions preserve invulnerability and resolve one accepted hit")
	_release(runtime)


func _test_attack_step_rollback() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	bridge.request_attack(Vector2.RIGHT)
	bridge.simulation.accumulator = CombatSimulation.FIXED_STEP * 3.0
	var before: Dictionary = runtime.call("capture_authoritative_state")
	write_attempts.clear()
	fail_writes = true
	runtime.checkpoint_writer = Callable(self, "_write_checkpoint")
	bridge.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(write_attempts.size() == 1, "attack-start fixed step must attempt one durable candidate")
	_check(runtime.call("capture_authoritative_state") == before, "attack step storage failure restores attack buffer, timers, RNG, queues and all authority state")
	_check(bridge.simulation.tick_index == 0 and bridge.simulation.attack_queued, "failed attack step must stop catch-up and retain queued input for retry")
	fail_writes = false
	_release(runtime)


func _test_empty_step_does_not_save() -> void:
	var runtime = _controller()
	write_attempts.clear()
	runtime.checkpoint_writer = Callable(self, "_write_checkpoint")
	runtime.in_run_runtime.advance_frame(0.25, Vector2.ZERO, Vector2.RIGHT)
	_check(runtime.in_run_runtime.simulation.tick_index == 15, "motion-only frame still installs each 60Hz step")
	_check(write_attempts.is_empty(), "empty 60Hz steps must not call checkpoint persistence")
	_check(runtime.action_receipts.is_empty(), "empty steps must not accumulate durable receipts")
	var bridge = runtime.in_run_runtime
	_check(bool(bridge.request_attack(Vector2.RIGHT).get("ok", false)), "later windup accepts attack input")
	bridge.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	_check(not _find_event(bridge.recent_domain_events, &"player_attack_started").is_empty(),
		"later windup immediately publishes its presentation fact")
	_check(write_attempts.is_empty(), "windup without a supply or status change does not save twice")
	bridge.advance_frame(0.25, Vector2.ZERO, Vector2.RIGHT)
	_check(_count_events(bridge.recent_domain_events, &"player_attack_resolved") == 1 and not write_attempts.is_empty(),
		"the resolved attack still writes a checkpoint")
	_release(runtime)


func _test_duplicate_tick_receipt() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	bridge.request_attack(Vector2.RIGHT)
	var frame: Dictionary = bridge.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	var committed: Dictionary = frame.get("step_result", {})
	_check(bool(committed.get("ok", false)), "effectful first tick must commit")
	var before: Dictionary = runtime.call("capture_authoritative_state")
	var payload := {
		"encounter_id": bridge.simulation.encounter_id,
		"combat_tick": 1, "combat_seed": bridge.simulation.encounter_seed,
		"durability_required": false,
	}
	var action_id := String(committed.get("action_id", ""))
	var duplicate: Dictionary = runtime.call("execute_atomic_operation", &"combat_fixed_step", payload,
		Callable(bridge, "_run_fixed_step").bind(bridge.simulation, payload), action_id)
	_check(bool(duplicate.get("ok", false)) and bool(duplicate.get("duplicate", false)), "duplicate tick resolves through the real stable action receipt")
	_check(runtime.call("capture_authoritative_state") == before, "duplicate tick must not advance physics, spend statuses or publish extra facts")
	_check(action_id.contains(String(runtime.context.run_id)) and action_id.ends_with(":tick:1"), "step identity must include run, encounter and tick")
	_release(runtime)


func _test_catchup_equivalence() -> void:
	var caught_up = _controller()
	var individual = _controller()
	_add_colliding_projectiles(caught_up.in_run_runtime.simulation, 4)
	_add_colliding_projectiles(individual.in_run_runtime.simulation, 4)
	caught_up.in_run_runtime.advance_frame(0.25, Vector2.ZERO, Vector2.RIGHT)
	for _index in range(15):
		individual.in_run_runtime.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	var catchup_state := _data_fields(caught_up.in_run_runtime.simulation)
	var single_state := _data_fields(individual.in_run_runtime.simulation)
	_check(is_equal_approx(float(catchup_state["accumulator"]), float(single_state["accumulator"])), "catch-up leaves equivalent substep debt")
	catchup_state.erase("accumulator")
	single_state.erase("accumulator")
	_check(catchup_state == single_state, "15-step catch-up and 15 frames yield identical simulation state")
	_check(caught_up.context.hp == individual.context.hp and caught_up.context.hp == 96, "catch-up uses immediate authoritative HP feedback")
	_check(caught_up.in_run_runtime.recent_domain_events == individual.in_run_runtime.recent_domain_events, "catch-up preserves stable fact order and IDs")
	_release(caught_up)
	_release(individual)


func _test_shield_and_single_survival() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	runtime.context.hp = 5
	runtime.context.shield = 10
	bridge.sync_room(Vector2(0.28, 0.50))
	_add_colliding_projectiles(bridge.simulation, 7)
	bridge.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	var shield_hit := _find_event(bridge.recent_domain_events, &"player_damaged")
	_check(runtime.context.hp == 5 and runtime.context.shield == 3, "shield absorbs before HP inside the accepted collision")
	_check(int(bridge.simulation.player["hp"]) == 5 and int(bridge.simulation.player["shield"]) == 3 and not bridge.simulation.defeated, "simulator receives shield survival before deciding defeat")
	_check(int(shield_hit.get("actual_hp_loss", -1)) == 0 and int(shield_hit.get("absorbed", -1)) == 7, "fully shielded hit facts record zero HP loss and actual absorption")
	_configure_survival(runtime.context)
	bridge.simulation.player["invulnerability"] = 0.0
	_add_colliding_projectiles(bridge.simulation, 10)
	bridge.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	_check(runtime.context.hp == 4 and not runtime.context.failed and not bridge.simulation.defeated, "talent life-save is applied before simulator death")
	_check(runtime.context.vitals_counters == {"talent_save": 0, "item_save": 1}, "same-step multiple collisions consume exactly one prioritized survival")
	_check(_count_events(bridge.recent_domain_events, &"player_damaged") == 2 and _count_events(bridge.recent_domain_events, &"player_defeated") == 0, "shield and survival facts contain no transient defeat")
	var before_hp: int = runtime.context.hp
	var replay: Array[Dictionary] = [shield_hit]
	bridge.call("_consume_domain_events", replay)
	_check(runtime.context.hp == before_hp and runtime.context.vitals_counters["item_save"] == 1, "re-consuming player_damaged is fact-only and never deducts HP again")
	_release(runtime)


func _test_terminal_runtime_priority() -> void:
	for survives in [false, true]:
		var runtime = _controller()
		var bridge = runtime.in_run_runtime
		var simulation = bridge.simulation
		runtime.context.hp = 5
		if survives:
			_configure_survival(runtime.context)
		_prepare_last_enemy_step(simulation, 5)
		write_attempts.clear()
		runtime.checkpoint_writer = Callable(self, "_write_checkpoint")
		bridge.advance_frame(0.25, Vector2.ZERO, Vector2.RIGHT)
		_check(simulation.tick_index == 1 and write_attempts.size() == 1, "terminal encounter commits one complete tick and stops catch-up")
		var facts: Array = write_attempts[0]["facts"] if not write_attempts.is_empty() else []
		_check(_count_events(facts, &"enemy_defeated") == 1 and _count_events(facts, &"player_damaged") == 1, "durable terminal step retains prior enemy and player hit facts")
		if survives:
			_check(runtime.context.run_active and runtime.context.hp == 4 and simulation.cleared and simulation.reward_emitted, "surviving last-enemy hit permits exactly one ordinary clear")
			_check(_count_events(facts, &"player_defeated") == 0 and _count_events(facts, &"combat_cleared") == 1, "survival never publishes a premature defeat before clear")
		else:
			_check(runtime.context.failed and simulation.defeated and not simulation.reward_emitted, "actual same-step death wins over last-enemy clear reward")
			_check(not runtime.context.truth_map.is_cleared(Vector2i(2, 2)) and int(runtime.context.run_stats.get("monsters_defeated", 0)) == 0, "death priority prevents room reward/progression")
			_check(_count_events(facts, &"player_defeated") == 1 and _count_events(facts, &"combat_cleared") == 0, "lethal step publishes defeat and no ordinary clear")
		_release(runtime)


func _test_terminal_step_rollback() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	runtime.context.hp = 5
	_configure_survival(runtime.context)
	_prepare_last_enemy_step(bridge.simulation, 5)
	bridge.simulation.accumulator = CombatSimulation.FIXED_STEP * 2.0
	var before: Dictionary = runtime.call("capture_authoritative_state")
	write_attempts.clear()
	fail_writes = true
	runtime.checkpoint_writer = Callable(self, "_write_checkpoint")
	bridge.advance_frame(0.0, Vector2.ZERO, Vector2.RIGHT)
	_check(write_attempts.size() == 1, "survival plus last-enemy reward must share a single durable candidate")
	_check(runtime.call("capture_authoritative_state") == before, "terminal save failure restores life-save charge, reward, enemy, hit receipt and step together")
	_check(not runtime.context.failed and not runtime.context.truth_map.is_cleared(Vector2i(2, 2)), "failed terminal candidate exposes neither death nor room clear")
	fail_writes = false
	_release(runtime)


func _test_status_time_inside_step() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	runtime.context.temporary_statuses = [{"id": "combat_dot", "type": "temporary_debuff", "temporary_type": "bleed", "phase": "active", "remaining": 0.1, "dot_per_second": 60.0}]
	_add_colliding_projectiles(bridge.simulation, 4)
	write_attempts.clear()
	runtime.checkpoint_writer = Callable(self, "_write_checkpoint")
	var frame: Dictionary = bridge.advance_frame(0.25, Vector2.ZERO, Vector2.RIGHT)
	_check(bool(frame.get("step_result", {}).get("ok", false)), "status step commits: " + str(frame.get("step_result", {})))
	var status: Dictionary = runtime.context.temporary_statuses[0]
	_check(String(status["phase"]) == "ended" and is_equal_approx(float(status.get("elapsed", 0.0)), 0.1), "combat advances status time exactly once for each fixed step")
	_check(runtime.context.hp == 90 and int(bridge.simulation.player["hp"]) == 90, "six per-second DOT ticks and one physical hit immediately sync to combat HP")
	_check(write_attempts.size() == 6, "status HP changes and expiry request durable whole steps; empty remainder does not save")
	_release(runtime)


func _test_waiting_status_starts_on_attack() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	runtime.context.hp = 90
	runtime.context.temporary_statuses = [{"id": "first_attack", "type": "temporary_buff", "temporary_type": "regen", "phase": "waiting", "start_trigger": "attack", "remaining": 0.05, "heal_per_second": 60.0}]
	bridge.advance_frame(CombatSimulation.FIXED_STEP * 5.0, Vector2.ZERO, Vector2.RIGHT)
	_check(runtime.context.hp == 90 and runtime.context.temporary_statuses[0]["phase"] == "waiting", "waiting status does not spend combat time before first attack")
	bridge.simulation.player["attack_cooldown"] = CombatSimulation.FIXED_STEP * 3.0
	bridge.request_attack(Vector2.RIGHT)
	bridge.advance_frame(CombatSimulation.FIXED_STEP * 2.0, Vector2.ZERO, Vector2.RIGHT)
	_check(runtime.context.hp == 90 and runtime.context.temporary_statuses[0]["phase"] == "waiting", "buffered attack does not start status until cooldown permits the attack")
	bridge.advance_frame(CombatSimulation.FIXED_STEP, Vector2.ZERO, Vector2.RIGHT)
	_check(runtime.context.hp == 91 and runtime.context.temporary_statuses[0]["phase"] == "active", "actual queued attack starts waiting status in its fixed step")
	bridge.advance_frame(CombatSimulation.FIXED_STEP * 2.0, Vector2.ZERO, Vector2.RIGHT)
	_check(runtime.context.hp == 93 and runtime.context.temporary_statuses[0]["phase"] == "ended", "first-attack status advances once per step through expiry")
	_release(runtime)


func _test_lethal_status_precedes_physics() -> void:
	var runtime = _controller()
	var bridge = runtime.in_run_runtime
	var simulation = bridge.simulation
	runtime.context.hp = 1
	runtime.context.temporary_statuses = [{"id": "lethal_dot", "type": "temporary_debuff", "temporary_type": "bleed", "phase": "active", "remaining": CombatSimulation.FIXED_STEP, "dot_per_second": 60.0}]
	_prepare_last_enemy_step(simulation, 1)
	write_attempts.clear()
	runtime.checkpoint_writer = Callable(self, "_write_checkpoint")
	var frame: Dictionary = bridge.advance_frame(0.25, Vector2.ZERO, Vector2.RIGHT)
	_check(bool(frame.get("step_result", {}).get("ok", false)), "lethal status step commits: " + str(frame.get("step_result", {})))
	_check(runtime.context.failed and simulation.tick_index == 1 and simulation.defeated, "lethal pre-physics status completes and commits its fixed step")
	_check(int(simulation.enemies[0]["hp"]) == 1 and not simulation.cleared, "lethal status prevents later player attack and clear in that step")
	var facts: Array = write_attempts[0]["facts"] if not write_attempts.is_empty() else []
	_check(_count_events(facts, &"player_defeated") == 1 and _count_events(facts, &"enemy_defeated") == 0, "pre-physics death keeps the correct terminal fact order")
	_release(runtime)


func _configure_survival(context) -> void:
	context.vitals_counters = {"talent_save": 1, "item_save": 1}
	context.vitals_modifiers = {"damage": {"survivals": [
		{"source_id": "item", "kind": "item", "counter_key": "item_save", "hp": 6},
		{"source_id": "talent", "kind": "talent", "counter_key": "talent_save", "hp": 4},
	]}}


func _controller():
	var runtime = RuntimeController.new()
	runtime.context.start_run({
		"id": "z2_combat", "seed": 348, "width": 5, "height": 5, "max_hp": 100, "power": 10,
		"manual_map": {"spawn": Vector2i.ZERO, "monsters": [Vector2i(2, 2)], "exits": [{"pos": Vector2i(4, 4), "exit_id": "test_exit"}]},
	})
	runtime.context.run_id = &"z2_combat_fixture"
	runtime.context.player_pos = Vector2i(2, 2)
	runtime.context.current_pos = Vector2i(2, 2)
	runtime.command_bus.room_resolver.enter_room(runtime.context)
	runtime.in_run_runtime.sync_room(Vector2(0.28, 0.50))
	runtime.in_run_runtime.simulation.set_arena_obstacles([])
	for enemy in runtime.in_run_runtime.simulation.enemies:
		enemy["entry_grace_remaining"] = 20.0
	runtime.checkpoint_writer = func(_snapshot: Dictionary) -> Dictionary: return {"ok": true}
	return runtime


func _add_colliding_projectiles(simulation, damage: int) -> void:
	for _index in range(2):
		simulation.call("_spawn_projectile", String(simulation.enemies[0]["enemy_id"]), simulation.player["pos"], Vector2.LEFT, damage, {"velocity": Vector2.ZERO})


func _write_checkpoint(snapshot: Dictionary) -> Dictionary:
	write_attempts.append({"snapshot": snapshot.duplicate(true), "facts": snapshot.get("bridge", {}).get("recent_domain_events", []).duplicate(true)})
	return {"ok": not fail_writes, "reason": "injected_storage_failure" if fail_writes else ""}


func _find_event(events: Array, event_type: StringName) -> Dictionary:
	for event in events:
		if StringName(event.get("event_type", &"")) == event_type:
			return event
	return {}


func _count_events(events: Array, event_type: StringName) -> int:
	var count := 0
	for event in events:
		count += int(StringName(event.get("event_type", &"")) == event_type)
	return count


func _busy_simulation():
	var simulation = CombatSimulation.new()
	simulation.start({
		"seed": 619, "player_hp": 77, "player_max_hp": 101, "player_power": 9,
		"monster_types": [&"bat", &"drone", &"z1_monster_m09"],
		"arena_obstacles": [Rect2(0.65, 0.60, 0.05, 0.08)],
	})
	simulation.set_player_input(Vector2.DOWN, Vector2.RIGHT)
	simulation.queue_player_attack()
	simulation.advance_ticks(3)
	simulation.player["attack_cooldown"] = 0.1
	simulation.queue_player_attack(Vector2.UP)
	simulation.call("_spawn_projectile", String(simulation.enemies[0]["enemy_id"]), Vector2(0.8, 0.15), Vector2.LEFT, 4)
	simulation.call("_spawn_drone_laser", simulation.enemies[1], {"laser_seconds": 2.0})
	simulation.call("_start_hazard", simulation.enemies[2], {
		"shape": &"circle", "center": Vector2(0.85, 0.85), "radius": 0.04,
		"warning_seconds": 0.3, "active_seconds": 2.0,
	})
	simulation.advance_frame(CombatSimulation.FIXED_STEP * 0.5)
	simulation.rng.state = 2147483646
	return simulation


func _data_fields(simulation) -> Dictionary:
	var result := {}
	for property in simulation.get_property_list():
		if int(property.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var key := String(property["name"])
		var value: Variant = simulation.get(key)
		if value is Callable:
			continue
		if key == "rng":
			result[key] = null if value == null else value.state
		elif value is Array or value is Dictionary:
			result[key] = value.duplicate(true)
		else:
			result[key] = value
	return result


func _first_difference(actual: Variant, expected: Variant, path: String = "bridge") -> String:
	if actual == expected:
		return ""
	if actual is Dictionary and expected is Dictionary:
		for key in expected:
			if not actual.has(key):
				return path + "/" + str(key) + " missing"
			if actual[key] != expected[key]:
				return _first_difference(actual[key], expected[key], path + "/" + str(key))
	elif actual is Array and expected is Array:
		if actual.size() != expected.size():
			return path + " size mismatch"
		for index in range(expected.size()):
			if actual[index] != expected[index]:
				return _first_difference(actual[index], expected[index], path + "/" + str(index))
	if actual is float and expected is float:
		return "%s actual=%.17f expected=%.17f bytes=%s/%s" % [path, actual, expected, var_to_bytes(actual).hex_encode(), var_to_bytes(expected).hex_encode()]
	return "%s actual=%s expected=%s" % [path, var_to_str(actual), var_to_str(expected)]


func _release(runtime) -> void:
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.bind_runtime_controller(null)
	runtime.context = null
	runtime.in_run_runtime = null
	runtime.command_bus = null


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _finish() -> void:
	for failure in failures:
		print("Z2_COMBAT_TRANSACTION_CASE_FAIL " + failure)
	print("Z2_COMBAT_TRANSACTION_CHECKS=%d" % checks)
	print("Z2_COMBAT_TRANSACTION=PASS" if failures.is_empty() else "Z2_COMBAT_TRANSACTION=FAIL")
	quit(0 if failures.is_empty() else 1)
