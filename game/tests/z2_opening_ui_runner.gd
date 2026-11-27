extends SceneTree

var checks := 0
var failures: Array[String] = []
var main: Node
var scene


func _initialize() -> void:
	call_deferred("_run")


func _check(value: bool, label: String) -> bool:
	checks += 1
	if not value:
		failures.append(label)
	return value


func _open_main() -> void:
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	scene = main.get_node("RunScene")
	await process_frame


func _close_main() -> void:
	main.queue_free()
	for frame in range(3):
		await process_frame


func _deploy() -> bool:
	var button: Button = scene.ui_shell.get_main_page().entry_nodes[&"deploy"].button
	button.pressed.emit()
	var deadline := Time.get_ticks_msec() + 6000
	while scene.screen_state != &"deploy_shell" and Time.get_ticks_msec() < deadline:
		await process_frame
	return _check(scene.screen_state == &"deploy_shell", "Main explore button opens deploy")


func _enter_run() -> bool:
	var deploy: Control = scene.ui_shell.get_deploy_page()
	if not _check(not deploy.primary_action_button.disabled, "confirm departure / continue is enabled"):
		return false
	deploy.primary_action_button.pressed.emit()
	var deadline := Time.get_ticks_msec() + 6000
	while scene.screen_state != &"run" and Time.get_ticks_msec() < deadline:
		await process_frame
	return _check(scene.screen_state == &"run", "confirm button reaches formal run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	if OS.get_cmdline_user_args().has("--restore-paid"):
		await _open_main()
		if await _deploy() and await _enter_run():
			var offer: Dictionary = scene.runtime_controller.spawn_opening_offer()
			_check(offer.get("status") == "offered" and offer.get("refresh_count") == 1 and offer.get("paid_gold") == 5 and offer.get("receipts", {}).size() == 1, "archived run restores paid offer and receipt")
			_check(int(scene.meta_progress_adapter.data.gold) == 0, "archived balance reflects one payment")
			var panel: Control = scene.z2_ui_controller.opening_panel
			if _check(panel.is_visible_in_tree(), "archive continuation restores spawn prompt"):
				panel.find_child("OpeningChoice0", true, false).pressed.emit()
				_check(scene.run_context.run_start_config.opening_effect.get("id") == offer.candidates[0], "archive selection is applied")
		await _close_main()
		_finish()
		return
	var manager := SaveManager.new()
	manager.load_manifest()
	var previous_profile := manager.active_profile_id
	manager.switch_profile("opening_ui_%d" % Time.get_ticks_usec())
	manager.save_manifest()
	await _open_main()
	var meta: MetaProgressAdapter = scene.meta_progress_adapter
	meta.begin_tutorial_training()
	meta.purchase_tutorial_flag()
	meta._apply_tutorial_settlement({"mode": "tutorial", "outcome": "Training Complete", "settlement": {"outcome": "success"}}, "opening_ui_tutorial")
	meta.data.gold = 5
	meta.data.talent_flags.append("z2_talent_15")
	_check(meta.save(), "qualification fixture persisted")
	scene._show_main_menu()
	if await _deploy():
		var page: Control = scene.ui_shell.get_deploy_page()
		page.show_tab(&"loadout")
		for row: Dictionary in page.current_model.selection_rows:
			_check(not str(row.id).begins_with("opening_"), "loadout has no opening choices")
		page.show_tab(&"config")
		var split: Control = page.map_split_view
		split.scale_buttons[&"7x7"].pressed.emit()
		await process_frame
		split.difficulty_buttons[&"classic_7x7_simple"].pressed.emit()
		await process_frame
		if str(split.selected_map_id) != "classic_7x7_simple":
			split.select_action_button.pressed.emit()
		if await _enter_run():
			await _spawn()
	await _close_main()
	if not OS.get_cmdline_user_args().has("--leave-paid"):
		manager.switch_profile(previous_profile)
		manager.save_manifest()
	_finish()


func _finish() -> void:
	for failure in failures: print("Z2_OPENING_UI_FAIL " + failure)
	print("Z2_OPENING_UI=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)


func _spawn() -> void:
	var panel: Control = scene.z2_ui_controller.opening_panel
	if not _check(scene._runtime_modal_is_top(&"spawn_opening") and panel.is_visible_in_tree(), "spawn waits with modal visible"):
		return
	var room: Vector2i = scene.run_context.get_current_pos()
	var position: Vector2 = scene.player_controller.get_local_position()
	Input.action_press("move_right")
	scene._process(0.2)
	Input.action_release("move_right")
	_check(scene.run_context.get_current_pos() == room and position == scene.player_controller.get_local_position(), "held movement is blocked in spawn")
	scene._close_top_runtime_modal()
	_check(panel.is_visible_in_tree(), "Escape does not silently decide")
	var refresh := panel.find_child("OpeningRefresh", true, false) as Button
	refresh.pressed.emit()
	refresh.pressed.emit()
	await process_frame
	_check(int(scene.meta_progress_adapter.data.gold) == 0 and refresh.disabled, "double press charges five once then disables unaffordable refresh")
	var offer: Dictionary = scene.runtime_controller.spawn_opening_offer()
	_check(offer.refresh_count == 1 and offer.candidates.size() == 3, "three refreshed candidates")
	if OS.get_cmdline_user_args().has("--leave-paid"):
		print("Z2_OPENING_ARCHIVE run=", scene.run_context.run_id, " candidates=", offer.candidates, " paid=", offer.paid_gold)
		return
	await _close_main()
	await _open_main()
	if not await _deploy() or not await _enter_run(): return
	panel = scene.z2_ui_controller.opening_panel
	_check(scene.runtime_controller.spawn_opening_offer() == JSON.parse_string(JSON.stringify(offer)) and panel.is_visible_in_tree(), "new Main continuation restores paid choices before input")
	var skip := panel.find_child("OpeningSkip", true, false) as Button
	_check(not skip.disabled, "free skip remains available")
	skip.pressed.emit()
	await process_frame
	_check(not panel.is_visible_in_tree() and scene.run_context.z1_event_flags.z2_opening.status == "skipped" and scene.player_controller.input_enabled, "skip restores gameplay input")
	await _close_main()
	await _open_main()
	if not await _deploy() or not await _enter_run(): return
	_check(not scene.z2_ui_controller.opening_panel.is_visible_in_tree() and scene.run_context.z1_event_flags.z2_opening.status == "skipped", "final skip survives another Main restart")
	Input.action_press("move_right")
	var before_move: Vector2 = scene.player_controller.get_local_position()
	scene._process(0.05)
	Input.action_release("move_right")
	_check(scene.player_controller.get_local_position() != before_move, "first movement works after skip")
