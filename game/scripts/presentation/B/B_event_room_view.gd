extends Node2D
## Actual GLB-backed presentation, sharing A2's normalized movement coordinates.
## The renderer consumes public snapshots only and never settles event rewards.
const Layout = preload("res://scripts/gameplay/runtime/g41_runtime_layout.gd")
const VoxelArt = preload("res://scripts/presentation/voxel_dungeon/voxel_room_art.gd")
const X_SPAN := 19.3
const Y_SPAN := 14.77
const ELEVATION := 55.0
const FRAME := Rect2(-0.08, -0.28, 1.16, 1.40)
const WALL_LIGHT_LAYER := 4
const DOOR_LAMP_ENERGY := 2.65
const DOOR_LIGHT_POSITIONS := {
	"north": [Vector3(-2.12, 1.5, -4.89), Vector3(2.12, 1.5, -4.89)],
	"east": [Vector3(7.00, 1.4, -1.85), Vector3(7.00, 1.4, 1.85)],
	"south": [Vector3(-2.12, 1.4, 5.20), Vector3(2.12, 1.4, 5.20)],
	"west": [Vector3(-7.00, 1.4, -1.85), Vector3(-7.00, 1.4, 1.85)],
}
const IMPACT_SECONDS := 0.24
const CHEST_OPEN_SECONDS := 0.28
var entry: Dictionary = {}
var viewport: SubViewport
var front_viewport: SubViewport
var room_world: Node3D
var camera: Camera3D
var front_camera: Camera3D
var back_sprite: Sprite2D
var front_sprite: Sprite2D
var model: Node3D
var gates: Dictionary = {}
var gate_targets: Dictionary = {}
var candle_lights: Array[OmniLight3D] = []
var assemblies: Dictionary = {}
var status_lamp: MeshInstance3D
var _ready_model := false
var _last_depth := -1
var _geometry_key := ""
var _generated_meshes: Dictionary = {}
var _prop_impacts: Dictionary = {}
var _lid_state := -1 # First snapshot for this room has no preceding transition.
var _lid_progress := 0.0

func configure(next_entry: Dictionary) -> void:
	var next_key := String(next_entry.get("geometry_key", next_entry.get("model_path", "")))
	next_key += "/" + str(next_entry.get("growth_key", ""))
	if not (next_entry.get("breakables", []) as Array).is_empty():
		next_key += "/with_furniture"
	if _geometry_key == next_key and _ready_model:
		show()
		set_process(true)
		return
	_clear()
	entry = next_entry.duplicate(true)
	_geometry_key = next_key
	if entry.is_empty():
		hide()
		return
	_build()

func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	assemblies.clear()
	gates.clear()
	gate_targets.clear()
	candle_lights.clear()
	_prop_impacts.clear()
	_lid_state = -1
	_lid_progress = 0.0
	status_lamp = null
	_ready_model = false
	_last_depth = -1
	set_process(false)

func deactivate() -> void:
	_clear()
	entry.clear()
	hide()

func _build() -> void:
	viewport = SubViewport.new()
	viewport.name = "ModelViewport"
	viewport.transparent_bg = true
	viewport.world_3d = World3D.new()
	viewport.size = Vector2i(1080, 820)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(viewport)
	room_world = Node3D.new()
	viewport.add_child(room_world)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_CLEAR_COLOR
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("#8398a3")
	settings.ambient_light_energy = 0.33 if entry.get("polished", false) else 0.25
	settings.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = settings
	room_world.add_child(environment)
	if entry.get("generated", false):
		model = _build_generated()
	else:
		room_world.add_child(VoxelArt.new().build_event_shell(Layout.ROOM_WALL_RECTS, str(entry.get("growth_key", _geometry_key))))
		model = (load(String(entry.model_path)) as PackedScene).instantiate() as Node3D
		_place_authored_furniture()
	room_world.add_child(model)
	if String(entry.get("code", "")) == "B26":
		_replace_offering_altar()
	var props: Array = entry.get("breakables", [])
	if not props.is_empty():
		room_world.add_child(VoxelArt.new().build_breakables(props))
	_ready_model = model != null
	_index_meshes(room_world)
	for prop: Dictionary in props:
		entry.units.append({"id": prop.id, "ground_y": Rect2(prop.rect).end.y})
		_set_assembly_visible(String(prop.id) + "_debris", false)
		_set_assembly_visible(String(prop.id) + "_burst", false)
	camera = _camera(viewport, 1)
	front_viewport = SubViewport.new()
	front_viewport.name = "ForegroundViewport"
	front_viewport.size = viewport.size
	front_viewport.transparent_bg = true
	front_viewport.world_3d = viewport.world_3d
	front_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(front_viewport)
	front_camera = _camera(front_viewport, 2)
	back_sprite = _sprite(viewport, -100)
	front_sprite = _sprite(front_viewport, 650)
	var occlusion := ShaderMaterial.new()
	occlusion.shader = preload("res://scripts/presentation/B/B_foreground_color.gdshader")
	occlusion.set_shader_parameter("lit_room", viewport.get_texture())
	front_sprite.material = occlusion
	_build_lights()
	_build_gates()
	status_lamp = _box(room_world, Vector3.ZERO, Vector3(0.12, 0.12, 0.12), Color("86b7a2"))
	var anchor: Vector2 = entry.interaction_pos
	status_lamp.position = local_to_model(anchor) + Vector3(0.0, 0.30, 0.0)
	status_lamp.visible = false
	set_meta("B_code", entry.code)
	set_meta("B_model_path", entry.get("model_path", ""))
	set_process(true)
	show()


func _place_authored_furniture() -> void:
	for unit: Dictionary in entry.units:
		if not unit.has("source_unit"):
			continue
		var source_tag := "__%s_" % unit.source_unit
		for source: MeshInstance3D in model.find_children("*" + source_tag + "*", "MeshInstance3D", true, false):
			var copy := source.duplicate() as MeshInstance3D
			copy.name = String(source.name).replace(source_tag, "__%s_" % unit.id)
			copy.set_meta("B_assembly", unit.id)
			source.get_parent().add_child(copy)
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var id := String(mesh.get_meta("B_assembly", ""))
		var belongs_to_unit := false
		for unit: Dictionary in entry.units:
			if id == unit.id or (id.is_empty() and String(mesh.name).contains("__" + String(unit.id) + "_")):
				var offset: Array = unit.get("model_offset", [0.0, 0.0])
				mesh.position += Vector3(offset[0] * X_SPAN, 0.0, offset[1] * Y_SPAN)
				if unit.has("yaw_degrees"):
					var rect: Array = unit.footprint
					var pivot := local_to_model(Vector2(rect[0] + rect[2] * 0.5, rect[1] + rect[3] * 0.5))
					var turn := Basis(Vector3.UP, deg_to_rad(float(unit.yaw_degrees)))
					mesh.transform = Transform3D(turn, pivot - turn * pivot) * mesh.transform
				belongs_to_unit = true
				break
		# The shortcut asset also embeds its original shell.
		if not belongs_to_unit:
			mesh.hide()


func _replace_offering_altar() -> void:
	for old_piece: MeshInstance3D in model.find_children("*__main_station_*", "MeshInstance3D", true, false):
		old_piece.hide()
		old_piece.set_meta("B_assembly", &"former_altar")
	room_world.add_child(VoxelArt.new().build_offering_altar(Rect2(entry.body_rect)))


func _build_generated() -> Node3D:
	var key := var_to_str([
		_geometry_key, entry.get("room_type"), entry.get("event_type"), entry.get("wall_rects"),
		entry.get("props"), entry.get("object_rect"), entry.get("interaction_pos")
	])
	if not _generated_meshes.has(key):
		var fresh := VoxelArt.new().build(entry)
		var meshes: Array[Dictionary] = []
		for part: MeshInstance3D in fresh.get_children():
			meshes.append({"name": part.name, "mesh": part.mesh, "transform": part.transform, "assembly": part.get_meta("B_assembly", &"")})
		# Re-entering a room gets fresh transforms and depth masks. The static
		# vertex and material resources are identical for the same layout.
		if _generated_meshes.size() >= 12:
			_generated_meshes.erase(_generated_meshes.keys().front())
		_generated_meshes[key] = meshes
		return fresh
	var reused := Node3D.new()
	for record: Dictionary in _generated_meshes[key]:
		var part := MeshInstance3D.new()
		part.name = record.name
		part.mesh = record.mesh
		part.transform = record.transform
		if record.assembly != &"":
			part.set_meta("B_assembly", record.assembly)
		reused.add_child(part)
	return reused

func _camera(parent: SubViewport, mask: int) -> Camera3D:
	var c := Camera3D.new()
	c.projection = Camera3D.PROJECTION_ORTHOGONAL
	c.keep_aspect = Camera3D.KEEP_HEIGHT
	var height := Y_SPAN * sin(deg_to_rad(ELEVATION)) * FRAME.size.y
	c.size = height
	# Match projection width to the source room coordinate span before the 2D
	# viewport is fitted to the same room rectangle as actors and hit tests.
	parent.size = Vector2i(roundi(820 * X_SPAN * FRAME.size.x / height), 820)
	var center := local_to_model(FRAME.get_center())
	c.position = center + Vector3(0, sin(deg_to_rad(ELEVATION)), cos(deg_to_rad(ELEVATION))) * 30.0
	parent.add_child(c)
	c.look_at(center, Vector3.UP)
	c.cull_mask = mask
	c.current = true
	return c

func _sprite(source: SubViewport, depth: int) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = source.get_texture()
	sprite.centered = false
	sprite.position = Layout.local_to_world(FRAME.position)
	sprite.scale = Layout.local_size_to_world(FRAME.size) / Vector2(source.size)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sprite.z_index = depth
	add_child(sprite)
	return sprite

func _index_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh := node as MeshInstance3D
		var id := String(mesh.get_meta("B_assembly", ""))
		mesh.layers = (1 | WALL_LIGHT_LAYER) if id.begins_with("ArchitectureWalls") else 1
		if id.is_empty():
			for unit: Dictionary in entry.units:
				if String(mesh.name).contains("__" + String(unit.id) + "_"):
					id = String(unit.id)
					break
		if not id.is_empty():
			if not assemblies.has(id):
				assemblies[id] = []
			assemblies[id].append(mesh)
	for child in node.get_children():
		_index_meshes(child)

func _build_lights() -> void:
	for side: String in DOOR_LIGHT_POSITIONS:
		for point: Vector3 in DOOR_LIGHT_POSITIONS[side]:
			var lamp := OmniLight3D.new()
			lamp.position = point
			lamp.light_color = Color("#ff912f")
			lamp.light_energy = DOOR_LAMP_ENERGY
			lamp.omni_range = 4.15
			lamp.omni_attenuation = 1.30
			room_world.add_child(lamp)
			candle_lights.append(lamp)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-76, -22, 0)
	fill.light_color = Color("#9badb3")
	fill.shadow_enabled = true
	fill.shadow_opacity = 0.36
	fill.directional_shadow_max_distance = 45.0
	fill.light_energy = 0.27 if entry.get("polished", false) else 0.12
	room_world.add_child(fill)
	var masonry := DirectionalLight3D.new()
	masonry.name = "MasonryFill"
	masonry.rotation_degrees = Vector3(-49.0, -37.0, 0.0)
	masonry.light_color = Color("#b9cbd1")
	masonry.light_energy = 0.24
	masonry.light_cull_mask = WALL_LIGHT_LAYER
	room_world.add_child(masonry)
	if entry.get("props", []).size() > 2 and entry.get("generated", false) and entry.get("room_type") in [&"Normal", &"Spawn", &"Chest"]:
		var bench: Rect2 = entry.props[2]
		var lamp := OmniLight3D.new()
		lamp.position = local_to_model(bench.get_center()) + Vector3(0.42, 1.25, 0.02)
		lamp.light_color = Color("#ffbd75")
		lamp.light_energy = 0.72
		lamp.omni_range = 5.2
		room_world.add_child(lamp)
	var kind := StringName(entry.get("room_type", &""))
	var work := OmniLight3D.new()
	work.name = "RoomSubjectLight"
	work.position = local_to_model(entry.interaction_pos) + Vector3(0, 4.5, -0.8)
	work.light_color = Color(1.0, 0.76, 0.44)
	match kind:
		&"Mine":
			work.position = local_to_model(entry.interaction_pos) + Vector3(-0.45, 3.0, 0.65)
			work.light_color = Color("#ffd59a")
			work.light_energy = 1.36
		&"Normal", &"Spawn":
			work.position = local_to_model(Vector2(0.50, 0.5)) + Vector3(-0.7, 4.0, 0.6)
			work.light_color = Color("#ecdac2")
			work.light_energy = 0.86
		&"Monster", &"Combat", &"Boss":
			work.light_color = Color("#e5bad2") if kind == &"Boss" else Color("#ddd7c8")
			work.light_energy = 0.64
		&"Event":
			work.position = local_to_model(Vector2(0.5, 0.5)) + Vector3(-0.60, 4.2, 2.1)
			work.light_color = Color("#ffe2c1")
			# The spot identifies the service while the door candles keep their shared color.
			match String(entry.get("id", entry.get("event_type", ""))).trim_prefix("B_"):
				"relief", "first_aid": work.light_color = Color("#b4e5cd")
				"recon", "information", "seal": work.light_color = Color("#b8d9f0")
				"altar", "dice": work.light_color = Color("#dbbce5")
				"mechanism", "trap", "coil": work.light_color = Color("#ffbe82")
			work.light_energy = 0.78
		&"Exit":
			work.light_color = Color("#b0e4ce")
			work.light_energy = 0.78
		_:
			work.light_energy = 0.70
	work.omni_range = 7.0
	work.shadow_enabled = false
	room_world.add_child(work)

func _box(parent: Node3D, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var obj := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	obj.mesh = shape
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	obj.material_override = material
	obj.position = pos
	obj.layers = 1
	parent.add_child(obj)
	return obj

func _build_gates() -> void:
	for side in ["north", "east", "south", "west"]:
		var gate := VoxelArt.new().build_gate()
		gate.name = "B_Gate_" + side
		gate.scale.x = 1.39
		room_world.add_child(gate)
		gate.position = {"north": Vector3(0, 0, -6.45), "south": Vector3(0, 0, 6.45), "east": Vector3(8.4, 0, 0), "west": Vector3(-8.4, 0, 0)}[side]
		if side in ["east", "west"]:
			gate.rotation.y = PI / 2
		gate.position.y = -1.9
		gate.hide()
		gates[side] = gate
		gate_targets[side] = -1.9

func apply_snapshot(snapshot: Dictionary, doors: Array[Dictionary]) -> void:
	if not _ready_model:
		return
	var state: Dictionary = snapshot.get("event_state", {})
	var lamp_on := StringName(snapshot.get("current_room", &"")) == &"Event" and bool(state.get("completed", false))
	var changed := status_lamp.visible != lamp_on
	status_lamp.visible = lamp_on
	match String(entry.get("numbered_id", "")):
		"e06":
			for piece: MeshInstance3D in assemblies.get("main_station", []):
				if String(piece.name).contains("__main_station_Door") and piece.visible == lamp_on:
					piece.visible = not lamp_on
					changed = true
		"e24":
			var locked := bool(state.get("cage", {}).get("active", false))
			for piece: MeshInstance3D in assemblies.get("main_station", []):
				if String(piece.name).contains("__main_station_RaisedGate"):
					if not piece.has_meta("raised_y"):
						piece.set_meta("raised_y", piece.position.y)
					var target := float(piece.get_meta("raised_y")) - (1.4 if locked else 0.0)
					if not is_equal_approx(piece.position.y, target):
						piece.position.y = target
						changed = true
	if entry.get("generated", false) and _apply_voxel_prop_state(snapshot):
		changed = true
	for d in doors:
		var side := String(d.get("orientation", ""))
		if gates.has(side):
			gate_targets[side] = -1.9 if StringName(d.get("visual_state", &"")) == &"available" else 0.0
	if changed:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		front_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _apply_voxel_prop_state(snapshot: Dictionary) -> bool:
	var changed := false
	if entry.get("room_type") == &"Chest":
		var opened := bool(snapshot.get("search_state_data", {}).get("searched", false))
		var next_state := int(opened)
		if _lid_state != next_state:
			if _lid_state < 0 or not opened:
				_lid_progress = float(next_state)
				_set_lid_pose(_lid_progress)
				changed = true
			_lid_state = next_state
	elif entry.get("room_type") == &"Mine":
		var armed := not bool(snapshot.get("current_room_detail", {}).get("triggered", false))
		for part: MeshInstance3D in assemblies.get("mine_signal", []) + assemblies.get("mine_cover", []):
			if part.visible != armed:
				part.visible = armed
				changed = true
	return changed

func _set_lid_pose(progress: float) -> void:
	var rect := Rect2(entry.object_rect)
	var hinge := local_to_model(Vector2(rect.get_center().x, rect.position.y)) + Vector3.UP * 0.72
	var eased := 1.0 - pow(1.0 - progress, 2.0)
	var turn := Basis(Vector3.RIGHT, deg_to_rad(-100.0) * eased)
	_set_prop_transform("chest_lid", Transform3D(turn, hinge - turn * hinge))

func update_player_depth(player: Vector2) -> void:
	if not _ready_model:
		return
	var bucket := roundi(player.y * 1000)
	if bucket == _last_depth:
		return
	_last_depth = bucket
	var changed := false
	for unit: Dictionary in entry.units:
		var mask := 3 if player.y < float(unit.ground_y) - 0.01 else 1
		for mesh: MeshInstance3D in assemblies.get(String(unit.id), []):
			changed = changed or mesh.layers != mask
			mesh.layers = mask
	if changed:
		front_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _process(delta: float) -> void:
	if _lid_state == 1 and _lid_progress < 1.0:
		_lid_progress = move_toward(_lid_progress, 1.0, delta / CHEST_OPEN_SECONDS)
		_set_lid_pose(_lid_progress)
		_request_model_redraw()
	for side in gates:
		var gate: Node3D = gates[side]
		var target := float(gate_targets[side])
		if is_equal_approx(gate.position.y, target):
			continue
		gate.position.y = move_toward(gate.position.y, target, delta * 4.0)
		gate.visible = gate.position.y > -1.64
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if not _prop_impacts.is_empty():
		_advance_prop_impacts(delta)


func sync_breakable_props(hp_by_id: Dictionary, impacted_ids: Array = []) -> void:
	if not _ready_model:
		return
	var changed := false
	for prop: Dictionary in entry.get("breakables", []):
		var id: String = prop.id
		var broken := int(hp_by_id.get(id, prop.max_hp)) <= 0
		changed = _set_assembly_visible(id, not broken) or changed
		changed = _set_assembly_visible(id + "_debris", broken) or changed
		if id in impacted_ids:
			_prop_impacts[id] = {"elapsed": 0.0, "broken": broken, "center": local_to_model(Rect2(prop.rect).get_center())}
			_set_prop_transform(id + "_burst", Transform3D.IDENTITY)
			_set_assembly_visible(id + "_burst", true)
			changed = true
		elif _prop_impacts.has(id) and bool(_prop_impacts[id].broken) != broken:
			_prop_impacts.erase(id)
			_set_prop_transform(id, Transform3D.IDENTITY)
			_set_assembly_visible(id + "_burst", false)
			changed = true
	if changed:
		_request_model_redraw()


func _set_assembly_visible(id: String, value: bool) -> bool:
	var changed := false
	for mesh: MeshInstance3D in assemblies.get(id, []):
		if mesh.visible != value:
			mesh.visible = value
			changed = true
	return changed


func _set_prop_transform(id: String, value: Transform3D) -> void:
	for mesh: MeshInstance3D in assemblies.get(id, []):
		mesh.transform = value


func _advance_prop_impacts(delta: float) -> void:
	for id: String in _prop_impacts.keys():
		var impact: Dictionary = _prop_impacts[id]
		impact.elapsed = float(impact.elapsed) + delta
		var progress := minf(float(impact.elapsed) / IMPACT_SECONDS, 1.0)
		if progress >= 1.0:
			_prop_impacts.erase(id)
			_set_prop_transform(id, Transform3D.IDENTITY)
			_set_assembly_visible(id + "_burst", false)
			continue
		var center: Vector3 = impact.center
		var arc := sin(progress * PI)
		var scale_up := (1.9 if impact.broken else 0.65) * progress
		var spread := Basis.from_scale(Vector3(1.0 + scale_up, 1.0 - progress * 0.63, 1.0 + scale_up))
		var lift := Vector3.UP * (0.61 if impact.broken else 0.51) * arc
		_set_prop_transform(id + "_burst", Transform3D(spread, center - spread * center + lift))
		if not impact.broken:
			var tilt := Basis(Vector3.BACK, sin(progress * TAU) * (1.0 - progress) * 0.19)
			_set_prop_transform(id, Transform3D(tilt, center - tilt * center))
	_request_model_redraw()


func _request_model_redraw() -> void:
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	front_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

static func local_to_model(pos: Vector2) -> Vector3:
	return Vector3((pos.x - 0.5) * X_SPAN, 0.06, (pos.y - 0.5) * Y_SPAN)

func debug_snapshot() -> Dictionary:
	return {"model_loaded": _ready_model, "code": entry.get("code", ""), "model_path": entry.get("model_path", ""), "assemblies": assemblies.keys(), "gate_targets": gate_targets.duplicate(), "lights": candle_lights.size()}
