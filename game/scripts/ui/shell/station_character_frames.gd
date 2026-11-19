extends RefCounted
## UI renders of the game's voxel rig, indexed by the existing portrait clips.

const FRONT_ATLAS := preload("res://assets/ui/station/graytail_voxel_front.png")
const DEPLOY_ATLAS := preload("res://assets/ui/station/graytail_voxel_deploy.png")
const FRONT_IDLE_ATLAS := preload("res://assets/ui/station/graytail_voxel_idle_front.png")
const DEPLOY_IDLE_ATLAS := preload("res://assets/ui/station/graytail_voxel_idle_deploy.png")
const KEY_PREFIX := "main_menu.scene.character."
const CELL := Vector2i(384, 448)
const COLUMNS := 4
const CLIP_START := {&"idle": 0, &"focus": 7, &"walk_dungeon": 10}
const IDLE_FRAME_COUNT := 28
const REST := [21, 22, 23, 24, 25, 26, 27]
const SCAN := [0, 1, 2, 3, 4, 5, 6]
const NOD := [7, 8, 9, 10, 11, 12, 13]
const CHECK_GLOVE := [14, 15, 16, 17, 18, 19, 20]
const IDLE_TIMELINE := [
	{"clip": REST, "seconds": 2.8},
	{"clip": SCAN, "seconds": 1.26},
	{"clip": REST, "seconds": 2.8},
	{"clip": NOD, "seconds": 0.98},
	{"clip": REST, "seconds": 2.8},
	{"clip": CHECK_GLOVE, "seconds": 1.4},
	{"clip": REST, "seconds": 2.8},
]
const IDLE_CYCLE_SECONDS := 14.84


static func lobby_frames(is_front: bool) -> Array[Texture2D]:
	var atlas := FRONT_IDLE_ATLAS if is_front else DEPLOY_IDLE_ATLAS
	var result: Array[Texture2D] = []
	for index in range(IDLE_FRAME_COUNT):
		result.append(_atlas_region(atlas, index))
	return result


static func lobby_frame_index(elapsed: float) -> int:
	var time := fposmod(elapsed, IDLE_CYCLE_SECONDS)
	for beat: Dictionary in IDLE_TIMELINE:
		var seconds := float(beat["seconds"])
		if time < seconds:
			var frames: Array = beat["clip"]
			return frames[mini(int(time / seconds * frames.size()), frames.size() - 1)]
		time -= seconds
	return int(REST[0])


static func front_frame(visual_key: StringName) -> Texture2D:
	return _frame(FRONT_ATLAS, visual_key)


static func deploy_frame(visual_key: StringName) -> Texture2D:
	return _frame(DEPLOY_ATLAS, visual_key)


static func _frame(atlas: Texture2D, visual_key: StringName) -> Texture2D:
	var key := String(visual_key)
	if not key.begins_with(KEY_PREFIX):
		return null
	var clip := key.substr(KEY_PREFIX.length()).split(".")
	if clip.size() != 2 or not clip[1].is_valid_int() or not CLIP_START.has(StringName(clip[0])):
		return null
	# Focus keys start at 01, immediately after the eight idle frames.
	var index := int(CLIP_START[StringName(clip[0])]) + clip[1].to_int()
	return _atlas_region(atlas, index)


static func _atlas_region(atlas: Texture2D, index: int) -> Texture2D:
	@warning_ignore("integer_division")
	var offset := Vector2i(index % COLUMNS, index / COLUMNS) * CELL
	if index < 0 or offset.y + CELL.y > atlas.get_height():
		return null
	var frame := AtlasTexture.new()
	frame.atlas = atlas
	frame.region = Rect2(Vector2(offset), Vector2(CELL))
	frame.filter_clip = true
	frame.resource_name = "%s_%02d" % [atlas.resource_path.get_file().get_basename(), index]
	return frame


static func floor_shadow() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([Color("#080d14"), Color("#080d1400")])
	var shadow := GradientTexture2D.new()
	shadow.gradient = gradient
	shadow.fill = GradientTexture2D.FILL_RADIAL
	shadow.fill_from = Vector2(0.5, 0.5)
	shadow.fill_to = Vector2(1.0, 0.5)
	return shadow
