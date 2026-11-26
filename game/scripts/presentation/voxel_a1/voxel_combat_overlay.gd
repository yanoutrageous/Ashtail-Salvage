extends Node2D
## Private 3D actor and effect pass registered to the existing room projection.

const Rig := preload("res://scripts/presentation/voxel_a1/voxel_rig.gd")
const EnemyArt := preload("res://scripts/presentation/voxel_a1/voxel_enemy_art.gd")
const Effects := preload("res://scripts/presentation/voxel_a1/voxel_fx.gd")
const HostileEffects := preload("res://scripts/presentation/voxel_a1/voxel_hostile_fx.gd")
const Weapons := preload("res://scripts/gameplay/combat/field_weapons.gd")
const Depth := preload("res://scripts/gameplay/runtime/g41_world_object_presentation_descriptor.gd")
const Combat := preload("res://scripts/gameplay/combat/g41_combat_simulation.gd")
const Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")
const Monsters := preload("res://scripts/gameplay/combat/z1_monster_catalog.gd")
const BossArrival := preload("res://scripts/presentation/voxel_a1/voxel_boss_arrival.gd")
const MODEL_TYPES := [&"slime", &"slimeling", &"bat", &"drone", &"ironback"]
const ELEVATION := 0.93
const SPAN := 10.0
const FLOOR := 0.065
const EFFECT_VIEW_SIZE := Vector2i(760, 756)
const MODEL_VIEW_SIZE := Vector2i(216, 200)
const BOSS_VIEW_SIZE := Vector2i(400, 336)
const PLAYER_MODEL_SCALE := 0.70
const SWING_START := 0.30
const SWING_END := 0.77
const FIELD_SWING_SECONDS := 0.42

var actor: Rig
var fx: Effects
var hostile_fx: HostileEffects
var stage: Node3D
var combat_entities: Node3D
var camera: Camera3D
var effects_view: SubViewport
var effects_picture: Sprite2D
var shared_world: World3D
var player_canvas: Dictionary
var player_draw_offset := Vector2.ZERO
var occupied_layers: Dictionary = {}
var last_local := Vector2(0.5, 0.5)
var actor_heading := Vector3.BACK
var last_event := -1
var room_key := ""
var encounter_id := ""
var clock := 0.0
var last_attack := -1.0
var free_swing_elapsed := FIELD_SWING_SECONDS
var free_swing_variant := 2
var free_swing_obstacles: Array = []
var free_swing_facing := Vector2.ZERO
var _field_contact: Dictionary = {}
var _field_shot: Dictionary = {}
var footstep_cooldown := 0.0
var was_sprinting := false
var was_airborne := false
var enemies: Dictionary = {}
var bolts: Dictionary = {}
var beams: Dictionary = {}
var muzzle_flashes := 0
var armor_impacts := 0
var soft_impacts := 0


func _ready() -> void:
	z_index = 660
	var view := SubViewport.new()
	effects_view = view
	view.size = EFFECT_VIEW_SIZE
	view.transparent_bg = true
	shared_world = World3D.new()
	view.world_3d = shared_world
	view.gui_disable_input = true
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	view.msaa_3d = Viewport.MSAA_2X
	add_child(view)
	var picture := Sprite2D.new()
	effects_picture = picture
	picture.hide()
	picture.texture = view.get_texture()
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	picture.position = G41RuntimeLayout.ROOM_RECT.get_center()
	add_child(picture)
	stage = Node3D.new()
	view.add_child(stage)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("#adb8c4")
	settings.ambient_light_energy = 0.61
	environment.environment = settings
	stage.add_child(environment)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-61, -39, 0)
	key.light_color = Color("#f4dfbc")
	key.light_energy = 0.91
	stage.add_child(key)
	camera = Camera3D.new()
	stage.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.cull_mask = 1
	camera.size = float(view.size.y) * SPAN / G41RuntimeLayout.ROOM_RECT.size.y
	camera.position = Vector3(0, sin(ELEVATION), cos(ELEVATION)) * 16.0
	camera.look_at(Vector3.ZERO)
	camera.current = true
	combat_entities = Node3D.new()
	stage.add_child(combat_entities)
	actor = Rig.new()
	stage.add_child(actor)
	actor.build(true)
	actor.scale = Vector3.ONE * PLAYER_MODEL_SCALE
	player_canvas = _add_model_view(actor)
	fx = Effects.new()
	stage.add_child(fx)
	fx.build()
	hostile_fx = HostileEffects.new()
	stage.add_child(hostile_fx)
	hostile_fx.build()
	if DisplayServer.get_name() != "headless":
		_prime_effect_rendering.call_deferred()


func _prime_effect_rendering() -> void:
	# Draw the real trail and slam shaders while the gameplay sprite is hidden.
	# Compatibility compiles these variants on their first visible surface.
	if is_visible_in_tree():
		return
	var player_rng := fx.rng.state
	var enemy_rng := hostile_fx.rng.state
	fx.prime_render_pipeline()
	var origin := Vector3(0.0, FLOOR, 0.15)
	hostile_fx.release(&"slam", origin, origin, Vector3.BACK, 2.1, PackedVector3Array(), PI / 3.0)
	hostile_fx.step(0.075, camera)
	effects_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	fx.clear()
	hostile_fx.clear()
	fx.rng.state = player_rng
	hostile_fx.rng.state = enemy_rng


static func visual_type(data: Dictionary) -> StringName:
	var kind := StringName(data.get("monster_type", &""))
	if data.get("behavior_id", &"") == &"directional_guard":
		return &"ironback"
	return StringName(Monsters.definition(kind).get("base_type", kind)) if Monsters.supports(kind) else kind


func request_field_swing(obstacles: Array, facing := Vector2.ZERO) -> bool:
	if free_swing_elapsed < FIELD_SWING_SECONDS or not is_visible_in_tree():
		return false
	free_swing_elapsed = 0.0
	free_swing_variant = (free_swing_variant + 1) % 3
	free_swing_obstacles = obstacles
	free_swing_facing = facing
	last_attack = -1.0
	return true


func take_field_swing_contact() -> Dictionary:
	var contact := _field_contact
	_field_contact = {}
	return contact


func present_field_shot(fact: Dictionary) -> void:
	_field_shot = fact


func present_boss_arrival(snapshot: Dictionary) -> void:
	for enemy: Dictionary in snapshot.get("enemies", []):
		var profile: Dictionary = BossArrival.PROFILES.get(enemy.get("behavior_id", &""), {})
		var row: Dictionary = enemies.get(str(enemy.get("enemy_id", "")), {})
		if profile.is_empty() or row.is_empty():
			continue
		var model := row["node"] as Node3D
		var ink: Color = profile["color"]
		var tips: Array = row.get("fist_tips", [])
		if tips.is_empty():
			fx.impact(model.position + Vector3.UP * 0.35, model.basis.z, ink, &"armor")
		else:
			for tip: Node3D in tips:
				fx.impact(tip.global_position, model.basis.z, ink, &"armor")
		return


func advance(delta: float, position_local: Vector2, facing: Vector2, snapshot: Dictionary, motion: Dictionary = {}) -> void:
	if actor == null or not is_visible_in_tree():
		return
	var next_room := String(snapshot.get("room_key", ""))
	var changed := next_room != room_key
	if changed:
		room_key = next_room
		encounter_id = ""
		last_event = -1
		last_attack = -1.0
		free_swing_elapsed = FIELD_SWING_SECONDS
		free_swing_obstacles.clear()
		_field_contact.clear()
		_field_shot = {}
		was_sprinting = false
		was_airborne = false
		fx.clear()
		hostile_fx.clear()
		hostile_fx.terrain.clear()
	var encounter := String(snapshot.get("encounter_id", ""))
	if not encounter.is_empty() and encounter != encounter_id:
		encounter_id = encounter
		last_event = -1
		free_swing_elapsed = FIELD_SWING_SECONDS
		hostile_fx.terrain.clear()
		for bounds: Rect2 in snapshot.get("arena_obstacles", []):
			var first := _world(bounds.position, FLOOR)
			var last := _world(bounds.end, FLOOR)
			hostile_fx.terrain.append(Rect2(first.x, first.z, last.x - first.x, last.z - first.z))
	var visual_delta := minf(delta, 1.0 / 30.0)
	clock += visual_delta
	var speed := 0.0 if changed or delta <= 0.0 else last_local.distance_to(position_local) * SPAN / delta
	last_local = position_local
	var field_swing := not bool(snapshot.get("active", false)) and free_swing_elapsed < FIELD_SWING_SECONDS
	var aim := free_swing_facing if field_swing and free_swing_facing != Vector2.ZERO else facing
	var heading := _direction(aim)
	if heading.length_squared() > 0.001:
		actor_heading = heading
	actor.rotation.y = atan2(actor_heading.x, actor_heading.z)
	var combat_player: Dictionary = snapshot.get("player", {})
	var loadout: Dictionary = snapshot.get("field_weapons", {})
	var lift := float(motion.get("visual_lift", 0.0))
	var airborne := float(motion.get("airborne", 0.0))
	var sprinting := bool(motion.get("sprinting", false)) and speed > 1.2
	var state := StringName(combat_player.get("state", &"idle"))
	actor.position = _world(position_local, FLOOR + lift * SPAN)
	var attack: Dictionary = snapshot.get("player_attack_geometry", {})
	var strike := _attack_phase(combat_player)
	var selected := StringName(loadout.get("selected", Weapons.AXE))
	var weapon := StringName(attack.get("weapon", selected))
	var variant := int(String(attack.get("attack_id", "0")).get_slice("_", 2)) % 3
	var obstacles: Array = snapshot.get("arena_obstacles", [])
	if selected != Weapons.AXE:
		free_swing_elapsed = FIELD_SWING_SECONDS
	elif field_swing:
		var before := free_swing_elapsed
		free_swing_elapsed = minf(FIELD_SWING_SECONDS, free_swing_elapsed + visual_delta)
		strike = free_swing_elapsed / FIELD_SWING_SECONDS
		variant = free_swing_variant
		obstacles = free_swing_obstacles
		if before < FIELD_SWING_SECONDS * 0.50 and strike >= 0.50:
			_field_contact = {"weapon": Weapons.AXE, "shape": &"sector", "origin": position_local,
				"facing": aim, "range": Combat.PLAYER_ATTACK_RANGE, "cone_dot": Combat.PLAYER_ATTACK_CONE_DOT,
				"arena_obstacles": obstacles}
	var origin := Vector2(attack.get("origin", position_local))
	var had_firearm := actor.firearm != null
	var running := float(sprinting) if not motion.is_empty() else smoothstep(3.2, 5.2, speed)
	var pose_speed := minf(speed, 8.0 if sprinting else 6.0)
	var attack_advanced := weapon == Weapons.AXE and strike >= SWING_START and strike > last_attack and last_attack < SWING_END
	if attack_advanced:
		var start := maxf(SWING_START, last_attack)
		var finish := minf(SWING_END, strike)
		var steps := mini(4, int(ceil((finish - start) / 0.075)))
		for i in range(1, steps):
			var sample := lerpf(start, finish, float(i) / steps)
			actor.animate(0.035, pose_speed, running, sample, weapon, 0.0, airborne, variant, state)
			fx.trace(_clip_blade(actor.blade_points(), origin, obstacles), variant)
		if strike > SWING_END:
			actor.animate(0.035, pose_speed, running, SWING_END, weapon, 0.0, airborne, variant, state)
			fx.trace(_clip_blade(actor.blade_points(), origin, obstacles), variant)
	actor.animate(visual_delta, pose_speed, running, strike, weapon,
		float(loadout.get("reload", 0.0)), airborne, variant, state)
	if not had_firearm and actor.firearm != null:
		_assign_render_layer(actor, int(player_canvas["layer"]))
	_position_model_view(player_canvas, actor.position, position_local.y)
	(player_canvas["sprite"] as Sprite2D).position += player_draw_offset
	if attack_advanced and strike <= SWING_END:
		fx.trace(_clip_blade(actor.blade_points(), origin, obstacles), variant)
	last_attack = strike
	footstep_cooldown -= visual_delta
	if lift <= 0.001 and ((sprinting and footstep_cooldown <= 0.0) or was_airborne):
		fx.footstep(_world(position_local, FLOOR + 0.025), actor_heading, not was_sprinting or was_airborne)
		footstep_cooldown = 0.15
	was_sprinting = sprinting
	was_airborne = lift > 0.001
	var seen := _sync_actors(snapshot.get("enemies", []))
	_events(snapshot.get("recent_events", []), snapshot.get("hazards", []))
	if not _field_shot.is_empty() and actor.muzzle != null:
		_player_hit(_field_shot)
		_field_shot = {}
	_sync_projectiles(snapshot)
	_retire_actors(seen)
	var player_effects := fx.step(visual_delta)
	var enemy_effects := hostile_fx.step(visual_delta, camera)
	var rendering_effects := player_effects or enemy_effects or not bolts.is_empty() or not beams.is_empty()
	effects_picture.visible = rendering_effects
	if rendering_effects:
		effects_view.render_target_update_mode = SubViewport.UPDATE_ONCE


func _attack_phase(player: Dictionary) -> float:
	var speed := Talents.speed_multiplier(player.get("z2_talents", {}), "attack_speed_percent")
	var timer := float(player.get("state_timer", 0.0)) * speed
	match player.get("state", &""):
		&"attack_windup":
			return lerpf(0.0, 0.40, 1.0 - clampf(timer / Combat.PLAYER_ATTACK_WINDUP, 0.0, 1.0))
		&"attack_active":
			return lerpf(0.40, 0.77, 1.0 - clampf(timer / Combat.PLAYER_ATTACK_ACTIVE, 0.0, 1.0))
		&"attack_recovery":
			return lerpf(0.77, 1.0, 1.0 - clampf(timer / Combat.PLAYER_ATTACK_RECOVERY, 0.0, 1.0))
	return -1.0


func _add_model_view(model: Node3D, view_size := MODEL_VIEW_SIZE, lift := 0.95) -> Dictionary:
	var layer_index := 1
	while occupied_layers.has(layer_index):
		layer_index += 1
	if layer_index >= 20:
		return {}
	occupied_layers[layer_index] = true
	var mask := 1 << layer_index
	_assign_render_layer(model, mask)
	var sprite := Sprite2D.new()
	sprite.z_as_relative = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(sprite)
	var view := SubViewport.new()
	view.size = view_size
	view.world_3d = shared_world
	view.transparent_bg = true
	view.gui_disable_input = true
	view.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	view.msaa_3d = Viewport.MSAA_2X
	sprite.add_child(view)
	var model_camera := Camera3D.new()
	view.add_child(model_camera)
	model_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	model_camera.size = float(view.size.y) * SPAN / G41RuntimeLayout.ROOM_RECT.size.y
	model_camera.cull_mask = mask
	model_camera.current = true
	sprite.texture = view.get_texture()
	return {"sprite": sprite, "camera": model_camera, "index": layer_index, "layer": mask, "lift": lift}


func _assign_render_layer(model: Node3D, layer: int) -> void:
	for child in model.find_children("*", "MeshInstance3D", true, false):
		(child as MeshInstance3D).layers = layer


func _position_model_view(row: Dictionary, position: Vector3, depth: float) -> void:
	var target := position + Vector3.UP * float(row["lift"])
	var sprite := row["sprite"] as Sprite2D
	var model_camera := row["camera"] as Camera3D
	sprite.position = G41RuntimeLayout.ROOM_RECT.get_center() + camera.unproject_position(target) - Vector2(EFFECT_VIEW_SIZE) * 0.5
	sprite.z_index = Depth.ground_depth(depth)
	model_camera.position = camera.position + target
	model_camera.basis = camera.basis


func _clip_blade(points: PackedVector3Array, center: Vector2, obstacles: Array) -> PackedVector3Array:
	for i in points.size():
		var p := points[i]
		var at := Vector2(p.x, p.z * sin(ELEVATION)) / SPAN + Vector2(0.5, 0.5)
		var first := at
		var distance := at.distance_squared_to(center)
		for bounds in obstacles:
			var rect := Rect2(bounds)
			var corners := [rect.position, rect.position + Vector2(rect.size.x, 0), rect.end, rect.position + Vector2(0, rect.size.y)]
			for side in 4:
				var contact = Geometry2D.segment_intersects_segment(center, at, corners[side], corners[(side + 1) % 4])
				if contact is Vector2 and center.distance_squared_to(contact) < distance:
					first = contact
					distance = center.distance_squared_to(contact)
		points[i] = _world(first, p.y)
	return points


func _sync_actors(snapshots: Array) -> Dictionary:
	var seen := {}
	for data: Dictionary in snapshots:
		var kind := visual_type(data)
		if kind not in MODEL_TYPES:
			continue
		var id := String(data["enemy_id"])
		seen[id] = true
		if not enemies.has(id):
			var instance := _create_actor(kind)
			var profile: Dictionary = BossArrival.PROFILES.get(data.get("behavior_id", &""), {})
			var boss := not profile.is_empty()
			if boss:
				(instance["node"] as Node3D).scale = Vector3.ONE * float(profile["scale"])
			var canvas := _add_model_view(instance["node"], BOSS_VIEW_SIZE if boss else MODEL_VIEW_SIZE, 1.43 if boss else 0.95)
			if canvas.is_empty():
				(instance["node"] as Node3D).queue_free()
				continue
			instance["canvas"] = canvas
			enemies[id] = instance
		var row: Dictionary = enemies[id]
		var model := row["node"] as Node3D
		model.visible = int(data.get("hp", 1)) > 0
		(row["canvas"]["sprite"] as Sprite2D).visible = model.visible
		var local := Vector2(data["pos"])
		var airborne := kind in [&"bat", &"drone"]
		var altitude := 0.34 + sin(clock * 8.8) * 0.073 if airborne else 0.0
		var lift := float(data.get("visual_lift", 0.0)) * SPAN / (G41RuntimeLayout.ROOM_RECT.size.y * cos(ELEVATION))
		model.position = _world(local, FLOOR + altitude + lift)
		var heading := _direction(Vector2(data.get("facing", local.direction_to(last_local))))
		model.rotation.y = atan2(heading.x, heading.z)
		var state := StringName(data.get("state", &"idle"))
		var body := row["body"] as Node3D
		var recoil := clampf(float(row.get("hit_until", 0.0)) - clock, 0.0, 0.16)
		body.rotation.x = -recoil * 1.4
		if kind in [&"slime", &"slimeling"]:
			var stretch := 0.77 if state == &"warning" else (1.24 if state == &"active" else 1.0)
			body.scale = Vector3(1.06 if stretch < 1.0 else 1.0, stretch, 1.06 if stretch < 1.0 else 1.0)
		if row.has("wings"):
			var beat := sin(clock * (27.0 if state == &"fire" else 17.0))
			row["wings"][0].rotation.z = beat * 0.69
			row["wings"][1].rotation.z = -beat * 0.69
		if row.has("rotor"):
			row["rotor"].rotation.y = clock * (12.6 if state == &"fire" else 4.1)
		if row.has("lens"):
			var lens := row["lens"] as MeshInstance3D
			(lens.material_override as StandardMaterial3D).albedo_color = EnemyArt.BLUE.lightened(0.39 if state == &"fire" else 0.0)
		_position_model_view(row["canvas"], model.position, local.y)
		if row.has("boss_fists"):
			var striking := state in [&"active", &"charge", &"fire"]
			var warn := 1.0 - clampf(float(data.get("state_timer", 0.0)) / 0.75, 0.0, 1.0)
			var arm_tilt := lerpf(0.12, 1.02, smoothstep(0.0, 0.68, warn)) if state == &"warning" else (-0.65 if striking else 0.12)
			body.rotation.x += lerpf(0.04, -0.15, warn) if state == &"warning" else (0.29 if striking else 0.0)
			for fist: Node3D in row["boss_fists"]:
				fist.rotation.x = arm_tilt
	return seen


func _retire_actors(seen: Dictionary) -> void:
	for id in enemies.keys():
		if seen.has(id):
			continue
		var row: Dictionary = enemies[id]
		var model := row["node"] as Node3D
		var canvas: Dictionary = row["canvas"]
		model.hide()
		model.queue_free()
		(canvas["sprite"] as Sprite2D).queue_free()
		occupied_layers.erase(canvas["index"])
		enemies.erase(id)


func _create_actor(kind: StringName) -> Dictionary:
	var anchor := Node3D.new()
	combat_entities.add_child(anchor)
	var body := Node3D.new()
	anchor.add_child(body)
	var row := {"node": anchor, "body": body, "type": kind}
	match kind:
		&"drone":
			var rotor := Node3D.new()
			rotor.position.y = 0.45
			body.add_child(rotor)
			row["rotor"] = rotor
			row["lens"] = EnemyArt.drone_parts(body, rotor)
		&"bat":
			EnemyArt.faceted(body, Vector3(0, 0.40, 0.0), Vector3(0.59, 0.53, 0.50), Color("#665778"))
			EnemyArt.bat_face(body)
			var wings: Array[Node3D] = []
			for sign_value in [-1.0, 1.0]:
				var wing := Node3D.new()
				wing.position = Vector3(float(sign_value) * 0.27, 0.49, 0.0)
				body.add_child(wing)
				EnemyArt.wing(wing, sign_value)
				wings.append(wing)
			row["wings"] = wings
		&"ironback":
			EnemyArt.armor(body, Vector3(0, 0.58, 0.0), Vector3(1.10, 1.06, 0.65), EnemyArt.IRON)
			EnemyArt.ironback_parts(row, body)
		_:
			var dim := Vector3(0.98, 0.66, 0.78) * (0.65 if kind == &"slimeling" else 1.0)
			var skin := EnemyArt.faceted(body, Vector3.UP * dim.y * 0.49, dim, Color("#758945"))
			(skin.material_override as StandardMaterial3D).roughness = 0.36
			(skin.material_override as StandardMaterial3D).metallic_specular = 0.62
			for side in [-1.0, 1.0]:
				EnemyArt.faceted(body, Vector3(float(side) * dim.x * 0.19, dim.y * 0.62, dim.z * 0.46), Vector3(0.101, 0.083, 0.046), Color("#b3e5a5"), "gem", true)
			EnemyArt.gel_details(body, dim)
	return row


func _events(events: Array, hazards: Array) -> void:
	for item: Dictionary in events:
		if encounter_id.is_empty() or item.get("encounter_id", "") != encounter_id:
			continue
		var index := int(item.get("event_index", -1))
		if index <= last_event:
			continue
		last_event = index
		match item.get("event_type", &""):
			&"player_attack_resolved":
				_player_hit(item)
			&"hazard_activated":
				_hostile_impact(item, hazards)
			&"projectile_hit", &"projectile_blocked":
				var id := String(item.get("projectile_id", ""))
				var owner: Dictionary = enemies.get(String(item.get("owner_id", "")), {})
				if bolts.has(id) or owner.get("type") == &"bat":
					hostile_fx.bolt_contact(_world(Vector2(item["position"]), 0.60),
						_direction(Vector2(item.get("direction", Vector2.RIGHT))))
			&"ranged_fired":
				var owner: Dictionary = enemies.get(String(item.get("enemy_id", "")), {})
				if owner.get("type") == &"bat":
					var source := owner["node"] as Node3D
					hostile_fx.release(&"spread", source.position + Vector3.UP * 0.28, source.position,
						source.basis.z, 0.0, PackedVector3Array())
			&"player_damaged":
				fx.impact(actor.position + Vector3.UP * 0.71, -actor_heading, Color("#e0785b"))


func _hostile_impact(event: Dictionary, hazards: Array) -> void:
	var owner: Dictionary = enemies.get(String(event.get("owner_id", "")), {})
	if owner.get("type") != &"ironback":
		return
	for hazard: Dictionary in hazards:
		if hazard.get("hazard_id") != event.get("hazard_id"):
			continue
		var fists := PackedVector3Array()
		for tip: Node3D in owner.get("fist_tips", []):
			fists.append(tip.global_position)
		var heading := _direction(hazard.get("direction", Vector2.RIGHT))
		var at := _world(hazard.get("origin", last_local), FLOOR)
		hostile_fx.release(&"slam", at, at, heading, float(hazard.get("radius", 0.21)) * SPAN, fists, float(hazard.get("half_angle", PI / 3.0)))
		return


func _player_hit(event: Dictionary) -> void:
	var weapon := StringName(event.get("weapon", &"axe"))
	var skill := StringName(event.get("skill_id", &""))
	var heading := _direction(Vector2(event.get("facing", Vector2.RIGHT)))
	if weapon != &"axe" and actor.muzzle != null:
		var ends := PackedVector3Array()
		var blocked: Array = event.get("shot_obstacle_endpoints", [])
		var muzzle := actor.muzzle.global_position
		for endpoint: Vector2 in event.get("shot_endpoints", PackedVector2Array()):
			var at := _world(endpoint, muzzle.y - (0.14 if endpoint in blocked else 0.0))
			ends.append(at)
			if endpoint in blocked:
				fx.obstruction_hit(at, -heading)
		fx.shot(muzzle, actor.shell_port.global_position, ends, heading, weapon == &"scattergun", skill)
		muzzle_flashes += 1
	for id: String in event.get("hit_enemy_ids", []):
		if not enemies.has(id):
			continue
		var row: Dictionary = enemies[id]
		var target := row["node"] as Node3D
		var kind := StringName(row["type"])
		var shell := kind in [&"drone", &"ironback"]
		var gel := kind in [&"slime", &"slimeling"]
		var height := (0.71 if kind == &"ironback" else 0.38) * target.scale.y
		var contact := (target.position + Vector3.UP * height).move_toward(actor.position + Vector3.UP * 0.71, 0.32)
		var tint := Color("#e6a665") if weapon == &"axe" else Color("#9bd7e9")
		if skill == &"piercing_shot":
			tint = Color("#aafff4")
		elif skill == &"sweeping_volley":
			tint = Color("#ffaf60")
		fx.impact(contact, heading, tint, &"armor" if shell else (&"gel" if gel else &"body"))
		row["hit_until"] = clock + 0.16
		armor_impacts += int(shell)
		soft_impacts += int(gel)


func _sync_projectiles(snapshot: Dictionary) -> void:
	var live_bolts := {}
	for shot: Dictionary in snapshot.get("projectiles", []):
		if enemies.get(String(shot.get("owner_id", "")), {}).get("type") != &"bat":
			continue
		var id := String(shot["projectile_id"])
		live_bolts[id] = true
		if not bolts.has(id):
			bolts[id] = hostile_fx.bolt_view(combat_entities)
		var bolt := bolts[id] as Node3D
		bolt.position = _world(Vector2(shot["pos"]), 0.62)
		var direction := _direction(Vector2(shot.get("velocity", Vector2.RIGHT)))
		bolt.rotation.y = atan2(direction.x, direction.z)
		(bolt.get_child(0) as Node3D).rotation.z = clock * 6.0
	_retire_missing(bolts, live_bolts)
	var live_beams := {}
	for laser: Dictionary in snapshot.get("lasers", []):
		var id := String(laser.get("owner_id", ""))
		var owner: Dictionary = enemies.get(id, {})
		if owner.get("type") != &"drone":
			continue
		var source := owner["node"] as Node3D
		var at := source.position + Vector3.UP * 0.28
		var to := _world(Vector2(laser["endpoint"]), at.y)
		var direction := at.direction_to(to)
		if at.distance_to(to) < 0.04:
			continue
		source.rotation.y = atan2(direction.x, direction.z)
		at = at.move_toward(to, minf(0.51, at.distance_to(to) * 0.35))
		live_beams[id] = true
		var first := not beams.has(id)
		if first:
			beams[id] = hostile_fx.laser_view(combat_entities)
		var beam := beams[id] as Node3D
		beam.scale = Vector3.ONE
		beam.position = at
		beam.look_at(to, Vector3.UP, true)
		var pulse := lerpf(0.27, 1.0, smoothstep(0.0, 0.14, float(laser["remaining"])))
		beam.scale = Vector3(pulse, pulse, at.distance_to(to))
		for i in range(1, beam.get_child_count()):
			var glint := beam.get_child(i) as Node3D
			var progress := fposmod(clock * 2.8 + i * 0.25, 1.0)
			glint.position.z = progress
			glint.visible = progress > 0.06 and progress < 0.95
		if bool(laser.get("occluded", false)) and (first or clock >= float(beam.get_meta("next_contact", 0.0))):
			hostile_fx.beam_contact(to - direction * 0.04, direction, first)
			beam.set_meta("next_contact", clock + 0.11)
	_retire_missing(beams, live_beams)


func _retire_missing(views: Dictionary, visible_ids: Dictionary) -> void:
	for id in views.keys():
		if not visible_ids.has(id):
			(views[id] as Node3D).queue_free()
			views.erase(id)


func _direction(value: Vector2) -> Vector3:
	return Vector3(value.x, 0, value.y / sin(ELEVATION)).normalized()


func _world(value: Vector2, height: float) -> Vector3:
	return Vector3((value.x - 0.5) * SPAN, height, (value.y - 0.5) * SPAN / sin(ELEVATION))
