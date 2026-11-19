extends "res://tests/i3r_production_combat_obstacle_journey_runner.gd"

const Weapons := preload("res://scripts/gameplay/combat/field_weapons.gd")
const ItemCatalog := preload("res://scripts/core/content/z2_item_catalog.gd")
const VectorSkin := preload("res://scripts/ui/run_surface/run_vector_skin.gd")
const WorldProjection := preload("res://scripts/gameplay/runtime/g41_world_object_projection.gd")
var evidence := ""
var capture_count := 0


func _run() -> void:
	var options := {}
	for arg in OS.get_cmdline_user_args():
		if arg.contains("="):
			options[arg.get_slice("=", 0)] = arg.substr(arg.find("=") + 1)
	var width := int(options.get("--width", 1280))
	var ui_scale := float(options.get("--ui-scale", 1.0))
	evidence = str(options.get("--evidence-dir", ""))
	if not evidence.is_empty():
		DirAccess.make_dir_recursive_absolute(evidence)
	root.size = Vector2i(width, roundi(width * 9.0 / 16.0))
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await _frames(12)
	root.size = Vector2i(width, roundi(width * 9.0 / 16.0))
	run_scene = main.get_node("RunScene")
	run_scene.call("_on_app_shell_ui_scale_changed", ui_scale)
	_require(bool(preload("res://tests/z2_legacy_main_fixture.gd").qualify(run_scene).get("ok", false)), "fixture qualification")
	await _tap_key(KEY_ENTER)
	if not await _wait_screen(&"deploy_shell", 12.0):
		_require(false, "Enter did not reach deployment")
		_finish()
		return
	_set_only_fixed_seed(_deploy_page())
	await _click_control(_deploy_page().find_child("DeployPrimaryAction", true, false))
	if not await _wait_screen(&"run", 12.0):
		_require(false, "deploy click did not start the run")
		_finish()
		return
	await _frames(8)
	var context: RunContext = run_scene.get("run_context")
	var surface = run_scene.get("run_surface")
	var weapon = surface.weapon_panel
	var runtime = run_scene.get("in_run_runtime")
	var room_view = run_scene.get("room_runtime_view")
	# Seed two documented encounter types on the deterministic route. Their
	# entrance, interactions and combat still go through the production scene.
	context.z1_event_rooms[context.cell_key(Vector2i(3, 5))] = {"event_type": &"relief"}
	context.truth_map.set_room_type(Vector2i(3, 4), &"Event")
	context.z1_event_rooms[context.cell_key(Vector2i(3, 4))] = {"event_type": &"cage"}
	context.asset_ledger.add_currency(&"black_coin", 8, "run_ui_journey")
	await _capture("normal")
	_require(weapon.weapon_name.text == "战斧" and weapon.weapon_buttons[Weapons.AXE].button_pressed, "initial axe")
	_require(surface.player_health_hud.get_node("HealthValue").text == "%s / %s" % [_status().hp, _status().max_hp], "health projection")
	_require(is_equal_approx(surface.player_health_hud._ratio, float(_status().hp) / float(_status().max_hp)), "health fill")
	_require(not weapon.get_global_rect().intersects(surface.get_minimap_panel().get_global_rect()), "HUD panels overlap")
	_require(weapon.get_global_rect().end.y <= surface.room_title_label.get_global_rect().position.y, "weapon panel overlaps room title")
	_require(surface.get_minimap_panel().view_model != null, "minimap has no revealed model")

	await _click_control(surface.get_minimap_panel())
	var map: Control = run_scene.get("map_overlay_panel")
	_require(map.visible, "click on minimap opens full map")
	await _capture("map")
	await _tap_key(KEY_ESCAPE)
	_require(not map.visible, "Escape closes map")
	context.asset_ledger.create_item_instance(ItemCatalog.definition("col_01"), &"inventory")
	context.asset_ledger.sync_compat_fields(context)
	run_scene.call("_refresh_view_models")
	await _tap_key(KEY_Q)
	var inventory: Control = run_scene.get("inventory_panel")
	_require(inventory.visible, "Q opens inventory")
	await _capture("inventory")
	await _tap_key(KEY_Q)
	_require(not inventory.visible, "Q closes inventory")
	await _tap_key(KEY_Q)
	await _click_control(inventory.find_child("InventoryCloseButton", true, false))
	_require(not inventory.visible, "pointer click on SVG inventory close control")

	_require(await _transition_room(Vector2i.RIGHT, Vector2i(3, 6), &"Chest"), "move into chest room")
	_require(await _transition_room(Vector2i.UP, Vector2i(3, 5), &"Event"), "move into relief room")
	var point := Vector2.INF
	for item: Dictionary in room_view.build_read_only_snapshot().get("interactables", []):
		if item.get("interaction_kind") == &"event":
			point = item.get("local_pos", Vector2.INF)
	if point.is_finite():
		await _move_axis(&"x", point.x)
		await _move_axis(&"y", minf(0.85, point.y + 0.08))
	var popup = room_view.get("context_popup")
	_require(popup.visible and popup.context_kind == &"event", "proximity opens world-anchored event hint")
	await _capture("relief_prompt")
	await _tap_key(KEY_E)
	var dialogue: Control = run_scene.get("z2_event_adapter").dialogue
	_require(dialogue.visible, "E opens relief dialogue")
	if dialogue.visible:
		for index in range(16):
			if dialogue.get_node("%ChoicesFrame").visible:
				break
			await _click_control(dialogue.get_node("%DialogueText"))
		await _capture("relief_dialogue")
		var blocked_pos := _player_local_pos()
		await _hold_key_seconds(KEY_A, 0.20)
		_require(blocked_pos.distance_to(_player_local_pos()) < 0.003, "dialogue blocks movement")
		await _tap_key(KEY_ESCAPE)
		_require(not dialogue.visible, "Escape closes relief dialogue")
		await _tap_key(KEY_E)
		await _click_control(dialogue.get_node("%CloseDialogue"))
		_require(not dialogue.visible, "pointer click on SVG dialogue close control")
		await _hold_key_seconds(KEY_D, 0.16)
		_require(blocked_pos.distance_to(_player_local_pos()) > 0.01, "movement resumes after dialogue")
	await _move_axis(&"x", 0.50)
	_require(await _hold_until(KEY_W, func() -> bool: return Vector2i(_status().position) == Vector2i(3, 4), 6.0),
		"move into cage room from %s at %s: %s" % [_status().position, _player_local_pos(), run_scene.last_command_result.get("reason", "")])
	if not await _wait_until(_combat_active, 5.0):
		_require(false, "cage did not start real combat: %s" % _status().get("event_state", {}).get("event_type", ""))
		_finish()
		return
	_require(runtime.build_read_only_snapshot().get("cage_active", false), "event combat is not cage")
	for entity in room_view.special_entities.values():
		var fallback := entity.get_node_or_null("VisualRoot/ProgramPlaceholder") as CanvasItem
		_require(fallback != null and not fallback.is_visible_in_tree(), "voxel room station drew its legacy placeholder during focus refresh")
	_require(surface.room_title_label.text.contains("封门") and not surface.action_buttons[&"combat"].disabled, "cage HUD exposes sealed status and attack")
	# Set danger-band start values through the same context the run displays.
	var prior_pressure := context.pressure
	var prior_hp := context.hp
	context.pressure = 76
	context.protocol_level = ProtocolService.level_for_pressure(context.pressure)
	context.hp = 21
	run_scene.call("_refresh_view_models")
	_require(surface.right_body_label.text.contains("76%") and surface.pressure_icon.texture == VectorSkin.ALERT, "protocol alert uses current pressure")
	var health_value := surface.player_health_hud.get_node("HealthValue") as Label
	_require(health_value.text.begins_with("21 /") and health_value.get_theme_color("font_color") == Color("#ffc9ab"), "low health displays its number and warning")
	var simulation = runtime.simulation
	# Separate the enemy from the first firearm aim consistently across GPUs.
	# Input, cooldowns, hit resolution, damage and cage settlement stay live.
	var enemy: Dictionary = simulation.enemies[0]
	enemy["pos"] = Vector2(0.70, 0.70)
	enemy["state"] = &"hurt"
	enemy["state_timer"] = 20.0
	_place_player(simulation, Vector2(0.55, 0.74), Vector2.RIGHT)
	await _tap_key(KEY_2)
	_require(weapon.weapon_buttons[Weapons.RIFLE].button_pressed, "numeric input selects rifle")
	var rounds: int = runtime.field_weapons.magazines[String(Weapons.RIFLE)]
	await _click_control(weapon.ammunition)
	_require(runtime.field_weapons.magazines[String(Weapons.RIFLE)] == rounds, "click on HUD fired a round")
	await _click_playfield_local(Vector2(0.26, 0.70))
	_require(await _wait_until(func() -> bool: return runtime.field_weapons.magazines[String(Weapons.RIFLE)] == rounds - 1, 4.0), "playfield click did not use a rifle round")
	_require(weapon.ammunition.text.contains("%d / %d" % [rounds - 1, rounds]), "rifle count lags runtime consumption")
	await _wait_until(func() -> bool: return not runtime.build_read_only_snapshot().field_weapon_busy, 4.0)
	var reserve: int = runtime.field_weapons.reserve
	await _tap_key(KEY_R)
	_require(weapon.reload_button.disabled and weapon.reload_button.text.contains("装填中"), "reload state does not disable button")
	await _capture("cage_reload")
	_require(await _wait_until(func() -> bool: return runtime.field_weapons.reload <= 0.0, 4.0), "reload did not finish")
	_require(runtime.field_weapons.reserve == reserve - 1 and weapon.ammunition.text.contains("%d / %d" % [rounds, rounds]), "reload amount or reserve display mismatched")

	await _click_control(weapon.weapon_buttons[Weapons.SCATTER])
	_require(weapon.weapon_buttons[Weapons.SCATTER].button_pressed and runtime.field_weapons.selected == Weapons.SCATTER, "HUD pointer click selects scattergun")
	# One starter round exercises genuine empty-magazine resolution.
	runtime.field_weapons.magazines[String(Weapons.SCATTER)] = 1
	await _click_playfield_local(Vector2(0.26, 0.70))
	_require(await _wait_until(func() -> bool: return runtime.field_weapons.magazines[String(Weapons.SCATTER)] == 0, 5.0), "scattergun did not reach zero rounds")
	await _wait_until(func() -> bool: return not runtime.build_read_only_snapshot().field_weapon_busy, 5.0)
	_require(weapon.ammunition.text.contains("0 / 3") and weapon.reload_button.text.contains("空弹") and not weapon.reload_button.disabled, "zero-round HUD exposes reload")
	await _capture("cage_empty_alert")
	context.pressure = prior_pressure
	context.protocol_level = ProtocolService.level_for_pressure(prior_pressure)
	context.hp = prior_hp
	run_scene.call("_refresh_view_models")
	await _tap_key(KEY_1)
	_require(weapon.weapon_buttons[Weapons.AXE].button_pressed, "numeric input selects axe")
	var hit := false
	for swing in range(20):
		if not _combat_active():
			break
		await _wait_until(func() -> bool: return not _combat_active() or bool(runtime.build_read_only_snapshot().get("attack_input", {}).get("ready", false)), 6.0)
		if not _combat_active():
			break
		var target: Dictionary = {}
		for candidate: Dictionary in runtime.simulation.enemies:
			if int(candidate.hp) > 0:
				target = candidate
				break
		if target.is_empty():
			break
		target["pos"] = Vector2(0.72, 0.50)
		target["state"] = &"hurt"
		target["state_timer"] = 20.0
		_place_player(runtime.simulation, Vector2(0.88, 0.50), Vector2.LEFT)
		var event_floor := _latest_combat_event_index(runtime)
		await _tap_key(KEY_J)
		var strike := await _wait_combat_event(runtime, &"player_attack_resolved", event_floor, 3.0)
		hit = hit or int(strike.get("hit_count", 0)) > 0
		print("CAGE_STRIKE %d hits=%s hp=%s active=%s cleared=%s" % [swing, strike.get("hit_count"), target.get("hp", -1), _combat_active(), context.truth_map.is_cleared(Vector2i(3, 4))])
		if strike.is_empty():
			break
	_require(hit, "axe did not damage cage enemy: %s" % run_scene.last_command_result.get("reason", ""))
	_require(await _wait_until(func() -> bool: return not _combat_active() and bool(_status().get("event_state", {}).get("completed", false)), 4.0), "real cage combat did not settle: active=%s event=%s cleared=%s persistence=%s" % [_combat_active(), _status().get("event_state", {}).get("completed", "-"), context.truth_map.is_cleared(Vector2i(3, 4)), run_scene.runtime_controller.persistence_error])
	await _capture("cage_cleared")
	# Check actual extraction UI at a registered exit, using the existing
	# resume runner's fixture placement to avoid another unrelated fight.
	var exit_room: Vector2i = context.truth_map.get_exits()[0]
	context.player_pos = exit_room
	context.current_pos = exit_room
	context.intel_map.reveal_cell(exit_room, context.truth_map)
	run_scene.command_bus.room_resolver.enter_room(context)
	run_scene.call("_refresh_view_models")
	run_scene.player_controller.set_local_position(WorldProjection.EXIT_LOCAL_POS)
	await _frames(4)
	await _tap_key(KEY_T)
	var extraction: Control = run_scene.get("extract_panel")
	_require(extraction.visible and StringName(_status().get("phase")) == &"confirm_extract", "T opens real extraction preview")
	if extraction.visible:
		await _capture("extract")
		await _click_control(run_scene.get("extract_cancel_button"))
		_require(not extraction.visible and StringName(_status().get("phase")) == &"running", "pointer cancel resumes in-run input")
	_finish()


func _click_control(control: Control) -> void:
	if control != null:
		await _click_viewport_point(control.get_global_rect().get_center())


func _click_playfield_local(local_position: Vector2) -> bool:
	var view = run_scene.get("room_runtime_view")
	var point: Vector2 = view.to_global(RuntimeLayoutScript.local_to_world(local_position))
	await _click_viewport_point(point)
	return true


func _click_viewport_point(point: Vector2) -> void:
	var window_point := root.get_stretch_transform() * point
	var motion := InputEventMouseMotion.new()
	motion.position = window_point
	motion.global_position = window_point
	Input.parse_input_event(motion)
	await process_frame
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = window_point
		event.global_position = window_point
		event.pressed = pressed
		Input.parse_input_event(event)
		parsed_input_count += 1
		await process_frame
	await _frames(3)


func _capture(label: String) -> void:
	if evidence.is_empty():
		return
	await _frames(3)
	await RenderingServer.frame_post_draw
	var shot := root.get_texture().get_image()
	_require(shot != null, "no rendered image")
	if shot != null:
		var path := evidence.path_join(label + ".png")
		_require(shot.save_png(path) == OK, "could not write " + path)
		capture_count += 1
		print("RUN_UI_CAPTURE %s %s" % [label, shot.get_size()])


func _finish() -> void:
	if failures.is_empty():
		print("RUN_UI_JOURNEY=PASS inputs=%d captures=%d" % [parsed_input_count, capture_count])
	else:
		for failure in failures:
			push_error(failure)
		print("RUN_UI_JOURNEY=FAIL inputs=%d captures=%d" % [parsed_input_count, capture_count])
	if main != null:
		main.queue_free()
	quit(0 if failures.is_empty() else 1)

