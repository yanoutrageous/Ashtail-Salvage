extends SceneTree
## Checks production deployment, fixed-step weapon hits, reload and the native art adapter.

const FieldWeapons := preload("res://scripts/gameplay/combat/field_weapons.gd")
var run
var runtime: G41InRunRuntime
var capture := false
var checks: Array[String] = []


func _initialize() -> void:
	capture = OS.get_cmdline_user_args().has("--capture")
	call_deferred("_test")


func _test() -> void:
	if capture:
		RenderingServer.viewport_set_update_mode(root.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ALWAYS)
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await _step(22)
	run = main.get_node("RunScene")
	run.call("_start_standard_from_ui")
	await _step(72)
	runtime = run.in_run_runtime
	if not run.run_context.run_active or run.combat_art == null:
		_finish("production deployment or 3D actor layer missing")
		return
	var context: RunContext = run.run_context
	_check(run.room_runtime_view.visible and run.room_controller.is_visible_in_tree(), "upstream room still visible")
	_check(run.combat_art.actor.pieces.size() > 0 and run.combat_art.is_visible_in_tree(), "voxel raccoon is mounted")
	if capture:
		_check(_model_rendered(run.combat_art.player_canvas), "raccoon is visible in the native render")
	var old_state := runtime.export_transaction_state()
	old_state.erase("field_weapons")
	_check(runtime.validate_transaction_state(old_state), "existing checkpoint without arsenal remains valid")
	var room := Vector2i(-1, -1)
	for y in context.height:
		for x in context.width:
			if context.truth_map.get_room_type(Vector2i(x, y)) == &"Monster":
				room = Vector2i(x, y)
	if room.x < 0:
		_finish("map has no combat room")
		return
	run.command_bus.dispatch(&"debug_teleport_to", {"pos": room, "enter_room": true})
	await _step(23)
	if not runtime.has_active_combat():
		_finish("combat did not begin")
		return
	var enemy: Dictionary = runtime.simulation.enemies[0]
	if capture:
		var art_enemy: Dictionary = run.combat_art.enemies.get(String(enemy["enemy_id"]), {})
		_check(_model_rendered(art_enemy.get("canvas", {})), "voxel enemy is visible in the native render")
	enemy["max_hp"] = 120
	enemy["hp"] = 120
	_check(runtime.equip_field_weapon(FieldWeapons.RIFLE).get("ok", false), "select carbine")
	_place(Vector2(0.26, 0.78), Vector2(0.69, 0.78))
	var hp := int(enemy["hp"])
	await _shot(Vector2.RIGHT)
	var result := _resolved()
	_check(result.get("weapon") == FieldWeapons.RIFLE and int(result.get("hit_count", 0)) == 1, "carbine hits distant enemy")
	_check(int(runtime.simulation.enemies[0]["hp"]) < hp, "real enemy HP decreased")
	_check(runtime.field_weapons["magazines"]["rifle"] == 5, "one resolved rifle shot spends one round")
	_check(run.combat_art.muzzle_flashes >= 1, "carbine triggered native muzzle effect")
	await _step(50)
	_place(Vector2(0.22, 0.50), Vector2(0.78, 0.50))
	await _shot(Vector2.RIGHT)
	result = _resolved()
	_check(result.get("shot_obstacle_endpoints", []).size() == 1 and int(result.get("hit_count", -1)) == 0, "obstacle clips rifle")
	_check(runtime.field_weapons["magazines"]["rifle"] == 4, "blocked shot still spends a round")
	await _step(48)
	_check(runtime.reload_field_weapon().get("ok", false), "reload commits through transaction")
	_check(runtime.field_weapons["magazines"]["rifle"] == 6 and runtime.field_weapons["reserve"] == 22, "reload transfers reserve into magazine")
	_check(not runtime.request_attack(Vector2.RIGHT).get("ok", false), "cannot fire while reloading")
	var roundtrip := runtime.export_transaction_state()
	_check(runtime.validate_transaction_state(roundtrip), "armed checkpoint encodes")
	runtime.import_transaction_state(roundtrip)
	_check(runtime.field_weapons["reserve"] == 22, "armed checkpoint reload preserves ammo")
	await _step(67)
	_check(runtime.equip_field_weapon(FieldWeapons.SCATTER).get("ok", false), "select scattergun")
	_place(Vector2(0.24, 0.77), Vector2(0.56, 0.77))
	await _shot(Vector2.RIGHT)
	result = _resolved()
	_check(result.get("weapon") == FieldWeapons.SCATTER and result.get("shot_endpoints", []).size() == 5, "scattergun produces five resolved pellets")
	_check(runtime.field_weapons["magazines"]["scattergun"] == 2, "pellets consume one shell")
	await _step(49)
	_check(runtime.equip_field_weapon(FieldWeapons.AXE).get("ok", false), "select axe")
	_place(Vector2(0.35, 0.77), Vector2(0.48, 0.77))
	run.call("_fight_and_show_result", Vector2.RIGHT)
	var max_blade_samples := 0
	for frame in 24:
		await _step(1)
		max_blade_samples = maxi(max_blade_samples, run.combat_art.fx.samples.size())
	result = _resolved()
	_check(result.get("shape") == &"sector" and int(result.get("hit_count", 0)) == 1, "original melee contract still lands")
	_check(max_blade_samples > 2, "axe generated sampled blade geometry")
	await _step(42)
	_finish("")


func _place(player: Vector2, enemy: Vector2) -> void:
	var sim := runtime.simulation
	run.player_controller.set_local_position(player)
	run.player_controller.set_facing_vector(player.direction_to(enemy))
	sim.player["pos"] = player
	# Isolate each weapon contract from bolts already in flight between shots.
	sim.player["invulnerability"] = 0.55
	sim.previous_player_pos = player
	sim.enemies[0]["pos"] = enemy
	sim.enemies[0]["entry_grace_remaining"] = 0.39
	sim.previous_enemy_positions[String(sim.enemies[0]["enemy_id"])] = enemy


func _shot(heading: Vector2) -> void:
	run.call("_fight_and_show_result", heading)
	await _step(24)


func _resolved() -> Dictionary:
	for i in range(runtime.recent_domain_events.size() - 1, -1, -1):
		var item := runtime.recent_domain_events[i]
		if item.get("event_type") == &"player_attack_resolved":
			return item
	return {}


func _model_rendered(canvas: Dictionary) -> bool:
	var sprite := canvas.get("sprite") as Sprite2D
	return is_instance_valid(sprite) and sprite.is_visible_in_tree() and sprite.texture.get_image().get_used_rect().has_area()


func _step(count: int) -> void:
	for i in count:
		await process_frame
		if capture:
			RenderingServer.force_draw(false, 1.0 / 60.0)


func _check(ok: bool, label: String) -> void:
	if not ok:
		checks.append(label)


func _finish(error: String) -> void:
	if not error.is_empty():
		checks.append(error)
	print("C_COMBAT_ART=", "PASS" if checks.is_empty() else "FAIL", " checks_failed=", checks)
	quit(0 if checks.is_empty() else 2)
