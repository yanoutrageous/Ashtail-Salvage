extends Node3D
## Attack visuals consume the combat snapshot, including clipped endpoints.

const Art := preload("res://scripts/presentation/voxel_a1/voxel_enemy_art.gd")
const Dust := preload("res://scripts/presentation/voxel_a1/voxel_hostile_dust.gdshader")
const COLD := Color("#49ddfc")
const AMETHYST := Color("#ba64f3")
const GEL := Color("#91cd52")
const HOT := Color("#ff993d")
const IVORY := Color("#fff0ca")
const GROUND := 0.093

var rng := RandomNumberGenerator.new()
var terrain: Array[Rect2] = []
var bounds := Rect2(-4.88, -4.88, 9.76, 9.76)
var items: Array[Dictionary] = []
var lights: Array[Dictionary] = []
var dust: Array[Dictionary] = []
var scars: Array[Dictionary] = []
var beam_mesh: ArrayMesh
var tip_mesh: ArrayMesh
var spark_mesh: ArrayMesh
var rock_mesh: ArrayMesh


func build() -> void:
	rng.seed = 62371
	beam_mesh = _make_beam()
	tip_mesh = _shape([Vector3(0, 0, -0.52), Vector3(0.43, 0, -0.16), Vector3(0, 0, 0.6)], false)
	spark_mesh = _shape([Vector3(0, 0, -0.55), Vector3(0.44, 0, -0.23), Vector3(0, 0, 0.53)], true)
	rock_mesh = Art.voxel_mass("slag")
	for i in 96:
		var node := MeshInstance3D.new()
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		node.hide()
		items.append({"node": node, "left": -1.0})
	var cloud := QuadMesh.new()
	for i in 18:
		var plume := MeshInstance3D.new()
		plume.mesh = cloud
		plume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := ShaderMaterial.new()
		material.shader = Dust
		plume.material_override = material
		add_child(plume)
		plume.hide()
		dust.append({"node": plume, "left": -1.0})
	for i in 3:
		var light := OmniLight3D.new()
		light.omni_attenuation = 2.0
		light.shadow_enabled = false
		light.light_energy = 0.0
		add_child(light)
		lights.append({"node": light, "left": -1.0})


func clear() -> void:
	for slot: Dictionary in items + dust + lights:
		slot["left"] = -1.0
		(slot["node"] as Node3D).hide()
	for scar in scars:
		(scar["node"] as MeshInstance3D).queue_free()
	scars.clear()


func release(kind: StringName, origin: Vector3, finish: Vector3, heading: Vector3, radius: float, fists: PackedVector3Array, half_angle := PI) -> void:
	match kind:
		&"slam":
			_slam(origin, heading, radius, fists, half_angle)
		&"charge":
			_contact(origin + Vector3.UP * 0.32, heading, HOT, 0.65, 10)
		&"laser":
			_contact(origin, heading, COLD, 0.70, 13)
		&"spread":
			for i in 3:
				var angle := (i - 1) * 0.366
				_contact(origin + heading * 0.21, heading.rotated(Vector3.UP, angle), AMETHYST, 0.45, 4)
			_plume(origin - heading * 0.04, -heading * 0.38, Color("#654882"), 0.82, 0.37, 0.38)
		&"gel_lunge":
			_gel(origin, finish, heading, radius, false)
		&"gel_splash":
			_gel(origin, finish, heading, radius, true)


func laser_view(parent: Node3D) -> Node3D:
	var group := Node3D.new()
	parent.add_child(group)
	var beam := MeshInstance3D.new()
	beam.mesh = beam_mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam.material_override = material
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.add_child(beam)
	for i in 4:
		var glint := MeshInstance3D.new()
		glint.mesh = tip_mesh
		glint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		glint.scale = Vector3(0.22, 0.12, 0.062)
		var glint_material := StandardMaterial3D.new()
		glint_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glint_material.albedo_color = Color("#a1f3ff")
		glint_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		glint.material_override = glint_material
		group.add_child(glint)
	return group


func bolt_view(parent: Node3D) -> Node3D:
	var root := Node3D.new()
	parent.add_child(root)
	for i in 4:
		var bolt := MeshInstance3D.new()
		bolt.mesh = tip_mesh if i == 0 else spark_mesh
		bolt.position.z = -i * 0.19
		bolt.scale = Vector3(0.25, 0.20, 0.49) if i == 0 else Vector3(0.18 - i * 0.037, 0.14 - i * 0.028, 0.24)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color("#f4dbff") if i == 0 else AMETHYST.lerp(Color("#503c88"), float(i) / 5.0)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		bolt.material_override = mat
		bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(bolt)
	return root


func beam_contact(at: Vector3, heading: Vector3, first: bool) -> void:
	if first:
		_contact(at, -heading, COLD, 0.79, 17)
		return
	_emit(spark_mesh, at, -heading * 1.1 + Vector3.UP * rng.randf_range(0.6, 1.35),
		Vector3(0.055, 0.075, 0.38), 0.21, COLD, -heading, true)


func bolt_contact(at: Vector3, heading: Vector3) -> void:
	_contact(at, -heading, AMETHYST, 0.64, 9)
	_plume(at, -heading * 0.36, Color("#9065b4"), 0.54, 0.35, 0.26)


func charge_step(from: Vector3, to: Vector3, facing: Vector3) -> void:
	if from.distance_to(to) > 0.90:
		return
	var side := facing.cross(Vector3.UP)
	for sign_value in [-1.0, 1.0]:
		var spot: Vector3 = from.lerp(to, 0.44) + side * 0.46 * sign_value
		spot.y = GROUND
		if not _walkable(spot):
			continue
		_emit(rock_mesh, spot, -facing * 1.35 + side * sign_value * 0.46 + Vector3.UP * 1.48,
			Vector3(0.21, 0.19, 0.30), 0.48, Color("#827061"), facing, false)
		_emit(spark_mesh, spot + Vector3.UP * 0.1, -facing * 1.6 + Vector3.UP * 0.62,
			Vector3(0.051, 0.062, 0.56), 0.20, HOT, -facing, true)
		_plume(spot, -facing * 0.72, Color("#a37f61"), 0.82, 0.43, 0.48)


func _slam(origin: Vector3, heading: Vector3, radius: float, fists: PackedVector3Array, half_angle: float) -> void:
	var side := heading.cross(Vector3.UP)
	for i in 2:
		var at := fists[i] if i < fists.size() else origin + side * (i * 1.04 - 0.52) + heading * 0.57
		at.y = GROUND
		if not _walkable(at):
			at = origin
		_contact(at + Vector3.UP * 0.08, heading, HOT, 0.83, 13)
	var triangles := SurfaceTool.new()
	triangles.begin(Mesh.PRIMITIVE_TRIANGLES)
	var direction_count := 8
	for i in direction_count:
		var angle := lerpf(-half_angle, half_angle, (float(i) + 0.5) / direction_count)
		angle += rng.randf_range(-0.12, 0.12)
		var forward := heading.rotated(Vector3.UP, angle)
		var reach := radius * rng.randf_range(0.57, 0.98)
		var p := origin.move_toward(origin + forward, 0.12)
		p.y = GROUND + 0.01
		var branch := p
		for j in 4:
			var d := forward.rotated(Vector3.UP, rng.randf_range(-0.30, 0.30))
			var q := _floor_end(p, p + d * reach * (0.19 if j == 0 else 0.28))
			var width := (0.131 - j * 0.031) * rng.randf_range(0.78, 1.36)
			_seam(triangles, p, q, width, HOT)
			if j in [1, 2]:
				branch = q
			if j == 2 and q.distance_to(p) > 0.12:
				var out := d.rotated(Vector3.UP, -0.66 if i % 2 == 1 else 0.62)
				_seam(triangles, branch, _floor_end(branch, branch + (out + d * 0.5) * 0.64), width * 0.47, Color("#c5532d"))
			p = q
		var rubble := _floor_end(origin, origin + forward * reach * rng.randf_range(0.45, 0.85))
		if rubble.distance_to(origin) < 0.19:
			continue
		for j in 2:
			var span := rng.randf_range(0.24, 0.42)
			_emit(rock_mesh, rubble - forward * j * 0.17, forward * rng.randf_range(0.4, 1.45) + Vector3.UP * rng.randf_range(2.95, 4.6),
				Vector3(span * 1.12, span * 1.38, span * 1.29), rng.randf_range(0.41, 0.65), Color("#a37853").lerp(Color("#bca181"), rng.randf()), forward, false, j * 0.041 + reach * 0.012)
		_plume(rubble, forward * 0.93, Color("#a87b58"), 1.46, 0.61, 0.59)
	var mesh := triangles.commit()
	if mesh != null:
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.vertex_color_use_as_albedo = true
		node.material_override = mat
		add_child(node)
		scars.append({"node": node, "left": 0.77})
	_lamp(origin + Vector3.UP * 0.32, HOT, 3.35, 3.6, 0.24)


func _gel(origin: Vector3, finish: Vector3, heading: Vector3, radius: float, splash: bool) -> void:
	var center := origin if splash else finish
	var n := 15 if splash else 12
	for i in n:
		var angle := TAU * i / n if splash else rng.randf_range(-1.13, 1.13)
		var direction := heading.rotated(Vector3.UP, angle)
		var start := _floor_end(center, center + direction * minf(radius * 0.44, 0.82))
		var size := rng.randf_range(0.11, 0.27)
		_emit(tip_mesh, start, direction * rng.randf_range(0.8, 2.4) + Vector3.UP * rng.randf_range(1.28, 3.25),
			Vector3(size, size * 1.55, size * 0.69), rng.randf_range(0.28, 0.53),
			GEL.lerp(Color("#d8f4aa"), rng.randf()), direction + Vector3.UP * 0.08, false)
		if i % 3 == 0:
			_plume(start, direction * 0.65, Color("#718841"), 1.17, 0.44, 0.44)
	_contact(center + Vector3.UP * 0.17, heading, GEL, 0.60, 8)


func _contact(at: Vector3, heading: Vector3, color: Color, size: float, count: int) -> void:
	_emit(tip_mesh, at, Vector3.ZERO, Vector3(0.27, 0.29, 0.62) * size, 0.11, IVORY.lerp(color, 0.24), heading, true)
	for i in count:
		var d := heading.rotated(Vector3.UP, rng.randf_range(-1.6, 1.6) + (PI if i % 4 == 0 else 0.0))
		var rise := rng.randf_range(0.38, 1.65)
		var v := (d + Vector3.UP * rise).normalized()
		var length := rng.randf_range(0.25, 0.88) * size
		_emit(spark_mesh, at + v * 0.11, v * rng.randf_range(1.8, 4.9), Vector3(length * 0.21, length * 0.17, length),
			rng.randf_range(0.11, 0.27), color.lerp(IVORY, 0.64 if i % 3 == 0 else 0.15), v, true)
	_lamp(at + Vector3.UP * 0.13, color, 0.71 + size * 1.6, 1.3 + size, 0.143)


func _seam(s: SurfaceTool, a: Vector3, b: Vector3, width: float, color: Color) -> void:
	var d := (b - a).cross(Vector3.UP).normalized() * width
	for row in [[d * 1.25, Color("#2e1d18", 0.83)], [d * 0.79, Color(color, 0.88)], [d * 0.24, Color(IVORY.lerp(color, 0.27), 1.0)]]:
		var side: Vector3 = row[0]
		var height := Vector3.UP * (0.0025 if side.length() >= d.length() else 0.004 + (1.0 - side.length() / maxf(0.001, d.length())) * 0.009)
		_face(s, [a - side + height, a + side + height, b + side * 0.39 + height, a - side + height, b + side * 0.39 + height, b - side * 0.39 + height], row[1])


func _walkable(at: Vector3) -> bool:
	var p := Vector2(at.x, at.z)
	if not bounds.has_point(p):
		return false
	for obstacle in terrain:
		if obstacle.has_point(p):
			return false
	return true


func _floor_end(from: Vector3, to: Vector3) -> Vector3:
	var result := from
	for i in range(1, 13):
		var point := from.lerp(to, i / 12.0)
		if not _walkable(point):
			break
		result = point
	return result


func _pick(pool: Array[Dictionary]) -> Dictionary:
	var slot := pool[0]
	for row in pool:
		if float(row["left"]) <= 0.0:
			return row
		if float(row["left"]) < float(slot["left"]):
			slot = row
	return slot


func _emit(mesh: ArrayMesh, at: Vector3, velocity: Vector3, dims: Vector3, life: float, tint: Color, along: Vector3, luminous: bool, delay := 0.0) -> void:
	var slot := _pick(items)
	var n := slot["node"] as MeshInstance3D
	n.mesh = mesh
	n.position = at
	n.scale = Vector3.ONE
	var up := Vector3.RIGHT if absf(along.normalized().dot(Vector3.UP)) > 0.94 else Vector3.UP
	n.look_at(at + along, up, true)
	n.scale = dims
	var mat := n.material_override as StandardMaterial3D
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if luminous else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.albedo_color = tint
	n.visible = delay <= 0.0
	slot.merge({"left": life + delay, "life": life, "at": at, "v": velocity, "size": dims, "color": tint, "lit": luminous}, true)


func _plume(at: Vector3, velocity: Vector3, tint: Color, width: float, height: float, life: float) -> void:
	var slot := _pick(dust)
	var n := slot["node"] as MeshInstance3D
	var material := n.material_override as ShaderMaterial
	material.set_shader_parameter("dust_color", Color(tint, 0.51))
	material.set_shader_parameter("seed", rng.randf_range(0.0, 17.0))
	material.set_shader_parameter("progress", 0.0)
	n.position = at + Vector3.UP * height * 0.32
	n.scale = Vector3(width, height, 1.0)
	n.show()
	slot.merge({"left": life, "life": life, "at": n.position, "v": velocity, "size": n.scale}, true)


func _lamp(at: Vector3, tint: Color, energy: float, reach: float, life: float) -> void:
	var slot := _pick(lights)
	var light := slot["node"] as OmniLight3D
	light.position = at
	light.light_color = tint
	light.omni_range = reach
	light.light_energy = energy
	light.show()
	slot.merge({"left": life, "life": life, "energy": energy}, true)


func step(delta: float, camera: Camera3D) -> bool:
	var drawing := false
	for slot in items:
		if float(slot["left"]) <= 0.0:
			continue
		slot["left"] = float(slot["left"]) - delta
		var n := slot["node"] as MeshInstance3D
		var age := float(slot["life"]) - float(slot["left"])
		n.visible = age >= 0.0 and float(slot["left"]) > 0.0
		if not n.visible:
			continue
		drawing = true
		var u := age / float(slot["life"])
		var v: Vector3 = slot["v"]
		var p: Vector3 = slot["at"] + v * age
		if not bool(slot["lit"]):
			p.y = maxf(GROUND, p.y - age * age * 5.3)
			n.rotate_x(delta * 4.7)
		n.position = p
		n.scale = (slot["size"] as Vector3) * (1.0 - smoothstep(0.26, 1.0, u) * 0.55)
		var tint: Color = slot["color"]
		(n.material_override as StandardMaterial3D).albedo_color = Color(tint, 1.0 - smoothstep(0.39, 1.0, u))
	for slot in dust:
		if float(slot["left"]) <= 0.0:
			continue
		slot["left"] = float(slot["left"]) - delta
		var plume := slot["node"] as MeshInstance3D
		plume.visible = float(slot["left"]) > 0.0
		if plume.visible:
			drawing = true
			var age := float(slot["life"]) - float(slot["left"])
			plume.position = slot["at"] + (slot["v"] as Vector3) * age + Vector3.UP * age * 0.24
			plume.basis = camera.basis
			plume.scale = (slot["size"] as Vector3) * (1.0 + 1.38 * age)
			(plume.material_override as ShaderMaterial).set_shader_parameter("progress", age / float(slot["life"]))
	for slot in lights:
		if float(slot["left"]) <= 0.0:
			continue
		slot["left"] = float(slot["left"]) - delta
		var light := slot["node"] as OmniLight3D
		light.light_energy = float(slot["energy"]) * pow(maxf(0.0, float(slot["left"])) / float(slot["life"]), 2.0)
		light.visible = float(slot["left"]) > 0.0
	for i in range(scars.size() - 1, -1, -1):
		var scar := scars[i]
		scar["left"] = float(scar["left"]) - delta
		var mesh := scar["node"] as MeshInstance3D
		if float(scar["left"]) <= 0.0:
			mesh.hide()
			mesh.queue_free()
			scars.remove_at(i)
		else:
			drawing = true
			(mesh.material_override as StandardMaterial3D).albedo_color = Color(1, 1, 1, minf(1.0, float(scar["left"]) * 2.2))
	return drawing


func _shape(profile: Array, flare: bool) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_smooth_group(-1)
	var a: Vector3 = profile[0]
	var b: Vector3 = profile[1]
	var c: Vector3 = profile[2]
	var rim := [b, Vector3(0, 0.51 if flare else 0.38, b.z), b * Vector3(-1, 1, 1), Vector3(0, -0.44, b.z)]
	var tones := [Color.WHITE, Color("#b3bbc9"), Color("#798a9c"), Color("#d3d8e4")]
	for i in 4:
		var next := (i + 1) % 4
		_face(surface, [a, rim[i], rim[next], c, rim[next], rim[i]], tones[i])
	surface.generate_normals()
	return surface.commit()


func _make_beam() -> ArrayMesh:
	var s := SurfaceTool.new()
	s.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 13:
		var t := float(i) / 13.0
		var u := float(i + 1) / 13.0
		var span := 0.070 if i in [0, 12] else 0.094 + 0.035 * absf(sin(i * 2.399))
		var k := span * (1.65 if i % 3 == 0 else 1.38)
		var core := 0.023 + float(i % 2) * 0.009
		for face_index in 4:
			var a := TAU * face_index / 4.0
			var b := a + TAU / 4.0
			var offset_a := Vector3(cos(a), sin(a), 0)
			var offset_b := Vector3(cos(b), sin(b), 0)
			var p := Vector3(0, 0, t)
			var q := Vector3(0, 0, (u + t) * 0.50)
			var r := Vector3(0, 0, u)
			var shell := Color(COLD.lerp(Color("#2087bf"), 0.33 + 0.14 * (face_index % 3)), 0.67)
			_face(s, [p + offset_a * span, q + offset_a * k, q + offset_b * k, p + offset_a * span, q + offset_b * k, p + offset_b * span], shell)
			_face(s, [q + offset_a * k, r + offset_a * span, r + offset_b * span, q + offset_a * k, r + offset_b * span, q + offset_b * k], shell.lightened(0.18))
			_face(s, [p + offset_a * core, r + offset_a * core, r + offset_b * core, p + offset_a * core, r + offset_b * core, p + offset_b * core], Color("#e5faff"))
	return s.commit()


func _face(s: SurfaceTool, points: Array, tint: Color) -> void:
	s.set_color(tint)
	for point: Vector3 in points:
		s.add_vertex(point)
