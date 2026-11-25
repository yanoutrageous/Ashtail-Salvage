extends RefCounted
class_name Z1EventRoomCatalog

const INDEX_PATH := "res://data/assets/z1_event_room_art_manifest.json"
const SHELL_PATH := "res://assets/z1/event_rooms/shell.png"
const SHELL_ASSET_ID := &"z1.room.shell"

static var _loaded := false
static var _rooms: Dictionary = {}


static func event_type_from_snapshot(snapshot: Dictionary, voxel := false) -> StringName:
	var state: Dictionary = snapshot.get("event_state", {})
	var encounter: Dictionary = snapshot.get("encounter_view_model", {})
	return StringName(state.get("event_type", encounter.get("encounter_type", &"")))


static func from_snapshot(snapshot: Dictionary, voxel := false) -> Dictionary:
	if StringName(snapshot.get("current_room", &"Unknown")) != &"Event":
		return {}
	return room(event_type_from_snapshot(snapshot), voxel)


static func room(event_type: StringName, voxel := false) -> Dictionary:
	var number := Z1EventCatalog.number(event_type)
	if voxel and number > 0:
		return preload("res://scripts/presentation/B/B_event_room_catalog.gd").numbered_room(number)
	var b_room := preload("res://scripts/presentation/B/B_event_room_catalog.gd").room(event_type)
	if not b_room.is_empty():
		return b_room
	if not _loaded:
		_load_rooms()
	return (_rooms.get(event_type, {}) as Dictionary).duplicate(true)


static func _load_rooms() -> void:
	_loaded = true
	if not FileAccess.file_exists(INDEX_PATH) or not ResourceLoader.exists(SHELL_PATH):
		return
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX_PATH))
	if not manifest is Dictionary:
		return
	var entries: Dictionary = manifest.get("rooms", {})
	for event_type in entries:
		var entry: Dictionary = entries[event_type]
		if not ResourceLoader.exists(String(entry["floor_path"])) or not ResourceLoader.exists(String(entry["wall_path"])) or not ResourceLoader.exists(String(entry["station_path"])):
			continue
		var converted := entry.duplicate(true)
		for key in ["floor_rect", "wall_rect", "body_rect"]:
			var value: Array = entry[key]
			converted[key] = Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
		for key in ["station_anchor", "station_size", "station_pivot", "interaction_pos", "loot_anchor", "station_open_size", "station_open_pivot"]:
			if entry.has(key):
				var value: Array = entry[key]
				converted[key] = Vector2(float(value[0]), float(value[1]))
		var body: Rect2 = converted.body_rect
		var offset := Vector2(0.50, 0.50) - body.get_center()
		converted.body_rect = Rect2(body.position + offset, body.size)
		for key in ["station_anchor", "interaction_pos", "loot_anchor"]:
			converted[key] += offset
		_rooms[StringName(event_type)] = converted
