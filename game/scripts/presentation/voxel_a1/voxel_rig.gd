extends Node3D
## Rigid Blender parts use rest-space transforms baked by the existing exporter.

const ASSETS := "res://assets/voxel_a1/"
const GEAR_FINISH := preload("res://scripts/presentation/voxel_a1/voxel_gear_finish.gdshader")
const EnemyArt := preload("res://scripts/presentation/voxel_a1/voxel_enemy_art.gd")
const AXIS := Basis(Vector3.RIGHT, -PI / 2.0)
const ACTOR_SCALE := 0.84
var axes: Node3D
var pieces: Array[Array] = []
var clips: Dictionary = {}
var blade: Array[Vector3] = []
var blade_heel := Vector3.ZERO
var hand_index := -1
var hair_phase := 0.0
var gait := 0.0
var gait_weight := 0.0
var jump_weight := 0.0
var hit_weight := 0.0
var pose_initialized := false
var upper_body: Dictionary = {}
var last_pose: Array[Transform3D] = []
var axe_parts: Array[MeshInstance3D] = []
var arms: Array[MeshInstance3D] = []
var firearm: Node3D
var rifle_front: Node3D
var scatter_front: Node3D
var gun_arms: Array[MeshInstance3D] = []
var muzzle: Node3D
var shell_port: Node3D
var current_weapon: StringName = &"axe"


func build(gameplay_finish := false) -> void:
	var model := (load(ASSETS + "raccoon.glb") as PackedScene).instantiate() as Node3D
	axes = Node3D.new()
	axes.basis = AXIS.scaled(Vector3.ONE * ACTOR_SCALE)
	add_child(axes)
	axes.add_child(model)
	var mapping: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ASSETS + "rig_bindings.json"))
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ASSETS + "motion.json"))
	var bones: Array = data["bones"]
	var finish_cache: Dictionary = {}
	hand_index = bones.find("Hand.R")
	for i in bones.size():
		pieces.append([])
		last_pose.append(Transform3D.IDENTITY)
		if String(bones[i]).begins_with("Arm.") or String(bones[i]).begins_with("Hand.") or String(bones[i]) in ["Chest", "Head"]:
			upper_body[i] = true
	for piece in model.find_children("Piece_*", "MeshInstance3D", true, false):
		var mesh := piece as MeshInstance3D
		if gameplay_finish:
			_finish_surfaces(mesh, finish_cache)
		var bone := bones.find(mapping[String(mesh.name)]["bone"])
		mesh.set_meta("rest", mesh.transform)
		pieces[bone].append(mesh)
		if String(mesh.name) in ["Piece_01", "Piece_03", "Piece_05", "Piece_06", "Piece_08", "Piece_11", "Piece_13", "Piece_15", "Piece_16"]:
			axe_parts.append(mesh)
		if String(mapping[String(mesh.name)]["bone"]) in ["Arm.L", "Arm.R", "Hand.L", "Hand.R"]:
			if mesh not in axe_parts:
				arms.append(mesh)
	clips["idle"] = [_decode_frame(data["idle"])]
	for key in ["walk", "run", "attack"]:
		var frames: Array = []
		for frame in data[key]:
			frames.append(_decode_frame(frame))
		clips[key] = frames
	for v in data["edge"]:
		blade.append(Vector3(float(v[0]), float(v[1]), float(v[2])))
	var heel: Array = data["heel"]
	blade_heel = Vector3(heel[0], heel[1], heel[2])


func _finish_surfaces(part: MeshInstance3D, cache: Dictionary) -> void:
	for surface in part.mesh.get_surface_count():
		var source := part.mesh.surface_get_material(surface) as StandardMaterial3D
		if source == null:
			continue
		if not cache.has(source):
			var label := source.resource_name
			var variety := -1
			var roughness := 0.86
			var metalness := 0.0
			if source.metallic >= 0.50:
				variety = 3
				roughness = 0.23 if "磨亮" in label else (0.34 if "刃面" in label else 0.38)
				metalness = 0.68 if "铜" in label else 0.58
			elif "皮革" in label or "靴手套" in label:
				variety = 1
				roughness = 0.59
			elif "橡木" in label or "木纹" in label:
				variety = 2
				roughness = 0.74
			elif "帽" in label or "围巾" in label or "外套" in label or "长裤" in label:
				variety = 0
				roughness = 0.86
			if variety >= 0:
				cache[source] = _gear_material(source.albedo_color, variety, roughness, metalness)
			else:
				cache[source] = source
		if cache[source] != source:
			part.set_surface_override_material(surface, cache[source])


func _gear_material(tint: Color, finish: int, roughness: float, metalness: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GEAR_FINISH
	material.set_shader_parameter("base_tone", tint)
	material.set_shader_parameter("finish", finish)
	material.set_shader_parameter("base_roughness", roughness)
	material.set_shader_parameter("metalness", metalness)
	return material


func animate(delta: float, ground_speed: float, running: float, attack: float, weapon: StringName = &"axe", reload: float = 0.0, airborne: float = 0.0, variation: int = 0, state: StringName = &"idle") -> void:
	if clips.is_empty():
		return
	var moving := smoothstep(0.045, 1.6, ground_speed)
	gait_weight = lerpf(gait_weight, moving, 1.0 - exp(-delta * (12.0 if moving > gait_weight else 9.0)))
	jump_weight = lerpf(jump_weight, smoothstep(0.04, 0.42, airborne), 1.0 - exp(-delta * 21.0))
	hit_weight = move_toward(hit_weight, 1.0 if state == &"hurt" else 0.0, delta * (17.0 if state == &"hurt" else 7.5))
	hair_phase += delta
	gait = fposmod(gait + delta * ground_speed / lerpf(2.6, 2.23, running), 1.0)
	var walk: Array = clips["walk"]
	var run: Array = clips["run"]
	var idle: Array = clips["idle"][0]
	var swing: Array = clips["attack"]
	var aiming := weapon != &"axe"
	var weight_shift := 0.0
	var yaw := 0.0
	var side := 0.0
	var load_up := 0.0
	if attack >= 0.0 and not aiming:
		load_up = sin(clampf(attack / 0.48, 0.0, 1.0) * PI)
		var finish := sin(clampf((attack - 0.31) / 0.69, 0.0, 1.0) * PI)
		weight_shift = -0.09 * load_up + [0.48, 0.38, 0.59][variation] * finish
		yaw = deg_to_rad([-13.0, 14.0, -21.0][variation] * load_up + [19.0, -17.0, 27.0][variation] * finish)
		side = [-0.08, 0.13, -0.11][variation] * finish
	axes.basis = (Basis(Vector3.UP, yaw) * AXIS).scaled(Vector3.ONE * ACTOR_SCALE)
	axes.position = Vector3(side - hit_weight * 0.051, 0.0, weight_shift - hit_weight * 0.12)
	for i in pieces.size():
		var pose: Transform3D
		if attack >= 0.0 and not aiming:
			var spline := clampf(attack + [-0.025, 0.055, -0.066][variation] * sin(PI * attack), 0.0, 1.0)
			pose = _sample(swing, spline, i)
			if upper_body.has(i):
				pose.origin.z -= load_up * [0.10, 0.07, 0.18][variation]
				pose.origin.z += sin(clampf((attack - 0.31) / 0.45, 0.0, 1.0) * PI) * [0.05, 0.14, -0.015][variation]
			if attack > 0.73:
				pose = pose.interpolate_with(idle[i], smoothstep(0.73, 1.0, attack) * 0.85)
		else:
			var cycle := _sample(walk, gait, i).interpolate_with(_sample(run, gait, i), running)
			pose = (idle[i] as Transform3D).interpolate_with(cycle, gait_weight)
			# Borrow the authored split-leg silhouettes, then tuck toward
			# the apex. Keep foot placement independent of the ground gait.
			var flight_pose := _sample(run, lerpf(0.17, 0.30, airborne), i)
			pose = pose.interpolate_with(flight_pose, jump_weight * 0.88)
			if upper_body.has(i):
				pose.origin.z += sin(hair_phase * 3.2) * (1.0 - gait_weight) * 0.024
				pose.origin.y += hit_weight * 0.12
		if pose_initialized:
			pose = last_pose[i].interpolate_with(pose, 1.0 - exp(-delta * (51.0 if attack >= 0.0 else 28.0)))
		last_pose[i] = pose
		for part in pieces[i]:
			part.transform = pose * (part.get_meta("rest") as Transform3D)
	pose_initialized = true
	if current_weapon != weapon:
		current_weapon = weapon
		if aiming and firearm == null:
			_build_firearm()
		for part in axe_parts + arms:
			part.visible = not aiming
		for part in gun_arms:
			part.visible = aiming
	if firearm != null:
		firearm.visible = aiming
		if aiming:
			_pose_firearm(weapon, attack, reload, ground_speed)


func _build_firearm() -> void:
	firearm = Node3D.new()
	add_child(firearm)
	var metal := Color("#586468")
	var barrel := Color("#303940")
	var grip := Color("#694a35")
	var brass := Color("#b08b54")
	_gun_box(firearm, Vector3(0, 0, 0.23), Vector3(0.19, 0.20, 0.48), metal, 3, true)
	_gun_box(firearm, Vector3(-0.096, 0.037, 0.31), Vector3(0.022, 0.047, 0.228), Color("#85969a"), 3)
	_gun_box(firearm, Vector3(0.095, 0.062, 0.49), Vector3(0.035, 0.043, 0.05), brass, 3)
	_gun_box(firearm, Vector3(0, -0.036, -0.08), Vector3(0.15, 0.19, 0.28), grip, 2)
	_gun_box(firearm, Vector3(0, -0.16, 0.13), Vector3(0.13, 0.20, 0.17), barrel)
	_gun_box(firearm, Vector3(0.10, 0.025, 0.28), Vector3(0.035, 0.07, 0.17), brass, 3)
	_gun_box(firearm, Vector3(0, 0.13, 0.29), Vector3(0.08, 0.063, 0.08), barrel)
	rifle_front = Node3D.new()
	firearm.add_child(rifle_front)
	_gun_box(rifle_front, Vector3(0, -0.02, 0.56), Vector3(0.155, 0.15, 0.26), grip, 2)
	_gun_box(rifle_front, Vector3(0, 0.025, 0.75), Vector3(0.10, 0.105, 0.38), barrel, 3)
	_gun_box(rifle_front, Vector3(0, 0.025, 0.94), Vector3(0.15, 0.145, 0.11), metal, 3, true)
	_gun_box(rifle_front, Vector3(0, 0.025, 0.992), Vector3(0.061, 0.067, 0.009), Color("#131a21"))
	scatter_front = Node3D.new()
	firearm.add_child(scatter_front)
	_gun_box(scatter_front, Vector3(0, -0.04, 0.61), Vector3(0.25, 0.16, 0.35), grip, 2)
	for x in [-0.065, 0.065]:
		_gun_box(scatter_front, Vector3(x, 0.045, 0.70), Vector3(0.10, 0.105, 0.49), barrel, 3)
		_gun_box(scatter_front, Vector3(x, 0.045, 0.993), Vector3(0.070, 0.077, 0.010), Color("#171c20"))
	_gun_box(scatter_front, Vector3(0, 0.045, 0.93), Vector3(0.26, 0.17, 0.12), metal, 3, true)
	muzzle = Node3D.new()
	muzzle.position = Vector3(0, 0.04, 0.99)
	firearm.add_child(muzzle)
	shell_port = Node3D.new()
	shell_port.position = Vector3(0.12, 0.06, 0.28)
	firearm.add_child(shell_port)
	for side in 2:
		gun_arms.append(_gun_box(self, Vector3.ZERO, Vector3(0.17, 0.17, 1), Color("#4b5634"), 0))
		gun_arms.append(_gun_box(self, Vector3.ZERO, Vector3(0.15, 0.15, 0.15), Color("#392c25"), 1))


func _pose_firearm(weapon: StringName, attack: float, reload: float, speed: float) -> void:
	rifle_front.visible = weapon == &"rifle"
	scatter_front.visible = weapon == &"scattergun"
	var recoil := 0.0
	if attack >= 0.40:
		recoil = (1.0 - smoothstep(0.43, 0.92, attack)) * (0.17 if rifle_front.visible else 0.28)
	var reload_tilt := sin(clampf(reload / (0.88 if rifle_front.visible else 1.21), 0.0, 1.0) * PI)
	var carry := 0.22 if attack < 0.0 else 0.065
	firearm.position = Vector3(-0.23, 0.73 + sin(gait * TAU) * minf(speed * 0.006, 0.04), 0.22 - recoil)
	firearm.rotation = Vector3(carry - recoil * 1.42 + reload_tilt * 0.65, -reload_tilt * 0.39, reload_tilt * 0.27)
	for side in 2:
		var shoulder := Vector3(0.39 if side == 0 else -0.39, 0.79, 0.015)
		var grip := firearm.transform * (Vector3(0.07, -0.068, 0.49) if side == 0 else Vector3(-0.005, -0.16, 0.11))
		var upper := gun_arms[side * 2]
		upper.position = shoulder.lerp(grip, 0.50)
		upper.look_at(to_global(grip), Vector3.UP)
		upper.scale.z = shoulder.distance_to(grip) + 0.08
		gun_arms[side * 2 + 1].position = grip


func _gun_box(parent: Node3D, p: Vector3, size: Vector3, tint: Color, finish := -1, beveled := false) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	if beveled:
		part.mesh = EnemyArt.voxel_mass("armor")
		part.scale = size
	else:
		var box := BoxMesh.new()
		box.size = size
		part.mesh = box
	if finish >= 0:
		var roughness: float = [0.86, 0.59, 0.77, 0.35][finish]
		part.material_override = _gear_material(tint, finish, roughness, 0.63 if finish == 3 else 0.0)
	else:
		var material := StandardMaterial3D.new()
		material.albedo_color = tint
		material.roughness = 0.78
		part.material_override = material
	part.position = p
	parent.add_child(part)
	return part


func blade_points() -> PackedVector3Array:
	var result := PackedVector3Array()
	var hand := axes.global_transform * last_pose[hand_index]
	for v in blade:
		result.append(hand * v)
	result.append(hand * blade_heel)
	return result


func _sample(frames: Array, phase: float, bone: int) -> Transform3D:
	var fi := clampf(phase, 0.0, 1.0) * float(frames.size() - 1)
	var i := int(fi)
	return (frames[i][bone] as Transform3D).interpolate_with(frames[mini(i + 1, frames.size() - 1)][bone], fi - float(i))


func _decode_frame(frame: Array) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	for v in frame:
		result.append(Transform3D(
			Basis(Vector3(v[0], v[4], v[8]), Vector3(v[1], v[5], v[9]), Vector3(v[2], v[6], v[10])).orthonormalized(),
			Vector3(v[3], v[7], v[11])
		))
	return result
