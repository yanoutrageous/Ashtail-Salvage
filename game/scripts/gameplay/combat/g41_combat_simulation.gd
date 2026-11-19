extends RefCounted
class_name G41CombatSimulation

const RngScript := preload("res://scripts/gameplay/combat/g41_deterministic_rng.gd")
const MonsterCatalogScript := preload("res://scripts/gameplay/combat/g41_monster_catalog.gd")
const WorldObjectProjection := preload("res://scripts/gameplay/runtime/g41_world_object_projection.gd")
const Z2Talents := preload("res://scripts/core/progression/z2_talent_runtime.gd")

const FIXED_STEP := 1.0 / 60.0
const MAX_FRAME_DELTA := 0.25
const MAX_CATCH_UP_STEPS := 15
const ROOM_MIN := 0.055
const ROOM_MAX := 0.945
const FieldWeapons := preload("res://scripts/gameplay/combat/field_weapons.gd")

const PLAYER_SPEED := 0.385
const PLAYER_ACCELERATION := 16.0
const PLAYER_DECELERATION := 22.0
const PLAYER_RADIUS := G41RuntimeLayout.PLAYER_BODY_RADIUS
const PLAYER_ATTACK_RANGE := 0.21
const PLAYER_ATTACK_CONE_DOT := 0.50
const PLAYER_ATTACK_COOLDOWN := 0.85
const PLAYER_INVULNERABILITY := 0.90
const PLAYER_ATTACK_WINDUP := 0.08
const PLAYER_ATTACK_ACTIVE := 0.12
# The authored active animation spends its first 0.06 seconds on
# attack_swing, then exposes attack_impact. Settlement waits for that visible
# impact pose instead of landing on the first active simulation tick.
const PLAYER_ATTACK_IMPACT_SECONDS := 0.06
const PLAYER_ATTACK_RECOVERY := 0.16
const PLAYER_ATTACK_BUFFER_SECONDS := 0.16
const PLAYER_HURT_SECONDS := 0.12
const ENEMY_HURT_SECONDS := 0.12
const PROJECTILE_SPEED := 0.80
const RETURN_PROJECTILE_MAX_DISTANCE := 0.42
# Presentation previously rendered projectiles at roughly a five-pixel radius
# and lasers at roughly a four-pixel half-width on the 560 px room plate while
# retaining the much larger UE prototype collision values. Keep the normalized
# gameplay contract aligned with that readable presentation footprint.
const PROJECTILE_RADIUS := 0.012
const LASER_RADIUS := 0.010
const EPSILON := 0.0000001
const GEOMETRY_EPSILON := 0.00001
const MELEE_NAVIGATION_MARGIN := 0.012
const MELEE_WAYPOINT_REACHED_DISTANCE := 0.010
const ATTACK_VISIBILITY_SEGMENTS := 32
const ARENA_CONTRACT_ID := &"g41.combat_arena.monster_room.v1"
const TRANSACTION_FIELDS := [
	"active", "paused", "cleared", "defeated", "reward_emitted", "tick_index", "event_index",
	"accumulator", "encounter_seed", "player", "enemies", "projectiles", "lasers", "hazards",
	"player_position_history", "pending_events", "move_input", "aim_input", "attack_queued",
	"attack_buffer_remaining", "attack_buffer_facing", "active_player_attack",
	"next_player_attack_index", "next_projectile_index", "next_hazard_index",
	"previous_player_pos", "previous_enemy_positions", "previous_projectile_positions",
	"previous_laser_origins", "arena_obstacles", "encounter_profile",
	"encounter_id", "next_hit_index", "step_error",
]

var active: bool = false
var paused: bool = false
var cleared: bool = false
var defeated: bool = false
var reward_emitted: bool = false
var tick_index: int = 0
var event_index: int = 0
var accumulator: float = 0.0
var encounter_seed: int = 1
var rng: G41DeterministicRng
var player: Dictionary = {}
var enemies: Array[Dictionary] = []
var projectiles: Array[Dictionary] = []
var lasers: Array[Dictionary] = []
var hazards: Array[Dictionary] = []
var player_position_history: Array[Vector2] = []
var pending_events: Array[Dictionary] = []
var move_input := Vector2.ZERO
var aim_input := Vector2.RIGHT
var attack_queued: bool = false
var attack_buffer_remaining: float = 0.0
var attack_buffer_facing := Vector2.ZERO
var active_player_attack: Dictionary = {}
var next_player_attack_index: int = 1
var next_projectile_index: int = 1
var next_hazard_index: int = 1
var previous_player_pos := Vector2.ZERO
var previous_enemy_positions: Dictionary = {}
var previous_projectile_positions: Dictionary = {}
var previous_laser_origins: Dictionary = {}
var arena_obstacles: Array[Rect2] = []
var encounter_profile: Dictionary = {}
var encounter_id: String = ""
var next_hit_index: int = 1
var step_error: Dictionary = {}
# Authority binding, deliberately excluded from transaction/checkpoint data.
var hit_resolver: Callable = Callable()
var attack_allowed_query: Callable = Callable()
var attack_started_resolver: Callable = Callable()
var attack_power_resolver: Callable = Callable()


func export_transaction_state() -> Dictionary:
	var state := {}
	for field in TRANSACTION_FIELDS:
		var value: Variant = get(field)
		state[field] = value.duplicate(true) if value is Array or value is Dictionary else value
	state["rng_state"] = null if rng == null else str(rng.state)
	return state


func import_transaction_state(state: Dictionary) -> void:
	for field in TRANSACTION_FIELDS:
		var value: Variant = state[field]
		if value is Array:
			# assign retains the declared Array element type after checkpoint decoding.
			var target: Array = get(field)
			target.assign(value.duplicate(true))
		else:
			set(field, value.duplicate(true) if value is Dictionary else value)
	if state["rng_state"] == null:
		rng = null
	else:
		if rng == null:
			rng = RngScript.new()
		# Seed normalization changes an existing state; restoring must be exact.
		rng.state = int(state["rng_state"])


func validate_transaction_state(state: Dictionary) -> bool:
	if state.size() != TRANSACTION_FIELDS.size() + 1 or not valid_transaction_value(state):
		return false
	for field in TRANSACTION_FIELDS:
		if not state.has(field) or typeof(state[field]) != typeof(get(field)):
			return false
	if not state.has("rng_state"):
		return false
	for field in ["tick_index", "event_index", "accumulator", "attack_buffer_remaining"]:
		if state[field] < 0:
			return false
	for field in ["next_player_attack_index", "next_projectile_index", "next_hazard_index", "next_hit_index"]:
		if state[field] < 1:
			return false
	if state.encounter_seed < 1 or state.encounter_seed >= RngScript.MODULUS:
		return false
	if (state.active and (state.cleared or state.defeated)) or (state.cleared and state.defeated):
		return false
	if state.rng_state == null:
		# An unstarted simulation cannot carry actor/history data. In particular,
		# do not let this branch bypass typed-array validation before installation.
		for field in ["player", "enemies", "projectiles", "lasers", "hazards", "pending_events", "player_position_history", "active_player_attack", "previous_enemy_positions", "previous_projectile_positions", "previous_laser_origins", "arena_obstacles", "encounter_profile"]:
			if not state[field].is_empty():
				return false
		return not state.active and not state.cleared and not state.defeated
	if not state.rng_state is String or not state.rng_state.is_valid_int():
		return false
	var restored_rng := int(state.rng_state)
	if restored_rng <= 0 or restored_rng >= RngScript.MODULUS or str(restored_rng) != state.rng_state or state.encounter_id.is_empty():
		return false
	if not _valid_record(state.player, {"pos": TYPE_VECTOR2, "velocity": TYPE_VECTOR2, "facing": TYPE_VECTOR2, "hp": TYPE_INT, "max_hp": TYPE_INT, "power": TYPE_INT, "shield": TYPE_INT, "state": TYPE_STRING_NAME, "state_timer": TYPE_FLOAT, "attack_cooldown": TYPE_FLOAT, "invulnerability": TYPE_FLOAT}):
		return false
	if state.player.has("z2_talents") and not Z2Talents.valid_profile(state.player.z2_talents):
		return false
	if state.player.max_hp < 1 or state.player.hp < 0 or state.player.hp > state.player.max_hp or state.player.power < 1 or state.player.shield < 0:
		return false
	if state.defeated != (state.player.hp == 0):
		return false
	if state.player_position_history.is_empty() or state.player_position_history.size() > 31:
		return false
	for position in state.player_position_history:
		if not position is Vector2:
			return false
	for rect in state.arena_obstacles:
		if not rect is Rect2 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
			return false
	var enemy_ids := {}
	for enemy in state.enemies:
		if not _valid_record(enemy, {"enemy_id": TYPE_STRING, "monster_type": TYPE_STRING_NAME, "pos": TYPE_VECTOR2, "hp": TYPE_INT, "max_hp": TYPE_INT, "damage": TYPE_INT, "body_radius": TYPE_FLOAT, "state": TYPE_STRING_NAME, "state_timer": TYPE_FLOAT, "entry_grace_remaining": TYPE_FLOAT, "attack_done": TYPE_BOOL, "wander_timer": TYPE_FLOAT, "wander_direction": TYPE_VECTOR2, "strafe_sign": TYPE_INT}):
			return false
		if enemy.enemy_id.is_empty() or enemy_ids.has(enemy.enemy_id) or enemy.max_hp < 1 or enemy.hp < 0 or enemy.hp > enemy.max_hp:
			return false
		enemy_ids[enemy.enemy_id] = true
		if str(enemy.get("behavior_id", "")) == "marked_jump" and str(enemy.state) in ["warning", "active"] and not _valid_record(enemy, {"jump_origin": TYPE_VECTOR2, "jump_target": TYPE_VECTOR2}):
			return false
		if str(enemy.get("repair_mode", "")) != "" and not _valid_record(enemy, {"repair_target": TYPE_VECTOR2, "repair_remaining": TYPE_FLOAT}):
			return false
	var projectile_ids := {}
	for projectile in state.projectiles:
		if not _valid_record(projectile, {"projectile_id": TYPE_STRING, "owner_id": TYPE_STRING, "pos": TYPE_VECTOR2, "velocity": TYPE_VECTOR2, "radius": TYPE_FLOAT, "damage": TYPE_INT, "state": TYPE_STRING_NAME}):
			return false
		if not enemy_ids.has(projectile.owner_id) or projectile_ids.has(projectile.projectile_id) or not _valid_sequence_id(projectile.projectile_id, "projectile_", state.next_projectile_index):
			return false
		projectile_ids[projectile.projectile_id] = true
		if projectile.has("return_distance") and not _valid_record(projectile, {"return_distance": TYPE_FLOAT, "distance_remaining": TYPE_FLOAT, "return_origin": TYPE_VECTOR2, "return_point": TYPE_VECTOR2, "inbound": TYPE_BOOL}):
			return false
	for laser in state.lasers:
		if not _valid_record(laser, {"owner_id": TYPE_STRING, "origin": TYPE_VECTOR2, "direction": TYPE_VECTOR2, "endpoint": TYPE_VECTOR2, "remaining": TYPE_FLOAT, "tick_timer": TYPE_FLOAT, "tick_seconds": TYPE_FLOAT, "damage": TYPE_INT, "radius": TYPE_FLOAT, "occluded": TYPE_BOOL}) or not enemy_ids.has(laser.owner_id):
			return false
	var hazard_ids := {}
	for hazard in state.hazards:
		if not _valid_record(hazard, {"hazard_id": TYPE_STRING, "owner_id": TYPE_STRING, "behavior_id": TYPE_STRING_NAME, "direction": TYPE_VECTOR2, "phase": TYPE_STRING_NAME, "warning_remaining": TYPE_FLOAT, "remaining": TYPE_FLOAT, "damage": TYPE_INT, "pressure_delta": TYPE_INT, "tick_seconds": TYPE_FLOAT, "tick_timer": TYPE_FLOAT, "hit": TYPE_BOOL, "created_tick": TYPE_INT}):
			return false
		if not enemy_ids.has(hazard.owner_id) or hazard_ids.has(hazard.hazard_id) or not _valid_sequence_id(hazard.hazard_id, "hazard_", state.next_hazard_index):
			return false
		hazard_ids[hazard.hazard_id] = true
		if str(hazard.get("shape", "circle")) == "line" and not _valid_record(hazard, {"endpoint": TYPE_VECTOR2}):
			return false
		if str(hazard.get("control", "")) == "pull" and not _valid_record(hazard, {"origin": TYPE_VECTOR2}):
			return false
	if not FieldWeapons.valid_weapon(state.player.get("field_weapon", FieldWeapons.AXE)):
		return false
	if state.player.has("queued_field_skill") and (not state.attack_queued or not FieldWeapons.skill_matches(
		StringName(state.player.get("field_weapon", FieldWeapons.AXE)), state.player["queued_field_skill"]
	)):
		return false
	if not FieldWeapons.valid_weapon(state.active_player_attack.get("weapon", FieldWeapons.AXE)):
		return false
	if not state.active_player_attack.is_empty():
		if not _valid_record(state.active_player_attack, {"attack_id": TYPE_STRING, "origin": TYPE_VECTOR2, "facing": TYPE_VECTOR2, "range": TYPE_FLOAT, "cone_dot": TYPE_FLOAT, "started_tick": TYPE_INT, "resolved": TYPE_BOOL}) or not _valid_sequence_id(state.active_player_attack.attack_id, "player_attack_", state.next_player_attack_index):
			return false
		if state.active_player_attack.has("skill_id") and not FieldWeapons.skill_matches(
			StringName(state.active_player_attack.get("weapon", FieldWeapons.AXE)), state.active_player_attack["skill_id"]
		):
			return false
	for field in ["previous_enemy_positions", "previous_projectile_positions", "previous_laser_origins"]:
		for entity_id in state[field]:
			if not entity_id is String or not state[field][entity_id] is Vector2:
				return false
			if field == "previous_projectile_positions":
				if not _valid_sequence_id(entity_id, "projectile_", state.next_projectile_index):
					return false
			elif not enemy_ids.has(entity_id):
				return false
	return valid_event_records(state.pending_events, state, enemy_ids)


static func valid_transaction_value(value: Variant, depth: int = 0) -> bool:
	if depth > 64:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME, TYPE_VECTOR2I:
			return true
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_VECTOR2:
			return value.is_finite()
		TYPE_RECT2:
			return value.position.is_finite() and value.size.is_finite()
		TYPE_ARRAY:
			for entry in value:
				if not valid_transaction_value(entry, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if typeof(key) not in [TYPE_STRING, TYPE_STRING_NAME, TYPE_INT] or not valid_transaction_value(value[key], depth + 1):
					return false
			return true
	return false


static func _valid_record(value: Variant, required: Dictionary) -> bool:
	if not value is Dictionary:
		return false
	for field in required:
		if not value.has(field):
			return false
		var kind: int = required[field]
		if kind in [TYPE_STRING, TYPE_STRING_NAME]:
			if typeof(value[field]) not in [TYPE_STRING, TYPE_STRING_NAME]:
				return false
		elif typeof(value[field]) != kind:
			return false
	# These optional vectors are consumed by special behaviors and geometry.
	for field in ["pos", "velocity", "facing", "origin", "endpoint", "direction", "size", "jump_origin", "jump_target", "repair_target", "projectile_return_point", "return_origin", "return_point", "wander_direction"]:
		if value.has(field) and not value[field] is Vector2:
			return false
	for field in ["radius", "inner_radius", "half_width", "half_angle", "range", "cone_dot", "half_angle_radians", "impact_seconds", "remaining", "warning_remaining", "tick_timer", "tick_seconds", "return_distance", "distance_remaining", "control_speed", "dash_timer", "wander_timer", "entry_grace_remaining", "state_timer", "attack_cooldown", "invulnerability", "visual_lift", "repair_remaining", "visual_radius", "turn_speed_degrees", "turn_speed", "body_radius", "attack_radius", "warning_radius"]:
		if value.has(field) and typeof(value[field]) not in [TYPE_INT, TYPE_FLOAT]:
			return false
	for field in ["hp", "max_hp", "power", "shield", "damage", "pressure_delta", "created_tick", "started_tick", "resolved_tick", "active_started_tick", "action_started_tick", "counter_window_until"]:
		if value.has(field) and not value[field] is int:
			return false
	for field in ["hit", "inbound", "resolved", "attack_done", "repair_attempted", "occluded"]:
		if value.has(field) and not value[field] is bool:
			return false
	return true


static func _valid_sequence_id(value: Variant, prefix: String, next_index: int) -> bool:
	if not value is String or not value.begins_with(prefix):
		return false
	var suffix: String = value.substr(prefix.length())
	if not suffix.is_valid_int():
		return false
	var index := int(suffix)
	return index > 0 and index < next_index and value == prefix + "%04d" % index


static func valid_event_records(events: Array, state: Dictionary = {}, enemy_ids: Dictionary = {}) -> bool:
	var previous_index := 0
	for event in events:
		if not _valid_record(event, {"event_type": TYPE_STRING_NAME, "event_index": TYPE_INT, "tick": TYPE_INT}) or str(event.event_type).is_empty() or event.event_index < 1 or event.tick < 0:
			return false
		if state.is_empty():
			continue # Bridge history may span earlier encounters.
		if event.event_index <= previous_index or event.event_index > state.event_index or event.tick > state.tick_index:
			return false
		previous_index = event.event_index
		for field in ["enemy_id", "owner_id"]:
			if event.has(field) and not enemy_ids.has(event[field]):
				return false
		for field in ["hit_enemy_ids", "blocked_enemy_ids"]:
			if event.has(field):
				if not event[field] is Array:
					return false
				for enemy_id in event[field]:
					if not enemy_ids.has(enemy_id):
						return false
		for item in [["projectile_id", "projectile_", "next_projectile_index"], ["hazard_id", "hazard_", "next_hazard_index"], ["attack_id", "player_attack_", "next_player_attack_index"]]:
			if event.has(item[0]) and not _valid_sequence_id(event[item[0]], item[1], state[item[2]]):
				return false
	return true


static func production_arena_obstacles() -> Array[Rect2]:
	return WorldObjectProjection.room_solid_rects(&"Monster")


func start(config: Dictionary = {}) -> void:
	encounter_seed = RngScript.normalize_seed(int(config.get("seed", 1)))
	encounter_id = String(config.get("encounter_id", "seed:%d" % encounter_seed))
	next_hit_index = 1
	step_error.clear()
	rng = RngScript.new(encounter_seed)
	active = true
	paused = false
	cleared = false
	defeated = false
	reward_emitted = false
	tick_index = 0
	event_index = 0
	accumulator = 0.0
	pending_events.clear()
	enemies.clear()
	projectiles.clear()
	lasers.clear()
	hazards.clear()
	player_position_history.clear()
	encounter_profile.clear()
	set_arena_obstacles(config.get("arena_obstacles", []))
	next_projectile_index = 1
	next_hazard_index = 1
	move_input = Vector2.ZERO
	aim_input = _normalized_or(Vector2(config.get("player_facing", Vector2.RIGHT)), Vector2.RIGHT)
	_clear_attack_buffer()
	active_player_attack.clear()
	next_player_attack_index = 1
	var player_spawn := _resolve_spawn_outside_obstacles(
		_clamp_position(Vector2(config.get("player_pos", Vector2(0.28, 0.50)))),
		PLAYER_RADIUS
	)
	player = {
		"pos": player_spawn,
		"velocity": Vector2.ZERO,
		"facing": aim_input,
		"hp": maxi(1, int(config.get("player_hp", 100))),
		"max_hp": maxi(1, int(config.get("player_max_hp", 100))),
		"power": maxi(1, int(config.get("player_power", 10))),
		"shield": maxi(0, int(config.get("player_shield", 0))),
		"state": &"idle",
		"state_timer": 0.0,
		"attack_cooldown": 0.0,
		"invulnerability": 0.0,
	}
	player["hp"] = mini(int(player["hp"]), int(player["max_hp"]))
	if bool(config.get("z2_talents", {}).get("enabled", false)):
		player["z2_talents"] = config.z2_talents.duplicate(true)
	player_position_history.append(player_spawn)
	var monster_types: Array = config.get("monster_types", MonsterCatalogScript.default_encounter())
	var enemy_profiles: Array = config.get("enemy_profiles", [])
	for monster_index in range(monster_types.size()):
		var enemy_profile: Dictionary = {}
		if monster_index < enemy_profiles.size() and enemy_profiles[monster_index] is Dictionary:
			enemy_profile = (enemy_profiles[monster_index] as Dictionary).duplicate(true)
		_spawn_enemy(StringName(monster_types[monster_index]), monster_index, "", null, enemy_profile)
		if monster_index == 0 and not enemy_profile.is_empty():
			encounter_profile = enemy_profile.duplicate(true)
	_capture_previous_transforms()
	_emit_event(&"combat_started", {"seed": encounter_seed, "enemy_count": enemies.size()})


func set_arena_obstacles(next_obstacles: Array) -> void:
	arena_obstacles.clear()
	for raw_obstacle in next_obstacles:
		if not raw_obstacle is Rect2:
			continue
		var obstacle := Rect2(raw_obstacle)
		if obstacle.size.x <= 0.0 or obstacle.size.y <= 0.0:
			continue
		arena_obstacles.append(obstacle)


func set_paused(next_paused: bool) -> void:
	paused = next_paused
	if paused:
		_clear_attack_buffer()


func set_player_input(next_move: Vector2, next_aim: Vector2 = Vector2.ZERO, speed_multiplier: float = 1.0) -> void:
	move_input = next_move.limit_length(1.0) * speed_multiplier
	if next_aim.length_squared() > EPSILON:
		aim_input = next_aim.normalized()
	elif move_input.length_squared() > EPSILON:
		aim_input = move_input.normalized()


func is_player_attack_allowed() -> bool:
	return not attack_allowed_query.is_valid() or attack_allowed_query.call() == true


func queue_player_attack(requested_facing: Vector2 = Vector2.ZERO) -> bool:
	if not active or paused or defeated or cleared or not is_player_attack_allowed():
		_clear_attack_buffer()
		return false
	var player_state := StringName(player.get("state", &"idle"))
	if player_state in [&"hurt", &"dead"]:
		_clear_attack_buffer()
		return false
	if player.has("queued_field_skill"):
		return false
	if float(player.get("attack_cooldown", 0.0)) > PLAYER_ATTACK_BUFFER_SECONDS + EPSILON:
		return false
	attack_queued = true
	attack_buffer_remaining = PLAYER_ATTACK_BUFFER_SECONDS
	attack_buffer_facing = _normalized_or(
		requested_facing,
		_normalized_or(aim_input, Vector2(player.get("facing", Vector2.RIGHT)))
	)
	return true


func queue_player_weapon_skill(weapon: StringName, requested_facing: Vector2 = Vector2.ZERO) -> bool:
	var skill := FieldWeapons.skill(weapon)
	if skill.is_empty() or attack_queued or player.get("state") not in [&"idle", &"move"]:
		return false
	if float(player.get("attack_cooldown", 0.0)) > EPSILON or not queue_player_attack(requested_facing):
		return false
	player["field_weapon"] = weapon
	player["queued_field_skill"] = skill["id"]
	return true


func advance_frame(delta: float, fixed_step_executor: Callable = Callable()) -> int:
	if not active or paused or delta < 0.0:
		return 0
	accumulator += minf(delta, MAX_FRAME_DELTA)
	var advanced := 0
	while active and not paused and accumulator + EPSILON >= FIXED_STEP and advanced < MAX_CATCH_UP_STEPS:
		var before_tick := tick_index
		var result: Dictionary = fixed_step_executor.call() if fixed_step_executor.is_valid() else advance_pending_step()
		# A failed transaction restores this very simulation, including its debt.
		# A duplicate receipt must not spin through catch-up without advancing.
		if not bool(result.get("ok", false)) or tick_index == before_tick:
			break
		advanced += 1
	return advanced


func advance_pending_step(before_physics: Callable = Callable()) -> Dictionary:
	if not active or paused or accumulator + EPSILON < FIXED_STEP:
		return {"ok": false, "reason": "fixed_step_unavailable"}
	accumulator = maxf(0.0, accumulator - FIXED_STEP)
	_step(before_physics)
	return {"ok": true} if step_error.is_empty() else step_error.duplicate(true)


func advance_ticks(count: int) -> void:
	if paused:
		return
	for _unused in range(maxi(0, count)):
		if not active:
			break
		_step()
		if not step_error.is_empty():
			break


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in pending_events:
		result.append(event.duplicate(true))
	pending_events.clear()
	return result


func mark_reward_committed() -> void:
	reward_emitted = true


func sync_player_durable_stats(hp: int, max_hp: int, power: int, shield: int = 0) -> void:
	if defeated:
		return
	player["max_hp"] = maxi(1, max_hp)
	player["hp"] = clampi(hp, 0, int(player["max_hp"]))
	player["power"] = maxi(1, power)
	player["shield"] = maxi(0, shield)
	if int(player["hp"]) <= 0:
		player["state"] = &"dead"
		defeated = true
		active = false
		_clear_attack_buffer()
		active_player_attack.clear()


func place_player_from_room_entry(next_position: Vector2, entry_direction: Vector2) -> Dictionary:
	if not active or player.is_empty() or tick_index != 0:
		return {
			"applied": false,
			"reason": &"entry_window_closed",
			"position": Vector2(player.get("pos", next_position)),
		}
	var resolved_position := _resolve_spawn_outside_obstacles(
		_clamp_position(next_position),
		PLAYER_RADIUS
	)
	var resolved_facing := _normalized_or(
		entry_direction,
		Vector2(player.get("facing", Vector2.RIGHT))
	)
	player["pos"] = resolved_position
	player["velocity"] = Vector2.ZERO
	player["facing"] = resolved_facing
	player["state"] = &"idle"
	player["state_timer"] = 0.0
	previous_player_pos = resolved_position
	move_input = Vector2.ZERO
	aim_input = resolved_facing
	return {
		"applied": true,
		"position": resolved_position,
		"facing": resolved_facing,
	}


func build_snapshot() -> Dictionary:
	var render_alpha := clampf(accumulator / FIXED_STEP, 0.0, 1.0)
	var render_player := player.duplicate(true)
	var current_player_pos := Vector2(player.get("pos", Vector2.ZERO))
	render_player["simulation_pos"] = current_player_pos
	render_player["previous_pos"] = previous_player_pos
	render_player["pos"] = previous_player_pos.lerp(current_player_pos, render_alpha)
	var attack_geometry := _build_player_attack_geometry_snapshot()
	render_player["attack_geometry"] = attack_geometry.duplicate(true)
	var render_enemies: Array[Dictionary] = []
	for enemy in enemies:
		var render_enemy := enemy.duplicate(true)
		var enemy_id := String(enemy.get("enemy_id", ""))
		var enemy_pos := Vector2(enemy.get("pos", Vector2.ZERO))
		var previous_pos := Vector2(previous_enemy_positions.get(enemy_id, enemy_pos))
		render_enemy["simulation_pos"] = enemy_pos
		render_enemy["previous_pos"] = previous_pos
		render_enemy["pos"] = previous_pos.lerp(enemy_pos, render_alpha)
		render_enemies.append(render_enemy)
	var render_projectiles: Array[Dictionary] = []
	for projectile in projectiles:
		var render_projectile := projectile.duplicate(true)
		var projectile_id := String(projectile.get("projectile_id", ""))
		var projectile_pos := Vector2(projectile.get("pos", Vector2.ZERO))
		var previous_pos := Vector2(previous_projectile_positions.get(projectile_id, projectile_pos))
		render_projectile["simulation_pos"] = projectile_pos
		render_projectile["previous_pos"] = previous_pos
		render_projectile["pos"] = previous_pos.lerp(projectile_pos, render_alpha)
		render_projectiles.append(render_projectile)
	var render_lasers: Array[Dictionary] = []
	for laser in lasers:
		var render_laser := laser.duplicate(true)
		var laser_id := String(laser.get("laser_id", laser.get("owner_id", "")))
		var laser_origin := Vector2(laser.get("origin", Vector2.ZERO))
		var previous_origin := Vector2(previous_laser_origins.get(laser_id, laser_origin))
		render_laser["simulation_origin"] = laser_origin
		render_laser["origin"] = previous_origin.lerp(laser_origin, render_alpha)
		render_lasers.append(render_laser)
	return {
		"active": active,
		"paused": paused,
		"cleared": cleared,
		"defeated": defeated,
		"reward_emitted": reward_emitted,
		"tick": tick_index,
		"seed": encounter_seed,
		"render_alpha": render_alpha,
		"player": render_player,
		"player_attack_geometry": attack_geometry,
		"arena_contract": ARENA_CONTRACT_ID,
		"arena_obstacles": arena_obstacles.duplicate(),
		"encounter_profile": encounter_profile.duplicate(true),
		"attack_input": {
			"buffered": attack_queued,
			"remaining_seconds": attack_buffer_remaining,
			"maximum_seconds": PLAYER_ATTACK_BUFFER_SECONDS,
			"cooldown_remaining_seconds": float(player.get("attack_cooldown", 0.0)),
			"cooldown_maximum_seconds": _attack_seconds(PLAYER_ATTACK_COOLDOWN),
			"ready": (
				StringName(player.get("state", &"idle")) in [&"idle", &"move"]
				and float(player.get("attack_cooldown", 0.0)) <= EPSILON
			),
			"buffer_window_open": (
				float(player.get("attack_cooldown", 0.0)) > EPSILON
				and float(player.get("attack_cooldown", 0.0)) <= PLAYER_ATTACK_BUFFER_SECONDS + EPSILON
			),
			"facing": attack_buffer_facing,
		},
		"enemies": render_enemies,
		"projectiles": render_projectiles,
		"lasers": render_lasers,
		"hazards": hazards.duplicate(true),
	}


func build_canonical_snapshot() -> Dictionary:
	var canonical_enemies: Array[Dictionary] = []
	for enemy in enemies:
		canonical_enemies.append({
			"enemy_id": String(enemy.get("enemy_id", "")),
			"monster_type": String(enemy.get("monster_type", &"")),
			"hp": int(enemy.get("hp", 0)),
			"state": String(enemy.get("state", &"idle")),
			"pos": _canonical_vector(Vector2(enemy.get("pos", Vector2.ZERO))),
		})
	var canonical_projectiles: Array[Dictionary] = []
	for projectile in projectiles:
		canonical_projectiles.append({
			"projectile_id": String(projectile.get("projectile_id", "")),
			"owner_id": String(projectile.get("owner_id", "")),
			"pos": _canonical_vector(Vector2(projectile.get("pos", Vector2.ZERO))),
		})
	return {
		"active": active,
		"cleared": cleared,
		"defeated": defeated,
		"tick": tick_index,
		"player_hp": int(player.get("hp", 0)),
		"player_state": String(player.get("state", &"idle")),
		"player_pos": _canonical_vector(Vector2(player.get("pos", Vector2.ZERO))),
		"attack_buffer_remaining": snappedf(attack_buffer_remaining, 0.000001),
		"attack_buffer_facing": _canonical_vector(attack_buffer_facing),
		"player_attack": _canonical_player_attack(),
		"arena_contract": String(ARENA_CONTRACT_ID),
		"arena_obstacles": _canonical_rects(arena_obstacles),
		"encounter_profile": encounter_profile.duplicate(true),
		"enemies": canonical_enemies,
		"projectiles": canonical_projectiles,
		"laser_count": lasers.size(),
		"hazards": hazards.duplicate(true),
		"rng_state": 0 if rng == null else rng.state,
	}


func _step(before_physics: Callable = Callable()) -> void:
	step_error.clear()
	_capture_previous_transforms()
	tick_index += 1
	if before_physics.is_valid():
		var advanced_time: Dictionary = before_physics.call()
		if not bool(advanced_time.get("ok", false)):
			step_error = advanced_time.duplicate(true)
			return
		if defeated:
			_emit_event(&"player_defeated", {"source_id": "simulation_time", "damage_kind": &"status"})
			return
	_update_player(FIXED_STEP)
	if not step_error.is_empty():
		return
	player_position_history.append(Vector2(player.get("pos", Vector2.ZERO)))
	if player_position_history.size() > 31:
		player_position_history.pop_front()
	var enemy_count_at_step_start := enemies.size()
	for enemy_index in range(enemy_count_at_step_start):
		if enemy_index >= enemies.size():
			break
		_update_enemy(enemy_index, FIXED_STEP)
		if not step_error.is_empty():
			return
	_update_projectiles(FIXED_STEP)
	if not step_error.is_empty():
		return
	_update_lasers(FIXED_STEP)
	if not step_error.is_empty():
		return
	_update_hazards(FIXED_STEP)
	if not step_error.is_empty():
		return
	_check_terminal_state()


func _capture_previous_transforms() -> void:
	previous_player_pos = Vector2(player.get("pos", previous_player_pos))
	previous_enemy_positions.clear()
	for enemy in enemies:
		previous_enemy_positions[String(enemy.get("enemy_id", ""))] = Vector2(enemy.get("pos", Vector2.ZERO))
	previous_projectile_positions.clear()
	for projectile in projectiles:
		previous_projectile_positions[String(projectile.get("projectile_id", ""))] = Vector2(projectile.get("pos", Vector2.ZERO))
	previous_laser_origins.clear()
	for laser in lasers:
		var laser_id := String(laser.get("laser_id", laser.get("owner_id", "")))
		previous_laser_origins[laser_id] = Vector2(laser.get("origin", Vector2.ZERO))


func _update_player(delta: float) -> void:
	if defeated:
		_clear_attack_buffer()
		active_player_attack.clear()
		return
	player["attack_cooldown"] = maxf(0.0, float(player.get("attack_cooldown", 0.0)) - delta)
	player["invulnerability"] = maxf(0.0, float(player.get("invulnerability", 0.0)) - delta)
	var player_state := StringName(player.get("state", &"idle"))
	var current_velocity := Vector2(player.get("velocity", Vector2.ZERO))
	if player_state in [&"attack_windup", &"attack_active"]:
		# The attack contract freezes its origin and facing. Lock locomotion for
		# the damaging cycle so the visible sector cannot detach from the actor.
		# Recovery keeps the authored facing but returns locomotion immediately.
		current_velocity = Vector2.ZERO
	else:
		var target_velocity := move_input * PLAYER_SPEED * Z2Talents.speed_multiplier(player.get("z2_talents", {}), "movement_speed_percent")
		var acceleration := PLAYER_ACCELERATION if move_input.length_squared() > EPSILON else PLAYER_DECELERATION
		current_velocity = current_velocity.move_toward(target_velocity, acceleration * delta)
	player["velocity"] = current_velocity
	var player_pos := Vector2(player.get("pos", Vector2.ZERO))
	player["pos"] = _resolve_body_motion(player_pos, player_pos + current_velocity * delta, PLAYER_RADIUS)
	if aim_input.length_squared() > EPSILON and player_state not in [&"attack_windup", &"attack_active", &"attack_recovery"]:
		player["facing"] = aim_input.normalized()
	_update_player_attack(delta)


func _update_player_attack(delta: float) -> void:
	var state := StringName(player.get("state", &"idle"))
	# Input can precede a restored opening state. Recheck before consuming any
	# first-attack effect or creating a damaging attack contract.
	if not is_player_attack_allowed():
		_clear_attack_buffer()
		if state in [&"attack_windup", &"attack_active", &"attack_recovery"]:
			active_player_attack.clear()
			state = &"move" if move_input.length_squared() > EPSILON else &"idle"
			player["state"] = state
			player["state_timer"] = 0.0
	if state == &"hurt":
		player["state_timer"] = maxf(0.0, float(player.get("state_timer", 0.0)) - delta)
		if float(player["state_timer"]) <= EPSILON:
			player["state"] = &"move" if move_input.length_squared() > EPSILON else &"idle"
		return
	if attack_queued and state in [&"idle", &"move"] and float(player.get("attack_cooldown", 0.0)) <= EPSILON:
		var queued_facing := attack_buffer_facing
		var use_skill := player.has("queued_field_skill")
		_clear_attack_buffer()
		state = &"attack_windup"
		player["state"] = state
		player["state_timer"] = _attack_seconds(PLAYER_ATTACK_WINDUP)
		active_player_attack = _create_player_attack_contract(queued_facing, use_skill)
		var weapon := StringName(active_player_attack.get("weapon", FieldWeapons.AXE))
		var cooldown := float(FieldWeapons.PROFILES[weapon]["cooldown"]) if FieldWeapons.PROFILES.has(weapon) else PLAYER_ATTACK_COOLDOWN
		player["attack_cooldown"] = _attack_seconds(cooldown)
		player["facing"] = Vector2(active_player_attack.get("facing", player.get("facing", Vector2.RIGHT)))
		if attack_started_resolver.is_valid():
			var started: Variant = attack_started_resolver.call()
			if not started is Dictionary or not bool(started.get("ok", false)):
				step_error = started.duplicate(true) if started is Dictionary else {"ok": false, "reason": "invalid_attack_start_result"}
				return
		_emit_event(&"player_attack_started", active_player_attack)
		_react_to_player_attack(active_player_attack)
	elif attack_queued:
		attack_buffer_remaining = maxf(0.0, attack_buffer_remaining - delta)
		if attack_buffer_remaining <= EPSILON:
			_clear_attack_buffer()
	if state in [&"attack_windup", &"attack_active", &"attack_recovery"]:
		player["state_timer"] = float(player.get("state_timer", 0.0)) - delta
		if state == &"attack_active" and _player_attack_impact_is_due():
			_perform_player_attack()
		if float(player["state_timer"]) <= EPSILON:
			match state:
				&"attack_windup":
					player["state"] = &"attack_active"
					player["state_timer"] = _attack_seconds(PLAYER_ATTACK_ACTIVE)
					active_player_attack["active_started_tick"] = tick_index
				&"attack_active":
					player["state"] = &"attack_recovery"
					player["state_timer"] = _attack_seconds(PLAYER_ATTACK_RECOVERY)
				&"attack_recovery":
					player["state"] = &"move" if move_input.length_squared() > EPSILON else &"idle"
					player["state_timer"] = 0.0
					active_player_attack.clear()
	else:
		player["state"] = &"move" if move_input.length_squared() > EPSILON else &"idle"


func _perform_player_attack() -> void:
	if active_player_attack.is_empty() or bool(active_player_attack.get("resolved", false)) or not is_player_attack_allowed():
		return
	active_player_attack["resolved"] = true
	active_player_attack["resolved_tick"] = tick_index
	var origin := Vector2(active_player_attack.get("origin", player.get("pos", Vector2.ZERO)))
	var facing := _normalized_or(Vector2(active_player_attack.get("facing", player.get("facing", Vector2.RIGHT))), Vector2.RIGHT)
	var attack_range := float(active_player_attack.get("range", PLAYER_ATTACK_RANGE))
	var cone_dot := float(active_player_attack.get("cone_dot", PLAYER_ATTACK_CONE_DOT))
	var hit_ids: Array[String] = []
	var blocked_ids: Array[String] = []
	var attack_power := int(player.get("power", 1))
	if attack_power_resolver.is_valid():
		var resolved: Variant = attack_power_resolver.call(attack_power)
		if not resolved is int or resolved < 1:
			step_error = {"ok": false, "reason": "invalid_attack_power"}
			return
		attack_power = resolved
	var weapon := StringName(active_player_attack.get("weapon", FieldWeapons.AXE))
	if FieldWeapons.PROFILES.has(weapon):
		_fire_field_weapon(origin, facing, weapon, attack_power)
		return
	for enemy_index in range(enemies.size()):
		var enemy := enemies[enemy_index]
		if int(enemy.get("hp", 0)) <= 0:
			continue
		var enemy_radius := _enemy_body_radius(enemy)
		if not _circle_intersects_attack_sector(
			origin,
			facing,
			attack_range,
			cone_dot,
			Vector2(enemy.get("pos", Vector2.ZERO)),
			enemy_radius
		):
			continue
		var enemy_id := String(enemy.get("enemy_id", ""))
		if _line_occluded(origin, Vector2(enemy.get("pos", Vector2.ZERO))):
			blocked_ids.append(enemy_id)
			continue
		_apply_player_strike(enemy_index, attack_power)
		hit_ids.append(enemy_id)
	var resolved_geometry := active_player_attack.duplicate(true)
	resolved_geometry["hit_enemy_ids"] = hit_ids
	resolved_geometry["hit_count"] = hit_ids.size()
	resolved_geometry["blocked_enemy_ids"] = blocked_ids
	resolved_geometry["blocked_count"] = blocked_ids.size()
	_emit_event(&"player_attack_resolved", resolved_geometry)


func _apply_player_strike(enemy_index: int, base_damage: int) -> void:
	var crit_stats := Z2Talents.critical_stats(player.get("z2_talents", {}))
	var critical := int(crit_stats.chance_percent) > 0 and rng.next_float() * 100.0 < float(crit_stats.chance_percent)
	var damage := maxi(1, floori(float(base_damage) * float(crit_stats.damage_percent) / 100.0)) if critical else base_damage
	_damage_enemy(enemy_index, damage, critical)


func _fire_field_weapon(origin: Vector2, facing: Vector2, weapon: StringName, power: int) -> void:
	var profile := FieldWeapons.shot_profile(weapon, active_player_attack.has("skill_id"))
	var passive := FieldWeapons.passive(weapon)
	var penetration := int(profile.get("penetration", 1))
	var endpoints: Array[Vector2] = []
	var blocked: Array[Vector2] = []
	var pellets := {}
	for angle: float in profile["rays"]:
		var finish := origin + facing.rotated(angle) * float(profile["range"])
		var obstacle_fraction := _first_obstacle_hit_fraction(origin, finish, 0.0)
		var limit := minf(1.0, obstacle_fraction)
		var contacts: Array[Vector2] = []
		for index in enemies.size():
			var enemy := enemies[index]
			if int(enemy.get("hp", 0)) <= 0:
				continue
			var contact := _segment_circle_hit_fraction(origin, finish, enemy["pos"], _enemy_body_radius(enemy))
			if contact < limit:
				contacts.append(Vector2(contact, index))
		contacts.sort_custom(func(left: Vector2, right: Vector2) -> bool:
			return left.x < right.x or (left.x == right.x and left.y < right.y)
		)
		var contact_count := mini(penetration, contacts.size())
		for index in contact_count:
			var contact := contacts[index]
			var target := int(contact.y)
			var weight := 1.0
			if weapon == FieldWeapons.SCATTER:
				if contact.x > 0.60:
					weight = 0.65
				elif contact.x <= 0.38:
					weight = float(passive.get("close_power_multiplier", 1.0))
			pellets[target] = float(pellets.get(target, 0.0)) + weight
		if contact_count == penetration:
			limit = contacts[contact_count - 1].x
		elif obstacle_fraction < 1.0:
			blocked.append(origin.lerp(finish, limit))
		endpoints.append(origin.lerp(finish, limit))
	var hit_ids: Array[String] = []
	for index: int in pellets:
		hit_ids.append(String(enemies[index]["enemy_id"]))
		_apply_player_strike(index, maxi(1, roundi(power * float(profile["power"]) * float(pellets[index]))))
	var event := active_player_attack.duplicate(true)
	event.merge({"hit_enemy_ids": hit_ids, "hit_count": hit_ids.size(), "shot_endpoints": endpoints,
		"shot_obstacle_endpoints": blocked, "blocked_count": blocked.size()}, true)
	_emit_event(&"player_attack_resolved", event)


func _player_attack_impact_is_due() -> bool:
	if active_player_attack.is_empty() or bool(active_player_attack.get("resolved", false)):
		return false
	var active_started_tick := int(active_player_attack.get("active_started_tick", tick_index))
	# Count the entry tick because presentation switches to attack_active on
	# that same authoritative step. This keeps the settlement on the first
	# fixed tick where attack_impact can already be visible.
	var visible_active_ticks := maxi(1, tick_index - active_started_tick + 1)
	return float(visible_active_ticks) * FIXED_STEP + EPSILON >= _attack_seconds(PLAYER_ATTACK_IMPACT_SECONDS)


func _attack_seconds(base_seconds: float) -> float:
	return base_seconds / Z2Talents.speed_multiplier(player.get("z2_talents", {}), "attack_speed_percent")


func _update_enemy(enemy_index: int, delta: float) -> void:
	var enemy := enemies[enemy_index]
	if int(enemy.get("hp", 0)) <= 0:
		return
	if StringName(enemy.get("behavior_id", &"")) == &"hit_counter":
		var charge_remaining := maxf(0.0, float(int(enemy.get("counter_window_until", -1)) - tick_index) * FIXED_STEP)
		enemy["counter_charge_remaining"] = charge_remaining
		enemy["counter_charge"] = 1 if charge_remaining > 0.0 else 0
	var entry_grace_remaining := maxf(
		0.0,
		float(enemy.get("entry_grace_remaining", 0.0)) - delta
	)
	if entry_grace_remaining > EPSILON:
		enemy["entry_grace_remaining"] = entry_grace_remaining
		enemies[enemy_index] = enemy
		return
	if float(enemy.get("entry_grace_remaining", 0.0)) > EPSILON:
		enemy["entry_grace_remaining"] = 0.0
		if StringName(enemy.get("state", &"arrival")) == &"arrival":
			enemy["state"] = &"idle"
			enemy["state_timer"] = float(
				MonsterCatalogScript.definition(
					StringName(enemy.get("monster_type", &"slime"))
				).get("idle_seconds", 0.0)
			)
		enemies[enemy_index] = enemy
		return
	if StringName(enemy.get("state", &"idle")) == &"hurt":
		enemy["state_timer"] = maxf(0.0, float(enemy.get("state_timer", 0.0)) - delta)
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"idle"
			enemy["state_timer"] = float(
				MonsterCatalogScript.definition(
					StringName(enemy.get("monster_type", &"slime"))
				).get("idle_seconds", 0.0)
			)
			if StringName(enemy.get("behavior_id", &"")) == &"attack_echo":
				for hazard in hazards:
					if String(hazard["owner_id"]) != String(enemy["enemy_id"]):
						continue
					var is_warning := StringName(hazard["phase"]) == &"warning"
					enemy["state"] = &"warning" if is_warning else &"active"
					enemy["state_timer"] = float(hazard["warning_remaining"] if is_warning else hazard["remaining"])
					enemy["action_started_tick"] = tick_index
					break
		enemies[enemy_index] = enemy
		return
	var monster_type := StringName(enemy.get("monster_type", &"slime"))
	if enemy.has("behavior_id"):
		match StringName(enemy["behavior_id"]):
			&"aftershock":
				_update_melee_enemy(enemy_index, delta)
			&"return_projectile", &"conveyor":
				_update_bat(enemy_index, delta)
			&"socket_repair":
				_update_repair_enemy(enemy_index, delta)
			_:
				_update_z1_hazard_enemy(enemy_index, delta)
		return
	match monster_type:
		MonsterCatalogScript.TYPE_SLIME, MonsterCatalogScript.TYPE_SLIMELING:
			_update_melee_enemy(enemy_index, delta)
		MonsterCatalogScript.TYPE_BAT:
			_update_bat(enemy_index, delta)
		MonsterCatalogScript.TYPE_DRONE:
			_update_drone(enemy_index, delta)


func _update_melee_enemy(enemy_index: int, delta: float) -> void:
	var enemy := enemies[enemy_index]
	var definition := MonsterCatalogScript.definition(StringName(enemy.get("monster_type", &"slime")))
	var state := StringName(enemy.get("state", &"idle"))
	var distance := Vector2(enemy.get("pos", Vector2.ZERO)).distance_to(Vector2(player.get("pos", Vector2.ZERO)))
	var melee_radius := _enemy_melee_hit_radius(enemy, definition)
	var has_clear_melee_path := not _line_occluded(
		Vector2(enemy.get("pos", Vector2.ZERO)),
		Vector2(player.get("pos", Vector2.ZERO))
	)
	if state == &"warning":
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"active"
			enemy["state_timer"] = float(definition.get("active_seconds", 0.2))
			enemy["attack_done"] = false
	elif state == &"active":
		if not bool(enemy.get("attack_done", false)):
			if StringName(enemy.get("behavior_id", &"")) == &"aftershock":
				_start_hazard(enemy, {
					"shape": &"ring", "origin": enemy["pos"],
					"radius": 0.31, "inner_radius": melee_radius,
					"warning_seconds": 0.65, "active_seconds": 0.18,
				})
			if distance <= melee_radius + EPSILON and has_clear_melee_path:
				_damage_player(int(enemy.get("damage", 1)), String(enemy.get("enemy_id", "")), &"melee")
			enemy["attack_done"] = true
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"cooldown"
			enemy["state_timer"] = float(definition.get("cooldown_seconds", 0.5))
	elif state == &"cooldown":
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"idle"
			enemy["state_timer"] = float(definition.get("idle_seconds", 0.0))
	elif state == &"idle":
		if distance <= melee_radius + EPSILON and has_clear_melee_path:
			enemy["state_timer"] = maxf(
				0.0,
				float(enemy.get("state_timer", definition.get("idle_seconds", 0.0))) - delta
			)
			if float(enemy["state_timer"]) <= EPSILON:
				enemy["state"] = &"warning"
				enemy["state_timer"] = float(definition.get("warning_seconds", 0.5))
				_emit_event(&"melee_warning_started", {
					"enemy_id": enemy.get("enemy_id", ""),
					"origin": enemy.get("pos", Vector2.ZERO),
					"radius": melee_radius,
				})
		else:
			enemy["state"] = &"move"
			var enemy_pos := Vector2(enemy.get("pos", Vector2.ZERO))
			enemy["pos"] = _resolve_body_motion(
				enemy_pos,
				enemy_pos + _melee_move_direction(enemy, delta) * float(definition.get("move_speed", 0.18)) * delta,
				_enemy_body_radius(enemy)
			)
	else:
		if distance <= melee_radius + EPSILON and has_clear_melee_path:
			enemy["state"] = &"idle"
			enemy["state_timer"] = float(definition.get("idle_seconds", 0.0))
		else:
			enemy["state"] = &"move"
			var direction := _melee_move_direction(enemy, delta)
			var enemy_pos := Vector2(enemy.get("pos", Vector2.ZERO))
			enemy["pos"] = _resolve_body_motion(
				enemy_pos,
				enemy_pos + direction * float(definition.get("move_speed", 0.18)) * delta,
				_enemy_body_radius(enemy)
			)
	enemies[enemy_index] = enemy


func _melee_move_direction(enemy: Dictionary, delta: float) -> Vector2:
	var player_direction := _direction_to_player(enemy)
	var desired_direction := player_direction
	if StringName(enemy.get("monster_type", &"slime")) == MonsterCatalogScript.TYPE_SLIMELING:
		var wander_timer := float(enemy.get("wander_timer", 0.0)) - delta
		if wander_timer <= EPSILON:
			var angle := rng.range_float(-PI, PI)
			enemy["wander_direction"] = Vector2.from_angle(angle)
			enemy["wander_timer"] = rng.range_float(0.45, 1.10)
		else:
			enemy["wander_timer"] = wander_timer
		desired_direction = _normalized_or(
			Vector2(enemy.get("wander_direction", player_direction)).lerp(player_direction, 0.35),
			player_direction
		)
	return _obstacle_aware_melee_direction(enemy, desired_direction)


func _obstacle_aware_melee_direction(enemy: Dictionary, desired_direction: Vector2) -> Vector2:
	var enemy_pos := Vector2(enemy.get("pos", Vector2.ZERO))
	var player_pos := Vector2(player.get("pos", Vector2.ZERO))
	var body_radius := _enemy_body_radius(enemy)
	var blocking_obstacle := Rect2()
	var blocking_fraction := INF
	for obstacle in arena_obstacles:
		var hit_fraction := _segment_rect_hit_fraction(
			enemy_pos,
			player_pos,
			_expanded_obstacle(obstacle, body_radius)
		)
		if hit_fraction < blocking_fraction:
			blocking_fraction = hit_fraction
			blocking_obstacle = obstacle
	if blocking_fraction > 1.0:
		enemy.erase("avoidance_waypoint")
		enemy.erase("avoidance_last_waypoint")
		return desired_direction

	# The production arena has only a handful of static rectangles. Four
	# clearance corners per blocking rectangle are cheaper and more
	# deterministic than a navigation mesh while still preventing a melee
	# actor from pushing forever into the visible altar. Re-evaluating the
	# shortest visible corner each fixed tick naturally advances from the near
	# corner to the far corner, then resumes direct pursuit.
	var clearance_rect := _expanded_obstacle(
		blocking_obstacle,
		body_radius + MELEE_NAVIGATION_MARGIN
	)
	var candidates: Array[Vector2] = [
		clearance_rect.position,
		Vector2(clearance_rect.end.x, clearance_rect.position.y),
		clearance_rect.end,
		Vector2(clearance_rect.position.x, clearance_rect.end.y),
	]
	var preferred_vertical_side := _stable_navigation_side(String(enemy.get("enemy_id", "")))
	var obstacle_center_y := blocking_obstacle.get_center().y
	var stored_waypoint_value: Variant = enemy.get("avoidance_waypoint", null)
	if stored_waypoint_value is Vector2:
		var stored_waypoint := Vector2(stored_waypoint_value)
		if enemy_pos.distance_to(stored_waypoint) > MELEE_WAYPOINT_REACHED_DISTANCE:
			if not _line_occluded(enemy_pos, stored_waypoint, body_radius):
				return _normalized_or(stored_waypoint - enemy_pos, desired_direction)
		else:
			enemy["avoidance_last_waypoint"] = stored_waypoint
		enemy.erase("avoidance_waypoint")
	var previous_waypoint_value: Variant = enemy.get("avoidance_last_waypoint", null)
	var best_waypoint := Vector2.ZERO
	var best_score := INF
	for candidate in candidates:
		if enemy_pos.distance_to(candidate) <= MELEE_WAYPOINT_REACHED_DISTANCE:
			continue
		if (
			previous_waypoint_value is Vector2
			and candidate.distance_to(Vector2(previous_waypoint_value)) <= MELEE_WAYPOINT_REACHED_DISTANCE
		):
			continue
		if _line_occluded(enemy_pos, candidate, body_radius):
			continue
		var candidate_side := -1 if candidate.y < obstacle_center_y else 1
		var stable_tie_break := 0.0001 if candidate_side != preferred_vertical_side else 0.0
		var score := enemy_pos.distance_to(candidate) + candidate.distance_to(player_pos) + stable_tie_break
		if score < best_score:
			best_score = score
			best_waypoint = candidate
	if not is_inf(best_score):
		enemy["avoidance_waypoint"] = best_waypoint
		return _normalized_or(best_waypoint - enemy_pos, desired_direction)

	# Degenerate imported fixtures can leave no visible corner. A stable
	# tangent still makes progress along the obstacle face and remains bounded
	# by the same body-motion resolver.
	var tangent := Vector2(-desired_direction.y, desired_direction.x)
	if preferred_vertical_side > 0:
		tangent = -tangent
	return _normalized_or(tangent, desired_direction)


func _stable_navigation_side(enemy_id: String) -> int:
	var checksum := 0
	for index in range(enemy_id.length()):
		checksum = (checksum * 31 + enemy_id.unicode_at(index)) & 0x7fffffff
	return -1 if checksum % 2 == 0 else 1


func _update_bat(enemy_index: int, delta: float) -> void:
	var enemy := enemies[enemy_index]
	var definition := MonsterCatalogScript.definition(StringName(enemy.get("monster_type", MonsterCatalogScript.TYPE_BAT)))
	var state := StringName(enemy.get("state", &"idle"))
	if state == &"aim":
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			_spawn_bat_spread(enemy, definition)
			enemy["state"] = &"fire"
			enemy["state_timer"] = FIXED_STEP
	elif state == &"fire":
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"cooldown"
			enemy["state_timer"] = float(definition.get("attack_interval", 1.5))
	elif state == &"cooldown":
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		_move_keep_distance(enemy, definition, delta)
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"aim"
			enemy["state_timer"] = float(definition.get("aim_seconds", 0.5))
			_prepare_bat_special_attack(enemy, definition)
	else:
		enemy["state"] = &"aim"
		enemy["state_timer"] = float(definition.get("aim_seconds", 0.5))
		_prepare_bat_special_attack(enemy, definition)
		_emit_event(&"ranged_aim_started", {"enemy_id": enemy.get("enemy_id", ""), "attack": &"spread"})
	enemies[enemy_index] = enemy


func _update_drone(enemy_index: int, delta: float) -> void:
	var enemy := enemies[enemy_index]
	var definition := MonsterCatalogScript.definition(MonsterCatalogScript.TYPE_DRONE)
	var state := StringName(enemy.get("state", &"idle"))
	if state == &"aim":
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			_spawn_drone_laser(enemy, definition)
			enemy["state"] = &"fire"
			enemy["state_timer"] = float(definition.get("laser_seconds", 1.2))
	elif state == &"fire":
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"move"
			enemy["dash_timer"] = float(definition.get("dash_seconds", 0.5))
			_emit_event(&"drone_dash_started", {"enemy_id": enemy.get("enemy_id", "")})
	elif state == &"move" and float(enemy.get("dash_timer", 0.0)) > EPSILON:
		enemy["dash_timer"] = float(enemy.get("dash_timer", 0.0)) - delta
		var dash_direction := -_direction_to_player(enemy)
		var enemy_pos := Vector2(enemy.get("pos", Vector2.ZERO))
		enemy["pos"] = _resolve_body_motion(
			enemy_pos,
			enemy_pos + dash_direction * float(definition.get("move_speed", 0.1)) * float(definition.get("dash_speed_multiplier", 2.0)) * delta,
			_enemy_body_radius(enemy)
		)
		if float(enemy["dash_timer"]) <= EPSILON:
			enemy["state"] = &"cooldown"
			enemy["state_timer"] = float(definition.get("attack_interval", 2.5))
	elif state == &"cooldown":
		enemy["state_timer"] = float(enemy.get("state_timer", 0.0)) - delta
		_move_keep_distance(enemy, definition, delta)
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"aim"
			enemy["state_timer"] = float(definition.get("aim_seconds", 0.5))
	else:
		enemy["state"] = &"aim"
		enemy["state_timer"] = float(definition.get("aim_seconds", 0.5))
		_emit_event(&"ranged_aim_started", {"enemy_id": enemy.get("enemy_id", ""), "attack": &"laser"})
	enemies[enemy_index] = enemy


func _move_keep_distance(enemy: Dictionary, definition: Dictionary, delta: float) -> void:
	var offset := Vector2(player.get("pos", Vector2.ZERO)) - Vector2(enemy.get("pos", Vector2.ZERO))
	var distance := offset.length()
	var ideal := float(definition.get("ideal_distance", 0.4))
	var direction := Vector2.ZERO
	if distance > ideal + 0.05:
		direction = _normalized_or(offset, Vector2.RIGHT)
	elif distance < ideal - 0.05:
		direction = -_normalized_or(offset, Vector2.RIGHT)
	else:
		direction = _normalized_or(offset, Vector2.RIGHT).orthogonal() * (1.0 if int(enemy.get("strafe_sign", 1)) >= 0 else -1.0)
	enemy["state"] = &"move" if StringName(enemy.get("state", &"idle")) != &"cooldown" else &"cooldown"
	var enemy_pos := Vector2(enemy.get("pos", Vector2.ZERO))
	enemy["pos"] = _resolve_body_motion(
		enemy_pos,
		enemy_pos + direction * float(definition.get("move_speed", 0.2)) * delta,
		_enemy_body_radius(enemy)
	)


func _spawn_bat_spread(enemy: Dictionary, definition: Dictionary) -> void:
	var origin := Vector2(enemy.get("pos", Vector2.ZERO))
	var base_direction := _normalized_or(Vector2(player.get("pos", Vector2.ZERO)) - origin, Vector2.LEFT)
	var returning := StringName(enemy.get("behavior_id", &"")) == &"return_projectile"
	if returning:
		base_direction = Vector2(enemy.get("facing", base_direction))
	var count := int(definition.get("spread_count", 3))
	var half_angle := deg_to_rad(float(definition.get("spread_half_angle_degrees", 25.0)))
	for spread_index in range(count):
		var ratio := 0.5 if count <= 1 else float(spread_index) / float(count - 1)
		var extra: Dictionary = {}
		if returning and spread_index == count / 2:
			var return_point := Vector2(enemy["projectile_return_point"])
			var return_distance := origin.distance_to(return_point)
			extra = {
				"return_origin": origin, "return_point": return_point,
				"return_distance": return_distance, "distance_remaining": return_distance,
				"inbound": false,
			}
		_spawn_projectile(String(enemy.get("enemy_id", "")), origin, base_direction.rotated(lerpf(-half_angle, half_angle, ratio)), int(enemy.get("damage", MonsterCatalogScript.base_damage(int(player.get("power", 1)), MonsterCatalogScript.TYPE_BAT))), extra)
	_emit_event(&"ranged_fired", {"enemy_id": enemy.get("enemy_id", ""), "projectile_count": count})


func _spawn_projectile(owner_id: String, origin: Vector2, direction: Vector2, damage: int, extra: Dictionary = {}) -> void:
	var projectile_id := "projectile_%04d" % next_projectile_index
	next_projectile_index += 1
	var projectile := {
		"projectile_id": projectile_id,
		"owner_id": owner_id,
		"pos": origin,
		"velocity": _normalized_or(direction, Vector2.LEFT) * PROJECTILE_SPEED,
		"radius": PROJECTILE_RADIUS,
		"visual_radius": PROJECTILE_RADIUS,
		"damage": maxi(1, damage),
		"state": &"active",
	}
	projectile.merge(extra, true)
	projectiles.append(projectile)


func _spawn_drone_laser(enemy: Dictionary, definition: Dictionary) -> void:
	var direction := _normalized_or(Vector2(player.get("pos", Vector2.ZERO)) - Vector2(enemy.get("pos", Vector2.ZERO)), Vector2.LEFT)
	var origin := Vector2(enemy.get("pos", Vector2.ZERO))
	var endpoint_contract := _laser_endpoint_contract(origin, direction, LASER_RADIUS)
	lasers.append({
		"owner_id": String(enemy.get("enemy_id", "")),
		"origin": origin,
		"direction": direction,
		"endpoint": endpoint_contract.get("endpoint", origin),
		"occluded": bool(endpoint_contract.get("occluded", false)),
		"remaining": float(definition.get("laser_seconds", 1.2)),
		"tick_timer": 0.0,
		"tick_seconds": float(definition.get("laser_tick_seconds", 0.3)),
		"turn_speed_degrees": float(definition.get("laser_turn_speed_degrees", definition.get("laser_turn_speed", 24.0))),
		"damage": int(enemy.get("damage", MonsterCatalogScript.base_damage(int(player.get("power", 1)), MonsterCatalogScript.TYPE_DRONE))),
		"radius": LASER_RADIUS,
		"visual_radius": LASER_RADIUS,
	})
	_emit_event(&"laser_started", {"enemy_id": enemy.get("enemy_id", "")})


func _update_projectiles(delta: float) -> void:
	var survivors: Array[Dictionary] = []
	for projectile in projectiles:
		var from := Vector2(projectile.get("pos", Vector2.ZERO))
		var velocity := Vector2(projectile.get("velocity", Vector2.ZERO))
		var to := from + velocity * delta
		var travel := velocity.length() * delta
		var completes_leg := false
		if projectile.has("return_distance"):
			var owner := _enemy_by_id(String(projectile.get("owner_id", "")))
			if owner.is_empty() or int(owner.get("hp", 0)) <= 0:
				continue
			var remaining := float(projectile.get("distance_remaining", 0.0))
			completes_leg = travel + EPSILON >= remaining
			travel = minf(travel, remaining)
			projectile["distance_remaining"] = maxf(0.0, remaining - travel)
			to = from + velocity.normalized() * travel
			if completes_leg:
				to = Vector2(projectile["return_origin"] if bool(projectile["inbound"]) else projectile["return_point"])
		var projectile_radius := float(projectile.get("radius", PROJECTILE_RADIUS))
		var player_hit_fraction := _segment_circle_hit_fraction(
			from,
			to,
			Vector2(player.get("pos", Vector2.ZERO)),
			projectile_radius + PLAYER_RADIUS
		)
		var obstacle_hit_fraction := _first_obstacle_hit_fraction(from, to, projectile_radius)
		if obstacle_hit_fraction <= 1.0 and obstacle_hit_fraction <= player_hit_fraction + GEOMETRY_EPSILON:
			_emit_event(&"projectile_blocked", {
				"projectile_id": projectile.get("projectile_id", ""),
				"owner_id": projectile.get("owner_id", ""),
				"direction": Vector2(projectile.get("velocity", Vector2.RIGHT)).normalized(),
				"position": from.lerp(to, obstacle_hit_fraction),
			})
			continue
		if player_hit_fraction <= 1.0:
			_damage_player(int(projectile.get("damage", 1)), String(projectile.get("owner_id", "")), &"projectile")
			if not step_error.is_empty():
				return
			_emit_event(&"projectile_hit", {
				"projectile_id": projectile.get("projectile_id", ""),
				"owner_id": projectile.get("owner_id", ""),
				"direction": Vector2(projectile.get("velocity", Vector2.RIGHT)).normalized(),
				"position": from.lerp(to, player_hit_fraction),
			})
			continue
		if to.x < -0.10 or to.x > 1.10 or to.y < -0.10 or to.y > 1.10:
			_emit_event(&"projectile_despawned", {"projectile_id": projectile.get("projectile_id", "")})
			continue
		projectile["pos"] = to
		if completes_leg:
			if bool(projectile.get("inbound", false)):
				_emit_event(&"projectile_despawned", {"projectile_id": projectile["projectile_id"]})
				continue
			projectile["inbound"] = true
			projectile["velocity"] = -velocity
			projectile["distance_remaining"] = float(projectile["return_distance"])
			_emit_event(&"projectile_returned", {"projectile_id": projectile["projectile_id"], "position": to})
		survivors.append(projectile)
	projectiles = survivors


func _update_lasers(delta: float) -> void:
	var survivors: Array[Dictionary] = []
	for laser in lasers:
		var owner := _enemy_by_id(String(laser.get("owner_id", "")))
		if owner.is_empty() or int(owner.get("hp", 0)) <= 0:
			continue
		laser["origin"] = Vector2(owner.get("pos", Vector2.ZERO))
		var desired := _normalized_or(Vector2(player.get("pos", Vector2.ZERO)) - Vector2(laser.get("origin", Vector2.ZERO)), Vector2.LEFT)
		var turn_speed_degrees := float(laser.get("turn_speed_degrees", laser.get("turn_speed", 24.0)))
		laser["direction"] = _rotate_direction_toward(
			Vector2(laser.get("direction", Vector2.LEFT)),
			desired,
			deg_to_rad(turn_speed_degrees) * delta
		)
		var origin := Vector2(laser.get("origin", Vector2.ZERO))
		var endpoint_contract := _laser_endpoint_contract(
			origin,
			Vector2(laser.get("direction", Vector2.LEFT)),
			float(laser.get("radius", LASER_RADIUS))
		)
		var endpoint := Vector2(endpoint_contract.get("endpoint", origin))
		laser["endpoint"] = endpoint
		laser["occluded"] = bool(endpoint_contract.get("occluded", false))
		laser["remaining"] = float(laser.get("remaining", 0.0)) - delta
		laser["tick_timer"] = float(laser.get("tick_timer", 0.0)) - delta
		if float(laser["tick_timer"]) <= EPSILON:
			laser["tick_timer"] += float(laser.get("tick_seconds", 0.3))
			if _distance_point_to_segment(Vector2(player.get("pos", Vector2.ZERO)), origin, endpoint) <= float(laser.get("radius", LASER_RADIUS)) + PLAYER_RADIUS:
				_damage_player(int(laser.get("damage", 1)), String(laser.get("owner_id", "")), &"laser")
				if not step_error.is_empty():
					return
			_emit_event(&"laser_tick", {
				"enemy_id": laser.get("owner_id", ""),
				"endpoint": endpoint,
				"occluded": bool(laser.get("occluded", false)),
			})
		if float(laser["remaining"]) > EPSILON:
			survivors.append(laser)
		else:
			_emit_event(&"laser_ended", {"enemy_id": laser.get("owner_id", "")})
	lasers = survivors


func _damage_enemy(enemy_index: int, damage: int, critical: bool = false) -> void:
	if enemy_index < 0 or enemy_index >= enemies.size():
		return
	var enemy := enemies[enemy_index]
	if int(enemy.get("hp", 0)) <= 0:
		return
	var applied := maxi(1, damage)
	var behavior := StringName(enemy.get("behavior_id", &""))
	if enemy.has("visual_lift"):
		enemy["visual_lift"] = 0.0
	if behavior == &"directional_guard" and StringName(enemy.get("state", &"")) != &"cooldown":
		var incoming := _normalized_or(Vector2(player.get("pos", Vector2.ZERO)) - Vector2(enemy["pos"]), Vector2.LEFT)
		if incoming.dot(Vector2(enemy.get("facing", Vector2.LEFT))) >= 0.5:
			var definition := MonsterCatalogScript.definition(StringName(enemy["monster_type"]))
			applied = maxi(1, int(round(float(applied) * float(definition.get("guard_multiplier", 0.25)))))
			_emit_event(&"guard_blocked", {"enemy_id": enemy["enemy_id"], "damage": applied})
	enemy["hp"] = maxi(0, int(enemy.get("hp", 0)) - applied)
	var hit := {"enemy_id": enemy.get("enemy_id", ""), "damage": applied, "hp": enemy["hp"]}
	if bool(player.get("z2_talents", {}).get("enabled", false)):
		hit["critical"] = critical
	_emit_event(&"enemy_damaged", hit)
	if int(enemy["hp"]) <= 0:
		enemy["state"] = &"dead"
		_cancel_enemy_hazards(String(enemy["enemy_id"]))
		enemies[enemy_index] = enemy
		_emit_event(&"enemy_defeated", {"enemy_id": enemy.get("enemy_id", ""), "monster_type": enemy.get("monster_type", &"")})
		if StringName(enemy.get("monster_type", &"")) == MonsterCatalogScript.TYPE_SLIME or behavior == &"aftershock":
			_spawn_slimelings(enemy)
	else:
		enemy["state"] = &"hurt"
		enemy["state_timer"] = ENEMY_HURT_SECONDS
		if behavior != &"attack_echo":
			_cancel_enemy_hazards(String(enemy["enemy_id"]))
		if behavior == &"hit_counter":
			_prime_hit_counter(enemy)
		elif behavior == &"socket_repair":
			_react_to_repair_damage(enemy)
		enemies[enemy_index] = enemy


func _damage_player(damage: int, source_id: String, damage_kind: StringName, pressure_delta: int = 0) -> bool:
	if defeated or float(player.get("invulnerability", 0.0)) > EPSILON:
		return false
	var applied := maxi(1, damage)
	var packet := {
		"damage": applied, "damage_kind": String(damage_kind), "source_id": source_id,
		"pressure_delta": maxi(0, pressure_delta), "combat_tick": tick_index,
		"hit_id": "combat:%s:tick:%d:hit:%d" % [encounter_id, tick_index, next_hit_index],
	}
	var hp_before := int(player.get("hp", 0))
	var resolved := {
		"ok": true, "hp": maxi(0, hp_before - applied),
		"max_hp": int(player.get("max_hp", 1)), "power": int(player.get("power", 1)),
		"shield": int(player.get("shield", 0)), "actual_hp_loss": mini(hp_before, applied),
		"absorbed": 0, "dead": hp_before <= applied,
	}
	if hit_resolver.is_valid():
		var returned: Variant = hit_resolver.call(packet.duplicate(true))
		if not returned is Dictionary or not bool(returned.get("ok", false)):
			step_error = returned.duplicate(true) if returned is Dictionary else {"reason": "invalid_combat_hit_result"}
			step_error["ok"] = false
			return false
		for field in ["hp", "max_hp", "power", "shield", "actual_hp_loss", "absorbed", "dead"]:
			if not returned.has(field):
				step_error = {"ok": false, "reason": "incomplete_combat_hit_result", "field": field}
				return false
		resolved = returned
	next_hit_index += 1
	# Install survival/shield feedback before considering death or later collisions.
	player["hp"] = int(resolved["hp"])
	player["max_hp"] = int(resolved["max_hp"])
	player["power"] = int(resolved["power"])
	player["shield"] = int(resolved["shield"])
	var dead := bool(resolved["dead"]) or int(player["hp"]) <= 0
	_clear_attack_buffer()
	if not active_player_attack.is_empty() and not bool(active_player_attack.get("resolved", false)):
		_emit_event(&"player_attack_interrupted", {
			"attack_id": active_player_attack.get("attack_id", ""),
			"phase": active_player_attack.get("phase", player.get("state", &"")),
			"source_id": source_id,
			"damage_kind": damage_kind,
		})
	active_player_attack.clear()
	player["invulnerability"] = maxf(0.0, float(resolved.get("invulnerability", PLAYER_INVULNERABILITY)))
	player["state"] = &"dead" if dead else &"hurt"
	player["state_timer"] = PLAYER_HURT_SECONDS
	var event := packet.duplicate(true)
	for field in ["hp", "max_hp", "power", "shield", "actual_hp_loss", "absorbed", "dead"]:
		event[field] = resolved[field]
	_emit_event(&"player_damaged", event)
	if dead:
		defeated = true
		active = false
		_clear_attack_buffer()
		active_player_attack.clear()
		_emit_event(&"player_defeated", {"source_id": source_id, "damage_kind": damage_kind, "hit_id": packet["hit_id"]})
	return true


func _spawn_enemy(
	monster_type: StringName,
	encounter_index: int,
	forced_id: String = "",
	forced_pos: Variant = null,
	enemy_profile: Dictionary = {}
) -> void:
	var definition := MonsterCatalogScript.definition(monster_type)
	if definition.is_empty():
		return
	var positions := [Vector2(0.70, 0.50), Vector2(0.68, 0.28), Vector2(0.70, 0.74), Vector2(0.56, 0.62)]
	var spawn_pos: Vector2 = positions[encounter_index % positions.size()]
	if forced_pos is Vector2:
		spawn_pos = forced_pos
	else:
		spawn_pos += Vector2(rng.range_float(-0.025, 0.025), rng.range_float(-0.025, 0.025))
	var enemy_id := forced_id if not forced_id.is_empty() else "enemy_%02d_%s" % [encounter_index + 1, String(monster_type)]
	var body_radius := float(definition.get("body_radius", 0.03))
	var max_hp := int(enemy_profile.get("max_hp", definition.get("max_hp", 1)))
	var spawned_enemy := {
		"enemy_id": enemy_id,
		"monster_type": monster_type,
		"visual_key": G41RuntimeVisualContract.visual_key_for(monster_type),
		"hp": max_hp,
		"max_hp": max_hp,
		"damage": int(enemy_profile.get(
			"damage",
			MonsterCatalogScript.base_damage(int(player.get("power", 1)), monster_type)
		)),
		"pos": _resolve_spawn_outside_obstacles(_clamp_position(spawn_pos), body_radius),
		"body_radius": body_radius,
		"attack_radius": float(definition.get("attack_radius", 0.0)),
		"warning_radius": float(definition.get("attack_radius", 0.0)),
		"state": &"arrival",
		"state_timer": MonsterCatalogScript.ENTRY_GRACE_SECONDS,
		"entry_grace_remaining": MonsterCatalogScript.ENTRY_GRACE_SECONDS,
		"attack_done": false,
		"strafe_sign": -1 if encounter_index % 2 == 0 else 1,
		"wander_timer": 0.0,
		"wander_direction": Vector2.RIGHT,
	}
	if enemy_profile.has("enemy_name"):
		spawned_enemy["enemy_name"] = String(enemy_profile.get("enemy_name", "异常体"))
	if enemy_profile.has("enemy_power"):
		spawned_enemy["enemy_power"] = int(enemy_profile.get("enemy_power", 0))
	if definition.has("source_id"):
		spawned_enemy["visual_key"] = definition["visual_key"]
		spawned_enemy["visual_subject"] = monster_type
		spawned_enemy["behavior_id"] = definition["behavior_id"]
		spawned_enemy["base_power"] = int(enemy_profile.get("base_power", enemy_profile.get("enemy_power", 12)))
		spawned_enemy["enemy_name"] = String(definition["display_name"])
		spawned_enemy["facing"] = Vector2.LEFT
	enemies.append(spawned_enemy)


func _spawn_slimelings(slime: Dictionary) -> void:
	var split_count := int(MonsterCatalogScript.definition(MonsterCatalogScript.TYPE_SLIME).get("split_count", 2))
	var origin := Vector2(slime.get("pos", Vector2.ZERO))
	for split_index in range(split_count):
		var offset := Vector2(-0.055 if split_index == 0 else 0.055, 0.04 if split_index == 0 else -0.04)
		var child_profile: Dictionary = {}
		if slime.has("enemy_power"):
			var child_power := int(floor(
				float(slime.get("enemy_power", 0))
				* float(MonsterCatalogScript.definition(MonsterCatalogScript.TYPE_SLIME).get("split_power_multiplier", 0.45))
			))
			child_profile = MonsterCatalogScript.runtime_profile(
				MonsterCatalogScript.TYPE_SLIMELING,
				child_power,
				"小史莱姆"
			)
		_spawn_enemy(
			MonsterCatalogScript.TYPE_SLIMELING,
			enemies.size(),
			"%s_split_%d" % [String(slime.get("enemy_id", "slime")), split_index + 1],
			_clamp_position(origin + offset),
			child_profile
		)
	_emit_event(&"slime_split", {"enemy_id": slime.get("enemy_id", ""), "spawn_count": split_count})


func _check_terminal_state() -> void:
	if defeated or cleared:
		return
	for enemy in enemies:
		if int(enemy.get("hp", 0)) > 0:
			return
	cleared = true
	active = false
	_clear_attack_buffer()
	active_player_attack.clear()
	projectiles.clear()
	lasers.clear()
	hazards.clear()
	_emit_event(&"combat_cleared", {"tick": tick_index})


func _prepare_bat_special_attack(enemy: Dictionary, definition: Dictionary) -> void:
	var behavior := StringName(enemy.get("behavior_id", &""))
	if behavior not in [&"return_projectile", &"conveyor"]:
		return
	var direction := _direction_to_player(enemy)
	enemy["facing"] = direction
	var warning_seconds := float(definition.get("aim_seconds", 0.50))
	if behavior == &"return_projectile":
		var origin := Vector2(enemy["pos"])
		var room_endpoint := _ray_endpoint_inside_unit_room(origin, direction, ROOM_MIN, ROOM_MAX)
		var return_point := origin.move_toward(room_endpoint, RETURN_PROJECTILE_MAX_DISTANCE)
		enemy["projectile_return_point"] = return_point
		_start_hazard(enemy, {
			"shape": &"circle", "origin": return_point,
			"radius": 0.025, "damage": 0,
			"warning_seconds": warning_seconds, "active_seconds": 0.55,
		})
	else:
		_start_hazard(enemy, _line_hazard(Vector2(enemy["pos"]), direction, 0.60, 0.055, {
			"damage": 0, "control": &"push", "control_speed": 0.22,
			"warning_seconds": warning_seconds, "active_seconds": 1.20,
		}))


func _update_z1_hazard_enemy(enemy_index: int, delta: float) -> void:
	var enemy := enemies[enemy_index]
	var definition := MonsterCatalogScript.definition(StringName(enemy["monster_type"]))
	var behavior := StringName(enemy["behavior_id"])
	var state := StringName(enemy.get("state", &"idle"))
	if state == &"warning" and int(enemy.get("action_started_tick", -1)) == tick_index:
		return
	if state in [&"idle", &"move"]:
		if behavior in [&"hit_counter", &"attack_echo"]:
			return
		var distance := Vector2(enemy["pos"]).distance_to(Vector2(player["pos"]))
		var approach_range := 0.19 if behavior == &"directional_guard" else 0.40
		if behavior in [&"directional_guard", &"magnetic_pull"] and distance > approach_range:
			var from := Vector2(enemy["pos"])
			enemy["pos"] = _resolve_body_motion(from, from + _obstacle_aware_melee_direction(enemy, _direction_to_player(enemy)) * float(definition.get("move_speed", 0.18)) * delta, _enemy_body_radius(enemy))
			enemy["state"] = &"move"
		else:
			_start_z1_action(enemy, definition)
	elif state == &"warning":
		enemy["state_timer"] = float(enemy["state_timer"]) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"active"
			enemy["state_timer"] = float(definition.get("active_seconds", 0.28))
			enemy["attack_done"] = false
	elif state == &"active":
		if behavior == &"rail_charge":
			_advance_rail_charge(enemy, definition, delta)
		elif behavior == &"marked_jump":
			var duration := float(definition.get("active_seconds", 0.25))
			var progress := clampf(1.0 - (float(enemy["state_timer"]) - delta) / duration, 0.0, 1.0)
			enemy["pos"] = Vector2(enemy["jump_origin"]).lerp(Vector2(enemy["jump_target"]), progress)
			enemy["visual_lift"] = sin(progress * PI) * 22.0
		if StringName(enemy["state"]) == &"active":
			enemy["state_timer"] = float(enemy["state_timer"]) - delta
			if float(enemy["state_timer"]) <= EPSILON:
				enemy["state"] = &"cooldown"
				enemy["state_timer"] = float(definition.get("cooldown_seconds", 0.55))
				enemy["visual_lift"] = 0.0
				if behavior == &"marked_jump":
					enemy["pos"] = enemy["jump_target"]
					_emit_event(&"jump_landed", {"enemy_id": enemy["enemy_id"], "position": enemy["pos"]})
	elif state == &"cooldown":
		enemy["state_timer"] = float(enemy["state_timer"]) - delta
		if float(enemy["state_timer"]) <= EPSILON:
			enemy["state"] = &"idle"
	enemies[enemy_index] = enemy


func _start_z1_action(enemy: Dictionary, definition: Dictionary, requested_direction: Vector2 = Vector2.ZERO) -> void:
	var behavior := StringName(enemy["behavior_id"])
	var origin := Vector2(enemy["pos"])
	var direction := _normalized_or(requested_direction, _direction_to_player(enemy))
	var warning_seconds := float(definition.get("warning_seconds", 0.50))
	var active_seconds := float(definition.get("active_seconds", 0.28))
	enemy["facing"] = direction
	enemy["state"] = &"warning"
	enemy["state_timer"] = warning_seconds
	enemy["action_started_tick"] = tick_index
	var common := {"warning_seconds": warning_seconds, "active_seconds": active_seconds, "direction": direction}
	match behavior:
		&"rail_charge":
			var length := float(definition.get("charge_speed", 0.90)) * active_seconds
			common["damage"] = 0
			_start_hazard(enemy, _line_hazard(origin, direction, length, _enemy_body_radius(enemy), common))
		&"directional_guard", &"hit_counter", &"attack_echo":
			common["shape"] = &"sector"
			common["origin"] = origin
			common["radius"] = 0.24 if behavior == &"hit_counter" else 0.21
			common["half_angle"] = PI / 3.0
			_start_hazard(enemy, common)
		&"delayed_archive":
			common["shape"] = &"rectangle"
			common["origin"] = player_position_history[maxi(0, player_position_history.size() - 25)]
			common["size"] = Vector2(0.20, 0.15)
			_start_hazard(enemy, common)
		&"four_way_laser":
			common["tick_seconds"] = 0.30
			for ray_direction: Vector2 in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
				_start_hazard(enemy, _line_hazard(origin, ray_direction, 1.4, LASER_RADIUS, common))
		&"magnetic_pull":
			common.merge({"shape": &"sector", "origin": origin, "radius": 0.42, "half_angle": PI / 3.0, "control": &"pull", "control_speed": 0.20, "tick_seconds": 0.30}, true)
			_start_hazard(enemy, common)
		&"pressure_pulse":
			common["pressure_delta"] = 4
			_start_hazard(enemy, _line_hazard(origin, direction, 0.70, 0.018, common))
		&"live_cable":
			var center := _clamp_position(origin + direction * 0.15)
			var tangent := direction.orthogonal()
			var first := _line_hazard(center, tangent, 0.35, LASER_RADIUS, {})
			var second := _line_hazard(center, -tangent, 0.35, LASER_RADIUS, {})
			common.merge({"shape": &"line", "origin": first["endpoint"], "endpoint": second["endpoint"], "half_width": LASER_RADIUS, "tick_seconds": 0.30}, true)
			_start_hazard(enemy, common)
		&"marked_jump":
			var target := _resolve_spawn_outside_obstacles(_clamp_position(Vector2(player["pos"])), _enemy_body_radius(enemy))
			enemy["jump_origin"] = origin
			enemy["jump_target"] = target
			common.merge({"shape": &"circle", "origin": target, "radius": 0.13, "warning_seconds": warning_seconds + active_seconds, "active_seconds": 0.18}, true)
			_start_hazard(enemy, common)


func _advance_rail_charge(enemy: Dictionary, definition: Dictionary, delta: float) -> void:
	var from := Vector2(enemy["pos"])
	var desired := from + Vector2(enemy["facing"]) * float(definition.get("charge_speed", 0.90)) * delta
	var resolved := _resolve_body_motion(from, desired, _enemy_body_radius(enemy))
	enemy["pos"] = resolved
	if not bool(enemy.get("attack_done", false)) and _distance_point_to_segment(Vector2(player["pos"]), from, resolved) <= _enemy_body_radius(enemy) + PLAYER_RADIUS:
		_damage_player(int(enemy["damage"]), String(enemy["enemy_id"]), &"charge")
		enemy["attack_done"] = true
	if resolved.distance_to(desired) > GEOMETRY_EPSILON:
		enemy["state"] = &"cooldown"
		enemy["state_timer"] = 1.0
		_cancel_enemy_hazards(String(enemy["enemy_id"]))
		_emit_event(&"charge_blocked", {"enemy_id": enemy["enemy_id"], "position": resolved})


func _line_hazard(origin: Vector2, direction: Vector2, length: float, half_width: float, values: Dictionary) -> Dictionary:
	var result := values.duplicate(true)
	var endpoint := _clamp_position(origin + direction.normalized() * length)
	var fraction := _first_obstacle_hit_fraction(origin, endpoint, half_width)
	if fraction <= 1.0:
		endpoint = origin.lerp(endpoint, maxf(0.0, fraction - GEOMETRY_EPSILON))
	result.merge({"shape": &"line", "origin": origin, "endpoint": endpoint, "direction": direction, "half_width": half_width}, true)
	return result


func _start_hazard(enemy: Dictionary, values: Dictionary) -> void:
	var hazard := {
		"hazard_id": "hazard_%04d" % next_hazard_index,
		"owner_id": String(enemy["enemy_id"]),
		"behavior_id": StringName(enemy.get("behavior_id", &"")),
		"direction": Vector2(enemy.get("facing", Vector2.LEFT)),
		"phase": &"warning",
		"warning_remaining": 0.50,
		"remaining": 0.28,
		"damage": int(enemy.get("damage", 1)),
		"pressure_delta": 0,
		"tick_seconds": 0.0,
		"tick_timer": 0.0,
		"hit": false,
		"created_tick": tick_index,
	}
	hazard.merge(values, true)
	hazard["warning_remaining"] = float(values.get("warning_seconds", 0.50))
	hazard["remaining"] = float(values.get("active_seconds", 0.28))
	next_hazard_index += 1
	hazards.append(hazard)
	_emit_event(&"z1_attack_started", {"enemy_id": enemy["enemy_id"], "behavior_id": hazard["behavior_id"], "hazard_id": hazard["hazard_id"], "direction": hazard["direction"]})


func _update_hazards(delta: float) -> void:
	var survivors: Array[Dictionary] = []
	for hazard in hazards:
		var owner := _enemy_by_id(String(hazard["owner_id"]))
		if owner.is_empty() or int(owner.get("hp", 0)) <= 0:
			continue
		if int(hazard["created_tick"]) == tick_index:
			survivors.append(hazard)
			continue
		if StringName(hazard["phase"]) == &"warning":
			hazard["warning_remaining"] = float(hazard["warning_remaining"]) - delta
			if float(hazard["warning_remaining"]) > EPSILON:
				survivors.append(hazard)
				continue
			hazard["phase"] = &"active"
			_emit_event(&"hazard_activated", {"hazard_id": hazard["hazard_id"], "owner_id": hazard["owner_id"], "behavior_id": hazard["behavior_id"]})
		var intersects := _hazard_hits_player(hazard)
		if intersects:
			_apply_hazard_control(hazard, delta)
		hazard["tick_timer"] = maxf(0.0, float(hazard["tick_timer"]) - delta)
		if intersects and int(hazard.get("damage", 0)) > 0 and not bool(hazard["hit"]) and float(hazard["tick_timer"]) <= EPSILON:
			var damaged := _damage_player(int(hazard["damage"]), String(hazard["owner_id"]), StringName(hazard["behavior_id"]), int(hazard.get("pressure_delta", 0)))
			if not step_error.is_empty():
				return
			hazard["hit"] = float(hazard["tick_seconds"]) <= 0.0
			hazard["tick_timer"] = float(hazard["tick_seconds"])
			if damaged:
				_emit_event(&"hazard_hit", {"hazard_id": hazard["hazard_id"], "behavior_id": hazard["behavior_id"]})
		hazard["remaining"] = float(hazard["remaining"]) - delta
		if float(hazard["remaining"]) > EPSILON:
			survivors.append(hazard)
		else:
			_emit_event(&"hazard_ended", {"hazard_id": hazard["hazard_id"], "behavior_id": hazard["behavior_id"]})
	hazards = survivors


func _hazard_hits_player(hazard: Dictionary) -> bool:
	var point := Vector2(player["pos"])
	var origin := Vector2(hazard.get("origin", Vector2.ZERO))
	if _line_occluded(origin, point):
		return false
	match StringName(hazard.get("shape", &"circle")):
		&"line":
			return _distance_point_to_segment(point, origin, Vector2(hazard["endpoint"])) <= float(hazard.get("half_width", 0.01)) + PLAYER_RADIUS
		&"rectangle":
			var half_size := Vector2(hazard.get("size", Vector2(0.2, 0.15))) * 0.5
			var closest := point.clamp(origin - half_size, origin + half_size)
			return point.distance_to(closest) <= PLAYER_RADIUS
		&"sector":
			return _circle_intersects_attack_sector(origin, Vector2(hazard["direction"]), float(hazard.get("radius", 0.21)), cos(float(hazard.get("half_angle", PI / 3.0))), point, PLAYER_RADIUS)
		&"ring":
			var distance := point.distance_to(origin)
			return distance <= float(hazard.get("radius", 0.31)) + PLAYER_RADIUS and distance + PLAYER_RADIUS >= float(hazard.get("inner_radius", 0.20))
	return point.distance_to(origin) <= float(hazard.get("radius", 0.13)) + PLAYER_RADIUS


func _apply_hazard_control(hazard: Dictionary, delta: float) -> void:
	var control := StringName(hazard.get("control", &""))
	if control == &"":
		return
	var from := Vector2(player["pos"])
	var direction := Vector2(hazard.get("direction", Vector2.ZERO))
	if control == &"pull":
		direction = _normalized_or(Vector2(hazard["origin"]) - from, Vector2.ZERO)
	var distance := float(hazard.get("control_speed", 0.20)) * delta
	player["pos"] = _resolve_body_motion(from, from + direction * distance, PLAYER_RADIUS)


func _cancel_enemy_hazards(enemy_id: String) -> void:
	var survivors: Array[Dictionary] = []
	for hazard in hazards:
		if String(hazard.get("owner_id", "")) != enemy_id:
			survivors.append(hazard)
	hazards = survivors


func _prime_hit_counter(enemy: Dictionary) -> void:
	if int(enemy.get("counter_window_until", -1)) > tick_index:
		enemy["counter_window_until"] = -1
		_start_z1_action(enemy, MonsterCatalogScript.definition(StringName(enemy["monster_type"])))
		_emit_event(&"counter_primed", {"enemy_id": enemy["enemy_id"]})
	else:
		var definition := MonsterCatalogScript.definition(StringName(enemy["monster_type"]))
		enemy["counter_window_until"] = tick_index + int(ceil(float(definition.get("counter_window_seconds", 1.20)) / FIXED_STEP))


func _react_to_player_attack(attack: Dictionary) -> void:
	for enemy in enemies:
		if int(enemy.get("hp", 0)) <= 0 or StringName(enemy.get("behavior_id", &"")) != &"attack_echo":
			continue
		if StringName(enemy.get("state", &"idle")) not in [&"idle", &"move", &"cooldown"]:
			continue
		var attack_id := String(attack.get("attack_id", ""))
		if String(enemy.get("copied_attack_id", "")) == attack_id:
			continue
		enemy["copied_attack_id"] = attack_id
		_start_z1_action(enemy, MonsterCatalogScript.definition(StringName(enemy["monster_type"])), Vector2(attack["facing"]))


func _react_to_repair_damage(enemy: Dictionary) -> void:
	if StringName(enemy.get("repair_mode", &"")) != &"":
		enemy["repair_mode"] = &""
		_emit_event(&"repair_interrupted", {"enemy_id": enemy["enemy_id"]})
		return
	if bool(enemy.get("repair_attempted", false)) or int(enemy["hp"]) * 2 >= int(enemy["max_hp"]):
		return
	enemy["repair_attempted"] = true
	enemy["repair_mode"] = &"seeking"
	enemy["repair_remaining"] = 4.0
	enemy["repair_target"] = _nearest_repair_socket(Vector2(enemy["pos"]), _enemy_body_radius(enemy))
	enemy["state"] = &"move"
	_emit_event(&"repair_started", {"enemy_id": enemy["enemy_id"], "target": enemy["repair_target"]})


func _nearest_repair_socket(origin: Vector2, body_radius: float) -> Vector2:
	var result := Vector2(ROOM_MAX, 0.50)
	var best_distance := INF
	for candidate: Vector2 in [Vector2(ROOM_MIN, 0.50), Vector2(ROOM_MAX, 0.50), Vector2(0.50, ROOM_MIN), Vector2(0.50, ROOM_MAX)]:
		var available := _resolve_spawn_outside_obstacles(candidate, body_radius)
		var distance := origin.distance_squared_to(available)
		if distance < best_distance:
			best_distance = distance
			result = available
	return result


func _update_repair_enemy(enemy_index: int, delta: float) -> void:
	var enemy := enemies[enemy_index]
	var mode := StringName(enemy.get("repair_mode", &""))
	if mode == &"":
		_update_drone(enemy_index, delta)
		return
	var target := Vector2(enemy["repair_target"])
	enemy["repair_remaining"] = float(enemy["repair_remaining"]) - delta
	if float(enemy["repair_remaining"]) <= EPSILON:
		enemy["repair_mode"] = &""
		enemy["state"] = &"cooldown"
		enemy["state_timer"] = 2.50
		_emit_event(&"repair_interrupted", {"enemy_id": enemy["enemy_id"], "reason": &"socket_blocked"})
	elif mode == &"seeking":
		var from := Vector2(enemy["pos"])
		var direction := _normalized_or(target - from, Vector2.ZERO)
		enemy["pos"] = _resolve_body_motion(from, from.move_toward(target, 0.26 * delta), _enemy_body_radius(enemy))
		enemy["facing"] = direction
		if Vector2(enemy["pos"]).distance_to(target) < 0.035 and Vector2(player["pos"]).distance_to(target) > 0.09:
			enemy["repair_mode"] = &"charging"
			enemy["state"] = &"warning"
			enemy["state_timer"] = 1.0
	else:
		if Vector2(player["pos"]).distance_to(target) <= 0.09:
			enemy["repair_mode"] = &""
			enemy["state"] = &"cooldown"
			enemy["state_timer"] = 2.50
			_emit_event(&"repair_interrupted", {"enemy_id": enemy["enemy_id"], "reason": &"socket_blocked"})
		else:
			enemy["state_timer"] = float(enemy["state_timer"]) - delta
			if float(enemy["state_timer"]) <= EPSILON:
				var healing := maxi(1, int(floor(float(enemy["max_hp"]) * 0.25)))
				enemy["hp"] = mini(int(enemy["max_hp"]), int(enemy["hp"]) + healing)
				enemy["repair_mode"] = &""
				enemy["state"] = &"cooldown"
				enemy["state_timer"] = 2.50
				_emit_event(&"monster_healed", {"enemy_id": enemy["enemy_id"], "amount": healing, "hp": enemy["hp"]})
	enemies[enemy_index] = enemy


func _direction_to_player(enemy: Dictionary) -> Vector2:
	return _normalized_or(Vector2(player.get("pos", Vector2.ZERO)) - Vector2(enemy.get("pos", Vector2.ZERO)), Vector2.LEFT)


func _enemy_by_id(enemy_id: String) -> Dictionary:
	for enemy in enemies:
		if String(enemy.get("enemy_id", "")) == enemy_id:
			return enemy
	return {}


func _create_player_attack_contract(requested_facing: Vector2 = Vector2.ZERO, use_skill: bool = false) -> Dictionary:
	var attack_id := "player_attack_%04d" % next_player_attack_index
	next_player_attack_index += 1
	var facing := _normalized_or(
		requested_facing,
		_normalized_or(Vector2(player.get("facing", aim_input)), Vector2.RIGHT)
	)
	var contract := {
		"attack_id": attack_id,
		"origin": Vector2(player.get("pos", Vector2.ZERO)),
		"facing": facing,
		"range": PLAYER_ATTACK_RANGE,
		"cone_dot": PLAYER_ATTACK_CONE_DOT,
		"half_angle_radians": acos(clampf(PLAYER_ATTACK_CONE_DOT, -1.0, 1.0)),
		"started_tick": tick_index,
		"impact_seconds": _attack_seconds(PLAYER_ATTACK_IMPACT_SECONDS),
		"resolved": false,
		"shape": &"sector",
		"target_radius_policy": &"circle_sector_intersection",
	}
	var weapon := StringName(player.get("field_weapon", FieldWeapons.AXE))
	if FieldWeapons.PROFILES.has(weapon):
		contract.merge(FieldWeapons.ray_contract(weapon, use_skill), true)
	return contract


func _build_player_attack_geometry_snapshot() -> Dictionary:
	if active_player_attack.is_empty():
		return {}
	var geometry := active_player_attack.duplicate(true)
	var phase := StringName(player.get("state", &"idle"))
	geometry["phase"] = phase
	geometry["visible"] = phase in [&"attack_windup", &"attack_active"]
	geometry["authoritative"] = true
	geometry["occlusion_contract"] = ARENA_CONTRACT_ID
	geometry["visual_contract"] = &"occlusion_clipped_sector_v1"
	var visibility := _build_attack_visibility_contract(
		Vector2(geometry.get("origin", Vector2.ZERO)),
		Vector2(geometry.get("facing", Vector2.RIGHT)),
		float(geometry.get("range", PLAYER_ATTACK_RANGE)),
		float(geometry.get("half_angle_radians", acos(PLAYER_ATTACK_CONE_DOT)))
	)
	geometry["visible_arc_points"] = visibility.get("visible_arc_points", [])
	geometry["occlusion_samples"] = visibility.get("occlusion_samples", [])
	geometry["occluded_sample_count"] = int(visibility.get("occluded_sample_count", 0))
	geometry["occluded"] = int(geometry["occluded_sample_count"]) > 0
	return geometry


func _build_attack_visibility_contract(
	origin: Vector2,
	facing: Vector2,
	attack_range: float,
	half_angle_radians: float
) -> Dictionary:
	var normalized_facing := _normalized_or(facing, Vector2.RIGHT)
	var safe_range := maxf(0.0, attack_range)
	var safe_half_angle := maxf(0.0, half_angle_radians)
	var facing_angle := normalized_facing.angle()
	var arc_points: Array[Vector2] = []
	var samples: Array[Dictionary] = []
	var occluded_count := 0
	for index in range(ATTACK_VISIBILITY_SEGMENTS + 1):
		var ratio := float(index) / float(ATTACK_VISIBILITY_SEGMENTS)
		var direction := Vector2.from_angle(
			facing_angle + lerpf(-safe_half_angle, safe_half_angle, ratio)
		)
		var full_endpoint := origin + direction * safe_range
		var hit_fraction := _first_obstacle_hit_fraction(origin, full_endpoint, 0.0)
		var occluded := hit_fraction <= 1.0
		var visible_fraction := clampf(hit_fraction, 0.0, 1.0) if occluded else 1.0
		var endpoint := origin.lerp(full_endpoint, visible_fraction)
		arc_points.append(endpoint)
		samples.append({
			"direction": direction,
			"full_endpoint": full_endpoint,
			"endpoint": endpoint,
			"hit_fraction": visible_fraction,
			"occluded": occluded,
		})
		if occluded:
			occluded_count += 1
	return {
		"visible_arc_points": arc_points,
		"occlusion_samples": samples,
		"occluded_sample_count": occluded_count,
	}


func _canonical_player_attack() -> Dictionary:
	if active_player_attack.is_empty():
		return {}
	return {
		"attack_id": String(active_player_attack.get("attack_id", "")),
		"origin": _canonical_vector(Vector2(active_player_attack.get("origin", Vector2.ZERO))),
		"facing": _canonical_vector(Vector2(active_player_attack.get("facing", Vector2.RIGHT))),
		"started_tick": int(active_player_attack.get("started_tick", 0)),
		"active_started_tick": int(active_player_attack.get("active_started_tick", 0)),
		"resolved": bool(active_player_attack.get("resolved", false)),
		"resolved_tick": int(active_player_attack.get("resolved_tick", 0)),
		"phase": String(player.get("state", &"idle")),
	}


func _clear_attack_buffer() -> void:
	attack_queued = false
	attack_buffer_remaining = 0.0
	attack_buffer_facing = Vector2.ZERO
	player.erase("queued_field_skill")


func _enemy_body_radius(enemy: Dictionary) -> float:
	var definition := MonsterCatalogScript.definition(StringName(enemy.get("monster_type", &"slime")))
	return maxf(0.0, float(enemy.get("body_radius", definition.get("body_radius", 0.03))))


func _enemy_melee_hit_radius(enemy: Dictionary, definition: Dictionary) -> float:
	return maxf(0.0, float(enemy.get("attack_radius", definition.get("attack_radius", 0.0))))


func _circle_intersects_attack_sector(
	origin: Vector2,
	facing: Vector2,
	attack_range: float,
	cone_dot: float,
	target_center: Vector2,
	target_radius: float
) -> bool:
	var safe_radius := maxf(0.0, target_radius)
	var safe_range := maxf(0.0, attack_range)
	var offset := target_center - origin
	var distance := offset.length()
	if distance <= safe_radius + GEOMETRY_EPSILON:
		return true
	if distance - safe_radius > safe_range + GEOMETRY_EPSILON:
		return false
	var normalized_facing := _normalized_or(facing, Vector2.RIGHT)
	var center_dot := clampf(normalized_facing.dot(offset / distance), -1.0, 1.0)
	var center_angle := acos(center_dot)
	var half_angle := acos(clampf(cone_dot, -1.0, 1.0))
	if distance <= safe_range + GEOMETRY_EPSILON and center_angle <= half_angle + GEOMETRY_EPSILON:
		return true
	if safe_range <= 0.0:
		return false
	var closest_distance_squared := INF
	for angle_sign in [-1.0, 1.0]:
		var edge_vector := normalized_facing.rotated(half_angle * angle_sign) * safe_range
		var edge_fraction := clampf(offset.dot(edge_vector) / (safe_range * safe_range), 0.0, 1.0)
		closest_distance_squared = minf(
			closest_distance_squared,
			offset.distance_squared_to(edge_vector * edge_fraction)
		)
	if center_angle <= half_angle + GEOMETRY_EPSILON:
		closest_distance_squared = minf(
			closest_distance_squared,
			(distance - safe_range) * (distance - safe_range)
		)
	var intersection_radius := safe_radius + GEOMETRY_EPSILON
	return closest_distance_squared <= intersection_radius * intersection_radius


func _rotate_direction_toward(current: Vector2, desired: Vector2, max_radians: float) -> Vector2:
	var current_direction := _normalized_or(current, desired)
	var desired_direction := _normalized_or(desired, current_direction)
	var angular_step := clampf(
		current_direction.angle_to(desired_direction),
		-maxf(0.0, max_radians),
		maxf(0.0, max_radians)
	)
	return current_direction.rotated(angular_step).normalized()


func _emit_event(event_type: StringName, payload: Dictionary = {}) -> void:
	event_index += 1
	var event := payload.duplicate(true)
	event["event_type"] = event_type
	event["event_index"] = event_index
	event["tick"] = tick_index
	pending_events.append(event)


func _clamp_position(value: Vector2) -> Vector2:
	return Vector2(clampf(value.x, ROOM_MIN, ROOM_MAX), clampf(value.y, ROOM_MIN, ROOM_MAX))


func _resolve_body_motion(from: Vector2, to: Vector2, radius: float) -> Vector2:
	var current := _resolve_spawn_outside_obstacles(_clamp_position(from), radius)
	var target := _clamp_position(to)
	current.x = _resolve_axis_coordinate(current, target.x, true, radius)
	current.y = _resolve_axis_coordinate(current, target.y, false, radius)
	return _clamp_position(current)


func _resolve_axis_coordinate(origin: Vector2, target_coordinate: float, horizontal: bool, radius: float) -> float:
	var origin_coordinate := origin.x if horizontal else origin.y
	var orthogonal_coordinate := origin.y if horizontal else origin.x
	var resolved := target_coordinate
	var motion := resolved - origin_coordinate
	if absf(motion) <= EPSILON:
		return resolved
	for obstacle in arena_obstacles:
		var expanded := _expanded_obstacle(obstacle, radius)
		var orthogonal_min := expanded.position.y if horizontal else expanded.position.x
		var orthogonal_max := expanded.end.y if horizontal else expanded.end.x
		if orthogonal_coordinate < orthogonal_min - GEOMETRY_EPSILON or orthogonal_coordinate > orthogonal_max + GEOMETRY_EPSILON:
			continue
		var near_edge := expanded.position.x if horizontal else expanded.position.y
		var far_edge := expanded.end.x if horizontal else expanded.end.y
		if motion > 0.0 and origin_coordinate <= near_edge + GEOMETRY_EPSILON and resolved >= near_edge:
			resolved = minf(resolved, near_edge - GEOMETRY_EPSILON)
		elif motion < 0.0 and origin_coordinate >= far_edge - GEOMETRY_EPSILON and resolved <= far_edge:
			resolved = maxf(resolved, far_edge + GEOMETRY_EPSILON)
	return clampf(resolved, ROOM_MIN, ROOM_MAX)


func _resolve_spawn_outside_obstacles(candidate: Vector2, radius: float) -> Vector2:
	var resolved := candidate
	# Obstacles do not overlap in the production contract. A small bounded loop
	# still makes imported fixtures deterministic if one rectangle touches
	# another after radius expansion.
	for _pass in range(maxi(1, arena_obstacles.size() + 1)):
		var displaced := false
		for obstacle in arena_obstacles:
			var expanded := _expanded_obstacle(obstacle, radius)
			if not _point_inside_rect_inclusive(resolved, expanded):
				continue
			var distance_left := absf(resolved.x - expanded.position.x)
			var distance_right := absf(expanded.end.x - resolved.x)
			var distance_top := absf(resolved.y - expanded.position.y)
			var distance_bottom := absf(expanded.end.y - resolved.y)
			var nearest := minf(minf(distance_left, distance_right), minf(distance_top, distance_bottom))
			if is_equal_approx(nearest, distance_left):
				resolved.x = expanded.position.x - GEOMETRY_EPSILON
			elif is_equal_approx(nearest, distance_right):
				resolved.x = expanded.end.x + GEOMETRY_EPSILON
			elif is_equal_approx(nearest, distance_top):
				resolved.y = expanded.position.y - GEOMETRY_EPSILON
			else:
				resolved.y = expanded.end.y + GEOMETRY_EPSILON
			resolved = _clamp_position(resolved)
			displaced = true
		if not displaced:
			break
	return resolved


func _position_hits_obstacle(position: Vector2, radius: float) -> bool:
	for obstacle in arena_obstacles:
		if _point_inside_rect_inclusive(position, _expanded_obstacle(obstacle, radius)):
			return true
	return false


func _expanded_obstacle(obstacle: Rect2, radius: float) -> Rect2:
	var clearance := maxf(0.0, radius)
	return Rect2(
		obstacle.position - Vector2(clearance, clearance),
		obstacle.size + Vector2(clearance, clearance) * 2.0
	)


static func _point_inside_rect_inclusive(point: Vector2, rect: Rect2) -> bool:
	return (
		point.x >= rect.position.x - GEOMETRY_EPSILON
		and point.x <= rect.end.x + GEOMETRY_EPSILON
		and point.y >= rect.position.y - GEOMETRY_EPSILON
		and point.y <= rect.end.y + GEOMETRY_EPSILON
	)


func _line_occluded(start: Vector2, finish: Vector2, clearance: float = 0.0) -> bool:
	return _first_obstacle_hit_fraction(start, finish, clearance) <= 1.0


func _first_obstacle_hit_fraction(start: Vector2, finish: Vector2, radius: float) -> float:
	var first_fraction := INF
	for obstacle in arena_obstacles:
		first_fraction = minf(
			first_fraction,
			_segment_rect_hit_fraction(start, finish, _expanded_obstacle(obstacle, radius))
		)
	return first_fraction


static func first_rect_hit_fraction(start: Vector2, finish: Vector2, obstacles: Array) -> float:
	var factor := INF
	for obstacle: Rect2 in obstacles:
		factor = minf(factor, _segment_rect_hit_fraction(start, finish, obstacle))
	return factor


static func _segment_rect_hit_fraction(start: Vector2, finish: Vector2, rect: Rect2) -> float:
	if _point_inside_rect_inclusive(start, rect):
		return 0.0
	var delta := finish - start
	var entry := 0.0
	var exit := 1.0
	if absf(delta.x) <= EPSILON:
		if start.x < rect.position.x or start.x > rect.end.x:
			return INF
	else:
		var inverse_x := 1.0 / delta.x
		var x_entry := (rect.position.x - start.x) * inverse_x
		var x_exit := (rect.end.x - start.x) * inverse_x
		if x_entry > x_exit:
			var swap_x := x_entry
			x_entry = x_exit
			x_exit = swap_x
		entry = maxf(entry, x_entry)
		exit = minf(exit, x_exit)
		if entry > exit + GEOMETRY_EPSILON:
			return INF
	if absf(delta.y) <= EPSILON:
		if start.y < rect.position.y or start.y > rect.end.y:
			return INF
	else:
		var inverse_y := 1.0 / delta.y
		var y_entry := (rect.position.y - start.y) * inverse_y
		var y_exit := (rect.end.y - start.y) * inverse_y
		if y_entry > y_exit:
			var swap_y := y_entry
			y_entry = y_exit
			y_exit = swap_y
		entry = maxf(entry, y_entry)
		exit = minf(exit, y_exit)
		if entry > exit + GEOMETRY_EPSILON:
			return INF
	if exit < -GEOMETRY_EPSILON or entry > 1.0 + GEOMETRY_EPSILON:
		return INF
	return clampf(entry, 0.0, 1.0)


func _segment_circle_hit_fraction(start: Vector2, finish: Vector2, center: Vector2, radius: float) -> float:
	var segment := finish - start
	var offset := start - center
	var safe_radius := maxf(0.0, radius)
	var c := offset.dot(offset) - safe_radius * safe_radius
	if c <= GEOMETRY_EPSILON:
		return 0.0
	var a := segment.dot(segment)
	if a <= EPSILON:
		return INF
	var b := 2.0 * offset.dot(segment)
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return INF
	var fraction := (-b - sqrt(discriminant)) / (2.0 * a)
	if fraction < -GEOMETRY_EPSILON or fraction > 1.0 + GEOMETRY_EPSILON:
		return INF
	return clampf(fraction, 0.0, 1.0)


func _laser_endpoint_contract(origin: Vector2, direction: Vector2, radius: float) -> Dictionary:
	var normalized_direction := _normalized_or(direction, Vector2.LEFT)
	var room_endpoint := _ray_endpoint_inside_unit_room(origin, normalized_direction)
	var obstacle_fraction := _first_obstacle_hit_fraction(origin, room_endpoint, radius)
	if obstacle_fraction <= 1.0:
		return {
			"endpoint": origin.lerp(room_endpoint, obstacle_fraction),
			"occluded": true,
		}
	return {
		"endpoint": room_endpoint,
		"occluded": false,
	}


func _ray_endpoint_inside_unit_room(origin: Vector2, direction: Vector2, room_min: float = 0.0, room_max: float = 1.0) -> Vector2:
	var normalized_direction := _normalized_or(direction, Vector2.LEFT)
	var closest_distance := INF
	if normalized_direction.x > EPSILON:
		closest_distance = minf(closest_distance, (room_max - origin.x) / normalized_direction.x)
	elif normalized_direction.x < -EPSILON:
		closest_distance = minf(closest_distance, (room_min - origin.x) / normalized_direction.x)
	if normalized_direction.y > EPSILON:
		closest_distance = minf(closest_distance, (room_max - origin.y) / normalized_direction.y)
	elif normalized_direction.y < -EPSILON:
		closest_distance = minf(closest_distance, (room_min - origin.y) / normalized_direction.y)
	if is_inf(closest_distance):
		return origin
	return origin + normalized_direction * maxf(0.0, closest_distance)


func _normalized_or(value: Vector2, fallback: Vector2) -> Vector2:
	if value.length_squared() <= EPSILON:
		return fallback.normalized()
	return value.normalized()


func _distance_point_to_segment(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= EPSILON:
		return point.distance_to(start)
	var ratio := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * ratio)


func _canonical_vector(value: Vector2) -> Array[float]:
	return [snappedf(value.x, 0.000001), snappedf(value.y, 0.000001)]


func _canonical_rects(rects: Array[Rect2]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for rect in rects:
		result.append({
			"position": _canonical_vector(rect.position),
			"size": _canonical_vector(rect.size),
		})
	return result
