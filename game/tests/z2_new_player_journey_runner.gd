extends SceneTree

# Natural current-profile journey. No profile/progression mutations, synthetic
# completion receipts, fake checkpoint writer, or pre-awarded teaching qualify it.
# The fixed tutorial route reuses i3r_tutorial_player_journey_runner's left/bottom
# route. Inputs are actual Main buttons and public commands; this is not visual QA.
# Only the final death run uses a controlled map corridor (never edited HP).
const Maps := preload("res://scripts/core/content/m7_content_catalog.gd")
const Tutorial := preload("res://scripts/core/run/tutorial_map_catalog.gd")
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
var checks := 0
var failures: Array[String] = []
var main: Node
var scene
var first_supplies: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var home := OS.get_environment("Z2_NEW_PLAYER_QA_HOME").simplify_path().replace("\\", "/").trim_suffix("/")
	var user_dir := OS.get_user_data_dir().simplify_path().replace("\\", "/")
	if not _check(home.is_absolute_path() and user_dir.to_lower().begins_with(home.to_lower() + "/") and not FileAccess.file_exists("user://saves/manifest.json"), "requires a fresh isolated user directory under Z2_NEW_PLAYER_QA_HOME"):
		_finish()
		return
	print("Z2_NEW_PLAYER_USER_DATA=" + user_dir)
	root.size = Vector2i(1280, 720)
	await _open_main()
	if await _tutorial_journey():
		if await _first_supplies():
			if await _ordinary_success():
				await _ordinary_abandon()
				await _ordinary_death()
	await _close_main()
	_finish()


func _open_main() -> void:
	main = (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	scene = main.get_node("RunScene")
	# Scripted public inputs own elapsed time; native UI animations still process.
	scene.set_process(false)
	await process_frame
	_check(scene.runtime_controller.persistence_error.is_empty(), "Main opens with real profile and checkpoint services")
	_check(scene.runtime_controller.checkpoint_service.meta_adapter == scene.meta_progress_adapter, "Main checkpoint and UI share the real Meta")


func _close_main() -> void:
	if not is_instance_valid(main):
		return
	var runtime = scene.runtime_controller
	for child in scene.player_feedback_service.get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null
	main.queue_free()
	runtime.in_run_runtime.bind(null)
	runtime.command_bus.bind_runtime_controller(null)
	for frame in range(4):
		await process_frame


func _reopen() -> void:
	await _close_main()
	await _open_main()


func _enter_deploy_from_main() -> bool:
	var menu: Control = scene.ui_shell.get_main_page()
	var button := menu.entry_nodes.get(&"deploy", {}).get("button") as Button
	if not _check(scene.screen_state == &"main_menu" and button != null and button.is_visible_in_tree() and not button.disabled, "fresh Main exposes the actual explore entry"):
		return false
	button.pressed.emit()
	var deadline := Time.get_ticks_msec() + 6000
	while scene.screen_state != &"deploy_shell" and Time.get_ticks_msec() < deadline:
		await process_frame
	return _check(scene.screen_state == &"deploy_shell", "actual Main explore button reaches deploy")


func _tutorial_journey() -> bool:
	_check(_data().profile_level == 0 and _data().profile_exp == 0 and not _data().tutorial_completed, "new Main creates Lv0 without teaching completion")
	_check(_data().talent_points == 100 and _data().talent_earned == 100 and _data().talent_spent == 0, "new Main grants exactly 100 teaching points")
	_check(_data().warehouse_items.is_empty() and _data().initial_supply_receipt.is_empty(), "new Main grants no automatic starter items")
	_check(_data().task_states.size() == 25 and _data().achievement_states.size() == 25 and _task("M01").status == "locked", "fresh catalogue contains all goals and locks M01 until teaching")
	if not await _enter_deploy_from_main():
		return false
	var deploy: Control = scene.ui_shell.get_deploy_page()
	var split: Control = deploy.map_split_view
	var scale_button := split.scale_buttons.get(&"5x5") as Button
	if not _check(scale_button != null and not scale_button.disabled, "actual map picker exposes tutorial scale"):
		return false
	scale_button.pressed.emit()
	await process_frame
	split = deploy.map_split_view
	var tutorial_button := split.difficulty_buttons.get(StringName(Tutorial.MAP_ID)) as Button
	if not _check(tutorial_button != null and not tutorial_button.disabled, "Lv0 can select the actual tutorial map"):
		return false
	tutorial_button.pressed.emit()
	await process_frame
	split = deploy.map_split_view
	if str(split.selected_map_id) != Tutorial.MAP_ID:
		split.select_action_button.pressed.emit()
		await process_frame
	_check(str(deploy.current_model.get("config", {}).get("map_config_id", "")) == Tutorial.MAP_ID, "deploy model uses the selected fixed tutorial")
	deploy.primary_action_button.pressed.emit()
	await process_frame
	if not _check(scene.run_context.run_active and scene.run_context.mode == &"tutorial" and scene.screen_state == &"run", "real deploy button starts admitted teaching"):
		return false
	_check(scene.run_context.seed_value == Tutorial.FIXED_SEED and scene.run_context.get_current_pos() == Vector2i.ZERO, "untouched tutorial seed and spawn")
	_check(not _data().get("admission", {}).is_empty(), "teaching admission is durably reserved")
	if not _confirm_popup("spawn_intro"):
		return false
	_check(_data().talent_flags.is_empty() and _data().talent_points == 100 and _data().talent_spent == 0, "closing opening guidance does not purchase the flag node")
	if not _walk(Vector2i(0, 1)):
		return false
	_check(str(scene.run_context.tutorial_popup.get("id", "")) == "number_rule", "tutorial number lesson reached by real movement without learning")
	_check(_data().talent_flags.is_empty() and _data().talent_points == 100, "real early tutorial movement leaves the teaching point budget available")
	if not _walk(Vector2i(0, 2)) or not _walk(Vector2i(0, 3)):
		return false
	_check(scene.run_context.hp == 85 and scene.run_context.run_stats.get("mine_hits", 0) == 1, "tutorial mine causes exactly 15 HP loss and a hit fact")
	_check(scene.run_context.current_room_type == &"Event", "tutorial event room reached without editing the map")
	var teaching_id: String = scene.run_context.run_id
	await _reopen()
	_check(scene.run_context.run_id == teaching_id and scene.run_context.get_current_pos() == Vector2i(0, 3), "Main restart resumes the exact unfinished teaching room")
	_check(_data().talent_earned == 100 and _data().talent_spent == 0 and not _data().tutorial_completed, "restart preserves unused teaching points before entering a chest")
	_check(scene._show_run_screen(), "resumed teaching screen opens")
	if not _walk(Vector2i(0, 4)):
		return false
	_check(scene.in_run_runtime.has_active_combat(), "fixed teaching monster starts the real encounter")
	if not _check(scene.in_run_runtime.request_flee().get("ok", false), "public combat flee resolves the actual teaching encounter"):
		return false
	if not _walk(Vector2i(1, 4)):
		return false
	_check(_data().talent_flags == ["z2_talent_01"] and _data().talent_points == 0 and _data().talent_spent == 100, "real first chest entry automatically learns flag marking once")
	_check(_cmd(&"toggle_flag_cell", {"pos": Vector2i(1, 1)}).get("ok", false), "learned flag uses the real player command")
	if not _walk(Vector2i(2, 4)) or not _walk(Vector2i(3, 4)) or not _walk(Vector2i(4, 4)):
		return false
	if not _confirm_popup("exit_goal"):
		return false
	if not _extract():
		return false
	var settlement: Dictionary = scene.run_context.result_snapshot.get("settlement", {})
	_check(settlement.get("finalized", false) and settlement.get("tutorial_completion_only", false), "full fixed teaching route has a finalized training-only settlement")
	_check(scene.runtime_controller.last_meta_commit.get("ok", false), "real checkpoint applies teaching to Meta")
	_check(_data().tutorial_completed and _data().profile_level == 1 and _data().profile_exp == 0, "completed teaching naturally reaches Lv1 with zero exploration XP")
	_check(_data().run_count == 0 and _data().warehouse_items.is_empty(), "teaching grants neither ordinary run count nor starter items")
	_check(_task("M01").status == "active" and _task("M02").status == "locked", "teaching completion activates M01 only")
	_check(scene.result_panel.return_deploy_button.is_visible_in_tree() and not scene.result_panel.return_deploy_button.disabled, "saved teaching exposes its real return button")
	scene.result_panel.return_deploy_button.pressed.emit()
	await process_frame
	return _check(scene.screen_state == &"deploy_shell", "teaching result returns to deploy")


func _first_supplies() -> bool:
	var request := {"request_id": "journey-first-supplies", "source_page": "deploy_prep", "action": "claim_initial_supplies"}
	var claim: Dictionary = scene.runtime_controller.execute_meta_action(request)
	if not _check(claim.get("ok", false), "public first-supplies request commits after real teaching"):
		return false
	first_supplies = _data().warehouse_items.duplicate(true)
	var ids: Array = first_supplies.map(func(item: Dictionary): return str(item.item_id))
	ids.sort()
	_check(ids == ["con_ration", "con_tape_roll"] and first_supplies.size() == 2, "first package contains exactly ration and tape, one instance each")
	_check(_data().initial_supply_receipt.instance_ids.size() == 2, "first package has a two-instance durable receipt")
	var duplicate: Dictionary = scene.runtime_controller.execute_meta_action(request)
	_check(duplicate.get("ok", false) and duplicate.get("duplicate", false) and _data().warehouse_items == first_supplies, "same first-supplies request does not duplicate items")
	await _reopen()
	var disk_items: Array = _data().warehouse_items.duplicate(true)
	# Meta uses ordinary JSON for warehouse records: StringName becomes String
	# and small numeric fields become float. Compare every field in that format.
	var saved_supplies: Array = JSON.parse_string(JSON.stringify(first_supplies))
	_check(_data().profile_level == 1 and _data().tutorial_completed and disk_items == saved_supplies, "Lv1 and all fields of the exact two instances survive real Main restart")
	duplicate = scene.runtime_controller.execute_meta_action(request)
	return _check(duplicate.get("ok", false) and duplicate.get("duplicate", false) and _data().warehouse_items == saved_supplies, "durable replay after reload grants no extra starter items")


func _start_formal(seed_pick: int) -> bool:
	var choices := Maps.commission_offer_candidates("classic_7x7_simple", int(_data().run_count), 3)
	var before_sequence := int(_data().z2_fact_sequence)
	var result := _cmd(&"start_standard_run", {"run_start_config": {"map_config_id": "classic_7x7_simple", "difficulty": &"simple", "seed_value": seed_pick, "selected_objective_id": choices[0].id}})
	if not _check(result.get("ok", false), "public ordinary departure accepted: %s" % result.get("action_result", result)):
		return false
	var base := int(scene.run_context.run_start_config.profile_fields.get("z2_fact_sequence_base", -1))
	_check(base == before_sequence and int(_data().z2_fact_sequence) == base + 1 and int(_data().z2_quest_departures[str(scene.run_context.run_id)].departure_sequence) == base + 1, "admission freezes the prior base and durably reserves the next global fact sequence")
	_check(scene.run_context.mode != &"tutorial" and scene.run_context.hp == scene.run_context.max_hp, "ordinary run starts with actual full health")
	_check(scene.runtime_controller.checkpoint_service.load_checkpoint().get("ok", false), "formal departure has a real disk checkpoint")
	return _check(scene._show_run_screen(), "ordinary exploration uses the production run screen")


func _ordinary_success() -> bool:
	if not _start_formal(71):
		return false
	var context: RunContext = scene.run_context
	var path := _safe_exit_path(context)
	if not _check(not path.is_empty(), "fixed seed has a real non-combat route to an exit"):
		return false
	var searched := false
	for target: Vector2i in path:
		if not _walk(target):
			return false
		if not searched and context.current_room_type == &"Normal":
			if not _check(_cmd(&"search_current_room").get("ok", false), "first ordinary room starts a real timed search"):
				return false
			for tick in range(8):
				if context.searched_cells.has(context.cell_key(target)):
					break
				scene.runtime_controller.advance_idle_frame(1.0)
			searched = context.searched_cells.has(context.cell_key(target))
			_check(searched, "actual elapsed simulation completes the search and its real rewards")
	_check(searched, "first ordinary run includes one completed search")
	if not _extract():
		return false
	await _finalize_selection()
	if not _assert_terminal("success", 1):
		return false
	_check(_task("M01").status == "claimable" and _task("M02").status == "active", "first ordinary settlement completes M01 and activates M02 before claiming")
	var gold := int(_data().gold)
	var experience := int(_data().profile_exp)
	await _reopen()
	_check(_task("M01").status == "claimable" and _data().gold == gold, "unclaimed M01 and its unpaid gold survive restart")
	var run_score: Dictionary = scene.run_context.result_snapshot.duplicate(true)
	var saved_receipts: Dictionary = _data().run_receipts.duplicate(true)
	var request := {"request_id": "journey-m01-tier1", "source_page": "long_term", "action": "claim_goal", "goal_kind": "task", "goal_id": "M01", "tier": 1}
	var claim: Dictionary = scene.runtime_controller.execute_meta_action(request)
	_check(claim.get("ok", false) and claim.get("result", {}).get("tier", 0) == 1, "manual public M01 tier-one claim commits")
	_check(_data().gold == gold + 10 and _data().profile_exp == experience + 10, "M01 grants exactly ten gold and ten independent XP")
	_check(scene.run_context.result_snapshot == run_score, "manual task XP leaves the frozen run score untouched")
	_check(_data().run_receipts == saved_receipts, "manual task XP leaves all durable terminal receipt fields unchanged")
	_check(_task("M01").status == "claimed", "claim persists separately from completion")
	await _reopen()
	var after: Dictionary = _data().duplicate(true)
	var replay: Dictionary = scene.runtime_controller.execute_meta_action(request)
	_check(replay.get("ok", false) and replay.get("duplicate", false) and _data() == after, "reloaded manual claim replays its receipt without awarding twice")
	return _check(_data().run_count == 1 and _data().profile_level <= 2, "one natural ordinary run; no injected high-level growth")


func _ordinary_abandon() -> void:
	if not _start_formal(72):
		return
	var run_id: String = scene.run_context.run_id
	var origin: Vector2i = scene.run_context.get_current_pos()
	for direction: Vector2i in DIRECTIONS:
		var target := origin + direction
		if scene.run_context.truth_map.is_inside(target) and scene.run_context.truth_map.get_room_type(target) == &"Normal":
			_walk(target)
			break
	var result := _cmd(&"abandon_run", {"confirmed": true, "source": "pause_panel"})
	if not _check(result.get("ok", false), "public abandon enters actual terminal retention"):
		return
	await _reopen()
	_check(scene.run_context.run_id == run_id and scene.run_context.phase == &"failure_salvage", "unconfirmed abandon survives real Main restart")
	await _finalize_selection()
	_assert_terminal("abandon", 2)
	await _reopen()
	_check(_data().run_count == 2 and _data().abandon_count == 1 and _task("M01").status == "claimed", "abandon restart preserves counts and earlier manual claim")


func _ordinary_death() -> void:
	if not _start_formal(73):
		return
	var context: RunContext = scene.run_context
	var visited: Array[Vector2i] = [context.get_current_pos()]
	var corridor: Array[Vector2i] = []
	for index in range(5):
		for direction: Vector2i in DIRECTIONS:
			var candidate: Vector2i = visited.back() + direction
			if context.truth_map.is_inside(candidate) and not visited.has(candidate) and not context.truth_map.get_exits().has(candidate):
				visited.append(candidate)
				corridor.append(candidate)
				break
	_check(corridor.size() == 5 and context.hp == 100, "death fixture controls five 20-damage simple-map mines and starts with natural 100 HP")
	for target: Vector2i in corridor:
		context.truth_map.set_room_type(target, &"Mine")
	_check(scene.runtime_controller.save_current_checkpoint().get("ok", false), "controlled mine corridor saved by the actual checkpoint service")
	for target: Vector2i in corridor:
		if not context.run_active:
			break
		_walk(target)
	_check(context.hp == 0 and context.failed and context.run_stats.get("mine_hits", 0) > 0, "actual mine entry damage reaches death without editing player vitals")
	await _finalize_selection()
	_assert_terminal("failure", 3)
	await _reopen()
	_check(_data().run_count == 3 and _data().extract_count == 1 and _data().abandon_count == 1 and _data().fail_count == 1, "three real endings survive Main reload exactly once each")
	_check(_data().talent_spent == 100 and _data().initial_supply_receipt.instance_ids.size() == 2 and _task("M01").status == "claimed", "all endings preserve teaching purchase, two-item first package and claimed M01")


func _safe_exit_path(context: RunContext) -> Array[Vector2i]:
	var origin := context.get_current_pos()
	var frontier: Array[Vector2i] = [origin]
	var previous := {origin: origin}
	for at: Vector2i in frontier:
		if at != origin and context.truth_map.get_exits().has(at):
			var path: Array[Vector2i] = []
			while at != origin:
				path.push_front(at)
				at = previous[at]
			return path
		for direction: Vector2i in DIRECTIONS:
			var next := at + direction
			if context.truth_map.is_inside(next) and not previous.has(next) and context.truth_map.get_room_type(next) not in [&"Mine", &"Monster"]:
				previous[next] = at
				frontier.append(next)
	return []


func _walk(target: Vector2i) -> bool:
	var result := _cmd(&"attempt_room_transition", {"direction": target - scene.run_context.get_current_pos()})
	return _check(result.get("ok", false) and scene.run_context.get_current_pos() == target, "public movement enters %s (%s)" % [target, result.get("reason", "")])


func _confirm_popup(id: String) -> bool:
	var button := scene.tutorial_popup_panel.find_child("ConfirmButton", true, false) as Button
	if not _check(str(scene.run_context.tutorial_popup.get("id", "")) == id and button != null and button.is_visible_in_tree(), "real tutorial confirmation visible: " + id):
		return false
	var meta_before: Dictionary = _data().duplicate(true)
	if not scene.tutorial_popup_panel.layout_snapshot().get("guidance_expanded", false):
		button.pressed.emit()
	_check(scene.tutorial_popup_panel.layout_snapshot().get("guidance_expanded", false), "details button expands complete teaching text: " + id)
	button.pressed.emit()
	return _check(str(scene.run_context.tutorial_popup.get("id", "")) != id and not scene.run_context.has_blocking_tutorial_popup() and _data() == meta_before, "separate guidance dismissal never purchases: " + id)


func _extract() -> bool:
	if not _check(_cmd(&"request_extract").get("ok", false) and scene.run_context.phase == &"confirm_extract", "public extraction request revalidates the actual exit"):
		return false
	return _check(_cmd(&"confirm_extract").get("ok", false), "public extraction confirmation creates the real settlement")


func _finalize_selection() -> void:
	if scene.run_context.phase == &"failure_salvage":
		var result := _cmd(&"confirm_failure_salvage", {"selected_instance_ids": []})
		_check(result.get("ok", false), "explicit terminal selection finalizes through the public command")
	await process_frame


func _assert_terminal(ending: String, count: int) -> bool:
	var snapshot: Dictionary = scene.run_context.result_snapshot
	var settlement: Dictionary = snapshot.get("settlement", {})
	_check(settlement.get("finalized", false) and str(settlement.get("outcome", "")) == ending, "actual finalized settlement outcome: " + ending)
	_check(scene.result_panel.is_visible_in_tree(), "production result panel presents " + ending)
	_check(_data().get("admission", {}).is_empty(), "committed terminal clears the active admission")
	_check(_data().run_count == count, "ordinary run count advances exactly once: %d" % count)
	return _check(scene.runtime_controller.last_meta_commit.get("ok", false) and _data().run_receipts.has(str(scene.run_context.run_id)), "actual Meta stores the terminal receipt for " + ending)


func _cmd(command: StringName, payload: Dictionary = {}) -> Dictionary:
	return scene._dispatch_command(command, payload, false, false)


func _data() -> Dictionary:
	return scene.meta_progress_adapter.data


func _task(id: String) -> Dictionary:
	return scene.meta_progress_adapter.get_summary().get("task_states", {}).get(id, {})


func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
		print("Z2_NEW_PLAYER_CASE_FAIL " + message)
	return condition


func _finish() -> void:
	print("Z2_NEW_PLAYER_JOURNEY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
