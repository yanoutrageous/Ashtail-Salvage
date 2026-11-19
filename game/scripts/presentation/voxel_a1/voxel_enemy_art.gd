extends RefCounted
## Faceted bodies, wings and ground markers use the same units as the encounter.

const WORN_METAL := preload("res://scripts/presentation/voxel_a1/voxel_worn_metal.gdshader")

const TEAL := Color("#57c2b0")
const VIOLET := Color("#a286e0")
const BLUE := Color("#6ec6e4")
const AMBER := Color("#ed9b57")
const RUST := Color("#d7654d")
const IRON := Color("#3c4855")
const STEEL := Color("#71818b")
const COPPER := Color("#ad7148")
const DARK := Color("#241e23")
static var bevel_mesh: ArrayMesh
static var masses: Dictionary = {}
static var materials: Dictionary



static func faceted(parent: Node3D, at: Vector3, dimensions: Vector3, color: Color, shape: String = "gem", luminous: bool = false) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = voxel_mass(shape)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.72
	mat.vertex_color_use_as_albedo = true
	if luminous:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	node.material_override = mat
	node.position = at
	node.scale = dimensions
	parent.add_child(node)
	return node


static func wing(parent: Node3D, side: float) -> void:
	var vertices := [
		Vector3.ZERO, Vector3(0.29, 0.12, -0.08), Vector3(0.60, 0.23, -0.20),
		Vector3(0.84, 0.08, -0.32), Vector3(0.57, -0.11, -0.44),
		Vector3(0.44, -0.04, -0.26), Vector3(0.29, -0.17, -0.44),
		Vector3(0.20, -0.09, -0.21), Vector3(0.02, -0.14, -0.19),
	]
	var indices := [0, 1, 7, 1, 2, 5, 2, 3, 4, 2, 4, 5, 1, 5, 7, 5, 6, 7, 0, 7, 8]
	var cloth := [Color("#794575"), Color("#663658"), Color("#985497"), Color("#592b50"), Color("#a05e9d"), Color("#7d447b"), Color("#422941")]
	var grid := 0.047
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row in 11:
		for col in 19:
			var x := (float(col) + 0.5) * grid
			var z := -(float(row) + 0.5) * grid
			var point := Vector2(x, z)
			for i in range(0, indices.size(), 3):
				var a: Vector3 = vertices[indices[i]]
				var b: Vector3 = vertices[indices[i + 1]]
				var c: Vector3 = vertices[indices[i + 2]]
				var basis := Transform2D(Vector2(b.x - a.x, b.z - a.z), Vector2(c.x - a.x, c.z - a.z), Vector2(a.x, a.z))
				if absf(basis.determinant()) < 0.00005:
					continue
				var uv := basis.affine_inverse() * point
				if uv.x < 0.0 or uv.y < 0.0 or uv.x + uv.y > 1.0:
					continue
				var y := snappedf(a.y + uv.x * (b.y - a.y) + uv.y * (c.y - a.y), 0.033)
				var center := Vector3(x * side, y, z)
				var shade: Color = cloth[i / 3]
				shade = shade.lightened(0.045) if (col * 5 + row * 3) % 12 < 3 else shade
				_box_faces(surface, center, Vector3(grid, 0.045, grid), shade)
				break
	var mesh := MeshInstance3D.new()
	mesh.mesh = surface.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.roughness = 0.69
	mat.metallic_specular = 0.28
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mat
	parent.add_child(mesh)
	for joints in [[0, 1], [1, 2], [2, 3], [2, 4], [1, 5], [1, 6], [0, 7], [0, 8]]:
		var a: Vector3 = vertices[joints[0]] * Vector3(side, 1, 1)
		var b: Vector3 = vertices[joints[1]] * Vector3(side, 1, 1)
		var spar := faceted(parent, (a + b) * 0.5, Vector3(0.045, 0.052, a.distance_to(b) + 0.055), Color("#5f3e65"))
		spar.look_at(parent.to_global(b), Vector3.UP)


static func marker(parent: Node3D, tone: Color) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = tone
	n.material_override = mat
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.position.y = 0.116
	parent.add_child(n)
	n.hide()
	return n


static func broken_edge(mesh: ImmediateMesh, at: Vector3, radius: float, opacity: float, bias: float = 0.0) -> void:
	for i in 18:
		var angle := TAU * i / 18.0 + bias
		var next := angle + (0.19 if i % 3 == 0 else 0.12)
		var p := at + Vector3(cos(angle), 0, sin(angle)) * radius
		var q := at + Vector3(cos(next), 0, sin(next)) * radius
		var tooth := at + Vector3(cos((angle + next) * 0.5), 0, sin((angle + next) * 0.5)) * radius * 0.91
		tri(mesh, p, tooth, q, opacity)


static func ground_streaks(mesh: ImmediateMesh, a: Vector3, b: Vector3, radius: float, progress: float, heavy: bool) -> void:
	var length := a.distance_to(b)
	if length < 0.020:
		broken_edge(mesh, a, radius, 0.82)
		return
	var forward := (b - a) / length
	var side := forward.cross(Vector3.UP)
	var intervals := clampi(ceili(length * 1.85), 3, 13)
	for i in intervals:
		var t := (float(i) + 0.33) / float(intervals)
		var at := a.lerp(b, t)
		var wide := side * radius
		var fade := 0.37 + 0.53 * smoothstep(t - 0.34, t + 0.03, progress)
		var tip := at + forward * minf(0.19 + radius * 0.20, length * 0.12)
		var notch := at - forward * minf(0.053, length * 0.04)
		if heavy:
			tri(mesh, at - wide * 0.52, tip, notch, fade * 0.9)
			tri(mesh, notch, tip, at + wide * 0.52, fade)
		else:
			tri(mesh, at - wide * 0.13, tip, at + wide * 0.13, fade)
		for sign_value in [-1.0, 1.0]:
			var scratch: Vector3 = at + side * sign_value * radius
			tri(mesh, scratch, scratch - side * sign_value * minf(0.084, radius * 0.3) - forward * 0.045,
				scratch + forward * minf(0.11, length * 0.08), 0.46 + 0.31 * progress)


static func tri(mesh: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3, opacity: float) -> void:
	mesh.surface_set_color(Color(1, 1, 1, opacity))
	mesh.surface_add_vertex(a)
	mesh.surface_add_vertex(b)
	mesh.surface_add_vertex(c)


static func armor(parent: Node3D, at: Vector3, size: Vector3, color: Color, rough := 0.65, metal := true) -> MeshInstance3D:
	if bevel_mesh == null:
		bevel_mesh = voxel_mass("armor")
	var part := MeshInstance3D.new()
	part.mesh = bevel_mesh
	var key := [color, rough, metal]
	if not materials.has(key):
		if metal:
			var material := ShaderMaterial.new()
			material.shader = WORN_METAL
			material.set_shader_parameter("base_tone", color)
			material.set_shader_parameter("base_roughness", rough)
			materials[key] = material
		else:
			var material := StandardMaterial3D.new()
			material.albedo_color = color
			material.roughness = rough
			material.vertex_color_use_as_albedo = true
			materials[key] = material
	part.material_override = materials[key]
	part.position = at
	part.scale = size
	parent.add_child(part)
	return part


static func voxel_mass(shape: String) -> ArrayMesh:
	if masses.has(shape):
		return masses[shape]
	const SIDES := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]
	var divisions := Vector3i(8, 7, 8)
	var pitch := Vector3.ONE / Vector3(divisions)
	var cells := {}
	for z in divisions.z:
		for y in divisions.y:
			for x in divisions.x:
				var index := Vector3i(x, y, z)
				var center := (Vector3(index) + Vector3.ONE * 0.5) * pitch - Vector3.ONE * 0.5
				if _inside(center * 2.0, shape):
					cells[index] = center
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index: Vector3i in cells:
		var center: Vector3 = cells[index]
		for direction: Vector3i in SIDES:
			if not cells.has(index + direction):
				_block_face(surface, center, pitch, Vector3(direction), Color.WHITE)
	var mesh := surface.commit()
	masses[shape] = mesh
	return mesh


static func _inside(p: Vector3, shape: String) -> bool:
	var f := p.abs()
	match shape:
		"armor":
			return f.x + f.z < (1.74 if f.y < 0.70 else 1.40) and (f.y < 0.80 or maxf(f.x, f.z) < 0.80)
		"plate":
			return f.x + f.z < (1.55 if p.y < 0.50 else 1.22)
		"slag":
			return f.z * 0.80 + f.y * 0.85 + absf(p.x - p.y * 0.29) * 0.60 < 1.46 and p.y < 0.84 - p.z * 0.31
		_:
			return p.length_squared() < 1.25 and f.x + f.y + f.z < 2.12


static func _box_faces(surface: SurfaceTool, at: Vector3, size: Vector3, pigment: Color) -> void:
	for normal in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]:
		_block_face(surface, at, size, normal, pigment)


static func _block_face(surface: SurfaceTool, at: Vector3, size: Vector3, normal: Vector3, color: Color) -> void:
	var pole := Vector3.RIGHT if absf(normal.y) > 0.5 else Vector3.UP
	var u := pole * size * 0.5
	var v := normal.cross(pole) * size * 0.5
	var c := at + normal * size * 0.5
	var shade := 1.0 if normal.y > 0.5 else (0.76 if normal.y < -0.5 else (0.92 + 0.043 * (normal.x - normal.z)))
	var corners := [c - u - v, c - u + v, c + u + v, c + u - v]
	for i in [0, 1, 2, 0, 2, 3]:
		surface.set_normal(normal)
		surface.set_color(color.darkened(1.0 - shade))
		surface.add_vertex(corners[i])


static func drone_parts(body: Node3D, rotor: Node3D) -> MeshInstance3D:
	armor(body, Vector3(0, 0.27, 0.0), Vector3(0.92, 0.50, 0.75), IRON)
	armor(body, Vector3(0, 0.50, -0.045), Vector3(0.77, 0.15, 0.58), STEEL)
	armor(body, Vector3(0, 0.28, 0.36), Vector3(0.58, 0.43, 0.16), COPPER)
	armor(body, Vector3(0, 0.28, 0.445), Vector3(0.44, 0.31, 0.10), DARK)
	armor(body, Vector3(0, 0.28, 0.49), Vector3(0.29, 0.22, 0.067), Color("#416a7e"))
	var lens := faceted(body, Vector3(0, 0.28, 0.532), Vector3(0.177, 0.139, 0.055), Color("#7adceb"), "gem", true)
	var glass := faceted(body, Vector3(-0.048, 0.315, 0.557), Vector3(0.072, 0.039, 0.014), Color("#a0d6df"), "plate")
	var glass_material := glass.material_override as StandardMaterial3D
	glass_material.roughness = 0.19
	glass_material.metallic_specular = 0.75
	for side in [-1.0, 1.0]:
		armor(body, Vector3(side * 0.36, 0.53, 0.02), Vector3(0.135, 0.075, 0.55), COPPER)
		armor(body, Vector3(side * 0.48, 0.22, -0.04), Vector3(0.20, 0.31, 0.38), DARK)
		for fin in 3:
			armor(body, Vector3(side * (0.47 + fin * 0.062), 0.22, -0.04), Vector3(0.036, 0.28, 0.32), COPPER if fin != 1 else STEEL)
		faceted(body, Vector3(side * 0.23, 0.025, -0.09), Vector3(0.17, 0.08, 0.20), BLUE, "plate", true)
		for height in [0.12, 0.44]:
			armor(body, Vector3(side * 0.245, height, 0.443), Vector3(0.061, 0.057, 0.05), STEEL)
	for i in 3:
		var pivot := Node3D.new()
		pivot.rotation.y = float(i) * TAU / 3.0
		rotor.add_child(pivot)
		armor(pivot, Vector3(0, 0, 0.46), Vector3(0.16, 0.087, 0.56), IRON)
		armor(pivot, Vector3(0, 0.026, 0.62), Vector3(0.23, 0.048, 0.36), STEEL)
		armor(pivot, Vector3(0, 0.035, 0.75), Vector3(0.217, 0.035, 0.09), COPPER)
	return lens


static func bat_face(body: Node3D) -> MeshInstance3D:
	armor(body, Vector3(0, 0.39, 0.23), Vector3(0.47, 0.26, 0.21), Color("#50374f"), 0.88, false)
	armor(body, Vector3(0, 0.31, 0.34), Vector3(0.31, 0.17, 0.13), Color("#2f213e"), 0.88, false)
	for side in [-1.0, 1.0]:
		var ear := armor(body, Vector3(side * 0.196, 0.59, 0.07), Vector3(0.188, 0.37, 0.18), Color("#5a415d"), 0.88, false)
		ear.rotation.z = -side * 0.31
		var ear_flesh := armor(body, Vector3(side * 0.216, 0.61, 0.163), Vector3(0.101, 0.242, 0.045), Color("#b86b8e"), 0.78, false)
		ear_flesh.rotation.z = ear.rotation.z
		var brow := armor(body, Vector3(side * 0.129, 0.43, 0.33), Vector3(0.172, 0.07, 0.07), Color("#3a2942"), 0.89, false)
		brow.rotation.z = side * 0.23
		faceted(body, Vector3(side * 0.122, 0.263, 0.383), Vector3(0.056, 0.127, 0.048), Color("#f4c3a8"))
		faceted(body, Vector3(side * 0.18, 0.108, 0.21), Vector3(0.065, 0.103, 0.19), Color("#876f7e"))
	return faceted(body, Vector3(0, 0.315, 0.414), Vector3(0.19, 0.11, 0.10), Color("#e7b1ff"), "gem", true)


static func gel_details(body: Node3D, dim: Vector3) -> MeshInstance3D:
	for edge in [-1.0, 1.0]:
		var bead := faceted(body, Vector3(edge * dim.x * 0.36, dim.y * 0.19, dim.z * 0.18), dim * Vector3(0.49, 0.39, 0.57), Color("#48694c"))
		var gel_material := bead.material_override as StandardMaterial3D
		gel_material.roughness = 0.31
		gel_material.metallic_specular = 0.58
		armor(body, Vector3(edge * dim.x * 0.33, dim.y * 0.60, dim.z * 0.27), dim * Vector3(0.16, 0.11, 0.17), Color("#9bb49a"), 0.29, false)
	armor(body, Vector3(0, dim.y * 0.25, dim.z * 0.45), dim * Vector3(0.41, 0.23, 0.11), Color("#324142"), 0.68, false)
	return faceted(body, Vector3(0, dim.y * 0.27, dim.z * 0.50), dim * Vector3(0.26, 0.18, 0.075), Color("#b9e46e"), "gem", true)


static func ironback_parts(row: Dictionary, body: Node3D) -> void:
	var granite := Color("#637c89")
	var shell := Color("#526978")
	var seam := Color("#b37849")
	var soot := Color("#383c43")
	var brass := Color("#c69159")
	var fists: Array[Node3D] = []
	var tips: Array[Node3D] = []
	var face := armor(body, Vector3(0, 1.06, 0.28), Vector3(0.72, 0.42, 0.59), granite)
	face.rotation.x = -0.25
	armor(body, Vector3(0, 0.96, 0.573), Vector3(0.55, 0.15, 0.072), soot)
	armor(body, Vector3(0, 0.93, 0.608), Vector3(0.16, 0.19, 0.115), seam)
	armor(body, Vector3(0, 0.55, 0.421), Vector3(0.60, 0.37, 0.17), soot)
	var furnace := faceted(body, Vector3(0, 0.55, 0.507), Vector3(0.43, 0.23, 0.11), Color("#e86531"), "plate", true)
	row["furnace"] = furnace
	for i in 5:
		var rib := armor(body, Vector3((i - 2) * 0.088, 0.55, 0.574), Vector3(0.072, 0.22, 0.053), brass)
		rib.rotation.z = (i - 2) * 0.18
		faceted(body, Vector3((i - 2) * 0.084, 0.54, 0.608), Vector3(0.031, 0.13, 0.019), Color("#ffc264"), "gem", true)
	var legs: Array[Node3D] = []
	for side in [-1.0, 1.0]:
		var visor := faceted(body, Vector3(side * 0.177, 0.98, 0.612), Vector3(0.155, 0.061, 0.033), Color("#ffc778"), "gem", true)
		visor.rotation.z = side * 0.26
		var brow := armor(body, Vector3(side * 0.248, 1.065, 0.604), Vector3(0.27, 0.085, 0.12), shell)
		brow.rotation.z = side * 0.30
		var cheek := armor(body, Vector3(side * 0.34, 0.86, 0.458), Vector3(0.20, 0.31, 0.27), shell)
		cheek.rotation.z = side * 0.51
		var boot := Node3D.new()
		boot.position = Vector3(side * 0.30, 0.11, 0.095)
		body.add_child(boot)
		faceted(boot, Vector3.UP * 0.12, Vector3(0.38, 0.39, 0.55), granite)
		armor(boot, Vector3.ZERO, Vector3(0.48, 0.20, 0.68), shell)
		for toe in 3:
			armor(boot, Vector3((toe - 1) * 0.129, -0.007, 0.325), Vector3(0.112, 0.118, 0.13), soot if toe == 1 else granite)
		legs.append(boot)
		var joint := Node3D.new()
		joint.position = Vector3(0.63 * side, 1.00, 0.034)
		body.add_child(joint)
		var guard := armor(joint, Vector3(side * 0.05, 0.04, -0.02), Vector3(0.59, 0.36, 0.70), granite)
		guard.rotation.z = side * 0.18
		armor(joint, Vector3(side * 0.14, 0.20, 0.005), Vector3(0.38, 0.115, 0.59), seam)
		armor(joint, Vector3(side * 0.09, -0.22, 0.072), Vector3(0.39, 0.47, 0.47), soot)
		armor(joint, Vector3(side * 0.17, -0.49, 0.22), Vector3(0.53, 0.40, 0.59), shell)
		var cuff := armor(joint, Vector3(side * 0.18, -0.37, 0.28), Vector3(0.50, 0.10, 0.50), seam)
		cuff.rotation.z = side * 0.11
		for j in 3:
			var dx: float = side * 0.17 + (j - 1) * 0.14
			armor(joint, Vector3(dx, -0.53, 0.508), Vector3(0.119, 0.20, 0.15), granite if j % 2 == 0 else soot)
			armor(joint, Vector3(dx, 0.06, 0.340), Vector3(0.052, 0.046, 0.026), brass)
		for chip in 3:
			var p := Vector3(side * (0.26 + chip * 0.035), -0.501 - chip * 0.014, 0.335 - chip * 0.064)
			armor(joint, p, Vector3(0.17, 0.028, 0.035), seam)
		fists.append(joint)
		var contact := Node3D.new()
		contact.position = Vector3(side * 0.18, -0.65, 0.50)
		joint.add_child(contact)
		tips.append(contact)
	for i in 3:
		for side in [-1.0, 1.0]:
			var at := Vector3(side * (0.29 + 0.041 * i), 0.69 + i * 0.17, -0.34 - (2 - i) * 0.07)
			var plate := armor(body, at, Vector3(0.55, 0.31, 0.49), shell if i == 1 else granite)
			plate.rotation.x = 0.40 - i * 0.13
			plate.rotation.z = side * (0.27 + i * 0.04)
			var cap := armor(body, at + Vector3(-side * 0.10, 0.13, -0.17), Vector3(0.25, 0.051, 0.14), seam)
			cap.rotation = plate.rotation
			for pin in 2:
				armor(body, at + Vector3(side * (0.17 + pin * 0.071), 0.109, -0.10 - pin * 0.079), Vector3(0.062, 0.06, 0.058), brass)
	row["boss_fists"] = fists
	row["fist_tips"] = tips
	row["boss_legs"] = legs
