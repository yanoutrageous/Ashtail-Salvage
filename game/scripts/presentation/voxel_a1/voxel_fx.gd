extends Node3D
## A trail section is a diamond cross-section following the real blade in world space.

const TTL := 0.15
const SECTIONS := 19
var clock := 0.0
var samples: Array[Dictionary] = []
var trails: Array[MeshInstance3D] = []
var pools: Dictionary = {}
var rng := RandomNumberGenerator.new()
var flash: OmniLight3D
var flash_until := -1.0
var voices: Dictionary = {}
var trail_style := 0


func build() -> void:
	rng.seed = 71923
	_build_contacts()
	var tint := _material(Color.WHITE)
	tint.vertex_color_use_as_albedo = true
	for _i in 2:
		var layer := MeshInstance3D.new()
		layer.mesh = ImmediateMesh.new()
		layer.material_override = tint
		layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(layer)
		trails.append(layer)
	var voxel := BoxMesh.new()
	var shard := _wedge()
	for spec in [["stone", 46, voxel], ["shell", 8, voxel], ["spark", 32, shard], ["wind", 20, shard], ["beam", 12, voxel], ["smoke", 16, voxel]]:
		var pool: Array[Dictionary] = []
		for _i in int(spec[1]):
			var n := MeshInstance3D.new()
			n.mesh = spec[2]
			var material := _material(Color.WHITE)
			if spec[0] == "shell":
				material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
				material.metallic = 0.64
				material.roughness = 0.35
			n.material_override = material
			n.visible = false
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(n)
			pool.append({"node": n})
		pools[spec[0]] = pool
	flash = OmniLight3D.new()
	flash.light_color = Color("#ffbe73")
	flash.omni_range = 2.2
	flash.light_energy = 0.0
	add_child(flash)


func trace(edge: PackedVector3Array, variation: int = 0) -> void:
	trail_style = clampi(variation, 0, 2)
	if edge.size() < 5:
		return
	var lip := edge[1].lerp(edge[2], 0.32)
	if not samples.is_empty() and lip.distance_squared_to(samples.back()["lip"]) < 0.0001:
		return
	samples.append({"t": clock, "lip": lip, "heel": edge[4]})


func prime_render_pipeline() -> void:
	samples.append({"t": clock, "lip": Vector3(-0.64, 0.83, 0.15), "heel": Vector3(-0.40, 0.68, -0.25)})
	samples.append({"t": clock, "lip": Vector3(0.28, 0.84, 0.42), "heel": Vector3(0.18, 0.68, -0.05)})
	_emit("spark", Vector3(0.6, 0.46, 0.4), Vector3.RIGHT, Vector3(0.22, 0.08, 0.12), 0.10, Color.WHITE)
	_emit("stone", Vector3(-0.4, 0.14, 0.2), Vector3.RIGHT, Vector3.ONE * 0.12, 0.10, Color.WHITE)
	step(0.0)


func impact(point: Vector3, heading: Vector3, accent: Color = Color("#eda760"), surface: StringName = &"body") -> void:
	var armored := surface == &"armor"
	var gel := surface == &"gel"
	_cue("metal_hit" if armored else ("gel_hit" if gel else "hit"))
	var front := heading.normalized()
	var spark_color := accent.lerp(Color("#fff0ce"), 0.38) if armored else accent
	var natural := Color("#88c55a") if gel else Color("#ab7360")
	if armored:
		var crest := _emit("spark", point, Vector3.ZERO, Vector3(0.31, 0.12, 0.13), 0.079, Color("#fff0c4"))
		if crest != null:
			crest.rotation.y = atan2(-front.z, front.x)
	for i in (11 if armored else 5):
		var sweep := rng.randf_range(-1.52, 1.52)
		var direction := (front.rotated(Vector3.UP, sweep) + Vector3.UP * rng.randf_range(0.23, 0.89)).normalized()
		var length := rng.randf_range(0.28, 0.51) if armored else rng.randf_range(0.12, 0.23)
		_emit("spark", point + direction * 0.044, direction * (4.5 if armored else 1.8),
			Vector3(length, 0.055 if armored else 0.081, 0.050), 0.11 if armored else 0.082,
			spark_color if armored else natural.lerp(accent, 0.35 if i % 2 == 0 else 0.19))
	for i in (12 if armored else 8):
		var direction := front.rotated(Vector3.UP, rng.randf_range(-1.45, 1.45))
		var size := rng.randf_range(0.036, 0.084)
		var vel := direction * rng.randf_range(0.8, 2.4) + Vector3.UP * rng.randf_range(0.45, 1.8)
		var pigment := [Color("#556673"), Color("#9ca8aa"), Color("#bc834e")][i % 3] as Color if armored else natural.darkened(rng.randf_range(0.0, 0.34))
		_emit("stone", point, vel, Vector3(1.4, 0.82, 0.7) * size, rng.randf_range(0.19, 0.32), pigment)


func shot(muzzle: Vector3, port: Vector3, endpoints: PackedVector3Array, heading: Vector3, scatter: bool, skill: StringName = &"") -> void:
	_cue("scatter" if scatter else "rifle")
	var hot := Color("#ffe0a4") if scatter else Color("#d1f5fa")
	var warm := Color("#cb743a") if scatter else Color("#6db9d6")
	var empowered := skill != &""
	if empowered:
		hot = Color("#fff2c5") if scatter else Color("#b3fff5")
		warm = Color("#f9954f") if scatter else Color("#3cb4b5")
	var side := Vector3.UP.cross(heading)
	flash.position = muzzle
	flash.light_color = Color("#ffc77f") if scatter else Color("#a2d9ea")
	flash.light_energy = 1.14 if empowered else (0.92 if scatter else 0.66)
	flash_until = clock + 0.07
	for i in (6 if scatter else 4):
		var direction := (heading + Vector3.UP * rng.randf_range(-0.47, 0.45) + side * rng.randf_range(-0.52, 0.52)).normalized()
		_emit("spark", muzzle + direction * 0.07, direction * 2.9, Vector3(rng.randf_range(0.27, 0.48), 0.09, 0.095), 0.075, hot if i % 2 == 0 else warm)
	for end in endpoints:
		var span := end - muzzle
		if span.dot(heading) <= 0.06:
			continue
		var thickness := (0.055 if scatter else 0.092) if empowered else 0.025
		var lifetime := (0.125 if scatter else 0.16) if empowered else (0.095 if scatter else 0.13)
		var beam := _emit("beam", (muzzle + end) * 0.5, Vector3.ZERO, Vector3(span.length(), thickness, thickness), lifetime, Color(hot, 0.90))
		if beam != null:
			beam.rotation.y = atan2(-span.z, span.x)
			beam.rotation.z = atan2(span.y, Vector2(span.x, span.z).length())
	for i in (5 if scatter else 3):
		_emit("smoke", muzzle + heading * (0.05 + i * 0.07), Vector3.UP * 0.63 + heading * 0.63, Vector3.ONE * (0.09 + i * 0.023), 0.24 + i * 0.029, Color(0.54, 0.48, 0.38, 0.34))
	_emit("shell", port, -side * 2.15 + Vector3.UP * 1.45, Vector3(0.093, 0.038, 0.042), 0.43, Color("#b89049"))


func obstruction_hit(point: Vector3, outward: Vector3) -> void:
	for i in 5:
		var direction := (outward.rotated(Vector3.UP, rng.randf_range(-0.68, 0.68)) + Vector3.UP * rng.randf_range(0.25, 0.85)).normalized()
		var tint := Color("#c6b89b") if i % 3 == 0 else Color("#877b66")
		_emit("spark", point, direction * rng.randf_range(1.35, 2.15), Vector3(0.14, 0.038, 0.04), 0.088, tint)
	_emit("smoke", point + outward * 0.05, outward * 0.33 + Vector3.UP * 0.44,
		Vector3(0.132, 0.102, 0.126), 0.18, Color(0.54, 0.49, 0.42, 0.28))


func monster_cue(slam: bool) -> void:
	_cue("slam" if slam else "surge")


func _build_contacts() -> void:
	# Short synthesized transients keep the playable scene self-contained.
	var specs := {
		"hit": [0.102, 114.0, 0.52, -18.0],
		"metal_hit": [0.135, 184.0, 0.53, -17.5],
		"gel_hit": [0.117, 96.0, 0.25, -20.0],
		"rifle": [0.125, 168.0, 0.76, -14.0],
		"scatter": [0.197, 81.0, 0.85, -12.5], "slam": [0.29, 57.0, 0.53, -12.0],
		"surge": [0.14, 182.0, 0.49, -22.0], "chest": [0.23, 410.0, 0.12, -22.0],
	}
	for key in specs:
		var spec: Array = specs[key]
		var sound := AudioStreamWAV.new()
		sound.format = AudioStreamWAV.FORMAT_16_BITS
		sound.mix_rate = 22050
		var data := PackedByteArray()
		var length := roundi(float(spec[0]) * sound.mix_rate)
		data.resize(length * 2)
		var random := RandomNumberGenerator.new()
		random.seed = 2781 + String(key).hash()
		var noise := 0.0
		for i in length:
			var t := float(i) / sound.mix_rate
			var u := float(i) / length
			noise = lerpf(noise, random.randf_range(-1.0, 1.0), 0.56)
			var thud := sin(TAU * float(spec[1]) * t * (1.0 - 0.38 * u))
			var transient := lerpf(thud, noise, float(spec[2])) * exp(-6.2 * u) * minf(1.0, i / 27.0)
			data.encode_s16(i * 2, roundi(transient * 30000.0))
		sound.data = data
		var voice := AudioStreamPlayer.new()
		voice.stream = sound
		voice.max_polyphony = 2
		voice.volume_db = float(spec[3])
		add_child(voice)
		voices[key] = voice


func _cue(key: String) -> void:
	(voices[key] as AudioStreamPlayer).play()


func chest_burst(point: Vector3, tier: int) -> void:
	_cue("chest")
	var accent := Color("#ffdda1") if tier < 3 else Color("#c6c0f9")
	flash.position = point + Vector3.UP * 0.35
	flash.light_energy = 0.66
	flash_until = clock + 0.14
	for i in (18 if tier == 3 else 11):
		var d := Vector3(cos(i * 2.4), rng.randf_range(0.45, 0.95), sin(i * 2.4)).normalized()
		_emit("spark", point, d * rng.randf_range(0.8, 2.0), Vector3(rng.randf_range(0.095, 0.25), 0.041, 0.064), rng.randf_range(0.32, 0.65), accent)


func footstep(point: Vector3, heading: Vector3, burst: bool) -> void:
	var cross := Vector3.UP.cross(heading)
	for i in (5 if burst else 2):
		var p := point - heading * rng.randf_range(0.06, 0.31) + cross * rng.randf_range(-0.37, 0.37)
		p.y = rng.randf_range(0.07, 0.13)
		var direction := -heading.rotated(Vector3.UP, rng.randf_range(-0.27, 0.27))
		_emit("wind", p, direction * rng.randf_range(1.5, 2.8), Vector3(rng.randf_range(0.42, 0.85), 0.035, 0.085), rng.randf_range(0.18, 0.28), Color(0.76, 0.65, 0.47, 0.53))
	for _i in (7 if burst else 4):
		var p := point + cross * rng.randf_range(-0.40, 0.40)
		p.y = 0.075
		var vel := -heading.rotated(Vector3.UP, rng.randf_range(-0.65, 0.65)) * rng.randf_range(0.8, 2.4) + Vector3.UP * rng.randf_range(0.4, 1.1)
		_emit("stone", p, vel, Vector3(0.072, 0.045, 0.064), rng.randf_range(0.20, 0.31), Color("#9f8564"))


func clear() -> void:
	samples.clear()
	if flash != null:
		flash.light_energy = 0.0
	for t in trails:
		t.visible = false
	for pool in pools.values():
		for item in pool:
			item["node"].visible = false


func step(delta: float) -> bool:
	clock += delta
	flash.light_energy = move_toward(flash.light_energy, 0.0, delta * (8.0 if clock > flash_until else 2.0))
	while not samples.is_empty() and clock - float(samples.front()["t"]) > TTL:
		samples.pop_front()
	var drawing := samples.size() > 1
	for i in trails.size():
		var t := trails[i]
		t.visible = drawing
		if t.visible:
			_make_trail(t.mesh as ImmediateMesh, i)
	for key in pools:
		for item in pools[key]:
			var n := item["node"] as MeshInstance3D
			if not n.visible:
				continue
			var age := clock - float(item["at"])
			var u := age / float(item["life"])
			if u >= 1.0:
				n.visible = false
				continue
			drawing = true
			var velocity: Vector3 = item["vel"]
			var start: Vector3 = item["pos"]
			var p := start + velocity * age
			if key in ["stone", "shell"]:
				p.y = maxf(0.06, p.y - 4.7 * age * age)
				n.rotate_z(delta * 8.0)
			n.position = p
			n.scale = (item["size"] as Vector3) * (1.0 + 1.6 * u if key == "smoke" else (1.0 if key == "beam" else 1.0 - 0.54 * u))
			var color: Color = item["color"]
			color.a *= 1.0 - smoothstep(0.24, 1.0, u)
			(n.material_override as StandardMaterial3D).albedo_color = color
	return drawing


func _make_trail(mesh: ImmediateMesh, layer: int) -> void:
	var rings: Array[PackedVector3Array] = []
	var shades: Array[PackedColorArray] = []
	for i in SECTIONS:
		var u := float(i) / float(SECTIONS - 1)
		var f := u * float(samples.size() - 1)
		var a := samples[int(f)]
		var b := samples[mini(samples.size() - 1, int(f) + 1)]
		var p := (a["lip"] as Vector3).lerp(b["lip"], fposmod(f, 1.0))
		var heel := (a["heel"] as Vector3).lerp(b["heel"], fposmod(f, 1.0))
		var inward := heel - p
		inward.y *= 0.50
		inward = inward.normalized()
		var taper := pow(maxf(0.0, sin(PI * u)), 0.73)
		var width := (0.016 + 0.51 * taper) * (1.0 + 0.16 * sin(i * 2.8) + 0.08 * cos(i * 1.51))
		var fade := 1.0 - smoothstep(0.015, TTL, clock - lerpf(float(a["t"]), float(b["t"]), fposmod(f, 1.0)))
		width *= 0.62 + 0.38 * fade
		var center := p + inward * width * (0.49 if layer == 0 else 0.28)
		center.y += 0.037 if layer == 1 else 0.0
		var half_width := width * (0.64 if layer == 0 else 0.23)
		var ridge := Vector3.UP * (0.012 + 0.055 * taper)
		rings.append(PackedVector3Array([center - inward * half_width, center + ridge, center + inward * half_width, center - ridge]))
		var ember: Color = [Color("#a34e2a"), Color("#bb7839"), Color("#995747")][trail_style]
		var edge: Color = [Color("#f0b475"), Color("#efd39b"), Color("#f7d5a0")][trail_style]
		var color_a := ember if layer == 0 else edge
		var color_b := edge if layer == 0 else Color("#fff0cc")
		var colors := PackedColorArray()
		for j in 4:
			var color := color_a.lerp(color_b, [0.66, 1.0, 0.44, 0.28][j])
			color.a = fade * (0.70 + 0.30 * taper)
			colors.append(color)
		shades.append(colors)
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SECTIONS - 1:
		for j in 4:
			var k := (j + 1) % 4
			for v in [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i, k), Vector2i(i, k), Vector2i(i + 1, j), Vector2i(i + 1, k)]:
				mesh.surface_set_color(shades[v.x][v.y])
				mesh.surface_add_vertex(rings[v.x][v.y])
	mesh.surface_end()


func _emit(key: String, p: Vector3, vel: Vector3, size: Vector3, life: float, color: Color) -> MeshInstance3D:
	for item in pools[key]:
		var n := item["node"] as MeshInstance3D
		if n.visible:
			continue
		item.merge({"pos": p, "vel": vel, "at": clock, "size": size, "color": color, "life": life}, true)
		n.position = p
		n.rotation = Vector3(0.0, atan2(-vel.z, vel.x), rng.randf_range(-0.52, 0.52) if key in ["stone", "shell"] else 0.0)
		n.scale = size
		(n.material_override as StandardMaterial3D).albedo_color = color
		n.visible = true
		return n
	return null


func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = color
	return m


func _wedge() -> ArrayMesh:
	var s := SurfaceTool.new()
	s.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p := [Vector3(0.75, 0, 0), Vector3(-0.6, 0, -0.5), Vector3(-0.6, 0, 0.5), Vector3(-0.28, 0.45, 0), Vector3(-0.28, -0.38, 0)]
	for i in [0, 1, 3, 1, 2, 3, 2, 0, 3, 1, 0, 4, 2, 1, 4, 0, 2, 4]:
		s.add_vertex(p[i])
	s.generate_normals()
	return s.commit()
