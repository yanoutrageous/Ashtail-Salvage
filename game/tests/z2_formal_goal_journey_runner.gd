extends SceneTree

const SIMPLE := "classic_7x7_simple"
const NORMAL := "classic_7x7_normal"
const Maps := preload("res://scripts/core/content/m7_content_catalog.gd")
const Goals := preload("res://scripts/core/progression/z2_goals/goal_progression.gd")
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]


class RejectTerminalWrite extends SaveAdapter:
	var blocked_run_id := ""
	var failures := 0

	func save_json(data: Dictionary, path: String = M1_META_PROGRESS_PATH, normalize_meta_progress: bool = true) -> bool:
		if failures == 0 and data.get("run_receipts", {}).has(blocked_run_id):
			failures += 1
			last_error = "z2_formal_test_terminal_write"
			return false
		return super.save_json(data, path, normalize_meta_progress)


var checks := 0
var failures: Array[String] = []
var shown_notices: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _isolated_save_directory():
		printerr("Z2_FORMAL_GOAL_JOURNEY=FAIL: use fresh user data under Z2_FORMAL_QA_HOME")
		quit(1)
		return
	root.size = Vector2i(1280, 720)
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var main := packed.instantiate()
	root.add_child(main)
	var scene = main.get_node("RunScene")
	# Only scripted player inputs advance this runner. UI timers still run.
	scene.set_process(false)
	await process_frame
	if _stage_post_tutorial(scene):
		var queue := _find_queue(root)
		_check(queue != null, "production Main mounts the T15 notification queue")
		if queue != null:
			queue.notification_shown.connect(_on_notification_shown)
		await _first_departure(scene, queue != null)
		await _three_flags_in_one_run(scene, queue != null)
		_visit_hidden_exit(scene)
		_first_step_mine_death(scene)
	await _release_main(main)
	for failure in failures:
		printerr("Z2_FORMAL_GOAL_JOURNEY_CASE_FAIL " + failure)
	print("Z2_FORMAL_GOAL_JOURNEY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _isolated_save_directory() -> bool:
	var qa_home := OS.get_environment("Z2_FORMAL_QA_HOME").simplify_path().replace("\\", "/").trim_suffix("/")
	var data_dir := OS.get_user_data_dir().simplify_path().replace("\\", "/")
	return qa_home.is_absolute_path() and data_dir.to_lower().begins_with(qa_home.to_lower() + "/") \
		and not FileAccess.file_exists("user://saves/manifest.json")


func _stage_post_tutorial(scene) -> bool:
	var adapter = scene.meta_progress_adapter
	var tutorial_state := {
		"tutorial_completed": true,
		"profile_level": 1,
		"profile_exp": 0,
		"talent_flags": ["z2_talent_01"],
		"talent_earned": 100,
		"talent_spent": 100,
		"talent_points": 0,
	}
	adapter.data.merge(tutorial_state, true)
	var unlocked: Array = adapter.data.get("unlocked_map_ids", []).duplicate()
	if not unlocked.has(SIMPLE):
		unlocked.append(SIMPLE)
	adapter.data.unlocked_map_ids = unlocked
	var ready: bool = scene.runtime_controller.persistence_error.is_empty() and adapter.save()
	_check(ready, "fresh production profile saved with post-tutorial fixture")
	print("Z2_FORMAL_GOAL_JOURNEY_USER_DATA ", OS.get_user_data_dir())
	return ready


func _first_departure(scene, queue_present: bool) -> void:
	_check(_task(scene, "M01").get("status", "") == "active", "M01 active on post-tutorial profile")
	_check(_task(scene, "M02").get("status", "") == "locked", "M02 locked before first settlement")
	if not _start(scene, SIMPLE, 1067):
		return
	var runtime = scene.runtime_controller
	var adapter = scene.meta_progress_adapter
	var run_id := str(scene.run_context.run_id)
	var profile_path := str(adapter.active_meta_progress_path)
	var disk_before := FileAccess.get_sha256(profile_path)
	var gold_before := int(adapter.data.get("gold", -1))
	var writer := RejectTerminalWrite.new()
	writer.blocked_run_id = run_id
	var normal_writer: SaveAdapter = adapter.save_adapter
	adapter.save_adapter = writer
	var abandoned: Dictionary = _abandon(scene)
	_check(abandoned.get("ok") == true, "ordinary abandon confirms its terminal checkpoint")
	_check(writer.failures == 1 and runtime.last_meta_commit.get("ok") == false, "actual terminal profile write rejected once: %s" % runtime.last_meta_commit)
	_check(not disk_before.is_empty() and FileAccess.get_sha256(profile_path) == disk_before, "terminal save failure leaves exact profile bytes intact")
	_check(int(adapter.data.get("gold", -1)) == gold_before and not adapter.data.get("run_receipts", {}).has(run_id), "failure leaves wallet and run receipts intact")
	_check(_task(scene, "M01").get("status", "") == "active", "failed terminal save leaves M01 active")
	await create_timer(0.45).timeout
	_check(_notices_for("M01").is_empty(), "no M01 notification for failed terminal save")
	adapter.save_adapter = normal_writer
	var retry_button: Button = scene.result_panel.retry_save_button
	var can_retry := retry_button != null and retry_button.is_visible_in_tree() and not retry_button.disabled
	_check(can_retry, "result panel exposes an enabled save retry")
	if can_retry:
		retry_button.pressed.emit()
	_check(runtime.last_meta_commit.get("ok") == true and runtime.last_meta_commit.get("status") == "committed", "result panel retry durably commits the same terminal result (%s)" % runtime.last_meta_commit.get("status", ""))
	var receipt: Dictionary = adapter.data.get("run_receipts", {}).get(run_id, {}).duplicate(true)
	_check(not receipt.is_empty() and FileAccess.get_sha256(profile_path) != disk_before, "committed run receipt is present and profile bytes changed")
	_check(_task(scene, "M01").get("status", "") == "claimable", "M01 becomes claimable from actual abandon")
	_check(_task(scene, "M02").get("status", "") == "active", "M02 unlocks before M01 reward is collected")
	_check(_task(scene, "S01").get("status", "") == "active", "S01 unlocks before M01 reward is collected")
	_check(int(adapter.data.get("gold", -1)) == gold_before, "M01 gold requires a separate claim")
	var duplicate: Dictionary = _dispatch(scene, &"retry_terminal_commit")
	_check(duplicate.get("ok") == true and adapter.data.get("run_receipts", {}).get(run_id, {}) == receipt, "terminal replay preserves the existing receipt")
	if queue_present:
		await create_timer(4.4).timeout
		var notices := _notices_for("M01")
		_check(notices.size() == 1, "actual committed M01 shows one notification across replay")
		if notices.size() == 1:
			_check(int(notices[0].get("tier", 0)) == 1 and not str(notices[0].get("receipt_id", "")).is_empty(), "top notice carries first tier and stable receipt identity")


func _three_flags_in_one_run(scene, queue_present: bool) -> void:
	var seed_pick := _fixture_seed(SIMPLE, &"Normal")
	for attempt in range(3):
		if not _start(scene, SIMPLE, seed_pick):
			return
		var context: RunContext = scene.run_context
		var origin := context.get_current_pos()
		var mines: Array[Vector2i] = []
		var wrong := Vector2i(-1, -1)
		for y in range(context.truth_map.height):
			for x in range(context.truth_map.width):
				var pos := Vector2i(x, y)
				if context.intel_map.is_revealed(pos):
					continue
				if context.truth_map.is_mine(pos):
					mines.append(pos)
				elif wrong.x < 0 and pos.distance_squared_to(origin) > 1:
					wrong = pos
		var step := _normal_neighbor(context)
		var fixture_ready := mines.size() >= 3 and wrong.x >= 0 and step != Vector2i.ZERO
		_check(fixture_ready, "seed %d has three hidden mines, a false flag target and a new safe neighbor" % seed_pick)
		if not fixture_ready:
			_abandon(scene)
			return
		var targets := [mines[0], mines[1], wrong, mines[0], mines[0]] if attempt == 0 else ([mines[2]] if attempt == 1 else mines.slice(0, 3))
		var flags_ok := true
		for target in targets:
			var result: Dictionary = _dispatch(scene, &"toggle_flag_cell", {"pos": target})
			flags_ok = result.get("ok") == true and flags_ok
		_check(flags_ok, "attempt %d: ordinary map flag commands accepted" % (attempt + 1))
		_check(_walk(scene, step) and context.get_current_pos() == origin + step, "attempt %d: actually entered the previously unvisited safe room" % (attempt + 1))
		_check(_abandon(scene).get("ok") == true and scene.runtime_controller.last_meta_commit.get("status") == "committed", "attempt %d: real result and profile committed" % (attempt + 1))
		var state := _task(scene, "M02")
		var expected := "claimable" if attempt == 2 else "active"
		_check(state.get("status", "") == expected, "attempt %d: M02 is %s after committed exploration" % [attempt + 1, expected])
		if queue_present and attempt != 2:
			await create_timer(0.35).timeout
			_check(_notices_for("M02").is_empty(), "incomplete attempt does not show an M02 notification")
	if queue_present:
		await create_timer(4.4).timeout
		_check(_notices_for("M02").size() == 1, "ordinary committed M02 shows exactly one notification")


func _visit_hidden_exit(scene) -> void:
	var adapter = scene.meta_progress_adapter
	var ready: Dictionary = Goals.initial_state(adapter.data)
	for number in range(1, 6):
		var id := "M%02d" % number
		var state: Dictionary = ready.z2_goals.states[id]
		state.unlocked = true
		state.progress = Goals.goal_state(ready, id).target
	ready = Goals.initial_state(ready)
	ready.profile_level = 6
	ready.profile_exp = 250
	ready.map_success_counts = {SIMPLE: 1}
	# This advanced fixture uses ordinary map generation after the first five departures.
	ready.run_count = maxi(int(ready.run_count), Z2EventRuntime.EARLY_DISCOVERY_RUNS)
	if not ready.unlocked_map_ids.has(NORMAL):
		ready.unlocked_map_ids.append(NORMAL)
	adapter.data = ready
	if not adapter.save():
		_check(false, "advanced M06 stage fixture saved")
		return
	_check(_task(scene, "M06").get("status", "") == "active", "M06 active with prior main milestones staged")
	var seed_pick := _fixture_seed(NORMAL, &"Exit")
	for visit in [false, true]:
		if not _start(scene, NORMAL, seed_pick):
			return
		var context: RunContext = scene.run_context
		var origin := context.get_current_pos()
		var exits := context.truth_map.get_exits()
		var hidden_adjacent := exits.size() == 1 and origin.distance_squared_to(exits[0]) == 1 \
			and context.truth_map.get_visible_exits(context.intel_map).is_empty()
		_check(hidden_adjacent, "M06 fixture begins beside an unpublished exit")
		if not hidden_adjacent:
			_abandon(scene)
			return
		var exit_pos := exits[0]
		if visit:
			_check(_walk(scene, exit_pos - origin) and context.get_current_pos() == exit_pos, "move command actually enters the hidden exit room")
			_check(_dispatch(scene, &"request_extract").get("ok") == true, "actual exit offers extraction")
			_check(_dispatch(scene, &"confirm_extract").get("ok") == true, "actual exit confirms extraction")
			_confirm_selection_if_required(scene)
		else:
			var scan_definitions: Array[Dictionary] = M3ItemCatalog.consumable_items()
			var scan_pin := {}
			for item in scan_definitions:
				if item.item_id == "con_scan_pin":
					scan_pin = item
					break
			var instance := context.asset_ledger.create_item_instance(scan_pin, &"inventory")
			var used := _dispatch(scene, &"use_consumable", {"instance_id": instance.get("instance_id", "")})
			_check(used.get("ok") == true and context.truth_map.get_visible_exits(context.intel_map).has(exit_pos), "actual scan pin reveals the hidden exit")
			_check(context.get_current_pos() == origin and not context.visited_cells.has(context.cell_key(exit_pos)), "scan does not move to exit")
			_check(_abandon(scene).get("ok") == true, "scan-only run reaches real terminal")
		var committed: Dictionary = scene.runtime_controller.last_meta_commit
		_check(committed.get("ok") == true and committed.get("status") == "committed", "M06 stage persisted its terminal outcome")
		var expected := "claimable" if visit else "active"
		_check(_task(scene, "M06").get("status", "") == expected, "M06 is %s after %s" % [expected, "actual visit" if visit else "scan only"])


func _first_step_mine_death(scene) -> void:
	var seed_pick := _fixture_seed(SIMPLE, &"Mine")
	if not _start(scene, SIMPLE, seed_pick):
		return
	var context: RunContext = scene.run_context
	var target := Vector2i.ZERO
	for delta: Vector2i in DIRECTIONS:
		if context.truth_map.is_mine(context.get_current_pos() + delta):
			target = delta
			break
	_check(target != Vector2i.ZERO, "death fixture begins beside a real live mine")
	if target == Vector2i.ZERO:
		_abandon(scene)
		return
	var runtime = scene.runtime_controller
	var prepared: Dictionary = runtime.execute_atomic_operation(&"z2_formal_death_vitals_fixture", {}, func() -> Dictionary:
		context.hp = 1
		return {"ok": true}
	)
	if prepared.get("ok") != true:
		_check(false, "death fixture persists one remaining HP")
		_abandon(scene)
		return
	_check(_walk(scene, target) and context.failed and not context.run_active, "first actual move triggers the mine and kills the explorer")
	_confirm_selection_if_required(scene)
	_check(runtime.last_meta_commit.get("ok") == true and runtime.last_meta_commit.get("status") == "committed", "ordinary death outcome gets a durable terminal commit")
	var state: Dictionary = scene.meta_progress_adapter.get_summary().get("achievement_states", {}).get("A13", {})
	_check(state.get("status", "") == "claimable", "first-step mine achievement is claimable after real death")


func _fixture_seed(map_id: String, room_type: StringName) -> int:
	for seed_pick in range(1067, 1131):
		var truth := TruthMap.new()
		truth.setup_from_config(Maps.map_runtime_config(map_id, seed_pick))
		for delta: Vector2i in DIRECTIONS:
			var target := truth.spawn_pos + delta
			if not truth.is_inside(target):
				continue
			if truth.get_room_type(target) == room_type:
				return seed_pick
	_check(false, "could not find deterministic neighbor for %s" % map_id)
	return 1067


func _normal_neighbor(context: RunContext) -> Vector2i:
	var origin := context.get_current_pos()
	for delta: Vector2i in DIRECTIONS:
		var next := origin + delta
		if context.truth_map.is_inside(next) and context.truth_map.get_room_type(next) == &"Normal" and not context.intel_map.is_revealed(next):
			return delta
	return Vector2i.ZERO


func _start(scene, map_id: String, seed_pick: int) -> bool:
	if scene.result_panel.is_visible_in_tree() and scene.result_panel.normal_exit_allowed():
		scene._return_from_result_to_deploy()
	var summary: Dictionary = scene.meta_progress_adapter.get_summary()
	var choices := Maps.commission_offer_candidates(map_id, int(summary.get("run_count", 0)), 3)
	var result := _dispatch(scene, &"start_standard_run", {
		"run_start_config": {
			"map_config_id": map_id,
			"seed_value": seed_pick,
			"difficulty": &"",
			"selected_objective_id": str(choices[0].id) if not choices.is_empty() else "",
		},
	})
	var ok: bool = result.get("ok") == true and scene.run_context.run_active
	_check(ok, "standard departure %s seed=%d (%s)" % [map_id, seed_pick, result.get("action_result", {"status": result.get("status", "")})])
	if ok:
		_check(scene._show_run_screen(), "formal run screen shows after accepted departure")
	return ok


func _abandon(scene) -> Dictionary:
	var result := _dispatch(scene, &"abandon_run", {"confirmed": true, "source": "pause_panel"})
	if result.get("ok") == true:
		_confirm_selection_if_required(scene)
	return result


func _confirm_selection_if_required(scene) -> void:
	if scene.run_context.phase != &"failure_salvage":
		return
	var confirm_button: Button = scene.result_panel.salvage_confirm_button
	var available := confirm_button != null and confirm_button.is_visible_in_tree() and not confirm_button.disabled
	_check(available, "formal result waits for an enabled carry-out confirmation")
	if available:
		confirm_button.pressed.emit()
		var result: Dictionary = scene.last_command_result
		_check(result.get("ok") == true, "actual carry-out selection commits: %s" % result.get("action_result", result))


func _walk(scene, step: Vector2i) -> bool:
	return _dispatch(scene, &"attempt_room_transition", {"direction": step}).get("ok") == true


func _task(scene, id: String) -> Dictionary:
	return scene.meta_progress_adapter.get_summary().get("task_states", {}).get(id, {})


func _dispatch(scene, command: StringName, payload: Dictionary = {}) -> Dictionary:
	return scene._dispatch_command(command, payload, false, false)


func _find_queue(scene: Node) -> Node:
	for node in scene.find_children("*", "", true, false):
		if node.has_method("enqueue_committed") and node.has_signal("notification_shown"):
			return node
	return null


func _on_notification_shown(notice: Dictionary) -> void:
	shown_notices.append(notice.duplicate(true))
	var output := OS.get_environment("Z2_FORMAL_CAPTURE_DIR").simplify_path().replace("\\", "/")
	if DisplayServer.get_name() == "headless" or str(notice.get("goal_id", "")) != "M01" or not output.to_lower().begins_with("d:/agame2/"):
		return
	await RenderingServer.frame_post_draw
	var captured := root.get_texture().get_image().save_png(output.path_join("formal_m01_notification.png"))
	_check(captured == OK, "actual committed M01 notification render saved")


func _notices_for(id: String) -> Array[Dictionary]:
	return shown_notices.filter(func(notice: Dictionary) -> bool: return str(notice.get("goal_id", "")) == id)


func _release_main(main: Node) -> void:
	var scene = main.get_node("RunScene")
	var runtime = scene.runtime_controller
	for child in scene.player_feedback_service.get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null
	main.queue_free()
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.bind_runtime_controller(null)
	for _frame in range(4):
		await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
