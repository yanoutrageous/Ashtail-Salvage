extends SceneTree

const MAIN_PATH := "res://scenes/main/main.tscn"
const DIALOGUE_SCRIPT := "res://scripts/ui/z2_overlays/z2_event_dialogue.gd"
const WorldProjectionScript := preload("res://scripts/gameplay/runtime/g41_world_object_projection.gd")
const RELIEF_FEE := 5
const RELIEF_AMOUNT := 5
const STARTING_BLACK := 8
const STARTING_PRESSURE := 40

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _isolated_save_directory():
		printerr("Z2_FORMAL_EVENT_OVERLAY=FAIL: use fresh user data under Z2_FORMAL_QA_HOME")
		quit(1)
		return
	root.size = Vector2i(1280, 720)
	print("Z2_FORMAL_EVENT_OVERLAY_CASE=relief")
	var packed := load(MAIN_PATH) as PackedScene
	if _check(packed != null, "load production main.tscn"):
		var main := packed.instantiate()
		root.add_child(main)
		current_scene = main
		var scene = main.get_node_or_null("RunScene")
		if _check(scene != null, "main.tscn owns RunScene"):
			scene.set_process(false)
			await process_frame
			if _enter_relief_room(scene):
				await _capture_room("B-main-exploration.png")
				await _test_dialogue(main, scene)
				await _capture_room("B-main-after-service.png")
			elif _find_dialogue(main) == null:
				_check(false, "main.tscn has no attached T15 EventDialogue")
		await _release_main(main, scene)
	for failure in failures:
		printerr("Z2_FORMAL_EVENT_OVERLAY=FAIL: " + failure)
	print("Z2_FORMAL_EVENT_OVERLAY=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _release_main(main: Node, scene: Node) -> void:
	var streams: Array[WeakRef] = []
	if scene != null:
		for child in scene.player_feedback_service.get_children():
			if child is AudioStreamPlayer and child.stream != null:
				streams.append(weakref(child.stream))
				child.stop()
				child.stream = null
		scene.in_run_runtime.bind(null)
		scene.command_bus.bind_runtime_controller(null)
	main.queue_free()
	await process_frame
	# The audio mixer may release stopped feedback streams on a later frame.
	var deadline := Time.get_ticks_msec() + 1000
	while streams.any(func(stream: WeakRef) -> bool: return stream.get_ref() != null):
		if Time.get_ticks_msec() >= deadline:
			failures.append("event audio teardown timed out")
			break
		await process_frame


func _isolated_save_directory() -> bool:
	var qa_home := OS.get_environment("Z2_FORMAL_QA_HOME").simplify_path().replace("\\", "/").trim_suffix("/")
	var data_dir := OS.get_user_data_dir().simplify_path().replace("\\", "/")
	if not qa_home.is_absolute_path() or not data_dir.to_lower().begins_with(qa_home.to_lower() + "/"):
		return false
	var saves := DirAccess.open("user://saves")
	var profiles := DirAccess.open("user://saves/profiles")
	return (saves == null or saves.get_files().is_empty()) \
		and (profiles == null or (profiles.get_directories().is_empty() and profiles.get_files().is_empty())) \
		and not FileAccess.file_exists("user://graytail_m1_meta_progress.json")


func _enter_relief_room(scene) -> bool:
	var runtime = scene.runtime_controller
	var context: RunContext = scene.run_context
	var meta = scene.meta_progress_adapter
	if not _check(runtime.checkpoint_service != null and runtime.persistence_error.is_empty() and not context.run_started, "fresh isolated Z2 profile and production checkpoint service"):
		return false
	if not _check(int(meta.data.get("z2_progression_version", 0)) == 1, "production profile initializes Z2 progression"):
		return false
	# Seed only the tutorial prerequisite. Admission and map entry still go through RunScene.
	meta.data.merge({"tutorial_completed": true, "profile_level": 1, "profile_exp": 0,
		"talent_flags": ["z2_talent_01"], "talent_earned": 100, "talent_spent": 100, "talent_points": 0,
		"unlocked_map_ids": ["tutorial_5x5", "classic_7x7_simple"]}, true)
	if not _check(meta.save(), "save level-one fixture profile: %s" % meta.last_error):
		return false
	var start: Dictionary = scene.command_bus.dispatch(&"start_standard_run", {"run_start_config": {
		"map_config_id": "classic_7x7_simple", "difficulty": "simple", "seed_value": 3141,
		"selected_objective_id": "commission_recover_supply"}})
	if not _check(bool(start.get("ok", false)) and context.run_active, "production Z2 run admission: %s" % _reason(start)):
		return false
	if not _check(scene._show_run_screen(), "real gameplay screen opens"):
		return false
	var direction := Vector2i.ZERO
	for candidate: Vector2i in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
		var neighbor := context.get_current_pos() + candidate
		if context.is_inside(neighbor) and context.truth_map.get_room_type(neighbor) == &"Normal":
			direction = candidate
			break
	if not _check(direction != Vector2i.ZERO, "seed 3141 has a normal neighbor for the fixed event fixture"):
		return false
	var room := context.get_current_pos() + direction
	var key := context.cell_key(room)
	# Fix the neighboring room identity and starting resources. The event service owns
	# its offers, availability, transaction, progress and response.
	var fixture: Dictionary = runtime.execute_atomic_operation(&"z2_formal_relief_fixture", {}, func() -> Dictionary:
		context.truth_map.set_room_type(room, &"Event")
		context.z1_event_rooms[key] = {"event_type": &"relief"}
		context.intel_map.reveal_cell(room, context.truth_map)
		context.tutorial_popup.clear()
		context.asset_ledger.add_currency(&"black_coin", STARTING_BLACK, "z2_formal_relief_fixture")
		return {"ok": true}
	)
	if not _check(bool(fixture.get("ok", false)), "fixed room and wallet are durably seeded: %s" % _reason(fixture)):
		return false
	scene._attempt_room_transition(direction)
	if not _check(context.get_current_pos() == room and context.visited_cells.has(key) and context.current_room_type == &"Event", "production room transition reaches the actual event room: %s" % _reason(scene.last_command_result)):
		return false
	var event: Dictionary = context.get_status_snapshot().get("event_state", {})
	if not _check(event.get("ruleset_id", "") == "z2" and event.get("event_type", "") == "relief", "room resolves through Z2 EventService: %s" % str(event.get("event_type", ""))):
		return false
	var vitals: Dictionary = runtime.execute_atomic_operation(&"z2_formal_relief_vitals", {}, func() -> Dictionary:
		context.pressure = STARTING_PRESSURE
		context.protocol_level = ProtocolService.level_for_pressure(context.pressure)
		context.temporary_statuses = [{"id": "z2-formal-relief-dot", "type": "temporary_debuff",
			"temporary_type": "dot", "phase": "active", "remaining": 10.0, "elapsed": 0.0, "dot_per_second": 10.0}]
		return {"ok": true}
	)
	if not _check(bool(vitals.get("ok", false)) and context.asset_ledger.get_currency(&"black_coin") == STARTING_BLACK, "fixture starts at 40 pressure and 8 black coins"):
		return false
	for object: Dictionary in WorldProjectionScript.build(context.get_status_snapshot()).get("world_objects", []):
		if object.get("interaction_kind", &"") == &"event":
			scene.player_controller.set_local_position(Vector2(object.local_pos))
			scene._process(0.0)
			print("Z2_FORMAL_EVENT_OVERLAY_ENTERED room=%s event=relief" % key)
			return true
	return _check(false, "real room projects a world interaction for relief")


func _test_dialogue(main: Node, scene) -> void:
	_key(KEY_E)
	await process_frame
	await process_frame
	var dialogue := _find_dialogue(main)
	var legacy_panel := scene.get("event_panel") as Control
	var legacy_visible := legacy_panel != null and legacy_panel.is_visible_in_tree()
	if not _check(dialogue != null and dialogue.is_visible_in_tree(), "world interact opens the T15 EventDialogue attached to production main.tscn (legacy panel visible: %s)" % legacy_visible):
		return
	var body := dialogue.get_node_or_null("%DialogueText") as RichTextLabel
	var speaker := dialogue.get_node_or_null("%SpeakerName") as Label
	var frame := dialogue.get_node_or_null("%DialogueFrame") as Control
	if not _check(body != null and speaker != null and frame != null, "T15 dialogue exposes its scene controls"):
		return
	_check(body.is_visible_in_tree() and not body.text.is_empty() and speaker.is_visible_in_tree() and not speaker.text.is_empty(),
		"real event opens with NPC name and dialogue (speaker %s, body %s)" % [speaker.text, body.text])
	var opening_line := body.text
	var frame_center := frame.get_global_transform_with_canvas() * (frame.size * 0.5)
	_check(frame_center.y > root.get_visible_rect().get_center().y, "dialogue frame sits in the lower part of the gameplay viewport")
	var requests: Array[Dictionary] = []
	dialogue.connect("choice_requested", func(request: Dictionary) -> void: requests.append(request.duplicate(true)))
	var flat := await _relief_button(dialogue)
	if not _check(flat != null and not flat.disabled, "relief quote exposes an actionable 简单休息 button"):
		return
	var cost := flat.find_child("OptionCost", true, false) as Label
	var effect := flat.find_child("OptionEffect", true, false) as Label
	_check(cost != null and cost.is_visible_in_tree() and cost.text.replace(" ", "").contains("%d黑币" % RELIEF_FEE), "visible simple rest quote costs 5 black coins")
	_check(effect != null and effect.is_visible_in_tree() and effect.text.contains("压") and effect.text.contains(str(RELIEF_AMOUNT)),
		"visible simple rest quote describes the 5-point pressure reduction (shown %s)" % (effect.text if effect != null else "missing"))
	await _capture("dialogue-open.png", scene, body)
	var foot_bath := _option(dialogue, "泡脚")
	if _check(foot_bath != null and foot_bath.disabled, "10-coin foot bath is disabled with 8 black coins"):
		var hint := foot_bath.find_child("OptionReason", true, false) as Label
		_check(hint != null and hint.is_visible_in_tree() and hint.text.contains("不足"), "unaffordable option explains its availability")
		var request_count := requests.size()
		await _click(foot_bath)
		_check(requests.size() == request_count, "clicking the disabled option sends no requests")

	var runtime = scene.runtime_controller
	var context: RunContext = scene.run_context
	var moved_quote: Dictionary = runtime.execute_atomic_operation(&"z2_formal_relief_wallet_change", {}, func() -> Dictionary:
		context.asset_ledger.add_currency(&"black_coin", 1, "z2_formal_relief_wallet_change")
		return {"ok": true}
	)
	if not _check(bool(moved_quote.get("ok", false)) and is_instance_valid(flat) and flat.is_visible_in_tree() and not flat.disabled, "durable balance change leaves the previously displayed button available for rejection"):
		return
	var checkpoint_path: String = runtime.checkpoint_service.checkpoint_path
	var before: Dictionary = runtime.capture_authoritative_state()
	var before_hash := FileAccess.get_sha256(checkpoint_path)
	var request_count := requests.size()
	await _click(flat)
	var rejection: Dictionary = scene.last_command_result
	var reason := _reason(rejection)
	var stale_submitted := requests.size() == request_count + 1
	var stale_request: Dictionary = requests.back() if stale_submitted else {}
	var rejected := _check(stale_submitted and not str(stale_request.get("room_id", "")).is_empty() and not bool(rejection.get("ok", false)) and reason in ["stale_preview", "stale_quote", "stale_revision"], "actual stale dialogue submission is rejected: %s" % reason)
	var unchanged := _check(runtime.capture_authoritative_state() == before and not before_hash.is_empty() and FileAccess.get_sha256(checkpoint_path) == before_hash, "rejection leaves authority and the durable checkpoint unchanged")
	if rejected and unchanged:
		print("Z2_FORMAL_EVENT_OVERLAY_REJECTED reason=%s checkpoint_unchanged=true" % reason)
	var feedback := dialogue.get_node_or_null("%DialogueStatus") as RichTextLabel
	_check(feedback != null and feedback.is_visible_in_tree() and not feedback.text.strip_edges().is_empty() and not feedback.text.contains("等待结果"), "actual dialogue shows the rejected submission's feedback")
	var rejected_line := body.text

	flat = await _relief_button(dialogue)
	if not _check(flat != null and not flat.disabled, "updated quote makes the real simple rest button usable again"):
		return
	var coins_before := context.asset_ledger.get_currency(&"black_coin")
	var pressure_before := context.pressure
	var receipts_before: int = runtime.action_receipts.size()
	var fresh_hash := FileAccess.get_sha256(checkpoint_path)
	request_count = requests.size()
	await _click(flat)
	var result: Dictionary = scene.last_command_result
	var action: Dictionary = result.get("action_result", {})
	var facts: Dictionary = action.get("facts", {})
	var receipt_id := str(result.get("action_id", ""))
	var receipt: Dictionary = runtime.action_receipts.get(receipt_id, {}).get("result", {})
	var fresh_request: Dictionary = requests.back() if requests.size() == request_count + 1 else {}
	var accepted := _check(not fresh_request.is_empty() and bool(result.get("ok", false)) and str(action.get("option_id", "")) == "flat", "actual updated button dispatches one successful relief selection: %s" % _reason(result))
	_check(not receipt_id.is_empty() and str(fresh_request.get("action_id", "")) == receipt_id and int(fresh_request.get("attempt_id", 0)) > int(stale_request.get("attempt_id", 0)), "new dialogue attempt owns the committed action identity")
	_check(context.asset_ledger.get_currency(&"black_coin") == coins_before - RELIEF_FEE and int(facts.get("fee_black", -1)) == RELIEF_FEE, "authoritative receipt and ledger record exactly 5 black coins spent")
	_check(context.pressure == pressure_before - RELIEF_AMOUNT and int(facts.get("pressure", {}).get("actual_pressure_delta", 0)) == -RELIEF_AMOUNT, "authoritative receipt records exactly 5 pressure reduced")
	var committed: bool = runtime.action_receipts.size() == receipts_before + 1 and not receipt.is_empty() \
		and receipt.get("action_result", {}) == action and not fresh_hash.is_empty() and FileAccess.get_sha256(checkpoint_path) != fresh_hash
	_check(committed, "one actual receipt is installed and the checkpoint is updated")
	if accepted and committed:
		print("Z2_FORMAL_EVENT_OVERLAY_COMMITTED black=%d->%d pressure=%d->%d" % [
			coins_before, context.asset_ledger.get_currency(&"black_coin"), pressure_before, context.pressure])
	var reply_visible := dialogue.is_visible_in_tree() and speaker.is_visible_in_tree() and not speaker.text.is_empty() \
		and body.is_visible_in_tree() and not body.text.strip_edges().is_empty() and body.text != opening_line and body.text != rejected_line \
		and body.text.contains(str(RELIEF_AMOUNT)) and body.text.contains(str(pressure_before - RELIEF_AMOUNT))
	_check(reply_visible, "successful committed choice shows a new NPC reply in the actual dialogue (speaker %s, body %s)" % [speaker.text, body.text])
	if not accepted or not committed or not dialogue.is_visible_in_tree():
		return
	await _capture("dialogue-accepted.png", scene, body)

	var interaction_position: Vector2 = scene.player_controller.get_local_position()
	await _test_modal_time_and_input(scene, dialogue)
	var recorded_black := context.asset_ledger.get_currency(&"black_coin")
	var recorded_pressure := context.pressure
	request_count = requests.size()
	scene.player_controller.set_local_position(interaction_position)
	scene._process(0.0)
	_key(KEY_E)
	await process_frame
	var choices := dialogue.get_node_or_null("%ChoicesFrame") as Control
	for _step in range(8):
		if not dialogue.is_visible_in_tree() or choices == null or choices.is_visible_in_tree():
			break
		_key(KEY_SPACE)
		await process_frame
	flat = _option(dialogue, "简单休息")
	_check(bool(action.get("completed", false)) and (flat == null or flat.disabled) and requests.size() == request_count \
		and context.asset_ledger.get_currency(&"black_coin") == recorded_black and context.pressure == recorded_pressure, "reopening the completed event offers no repeat payment")


func _test_modal_time_and_input(scene, dialogue: Control) -> void:
	var context: RunContext = scene.run_context
	var player = scene.player_controller
	var room := context.get_current_pos()
	var position: Vector2 = player.get_local_position()
	var hp := context.hp
	if not _check(not context.temporary_statuses.is_empty(), "timed DOT fixture survives the relief action"):
		return
	var remaining := float(context.temporary_statuses[0].remaining)
	Input.action_press(&"move_right")
	scene._process(0.25)
	scene._process(0.25)
	Input.action_release(&"move_right")
	_check(not player.input_enabled and context.get_current_pos() == room and player.get_local_position().is_equal_approx(position), "dialogue blocks movement without leaving the room")
	_check(context.hp < hp and not context.temporary_statuses.is_empty() and is_equal_approx(float(context.temporary_statuses[0].remaining), remaining - 0.5), "the production frame still advances DOT damage and status time during dialogue")
	var close := dialogue.get_node_or_null("%CloseDialogue") as Button
	if not _check(close != null and close.is_visible_in_tree(), "dialogue exposes the actual close button"):
		return
	await _click(close)
	var closed := not dialogue.is_visible_in_tree() and not bool(scene._runtime_modal_is_top(&"event"))
	# The interaction anchor may overlap the station's inflated collision box.
	# Probe restored input from the actual room's clear floor.
	var clear_floor: Vector2 = player.place_on_clear_floor(Vector2(0.50, 0.72))
	Input.action_press(&"move_right")
	scene._process(0.15)
	Input.action_release(&"move_right")
	var resumed: Vector2 = player.get_local_position()
	_check(closed and player.input_enabled and resumed.x > clear_floor.x,
		"closing the dialogue releases gameplay input and movement resumes (closed %s, input %s, local %s -> %s)" %
		[closed, player.input_enabled, clear_floor, resumed])


func _find_dialogue(main: Node) -> Control:
	for control in main.find_children("*", "Control", true, false):
		var script := control.get_script() as Script
		if script != null and script.resource_path == DIALOGUE_SCRIPT:
			return control as Control
	return null


func _relief_button(dialogue: Control) -> Button:
	# S3 has source dialogue both before and after preparing the service.
	for phase in range(2):
		var line_count: int = (dialogue.get("_lines") as Array).size()
		for _step in range(2 * line_count + 3):
			var flat := _option(dialogue, "简单休息")
			if flat != null and flat.is_visible_in_tree() and not flat.disabled:
				await _scroll_option_into_view(flat)
				return flat
			var prepare := _option(dialogue, "查看服务")
			if phase == 0 and prepare != null and prepare.is_visible_in_tree() and not prepare.disabled:
				await _click(prepare)
				break
			_key(KEY_SPACE)
			await process_frame
	return null


func _option(dialogue: Control, title: String) -> Button:
	var options := dialogue.get_node_or_null("%Options")
	if options == null:
		return null
	for child in options.get_children():
		if child is Button and child.is_visible_in_tree() and child.accessibility_name == title:
			return child as Button
	return null


func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		root.push_input(event, true)


func _scroll_option_into_view(control: Control) -> void:
	var ancestor := control.get_parent()
	while ancestor is Control:
		if ancestor is ScrollContainer:
			await process_frame
			ancestor.ensure_control_visible(control)
			await process_frame
			return
		ancestor = ancestor.get_parent()


func _click(control: Control) -> void:
	await _scroll_option_into_view(control)
	var point := control.get_global_transform_with_canvas() * (control.size * 0.5)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		root.push_input(event, true)
	await process_frame
	await process_frame


func _capture(file_name: String, scene, body: RichTextLabel) -> void:
	var directory := OS.get_environment("Z2_FORMAL_CAPTURE_DIR")
	if directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	if not _check(directory.is_absolute_path() and DirAccess.make_dir_recursive_absolute(directory) == OK, "create rendered capture directory"):
		return
	scene._process(0.0)
	# Wait for the currently displayed line without advancing the gameplay clock.
	for _frame in range(240):
		if body.visible_characters < 0 or body.visible_characters >= body.get_total_character_count():
			break
		await process_frame
	await RenderingServer.frame_post_draw
	var screenshot := root.get_texture().get_image()
	var path := directory.path_join(file_name)
	if _check(screenshot != null and not screenshot.is_empty() and screenshot.save_png(path) == OK, "save %s" % file_name):
		print("Z2_FORMAL_EVENT_OVERLAY_CAPTURE=" + path)


func _reason(result: Dictionary) -> String:
	var action: Dictionary = result.get("action_result", {})
	return str(result.get("reason", action.get("reason", result.get("status", ""))))


func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


func _capture_room(file_name: String) -> void:
	var directory := OS.get_environment("Z2_FORMAL_CAPTURE_DIR")
	if directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(directory)
	await create_timer(0.25).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	_check(image != null and not image.is_empty() and image.save_png(directory.path_join(file_name)) == OK, "capture actual B room in production Main")
