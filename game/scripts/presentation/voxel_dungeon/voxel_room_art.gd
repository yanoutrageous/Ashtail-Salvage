extends RefCounted
## Builds volume, material detail and matching footprints in the authored room projection.

const X_SPAN := 19.3
const Z_SPAN := 14.77
const FLOOR_Y := 0.06
const STONE := Color("#666c68")
const MORTAR := Color("#292e30")
const BRICK := Color("#69706c")
const WALL_CAP := Color("#183a3c")
const BLOCK_EDGE := Color("#8b8c7e")
const METAL := Color("#465354")
const BRASS := Color("#ad8a5b")
const OAK := Color("#865334")
const DARK_OAK := Color("#503529")
const AMBER := Color("#ffc47b")
const TEAL := Color("#62d9bf")
const RED := Color("#e27850")
const STONE_SHADER := preload("res://scripts/presentation/voxel_dungeon/voxel_block_patina.gdshader")

enum Finish { STONE, IRON, WOOD, BRONZE, GLOW, PAVING }

const DUNGEON_SHELL := preload("res://assets/B_event_rooms/B_room_shell.glb")
static var floor_meshes: Array[Mesh] = []
static var gate_mesh: ArrayMesh

var rng := RandomNumberGenerator.new()
var boxes: Array
var stone := STONE
var groups: Dictionary = {}
var vertex_counts: Dictionary = {}
var default_group := ""


func build(entry: Dictionary) -> Node3D:
	rng.seed = hash(entry["geometry_key"])
	boxes = BoxMesh.new().get_mesh_arrays()
	var scene := Node3D.new()
	scene.name = "VoxelArchitecture"
	var palette := {
		"Spawn": "#777363", "Monster": "#615d65", "Combat": "#615d65", "Chest": "#6c706b",
		"Mine": "#665851", "Exit": "#567272", "Boss": "#63556b", "Event": "#687269",
	}
	var kind := String(entry["room_type"])
	stone = Color(palette.get(kind, "#626b66"))
	_build_shell(scene, entry.wall_rects)
	for index in entry["props"].size():
		var prop: Rect2 = entry["props"][index]
		match kind:
			"Monster", "Combat", "Boss":
				_altar(prop, "fixture_%d" % index)
			"Event":
				_station(prop, "fixture_%d" % index, String(entry.get("event_type", "")))
			_:
				_perimeter_prop(prop, "fixture_%d" % index, index)
	var station := Vector2(entry["interaction_pos"])
	match kind:
		"Spawn":
			_floor_seal(Vector2(0.5, 0.52), BRASS, 3.60)
		"Monster", "Combat", "Boss":
			_floor_seal(Vector2(0.5, 0.51), RED if kind != "Boss" else Color("#b191d2"), 4.20)
		"Chest":
			_chest(Rect2(entry["object_rect"]))
		"Mine":
			_mine(station)
		"Exit":
			_exit(station)
		"Event":
			_floor_seal(station, TEAL, 2.85)
	_room_inlay(kind, station)
	_finish(scene)
	return scene


func build_event_shell(walls: Array) -> Node3D:
	rng.seed = hash("event masonry")
	boxes = BoxMesh.new().get_mesh_arrays()
	stone = Color("#626b66")
	var shell := Node3D.new()
	shell.name = "VoxelArchitecture"
	_build_shell(shell, walls)
	_finish(shell)
	return shell


func _build_shell(scene: Node3D, walls: Array) -> void:
	_add_dungeon_floor(scene)
	default_group = "ArchitectureWalls"
	for rect: Rect2 in walls:
		_wall(rect)
	default_group = ""
	_frame_dressing()


func build_offering_altar(rect: Rect2) -> Node3D:
	boxes = BoxMesh.new().get_mesh_arrays()
	rng.seed = 26
	var altar := Node3D.new()
	altar.name = "OfferingAltarStonework"
	var id := "main_station"
	var size := rect.size * Vector2(X_SPAN, Z_SPAN)
	var p := _point(rect.get_center(), 0.0)
	var slate := Color("#657775")
	var capstone := Color("#8f9c8d")
	var bronze := Color("#bd9b62")
	var iron := Color("#414c4c")
	_stone_block(p + Vector3.UP * 0.173,
		Vector3(size.x, 0.226, size.y), slate.darkened(0.22), 0.095, id)
	_stone_block(p + Vector3.UP * 0.335,
		Vector3(size.x - 0.16, 0.17, size.y - 0.15), slate, 0.058, id)
	_stone_block(p + Vector3.UP * 0.657,
		Vector3(size.x * 0.76, 0.52, size.y * 0.69), slate.darkened(0.09), 0.074, id)
	for side in [-1.0, 1.0]:
		for column in [-1.0, 0.0, 1.0]:
			var tablet := p + Vector3(column * size.x * 0.211, 0.638, side * size.y * 0.344)
			_stone_block(tablet, Vector3(size.x * 0.176, 0.360, 0.108),
				_shade(slate, 0.085), 0.035, id)
			_box(tablet + Vector3(0, -0.019, side * 0.062), Vector3(0.17, 0.21, 0.024),
				iron, id, 0.0, Finish.IRON)
			for rung in [-0.068, 0.0, 0.068]:
				var width := 0.103 if absf(rung) > 0.01 else 0.059
				_box(tablet + Vector3(0, rung - 0.019, side * 0.079),
					Vector3(width, 0.023, 0.017), bronze.darkened(0.19), id, 0.0, Finish.BRONZE)
		for end in [-1.0, 1.0]:
			var pier := p + Vector3(end * size.x * 0.405, 0.646, side * size.y * 0.301)
			_stone_block(pier, Vector3(0.32, 0.50, 0.37), slate.lightened(0.11), 0.052, id)
			_box(pier + Vector3.UP * 0.195, Vector3(0.36, 0.07, 0.40),
				bronze.darkened(0.29), id, 0.0, Finish.BRONZE)
	_stone_block(p + Vector3.UP * 0.945, Vector3(size.x * 0.91, 0.15, size.y * 0.87),
		slate.darkened(0.22), 0.055, id)
	_stone_block(p + Vector3.UP * 1.106, Vector3(size.x * 0.90, 0.24, size.y * 0.86),
		capstone, 0.081, id)
	_stone_block(p + Vector3.UP * 1.236, Vector3(size.x * 0.67, 0.042, size.y * 0.65),
		slate.darkened(0.33), 0.013, id)
	for side in [-1.0, 1.0]:
		_box(p + Vector3(side * size.x * 0.35, 1.245, 0), Vector3(0.058, 0.034, size.y * 0.66),
			bronze.darkened(0.19), id, 0.0, Finish.BRONZE)
		_box(p + Vector3(0, 1.245, side * size.y * 0.33), Vector3(size.x * 0.71, 0.034, 0.052),
			bronze.darkened(0.19), id, 0.0, Finish.BRONZE)
		for mark in [-1, 0, 1]:
			var line := p + Vector3(float(mark) * size.x * 0.128, 1.253, side * size.y * 0.265)
			_box(line, Vector3(0.061, 0.018, 0.18), bronze, id, PI * 0.25, Finish.BRONZE)
			_box(line + Vector3(0, 0.004, -side * 0.13), Vector3(0.133, 0.018, 0.037),
				bronze.darkened(0.18), id, 0.0, Finish.BRONZE)
		var foot := p + Vector3(side * size.x * 0.322, 1.276, -size.y * 0.273)
		_stone_block(foot, Vector3(0.35, 0.12, 0.35), iron, 0.042, id, PI * 0.25, Finish.IRON)
		_box(foot + Vector3.UP * 0.189, Vector3(0.15, 0.32, 0.16), Color("#dbc38d"), id)
		_box(foot + Vector3(0, 0.30, 0.07), Vector3(0.071, 0.12, 0.051), Color("#d5b67f"), id)
		_stone_block(foot + Vector3.UP * 0.421, Vector3(0.10, 0.14, 0.11),
			AMBER, 0.036, id, PI * 0.25, Finish.GLOW)
	var offering := p + Vector3.UP * 1.25
	_stone_block(offering + Vector3.UP * 0.062, Vector3(0.96, 0.12, 0.96),
		iron, 0.042, id, PI * 0.25, Finish.IRON)
	_stone_block(offering + Vector3.UP * 0.157, Vector3(0.66, 0.12, 0.66),
		bronze, 0.044, id, PI * 0.25, Finish.BRONZE)
	_stone_block(offering + Vector3.UP * 0.24, Vector3(0.55, 0.10, 0.55),
		iron, 0.027, id, PI * 0.25, Finish.IRON)
	_stone_block(offering + Vector3.UP * 0.379, Vector3(0.39, 0.33, 0.4),
		Color("#65b2bd"), 0.105, id, PI * 0.25, Finish.GLOW)
	_stone_block(offering + Vector3.UP * 0.529, Vector3(0.30, 0.16, 0.30),
		Color("#a0d5d1"), 0.061, id, PI * 0.25, Finish.GLOW)
	_finish(altar)
	return altar


func build_breakables(props: Array) -> Node3D:
	boxes = BoxMesh.new().get_mesh_arrays()
	var furniture := Node3D.new()
	furniture.name = "BreakableFurniture"
	for prop: Dictionary in props:
		rng.seed = hash(prop.id)
		var rect: Rect2 = prop.rect
		match StringName(prop.kind):
			&"crate":
				_breakable_crate(rect, prop.id)
			&"barrel":
				_perimeter_prop(rect, prop.id, 1)
			&"urn":
				_breakable_urn(rect, prop.id)
		_breakable_fragments(rect, prop.id, StringName(prop.kind))
	_finish(furniture)
	return furniture


func _breakable_crate(rect: Rect2, id: String) -> void:
	var p := _point(rect.get_center())
	var size := rect.size * Vector2(X_SPAN, Z_SPAN)
	_box(p + Vector3.UP * 0.29, Vector3(size.x * 0.91, 0.56, size.y * 0.91),
		DARK_OAK, id, 0.0, Finish.WOOD)
	for i in 4:
		var tint := _shade(OAK.lightened(0.10), 0.12)
		_box(p + Vector3.UP * (0.105 + i * 0.126), Vector3(size.x * 0.96, 0.115, size.y * 0.96),
			tint, id, 0.0, Finish.WOOD)
		_box(p + Vector3((i - 1.5) * size.x * 0.235, 0.581, 0), Vector3(size.x * 0.223, 0.067, size.y * 0.94),
			tint.lightened(0.07), id, 0.0, Finish.WOOD)
	for x in [-0.383, 0.383]:
		_box(p + Vector3(x * size.x, 0.319, 0), Vector3(0.088, 0.65, size.y),
			METAL, id, 0.0, Finish.IRON)
		for z in [-0.36, 0.36]:
			_box(p + Vector3(x * size.x, 0.65, z * size.y), Vector3(0.072, 0.018, 0.072),
				BRASS, id, 0.0, Finish.BRONZE)
	_box(p + Vector3(0, 0.31, size.y * 0.486), Vector3(size.x * 0.65, 0.14, 0.04),
		Color("#88724f"), id, 0.0, Finish.WOOD)
	_box(p + Vector3(0, 0.621, 0), Vector3(0.25, 0.026, 0.25),
		Color("#bbab83"), id, PI * 0.25)


func _breakable_urn(rect: Rect2, id: String) -> void:
	var p := _point(rect.get_center())
	var span := minf(rect.size.x * X_SPAN, rect.size.y * Z_SPAN)
	var clay := Color("#9a5d45")
	for tier in 6:
		var width: float = [0.54, 0.72, 0.88, 0.90, 0.76, 0.53][tier] * span
		var tint := Color("#c49c6d") if tier == 3 else _shade(clay, 0.14)
		_stone_block(p + Vector3.UP * (0.075 + tier * 0.12), Vector3(width, 0.127, width),
			tint, 0.050, id)
	_stone_block(p + Vector3.UP * 0.766, Vector3(span * 0.58, 0.13, span * 0.58),
		clay.lightened(0.17), 0.042, id)
	_box(p + Vector3.UP * 0.834, Vector3(span * 0.34, 0.013, span * 0.34),
		clay.darkened(0.70), id, PI * 0.25)


func _breakable_fragments(rect: Rect2, id: String, kind: StringName) -> void:
	var p := _point(rect.get_center())
	var span := minf(rect.size.x * X_SPAN, rect.size.y * Z_SPAN)
	var color := Color("#a66b51") if kind == &"urn" else OAK
	var finish := Finish.STONE if kind == &"urn" else Finish.WOOD
	for fragment in 7:
		var angle := TAU * fragment / 7.0 + rng.randf_range(-0.24, 0.24)
		var reach := rng.randf_range(0.20, 0.52) * span
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var cut := rng.randf_range(0.14, 0.28) * span
		var tone := _shade(color.lightened(0.12), 0.22)
		_stone_block(p + direction * reach + Vector3.UP * 0.053,
			Vector3(cut * (1.35 if kind == &"urn" else 2.05), 0.09, cut), tone, 0.036,
			id + "_debris", angle, finish)
		_box(p + direction * (reach * 0.68) + Vector3.UP * rng.randf_range(0.04, 0.29),
			Vector3(cut * 0.57, cut * 0.45, cut * 0.54), tone.lightened(0.18), id + "_burst", angle)
	if kind != &"urn":
		_box(p + Vector3(0.22 * span, 0.075, 0.08), Vector3(0.12, 0.07, span * 0.5),
			METAL.lightened(0.10), id + "_debris", 0.44, Finish.IRON)


func build_gate() -> Node3D:
	var gate := Node3D.new()
	if gate_mesh != null:
		var instance := MeshInstance3D.new()
		instance.name = "Ironwork"
		instance.mesh = gate_mesh
		gate.add_child(instance)
		return gate
	boxes = BoxMesh.new().get_mesh_arrays()
	for i in 9:
		var x := -0.96 + i * 0.24
		var weight := 0.14 if i in [0, 4, 8] else 0.09
		_box(Vector3(x, 0.82, 0), Vector3(weight, 1.64, 0.12), METAL, "", 0.0, Finish.IRON)
		_box(Vector3(x, 1.51, 0.006), Vector3(weight + 0.034, 0.12, 0.16), METAL.lightened(0.15), "", 0.0, Finish.IRON)
	for y in [0.18, 1.40]:
		_box(Vector3(0, y, 0), Vector3(2.15, 0.19, 0.20), METAL.darkened(0.12), "", 0.0, Finish.IRON)
		_box(Vector3(0, y + 0.06, 0), Vector3(2.06, 0.044, 0.22), BRASS.darkened(0.26), "", 0.0, Finish.BRONZE)
		for x in [-0.93, -0.48, 0.0, 0.48, 0.93]:
			for face in [-1.0, 1.0]:
				_box(Vector3(x, y, face * 0.114), Vector3(0.075, 0.075, 0.030), BRASS, "", PI * 0.25, Finish.BRONZE)
	_box(Vector3(0, 0.82, 0), Vector3(0.36, 0.32, 0.17), METAL.darkened(0.17), "", 0.0, Finish.IRON)
	for face in [-1.0, 1.0]:
		_box(Vector3(0, 0.82, face * 0.11), Vector3(0.15, 0.12, 0.075), BRASS, "", PI * 0.25, Finish.BRONZE)
	_finish(gate)
	var ironwork := gate.get_child(0) as MeshInstance3D
	ironwork.name = "Ironwork"
	gate_mesh = ironwork.mesh as ArrayMesh
	return gate


func _point(p: Vector2, height := FLOOR_Y) -> Vector3:
	return Vector3((p.x - 0.5) * X_SPAN, height, (p.y - 0.5) * Z_SPAN)


func _rect_fill(rect: Rect2, height: float, color: Color, group := "", inset := 0.0, base := FLOOR_Y) -> void:
	var size := rect.size * Vector2(X_SPAN, Z_SPAN) - Vector2.ONE * inset
	_box(_point(rect.get_center(), base + height * 0.5), Vector3(size.x, height, size.y), color, group)


func _add_dungeon_floor(scene: Node3D) -> void:
	# Reuse the carved slabs and their painted mineral/roughness atlases from the event-room kit.
	if floor_meshes.is_empty():
		var shell := DUNGEON_SHELL.instantiate()
		for part: MeshInstance3D in shell.find_children("Floor_*", "MeshInstance3D", true, false):
			if part.name != &"Floor_Substrate":
				var slab: Mesh = part.mesh.duplicate()
				for surface in slab.get_surface_count():
					var original := slab.surface_get_material(surface) as BaseMaterial3D
					if original != null:
						var stone := original.duplicate() as BaseMaterial3D
						stone.albedo_color *= Color("#ebe8e0")
						slab.surface_set_material(surface, stone)
				floor_meshes.append(slab)
		shell.free()
	_box(Vector3(0, -0.17, 0), Vector3(X_SPAN, 0.33, Z_SPAN), MORTAR.darkened(0.24))
	for mesh in floor_meshes:
		var floor_piece := MeshInstance3D.new()
		floor_piece.mesh = mesh
		floor_piece.name = mesh.resource_name
		floor_piece.scale = Vector3(X_SPAN / 16.0, 1.0, Z_SPAN / 12.0)
		scene.add_child(floor_piece)

	for side in [-1.0, 1.0]:
		_threshold(Vector3(0.0, FLOOR_Y, side * 6.72), false)
		_threshold(Vector3(side * 8.55, FLOOR_Y, 0.0), true)


func _threshold(p: Vector3, side: bool) -> void:
	var turn := PI * 0.5 if side else 0.0
	var basis := Basis(Vector3.UP, turn)
	_stone_block(p + Vector3.UP * 0.06, Vector3(3.20, 0.13, 1.24), BRICK.lightened(0.16), 0.045, "", turn)
	for offset in [-0.42, 0.38]:
		_box(p + basis * Vector3(0, 0.142, offset), Vector3(3.08, 0.043, 0.13), METAL, "", turn, Finish.IRON)
		for plate in range(-2, 3):
			_box(p + basis * Vector3(plate * 0.43, 0.168, offset), Vector3(0.11, 0.014, 0.092), BRASS.darkened(0.18), "", turn, Finish.BRONZE)
	# A lintel joins the wall ends above the gate, leaving the walkable floor open.
	var outer := signf(p.x if side else p.z)
	var lintel := p + (Vector3.RIGHT if side else Vector3.BACK) * outer * 0.24 + Vector3.UP * 1.91
	_stone_block(lintel, Vector3(3.72, 0.32, 0.66), WALL_CAP.lightened(0.08), 0.05, "ArchitectureWalls", turn)
	_stone_block(lintel - Vector3.UP * 0.18, Vector3(3.54, 0.11, 0.57), BRICK.darkened(0.08), 0.025, "ArchitectureWalls", turn)
	for offset in [-1.65, 1.65]:
		var post := p + basis * Vector3(offset, 0.0, 0.08)
		_box(post + Vector3.UP * 0.13, Vector3(0.47, 0.26, 0.87), MORTAR, "", turn)
		_box(post + Vector3.UP * 0.89, Vector3(0.36, 1.78, 0.74), BRICK, "", turn)
		_stone_block(post + Vector3.UP * 1.71, Vector3(0.48, 0.16, 0.89), BLOCK_EDGE, 0.058, "", turn)
		_box(post + Vector3.UP * 0.76, Vector3(0.40, 0.14, 0.79), METAL, "", turn, Finish.IRON)
		_box(post + basis * Vector3(0, 0.76, 0.408), Vector3(0.115, 0.081, 0.027), BRASS, "", turn, Finish.BRONZE)

func _wall(rect: Rect2) -> void:
	var center := _point(rect.get_center())
	var size := rect.size * Vector2(X_SPAN, Z_SPAN)
	var along_x := size.x >= size.y
	var turn := 0.0 if along_x else PI * 0.5
	var basis := Basis(Vector3.UP, turn)
	var length := maxf(size.x, size.y)
	var across := minf(size.x, size.y)
	var north := rect.position.y < 0.12
	var height := 1.73 if north else (0.56 if rect.end.y > 0.90 and along_x else 1.06)
	var inward := 1.0 if (basis * Vector3.BACK).dot(center) < 0.0 else -1.0
	var cols := maxi(2, roundi(length / 0.94))
	var tiers := maxi(2, roundi(height / 0.30))
	var run := length / cols
	var wall_tint := Color("#46535d").lerp(stone, 0.12)
	# The right-hand north bay contains one recessed cupboard. Its backing
	# continues behind the opening and keeps the outside face closed.
	var has_niche := along_x and north and center.x > 0.0 and length > 5.0 and across > 0.90
	var niche_x := -length * 0.20
	var niche_half := 0.94
	var core_inset := 0.52 if has_niche else 0.14
	var core_center := center + basis * Vector3(0, height * 0.5 - 0.05, -inward * core_inset * 0.5)
	_box(core_center, Vector3(length - 0.045, height + 0.08, across - core_inset - 0.05), MORTAR.darkened(0.27), "", turn)
	for tier in tiers:
		for col in cols + 1:
			var left := maxf(0.0, (col - 0.5 * (tier % 2)) * run)
			var right := minf(length, (col + 1.0 - 0.5 * (tier % 2)) * run)
			if right - left < 0.06:
				continue
			var p := center + basis * Vector3((left + right - length) * 0.5, 0.017 + height / tiers * (tier + 0.5), 0)
			var block := Vector3(right - left - 0.028, height / tiers - 0.032, across - rng.randf_range(0.0, 0.07))
			var tint := _shade(wall_tint, 0.11).darkened(0.13 if tier == 0 else 0.0)
			if has_niche and tier > 0 and tier < tiers - 1:
				var opening_left := length * 0.5 + niche_x - niche_half
				var opening_right := opening_left + niche_half * 2.0
				if left < opening_right and right > opening_left:
					for span: Vector2 in [Vector2(left, opening_left), Vector2(opening_right, right)]:
						if span.y - span.x > 0.08:
							var cut_pos := Vector3(center.x + (span.x + span.y - length) * 0.5, p.y, p.z)
							_box(cut_pos, Vector3(span.y - span.x - 0.028, block.y, block.z), tint)
					continue
			_box(p, block, tint, "", turn)
	if has_niche:
		var course := height / tiers
		var sill := center + Vector3(niche_x, course + 0.02, across * 0.5)
		_north_wall_niche(sill, niche_half, height - 2.0 * course, wall_tint)

	# A projecting foot and a sloped coping reveal the wall depth from the fixed camera.
	for course_index in cols:
		var offset := (course_index + 0.5) * run - length * 0.5
		var foot := center + basis * Vector3(offset, 0.14, inward * (across * 0.5 - 0.02))
		_stone_block(foot, Vector3(run - 0.028, 0.24, 0.21), wall_tint.darkened(0.18), 0.035, "", turn)
		var coping := center + basis * Vector3(offset, height + 0.12, inward * (across * 0.5 - 0.04))
		_stone_block(coping, Vector3(run - 0.024, 0.16, 0.21), Color("#587172"), 0.035, "", turn)

	var cap_depth := across / 2.0
	for row in 2:
		var row_shift := 0.5 * row * run
		for col in cols + 1:
			var left := maxf(0.0, col * run - row_shift)
			var right := minf(length, (col + 1.0) * run - row_shift)
			if right - left < 0.06:
				continue
			var lip := (float(row) - 0.5) * cap_depth
			var cap := center + basis * Vector3((left + right - length) * 0.5, height + 0.075, lip)
			var tone := _shade(WALL_CAP.lerp(wall_tint, 0.12 if lip * inward > 0.0 else 0.03), 0.045)
			_stone_block(cap, Vector3(right - left - 0.035, 0.175, cap_depth - 0.038), tone, rng.randf_range(0.037, 0.073), "", turn)

	for end: float in [-1.0, 1.0]:
		var x := end * (length * 0.5 - 0.39)
		_wall_buttress(center, basis, turn, x, inward * (across * 0.5 - 0.20), height, wall_tint)
	if length > 4.5:
		_wall_buttress(center, basis, turn, length * 0.11, inward * (across * 0.5 - 0.20), height, wall_tint)


func _north_wall_niche(sill: Vector3, half_width: float, opening_height: float, tint: Color) -> void:
	var edging := tint.lerp(Color("#9e8e70"), 0.38)
	var span := half_width * 2.0
	_stone_block(sill + Vector3(0, 0.07, -0.24), Vector3(span - 0.01, 0.14, 0.48), edging, 0.036)
	for side: float in [-1.0, 1.0]:
		var jamb := sill + Vector3(side * (half_width - 0.09), opening_height * 0.5, -0.225)
		_box(jamb, Vector3(0.17, opening_height - 0.28, 0.45), edging.darkened(0.09))
	_stone_block(sill + Vector3(0, opening_height - 0.07, -0.235), Vector3(span - 0.01, 0.14, 0.47), edging, 0.032)
	var ledge := sill + Vector3(0, 0.14, -0.19)
	var crock := ledge + Vector3(-0.28, 0, 0)
	var clay := Color("#aa6b46")
	_stone_block(crock + Vector3.UP * 0.16, Vector3(0.43, 0.32, 0.33), clay, 0.06)
	_box(crock + Vector3.UP * 0.36, Vector3(0.27, 0.08, 0.22), clay.darkened(0.08))
	_box(crock + Vector3.UP * 0.42, Vector3(0.32, 0.04, 0.26), clay.lightened(0.09))
	_box(crock + Vector3.UP * 0.445, Vector3(0.21, 0.012, 0.15), DARK_OAK.darkened(0.25))
	var flask := ledge + Vector3(0.29, 0, 0.045)
	_stone_block(flask + Vector3.UP * 0.13, Vector3(0.26, 0.26, 0.25), Color("#738b81"), 0.045)
	_box(flask + Vector3.UP * 0.31, Vector3(0.13, 0.10, 0.14), Color("#607970"))
	_box(flask + Vector3.UP * 0.385, Vector3(0.14, 0.05, 0.15), OAK, "", 0.0, Finish.WOOD)


func _wall_buttress(center: Vector3, basis: Basis, turn: float, x: float, z: float, height: float, tint: Color) -> void:
	var base := center + basis * Vector3(x, 0, z)
	var accent := tint.lerp(BLOCK_EDGE, 0.31)
	_box(base + Vector3.UP * 0.12, Vector3(0.66, 0.22, 0.40), tint.darkened(0.22), "", turn)
	_box(base + Vector3.UP * (height * 0.50), Vector3(0.49, height * 0.82, 0.34), accent, "", turn)
	_box(base + Vector3.UP * (height - 0.015), Vector3(0.63, 0.15, 0.40), tint.darkened(0.07), "", turn)
	var crest := base + Vector3.UP * (height + 0.102)
	_stone_block(crest, Vector3(0.65, 0.174, 0.40), WALL_CAP.lerp(accent, 0.20), 0.066, "", turn)
	for rail in [-0.16, 0.16]:
		_box(crest + basis * Vector3(rail, 0.093, 0), Vector3(0.052, 0.025, 0.31), METAL, "", turn, Finish.IRON)
		_box(crest + basis * Vector3(rail, 0.109, 0.0), Vector3(0.078, 0.017, 0.071), BRASS.darkened(0.12), "", turn, Finish.BRONZE)

func _frame_dressing() -> void:
	for side in [-1.0, 1.0]:
		for p: Vector3 in [Vector3(side * 2.22, 0.38, -4.95), Vector3(side * 7.02, 0.31, 1.90), Vector3(side * 7.02, 0.31, -1.90), Vector3(side * 2.22, 0.31, 5.21)]:
			_box(p + Vector3.DOWN * 0.13, Vector3(0.39, 0.26, 0.39), STONE.darkened(0.23))
			_box(p + Vector3.UP * 0.29, Vector3(0.16, 0.62, 0.16), METAL, "", 0.0, Finish.IRON)
			_box(p + Vector3.UP * 0.63, Vector3(0.40, 0.19, 0.40), METAL.darkened(0.16), "", 0.0, Finish.IRON)
			_box(p + Vector3.UP * 0.72, Vector3(0.32, 0.05, 0.32), BRASS.darkened(0.20), "", 0.0, Finish.BRONZE)
			_box(p + Vector3.UP * 0.88, Vector3(0.18, 0.28, 0.18), Color("#d7b88a"))
			_box(p + Vector3(0.084, 0.93, 0.05), Vector3(0.045, 0.15, 0.075), Color("#e2cba5"))
			_box(p + Vector3.UP * 1.08, Vector3(0.13, 0.15, 0.13), AMBER, "Embers")
			_box(p + Vector3(0.016, 1.19, -0.018), Vector3(0.075, 0.095, 0.075), Color("#ffedc5"), "Embers")
		for corner in [-1.0, 1.0]:
			for index in 12:
				var offset := rng.randf_range(0.16, 1.1)
				var p := Vector3(side * (8.0 - offset), 0.09, corner * rng.randf_range(5.05, 5.88))
				var cube := rng.randf_range(0.06, 0.24)
				_box(p + Vector3.UP * cube * 0.2, Vector3(cube, cube * 0.55, cube * 1.4), _shade(STONE, 0.23), "", rng.randf_range(-0.3, 0.3))
			var corner_block := Vector3(side * 8.89, 0.28, corner * 6.58)
			for tier in 3:
				_box(corner_block + Vector3.UP * tier * 0.28, Vector3(1.24 - tier * 0.13, 0.30, 1.14 - tier * 0.12), _shade(BRICK, 0.12))

func _room_inlay(kind: String, anchor: Vector2) -> void:
	match kind:
		"Spawn", "Normal":
			for side in [-1.0, 1.0]:
				for i in 8:
					_box(Vector3(side * (1.17 + (i % 2) * 0.12), 0.088, -3.70 + i * 1.05), Vector3(0.14, 0.02, 0.42), BRASS.darkened(0.30))
			for quadrant in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
				var p := Vector3(quadrant.x * 4.5, 0.084, quadrant.y * 3.78)
				for row in 3:
					for col in 3:
						_box(p + Vector3(col * 0.17, 0, row * 0.17), Vector3(0.14, 0.021, 0.14), BRICK.darkened(0.31 if (row + col) % 2 == 0 else 0.16))
		"Monster", "Combat", "Boss":
			var hint := Color("#a26a55") if kind != "Boss" else Color("#8e718f")
			for side in [-1.0, 1.0]:
				for i in 12:
					var p := Vector3(side * (3.37 + (i % 3) * 0.089), 0.087, -4.08 + i * 0.71)
					_box(p, Vector3(0.09, 0.028, 0.46), hint.darkened(0.27))
					_box(p + Vector3(side * 0.31, 0.006, 0.19), Vector3(0.21, 0.028, 0.13), METAL.darkened(0.13))
		"Exit":
			var p := _point(anchor, 0.087)
			var tint := TEAL.darkened(0.44)
			for direction in [-1.0, 1.0]:
				for i in 7:
					var mark := p + Vector3(direction * (1.16 + 0.15 * (i % 2)), 0, 0.98 + i * 0.48)
					_box(mark, Vector3(0.13, 0.023, 0.32), tint)
					_box(mark + Vector3(direction * 0.28, 0.012, 0.14), Vector3(0.093, 0.021, 0.091), tint.darkened(0.30))
		_:
			pass


func _floor_seal(local: Vector2, tint: Color, width: float) -> void:
	var p := _point(local, 0.083)
	var dark := tint.lerp(MORTAR, 0.62)
	for i in range(-4, 5):
		var w := width * 0.5 - absf(i) * width * 0.048
		for step in [-1.0, 1.0]:
			var edge := p + Vector3(step * w, 0, i * width * 0.102)
			_box(edge, Vector3(width * 0.058, 0.029, width * 0.092), dark)
			if i in [-4, 0, 4]:
				_box(edge + Vector3.UP * 0.017, Vector3(0.14, 0.018, 0.19), tint)
	for step in [-1.0, 1.0]:
		_box(p + Vector3(0, 0, step * width * 0.48), Vector3(width * 0.49, 0.028, 0.082), dark)


func _perimeter_prop(rect: Rect2, id: String, index: int) -> void:
	var p := _point(rect.get_center())
	var size := rect.size * Vector2(X_SPAN, Z_SPAN)
	if index == 2:
		# Low repair bench: stacked timber offcuts, a copper lamp and a small tool.
		for rail in [-0.32, 0.32]:
			_box(p + Vector3(rail * size.x, 0.19, 0), Vector3(0.16, 0.38, size.y * 0.74), DARK_OAK, id, 0.0, Finish.WOOD)
		_box(p + Vector3.UP * 0.42, Vector3(size.x, 0.13, size.y), OAK, id, 0.0, Finish.WOOD)
		for board in 2:
			_box(p + Vector3(-0.28, 0.52 + board * 0.07, -0.03), Vector3(0.70, 0.07, 0.20), OAK.lightened(0.12), id, 0.09 * board, Finish.WOOD)
		var wick := p + Vector3(0.42, 0.56, 0.02)
		_stone_block(wick, Vector3(0.34, 0.15, 0.30), BRASS, 0.04, id, 0.0, Finish.BRONZE)
		_box(wick + Vector3.UP * 0.20, Vector3(0.14, 0.28, 0.15), AMBER, id, 0.0, Finish.GLOW)
	elif index % 2 == 0:
		_box(p + Vector3.UP * 0.33, Vector3(size.x * 0.97, 0.66, size.y * 0.96), DARK_OAK, id, 0.0, Finish.WOOD)
		for i in 5:
			var x := (i - 2) * size.x * 0.18
			_box(p + Vector3(x, 0.69, 0), Vector3(size.x * 0.17, 0.075, size.y * 0.93), _shade(OAK, 0.12), id, 0.0, Finish.WOOD)
		for rail in [-0.37, 0.37]:
			_box(p + Vector3(rail * size.x, 0.37, 0), Vector3(0.085, 0.74, size.y), METAL, id, 0.0, Finish.IRON)
			_box(p + Vector3(rail * size.x, 0.754, 0), Vector3(0.074, 0.018, 0.074), BRASS.darkened(0.16), id, 0.0, Finish.BRONZE)
		_box(p + Vector3(0.0, 0.44, size.y * 0.5), Vector3(0.19, 0.11, 0.074), BRASS, id, 0.0, Finish.BRONZE)
	else:
		var r := minf(size.x, size.y) * 0.40
		for plank in 8:
			var angle := TAU * plank / 8.0
			_box(p + Vector3(cos(angle) * r, 0.41, sin(angle) * r), Vector3(r * 0.79, 0.80, 0.09), _shade(OAK, 0.17), id, PI * 0.5 - angle, Finish.WOOD)
		for band in [0.15, 0.63]:
			_stone_block(p + Vector3.UP * band, Vector3(r * 2.35, 0.092, r * 2.35), METAL, 0.034, id, 0.0, Finish.IRON)
		_stone_block(p + Vector3.UP * 0.84, Vector3(r * 2.06, 0.09, r * 2.06), OAK, 0.036, id, 0.0, Finish.WOOD)
		_box(p + Vector3(0.0, 0.895, 0.08), Vector3(0.10, 0.021, 0.10), BRASS.darkened(0.19), id, 0.0, Finish.BRONZE)

func _altar(rect: Rect2, id: String) -> void:
	var size := rect.size * Vector2(X_SPAN, Z_SPAN)
	var p := _point(rect.get_center(), 0.0)
	var slate := stone.lerp(BRICK, 0.54)
	_stone_block(p + Vector3.UP * 0.196, Vector3(size.x - 0.04, 0.27, size.y - 0.04), slate.darkened(0.20), 0.12, id)
	_box(p + Vector3.UP * 0.41, Vector3(size.x * 0.94, 0.20, size.y * 0.91), slate, id)
	_stone_block(p + Vector3.UP * 0.64, Vector3(size.x * 0.86, 0.30, size.y * 0.81), slate.darkened(0.20), 0.11, id)
	for side in [-1.0, 1.0]:
		for panel in range(-2, 3):
			var tile := p + Vector3(panel * size.x * 0.145, 0.80, side * size.y * 0.265)
			_box(tile, Vector3(size.x * 0.138, 0.079, size.y * 0.17), _shade(slate, 0.13), id)
		var rail := p + Vector3(0, 0.83, side * size.y * 0.361)
		_box(rail, Vector3(size.x * 0.77, 0.13, 0.15), METAL, id, 0.0, Finish.IRON)
		for mark in range(-3, 4):
			var dim := 0.17 if mark == 0 else 0.088
			_box(rail + Vector3(mark * size.x * 0.094, 0.075, 0), Vector3(dim, 0.041, 0.10), BRASS.darkened(0.12), id, 0.0, Finish.BRONZE)
		_box(p + Vector3(side * size.x * 0.39, 0.83, 0), Vector3(0.16, 0.13, size.y * 0.61), METAL, id, 0.0, Finish.IRON)

	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			var corner := p + Vector3(x * size.x * 0.338, 0.69, z * size.y * 0.303)
			_box(corner, Vector3(0.48, 0.64, 0.46), slate, id)
			_box(corner + Vector3.UP * 0.22, Vector3(0.54, 0.14, 0.54), METAL, id, 0.0, Finish.IRON)
			_stone_block(corner + Vector3.UP * 0.36, Vector3(0.61, 0.18, 0.63), slate.lightened(0.25), 0.073, id)
			_box(corner + Vector3.UP * 0.465, Vector3(0.18, 0.027, 0.18), BRASS.darkened(0.06), id, PI * 0.25, Finish.BRONZE)

	_stone_block(p + Vector3.UP * 0.93, Vector3(1.82, 0.28, 1.82), slate.lightened(0.17), 0.12, id, PI * 0.25)
	_box(p + Vector3.UP * 1.11, Vector3(1.55, 0.165, 1.55), METAL.darkened(0.17), id, PI * 0.25, Finish.IRON)
	_stone_block(p + Vector3.UP * 1.235, Vector3(1.41, 0.115, 1.41), BRASS.darkened(0.18), 0.040, id, PI * 0.25, Finish.BRONZE)
	_box(p + Vector3.UP * 1.325, Vector3(1.14, 0.13, 1.14), METAL.lightened(0.10), id, PI * 0.25, Finish.IRON)
	for direction in [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		_box(p + Vector3.UP * 1.41 + direction * 0.45, Vector3(0.20, 0.13, 0.20), BRASS, id, PI * 0.25, Finish.BRONZE)
	_stone_block(p + Vector3.UP * 1.52, Vector3(0.57, 0.27, 0.57), DARK_OAK, 0.095, id, PI * 0.25, Finish.IRON)
	_stone_block(p + Vector3.UP * 1.744, Vector3(0.38, 0.34, 0.38), RED, 0.10, id, PI * 0.25, Finish.GLOW)

func _station(rect: Rect2, id: String, event: String) -> void:
	if event == "trap":
		_ratchet_workstation(rect, id)
		return
	_rect_fill(rect, 0.22, BRICK, id, 0.04)
	var p := _point(rect.get_center(), 0.86)
	var size := rect.size * Vector2(X_SPAN, Z_SPAN)
	var tint := TEAL if hash(event) % 2 == 0 else BRASS
	_box(p, Vector3(size.x * 0.87, 1.28, size.y * 0.84), DARK_OAK, id, 0.0, Finish.WOOD)
	_stone_block(p + Vector3.UP * 0.69, Vector3(size.x * 0.94, 0.17, size.y * 0.94), OAK.lightened(0.11), 0.062, id, 0.0, Finish.WOOD)
	for step in [-1, 0, 1]:
		var off := Vector3(size.x * 0.25 * step, 0.0, size.y * 0.43)
		_box(p + off, Vector3(size.x * 0.19, 0.83, 0.10), OAK, id, 0.0, Finish.WOOD)
		_box(p + off + Vector3(0, 0.053, 0.060), Vector3(0.27, 0.17, 0.060), METAL, id, 0.0, Finish.IRON)
		_box(p + off + Vector3(0, 0.06, 0.10), Vector3(0.15, 0.078, 0.033), BRASS, id, 0.0, Finish.BRONZE)
		var station := p + Vector3(size.x * 0.25 * step, 0.91, 0.06)
		_stone_block(station, Vector3(0.48, 0.27 + 0.10 * absi(step), 0.40), METAL, 0.052, id, 0.0, Finish.IRON)
		_box(station + Vector3.UP * (0.15 + absi(step) * 0.05), Vector3(0.28, 0.045, 0.26), tint.darkened(0.12), id, 0.0, Finish.GLOW)
		for corner in [-0.17, 0.17]:
			_box(station + Vector3(corner, 0.15 + absi(step) * 0.05, 0.10), Vector3(0.055, 0.033, 0.055), BRASS, id, 0.0, Finish.BRONZE)

func _ratchet_workstation(rect: Rect2, id: String) -> void:
	var p := _point(rect.get_center())
	var span := rect.size * Vector2(X_SPAN, Z_SPAN)
	var iron := Color("#596669")
	var iron_shadow := Color("#323d3e")
	var ochre := Color("#c49242")
	var rust := Color("#ae5131")
	for side: float in [-1.0, 1.0]:
		var foot := p + Vector3(side * span.x * 0.36, 0, 0)
		_stone_block(foot + Vector3.UP * 0.09, Vector3(0.64, 0.18, span.y * 0.92), BRICK, 0.035, id)
		_box(foot + Vector3.UP * 0.42, Vector3(0.42, 0.48, span.y * 0.68), DARK_OAK, id, 0.0, Finish.WOOD)
	_box(p + Vector3.UP * 0.45, Vector3(span.x * 0.70, 0.17, 0.18), OAK, id, 0.0, Finish.WOOD)
	_stone_block(p + Vector3.UP * 0.77, Vector3(span.x * 0.94, 0.22, span.y * 0.95), OAK, 0.04, id, 0.0, Finish.WOOD)

	# Looking from the front, daylight is visible between rim, spokes and axle.
	var pitch := 0.119
	var axle := p + Vector3(-span.x * 0.20, 1.74, -0.03)
	_box(axle + Vector3(0, -0.36, -0.21), Vector3(0.49, 1.00, 0.25), iron_shadow, id, 0.0, Finish.IRON)
	var profile := PackedStringArray([
		".....###.....", "..##.###.##..", ".###########.", ".###..#..###.",
		"..#.#.#.#.#..", "###..###..###", "#############", "###..###..###",
		"..#.#.#.#.#..", ".###..#..###.", ".###########.", "..##.###.##..", ".....###....."
	])
	for row in profile.size():
		var line := profile[row]
		var first := -1
		for col in line.length() + 1:
			if col < line.length() and line[col] == "#":
				if first < 0:
					first = col
			elif first >= 0:
				var center_x := (0.5 * (first + col - 1) - 6.0) * pitch
				var part := axle + Vector3(center_x, (6 - row) * pitch, 0)
				_box(part, Vector3((col - first) * pitch, pitch, 0.20), iron, id, 0.0, Finish.IRON)
				first = -1
	_box(axle + Vector3(0, 0, 0.145), Vector3(0.32, 0.32, 0.09), ochre, id, 0.0, Finish.BRONZE)
	_box(axle + Vector3(0.28, 0, 0.22), Vector3(0.68, 0.14, 0.07), iron_shadow, id, 0.0, Finish.IRON)
	_box(axle + Vector3(0.57, 0, 0.31), Vector3(0.15, 0.17, 0.12), rust, id, 0.0, Finish.WOOD)

	var rack := p + Vector3(span.x * 0.10, 0.935, 0.0)
	_box(rack, Vector3(span.x * 0.66, 0.11, 0.26), iron_shadow, id, 0.0, Finish.IRON)
	for tooth in 9:
		_box(rack + Vector3((tooth - 4) * span.x * 0.065, 0.105, 0), Vector3(0.13, 0.10, 0.24), iron, id, 0.0, Finish.IRON)
	var latch := p + Vector3(span.x * 0.30, 0.88, -0.04)
	_stone_block(latch + Vector3.UP * 0.19, Vector3(0.48, 0.38, 0.52), rust, 0.04, id, 0.0, Finish.IRON)
	_box(latch + Vector3(-0.25, 0.34, 0.04), Vector3(0.39, 0.15, 0.18), ochre, id, 0.0, Finish.BRONZE)
	_box(latch + Vector3(0.06, 0.406, 0), Vector3(0.105, 0.052, 0.105), TEAL, id, 0.0, Finish.GLOW)


func _chest(rect: Rect2) -> void:
	var p := _point(rect.get_center())
	var size := rect.size * Vector2(X_SPAN, Z_SPAN)
	var chestnut := Color("#814235")
	var iron := Color("#303b3c")
	var brass := Color("#d5a15b")
	var lining := Color("#314346")
	var lip := 0.12
	_box(p + Vector3.UP * 0.08, Vector3(size.x, 0.16, size.y), iron, "chest", 0.0, Finish.IRON)
	_box(p + Vector3.UP * 0.17, Vector3(size.x - 2.0 * lip, 0.04, size.y - 2.0 * lip), lining, "chest", 0.0, Finish.WOOD)
	for course in 3:
		var y := 0.244 + course * 0.168
		var tone := chestnut.lerp(DARK_OAK, 0.22 if course == 0 else 0.08 * course)
		for side in [-1.0, 1.0]:
			_box(p + Vector3(0, y, side * (size.y - lip) * 0.5), Vector3(size.x, 0.165, lip), tone, "chest", 0.0, Finish.WOOD)
			_box(p + Vector3(side * (size.x - lip) * 0.5, y, 0), Vector3(lip, 0.165, size.y - 2.0 * lip), tone, "chest", 0.0, Finish.WOOD)
	for side in [-1.0, 1.0]:
		_box(p + Vector3(0, 0.689, side * (size.y - lip) * 0.5), Vector3(size.x, 0.05, lip), iron, "chest", 0.0, Finish.IRON)
		_box(p + Vector3(side * (size.x - lip) * 0.5, 0.689, 0), Vector3(lip, 0.05, size.y - 2.0 * lip), iron, "chest", 0.0, Finish.IRON)
		for end in [-1.0, 1.0]:
			var band := p + Vector3(side * size.x * 0.32, 0.41, end * size.y * 0.5)
			_box(band, Vector3(0.20, 0.61, 0.055), iron, "chest", 0.0, Finish.IRON)
			_box(band + Vector3(0, -0.15, end * 0.03), Vector3(0.070, 0.070, 0.025), BRASS, "chest", 0.0, Finish.BRONZE)

	# The stepped lock plate sits on the front boards. The larger lozenge is
	# fixed to the lid so its silhouette stays readable at the game camera.
	var lock := p + Vector3(0, 0.47, size.y * 0.5 + 0.03)
	_box(lock, Vector3(0.37, 0.18, 0.065), brass, "chest", 0.0, Finish.BRONZE)
	for edge in [-1.0, 1.0]:
		_box(lock + Vector3.UP * edge * 0.13, Vector3(0.20, 0.08, 0.065), brass, "chest", 0.0, Finish.BRONZE)
	_box(lock + Vector3(0, 0, 0.042), Vector3(0.073, 0.105, 0.027), iron, "chest", 0.0, Finish.IRON)

	_box(p + Vector3.UP * 0.788, Vector3(size.x, 0.15, size.y), chestnut, "chest_lid", 0.0, Finish.WOOD)
	for row in range(-2, 3):
		var crown := 0.21 - 0.065 * absi(row)
		var z := size.y * 0.2 * row
		var top := 0.863 + crown
		_box(p + Vector3(0, top - crown * 0.5, z), Vector3(size.x * 0.994, crown, size.y * 0.199), chestnut.lightened(0.028 * (2 - absi(row))), "chest_lid", 0.0, Finish.WOOD)
		for side in [-1.0, 1.0]:
			var cap := p + Vector3(side * size.x * 0.32, top + 0.025, z)
			_box(cap, Vector3(0.205, 0.055, size.y * 0.20), iron, "chest_lid", 0.0, Finish.IRON)
			if absi(row) == 2:
				_box(cap + Vector3.UP * 0.043, Vector3(0.076, 0.034, 0.076), BRASS, "chest_lid", 0.0, Finish.BRONZE)
	var seal := p + Vector3.UP * 1.096
	_box(seal, Vector3(0.55, 0.062, 0.55), iron, "chest_lid", PI * 0.25, Finish.IRON)
	_box(seal + Vector3.UP * 0.043, Vector3(0.405, 0.047, 0.405), brass, "chest_lid", PI * 0.25, Finish.BRONZE)
	_box(seal + Vector3.UP * 0.075, Vector3(0.19, 0.034, 0.19), iron, "chest_lid", PI * 0.25, Finish.IRON)

func _mine(local: Vector2) -> void:
	var p := _point(local, 0.13)
	var frame := Color("#966637")
	var inset := Color("#28363e")
	_stone_block(p, Vector3(2.36, 0.19, 2.08), frame, 0.075, "", 0.0, Finish.BRONZE)
	_stone_block(p + Vector3.UP * 0.13, Vector3(2.12, 0.12, 1.84), inset, 0.048)
	# One revealed board square, with an inlaid mine glyph readable from above.
	for side in [-1.0, 1.0]:
		for end in [-1.0, 1.0]:
			_box(p + Vector3(side * 0.92, 0.215, end * 0.75), Vector3(0.24, 0.055, 0.14), BRASS, "", 0.0, Finish.BRONZE)
	var amber := Color("#f6b24d")
	for row in 3:
		var width := 0.54 if row != 1 else 0.85
		_box(p + Vector3(0, 0.226, (row - 1) * 0.25), Vector3(width, 0.055, 0.25), amber, "", 0.0, Finish.BRONZE)
	_box(p + Vector3(-0.13, 0.264, -0.12), Vector3(0.13, 0.03, 0.12), Color("#ffe0ae"), "", 0.0, Finish.GLOW)
	_box(p + Vector3(0, 0.225, -0.53), Vector3(0.15, 0.06, 0.22), amber, "", 0.0, Finish.BRONZE)
	# A raised copper lid covers the glyph until the existing triggered state reveals it.
	_stone_block(p + Vector3.UP * 0.32, Vector3(1.48, 0.15, 1.27), Color("#895938"), 0.06, "mine_cover", 0.0, Finish.BRONZE)
	_box(p + Vector3.UP * 0.42, Vector3(0.33, 0.052, 0.33), AMBER, "mine_signal", PI * 0.25, Finish.GLOW)

func _exit(local: Vector2) -> void:
	var p := _point(local)
	for i in 3:
		_stone_block(p + Vector3.UP * (0.07 + i * 0.112), Vector3(2.70 - i * 0.48, 0.14, 2.25 - i * 0.39), BRICK.lightened(i * 0.065), 0.047)
	for x in [-0.98, 0.98]:
		var post := p + Vector3(x, 0.75, -0.29)
		_box(post + Vector3.DOWN * 0.53, Vector3(0.43, 0.31, 0.52), METAL.darkened(0.18), "", 0.0, Finish.IRON)
		_box(post, Vector3(0.28, 1.42, 0.34), METAL, "", 0.0, Finish.IRON)
		_stone_block(post + Vector3.UP * 0.69, Vector3(0.44, 0.22, 0.47), BRASS.darkened(0.10), 0.055, "", 0.0, Finish.BRONZE)
		_box(post + Vector3(0.0, 0.45, 0.20), Vector3(0.11, 0.55, 0.07), TEAL, "Embers")
		for y in [-0.29, 0.02, 0.26]:
			_box(post + Vector3(0, y, 0.18), Vector3(0.23, 0.097, 0.075), METAL.lightened(0.12), "", 0.0, Finish.IRON)
			_box(post + Vector3(0, y, 0.228), Vector3(0.069, 0.068, 0.028), BRASS, "", 0.0, Finish.BRONZE)
	_stone_block(p + Vector3(0.0, 1.46, -0.29), Vector3(2.04, 0.21, 0.37), METAL, 0.059, "", 0.0, Finish.IRON)
	_box(p + Vector3(0.0, 1.57, -0.29), Vector3(1.21, 0.032, 0.10), BRASS.darkened(0.09), "", 0.0, Finish.BRONZE)
	_box(p + Vector3(0.0, 0.371, 0.1), Vector3(0.75, 0.088, 0.59), METAL, "", 0.0, Finish.IRON)
	_box(p + Vector3(0.0, 0.425, 0.1), Vector3(0.41, 0.025, 0.35), TEAL, "Embers")
	_floor_seal(local, TEAL, 3.85)

func _shade(color: Color, amount: float) -> Color:
	var delta := rng.randf_range(-amount, amount)
	return color.lightened(delta) if delta > 0 else color.darkened(-delta)


func _surface(group: String) -> SurfaceTool:
	if not groups.has(group):
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		groups[group] = surface
		vertex_counts[group] = 0
	return groups[group]


func _tint(color: Color, normal: Vector3) -> Color:
	var shade := 0.12 * maxf(0.0, normal.y) - 0.16 * maxf(0.0, -normal.y)
	shade += 0.035 * normal.x - 0.055 * normal.z
	return color.lightened(shade) if shade >= 0.0 else color.darkened(-shade)


func _box(center: Vector3, size: Vector3, color: Color, group := "", yaw := 0.0, finish := Finish.STONE) -> void:
	if group.is_empty():
		group = default_group
	var surface := _surface(group)
	var start: int = vertex_counts[group]
	var vertices: PackedVector3Array = boxes[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = boxes[Mesh.ARRAY_NORMAL]
	var basis := Basis(Vector3.UP, yaw)
	for vertex in vertices.size():
		var normal := basis * normals[vertex]
		surface.set_color(_tint(color, normal))
		surface.set_normal(normal)
		surface.set_uv(Vector2(finish, 0.0))
		surface.add_vertex(center + basis * (vertices[vertex] * size))
	for vertex: int in boxes[Mesh.ARRAY_INDEX]:
		surface.add_index(start + vertex)
	vertex_counts[group] = start + vertices.size()


func _stone_ring(half_width: float, half_depth: float, clip: float, y: float) -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(-half_width + clip, y, -half_depth), Vector3(half_width - clip, y, -half_depth),
		Vector3(half_width, y, -half_depth + clip), Vector3(half_width, y, half_depth - clip),
		Vector3(half_width - clip, y, half_depth), Vector3(-half_width + clip, y, half_depth),
		Vector3(-half_width, y, half_depth - clip), Vector3(-half_width, y, -half_depth + clip),
	])


func _stone_block(center: Vector3, size: Vector3, color: Color, bevel: float, group := "", yaw := 0.0, finish := Finish.STONE) -> void:
	var half := size * 0.5
	var cut := minf(bevel, minf(half.x, minf(half.z, half.y)) * 0.82)
	var foot := _stone_ring(half.x, half.z, cut, -half.y)
	var shoulder := _stone_ring(half.x, half.z, cut, half.y - cut)
	var top := _stone_ring(half.x - cut * 0.68, half.z - cut * 0.68, cut * 0.70, half.y)
	var basis := Basis(Vector3.UP, yaw)
	_face(group, center, basis, top, Vector3.UP, color, finish)
	foot.reverse()
	_face(group, center, basis, foot, Vector3.DOWN, color, finish)
	foot.reverse()
	for index in 8:
		var next := (index + 1) % 8
		var edge := shoulder[next] - shoulder[index]
		var side := Vector3(edge.z, 0, -edge.x).normalized()
		_face(group, center, basis, PackedVector3Array([foot[index], foot[next], shoulder[next], shoulder[index]]), side, color, finish)
		var bevel_normal := (side + Vector3.UP * 0.72).normalized()
		_face(group, center, basis, PackedVector3Array([shoulder[index], shoulder[next], top[next], top[index]]), bevel_normal, color.lightened(0.08), finish)


func _face(group: String, center: Vector3, basis: Basis, points: PackedVector3Array, normal: Vector3, color: Color, finish: Finish) -> void:
	if group.is_empty():
		group = default_group
	var surface := _surface(group)
	var start: int = vertex_counts[group]
	var world_normal := basis * normal
	var tinted := _tint(color, world_normal)
	for point in points:
		surface.set_color(tinted)
		surface.set_normal(world_normal)
		surface.set_uv(Vector2(finish, 0.0))
		surface.add_vertex(center + basis * point)
	var clockwise := (points[1] - points[0]).cross(points[2] - points[0]).dot(normal) < 0.0
	for i in range(1, points.size() - 1):
		surface.add_index(start)
		surface.add_index(start + (i if clockwise else i + 1))
		surface.add_index(start + (i + 1 if clockwise else i))
	vertex_counts[group] = start + points.size()

func _finish(parent: Node3D) -> void:
	var stone_material := ShaderMaterial.new()
	stone_material.shader = STONE_SHADER
	var ember_material := StandardMaterial3D.new()
	ember_material.vertex_color_use_as_albedo = true
	ember_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for key in groups:
		var surface: SurfaceTool = groups[key]
		surface.set_material(ember_material if key in ["Embers", "mine_signal"] else stone_material)
		var part := MeshInstance3D.new()
		part.name = "Stonework" if String(key).is_empty() else key
		part.mesh = surface.commit()
		if not String(key).is_empty():
			part.set_meta("B_assembly", key)
		parent.add_child(part)
	groups.clear()
	vertex_counts.clear()
