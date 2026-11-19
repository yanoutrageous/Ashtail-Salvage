extends SceneTree

const Weapons := preload("res://scripts/gameplay/combat/field_weapons.gd")
const Simulation := preload("res://scripts/gameplay/combat/g41_combat_simulation.gd")
const InputProfile := preload("res://scripts/core/input/runtime_input_profile.gd")
const RuntimeLayout := preload("res://scripts/gameplay/runtime/g41_runtime_layout.gd")
const MainFixture := preload("res://tests/z2_legacy_main_fixture.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(_weapons_has_skill_profile(), "weapon profiles expose rarity-gated skills")
	_check(Simulation.new().has_method("queue_player_weapon_skill"), "simulator exposes an authoritative weapon skill input")
	if _weapons_has_skill_profile() and Simulation.new().has_method("queue_player_weapon_skill"):
		_test_piercing_contact_and_restore()
		_test_scatter_spread_and_passive()
	if OS.get_cmdline_user_args().has("--production"):
		await _test_production_route()
	for failure in failures:
		printerr(failure)
	print("FIELD_WEAPON_SKILLS=%s checks=%d" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)


func _test_piercing_contact_and_restore() -> void:
	_check(Weapons.new().call("skill", Weapons.AXE).is_empty(), "common axe has no active skill")
	var sim := _fixture([Vector2(0.50, 0.78), Vector2(0.72, 0.78), Vector2(0.91, 0.78)])
	_check(sim.call("queue_player_weapon_skill", Weapons.RIFLE, Vector2.RIGHT), "carbine can queue piercing shot")
	_check(not sim.queue_player_attack(Vector2.LEFT), "normal attack cannot overwrite queued skill or its direction")
	var state := sim.export_transaction_state()
	var restored := Simulation.new()
	_check(restored.validate_transaction_state(state), "queued skill preserves a valid checkpoint")
	restored.import_transaction_state(state)
	for step in 15:
		restored.advance_frame(restored.FIXED_STEP)
	var hit := _last_hit(restored.drain_events())
	_check(hit.get("skill_id") == &"piercing_shot" and hit.get("hit_count") == 3, "restored piercing shot strikes three aligned enemies")
	_check(restored.enemies[0].hp < 100 and restored.enemies[1].hp < 100 and restored.enemies[2].hp < 100, "all three targets take damage")

	var blocked := _fixture([Vector2(0.50, 0.78), Vector2(0.78, 0.78)])
	blocked.set_arena_obstacles([Rect2(0.62, 0.73, 0.055, 0.10)])
	_check(blocked.call("queue_player_weapon_skill", Weapons.RIFLE, Vector2.RIGHT), "piercing input queues into a blocked lane")
	for step in 15:
		blocked.advance_frame(blocked.FIXED_STEP)
	var wall_hit := _last_hit(blocked.drain_events())
	_check(wall_hit.get("hit_count") == 1 and wall_hit.get("shot_obstacle_endpoints", []).size() == 1, "piercing shot hits before the wall and stops there")
	_check(blocked.enemies[1].hp == 100, "piercing cannot damage an enemy beyond a wall")


func _test_scatter_spread_and_passive() -> void:
	var normal := _fixture([Vector2(0.40, 0.78), Vector2(0.58, 0.62)])
	normal.player["field_weapon"] = Weapons.SCATTER
	normal.queue_player_attack(Vector2.RIGHT)
	for step in 15:
		normal.advance_frame(normal.FIXED_STEP)
	var regular_hit := _last_hit(normal.drain_events())
	_check(regular_hit.get("hit_count") == 1 and regular_hit.get("shot_endpoints", []).size() == 5, "normal scatter retains its narrow five-pellet shot")
	_check(normal.enemies[0].hp <= 74, "rock salt passive increases close-range pellet damage")

	var skill := _fixture([Vector2(0.40, 0.78), Vector2(0.58, 0.62)])
	_check(skill.call("queue_player_weapon_skill", Weapons.SCATTER, Vector2.RIGHT), "scattergun can queue sweeping volley")
	for step in 15:
		skill.advance_frame(skill.FIXED_STEP)
	var volley := _last_hit(skill.drain_events())
	_check(volley.get("skill_id") == &"sweeping_volley" and volley.get("hit_count") == 2, "sweeping volley reaches a target outside normal spread")
	_check(volley.get("shot_endpoints", []).size() > 5, "sweeping volley uses its authored ray fan")


func _test_production_route() -> void:
	if not OS.get_user_data_dir().replace("\\", "/").begins_with("D:/Codex_Output/Temp/"):
		_check(false, "production runner requires isolated D-drive user data")
		return
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	root.size = Vector2i(1280, 720)
	await _frames(15)
	var run: Node = main.get_node("RunScene")
	_check(MainFixture.qualify(run).get("ok", false), "isolated profile qualifies for a normal run")
	run.call("_start_standard_from_ui")
	await _frames(65)
	var runtime: G41InRunRuntime = run.get("in_run_runtime")
	_check(runtime != null and runtime.has_method("request_field_attack"), "production runtime owns field shots and skills")
	if runtime == null or not runtime.has_method("request_field_attack"):
		return
	var disabled := runtime.call("request_field_attack", Vector2(0.25, 0.75), Vector2.RIGHT, [], true) as Dictionary
	_check(disabled.get("reason") == &"weapon_has_no_skill", "starting axe cannot execute a field skill")
	_check(runtime.equip_field_weapon(Weapons.RIFLE).get("ok"), "field carbine can equip before combat")
	await _frames(4)
	var weapon_panel: Control = run.get("run_surface").weapon_panel
	_check(weapon_panel.get_node("Details/WeaponActions/WeaponSkill").text.contains("穿甲点射"), "live weapon panel advertises the equipped skill")
	_check(weapon_panel.get_global_rect().end.y <= run.get("run_surface").room_title_label.get_global_rect().position.y, "skill trait does not overlap the room title")
	var prior := int(runtime.field_weapons.magazines.rifle)
	_check(InputProfile.event_pressed(_skill_key(true), &"weapon_skill"), "K is registered as the semantic weapon skill input")
	_check(not bool(run.call("_gameplay_input_blocked")), "field keyboard starts in an actionable room (%s/%s)" % [run.get("screen_state"), run.get("run_context").mode])
	Input.parse_input_event(_skill_key(true))
	await _frames(5)
	Input.parse_input_event(_skill_key(false))
	_check(runtime.field_weapons.magazines.rifle == prior - 2, "real K input commits a field skill and consumes two rounds (%d after %d)" % [runtime.field_weapons.magazines.rifle, prior])
	var field_state := runtime.export_transaction_state()
	_check(runtime.validate_transaction_state(field_state), "field skill cooldown can be saved")
	var controller: RunRuntimeController = run.get("runtime_controller")
	_check(controller.call("_restore_durable_checkpoint", true).get("ok", false), "field shot checkpoint can be restored from disk")
	var waiting := runtime.call("request_field_attack", Vector2(0.25, 0.75), Vector2.RIGHT, [], true) as Dictionary
	_check(waiting.get("reason") == &"weapon_skill_cooling_down", "restored field skill rejects reuse while its cooldown is active")
	_check(runtime.reload_field_weapon().get("ok"), "partial magazine can be topped up")
	_check(float(runtime.field_weapons.reload) > 0.0 and float(runtime.field_weapons.reload) < 0.7, "carbine tactical reload shortens partial-magazine reload")
	var old_state := runtime.export_transaction_state()
	for field in ["skill_cooldowns", "field_attack_cooldown"]:
		old_state.field_weapons.erase(field)
	_check(runtime.validate_transaction_state(old_state), "old four-field arsenal checkpoints still validate")
	runtime.advance_field_reload(1.0)
	_check(runtime.equip_field_weapon(Weapons.SCATTER).get("ok", false), "scattergun equips after the carbine reload")
	await _frames(3)
	var view: Node2D = run.get("room_runtime_view")
	await _right_click(weapon_panel.get_global_rect().get_center())
	_check(runtime.field_weapons.magazines.scattergun == 3, "right-click on weapon HUD does not fire")
	await _right_click(view.to_global(RuntimeLayout.local_to_world(Vector2(0.73, 0.72))))
	_check(runtime.field_weapons.magazines.scattergun == 1, "right-click aims and spends two scatter shells in the live room")

	runtime.advance_field_reload(1.0)
	var near_edge := runtime.call("request_field_attack", Vector2(0.95, 0.92), Vector2(1.0, 1.0), []) as Dictionary
	var all_endpoints_inside := bool(near_edge.get("ok", false))
	for endpoint: Vector2 in near_edge.get("field_attack", {}).get("shot_endpoints", []):
		all_endpoints_inside = all_endpoints_inside and endpoint.x <= 1.0001 and endpoint.y <= 1.0001
	_check(all_endpoints_inside and runtime.field_weapons.magazines.scattergun == 0, "field rays stop at the room edge and spend one round")

	runtime.advance_field_reload(8.0)
	var context: RunContext = run.get("run_context")
	var room := Vector2i(-1, -1)
	for y in context.height:
		for x in context.width:
			if context.truth_map.get_room_type(Vector2i(x, y)) == &"Monster":
				room = Vector2i(x, y)
	if room.x < 0:
		_check(false, "qualified route has a combat room")
		return
	run.get("command_bus").dispatch(&"debug_teleport_to", {"pos": room, "enter_room": true})
	await _frames(8)
	_check(runtime.has_active_combat(), "qualified route enters real combat")
	if not runtime.has_active_combat():
		return
	var starved := runtime.call("request_weapon_skill", Vector2.RIGHT) as Dictionary
	_check(starved.get("reason") == &"magazine_empty", "combat volley requires at least two shells")
	_check(runtime.equip_field_weapon(Weapons.RIFLE).get("ok", false), "combat can equip a different ability")
	var sim := runtime.simulation
	sim.player["pos"] = Vector2(0.30, 0.78)
	sim.previous_player_pos = sim.player["pos"]
	sim.player["invulnerability"] = 3.0
	sim.enemies[0]["pos"] = Vector2(0.70, 0.78)
	sim.enemies[0]["max_hp"] = 100
	sim.enemies[0]["hp"] = 100
	sim.enemies[0]["entry_grace_remaining"] = 3.0
	_check(runtime.call("request_weapon_skill", Vector2.RIGHT).get("ok", false), "carbine ability queues in runtime combat")
	for frame in 240:
		if runtime.field_weapons.magazines.rifle == prior - 2:
			break
		await process_frame
	var resolved := _last_hit(runtime.recent_domain_events)
	_check(runtime.field_weapons.magazines.rifle == prior - 2 and resolved.get("skill_id") == &"piercing_shot", "combat skill resolves and consumes exactly two carbine rounds")


func _weapons_has_skill_profile() -> bool:
	var script: Script = Weapons
	for method: Dictionary in script.get_script_method_list():
		if method.get("name") == &"skill":
			return true
	return false


func _fixture(positions: Array[Vector2]) -> G41CombatSimulation:
	var sim := Simulation.new()
	var types: Array[StringName] = []
	types.resize(positions.size())
	types.fill(&"bat")
	sim.start({"seed": 21047, "player_pos": Vector2(0.25, 0.78), "player_power": 10, "monster_types": types})
	for index in positions.size():
		sim.enemies[index]["pos"] = positions[index]
		sim.enemies[index]["hp"] = 100
		sim.enemies[index]["max_hp"] = 100
		sim.enemies[index]["entry_grace_remaining"] = 2.0
	return sim


func _last_hit(events: Array[Dictionary]) -> Dictionary:
	for index in range(events.size() - 1, -1, -1):
		if events[index].event_type == &"player_attack_resolved":
			return events[index]
	return {}


func _skill_key(pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_K
	event.pressed = pressed
	return event


func _right_click(point: Vector2) -> void:
	var window_point := root.get_stretch_transform() * point
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.position = window_point
		event.global_position = window_point
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await _frames(3)


func _frames(count: int) -> void:
	for frame in count:
		await process_frame


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

