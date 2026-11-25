extends RefCounted

const INDEX := "res://data/assets/B_event_rooms.json"
static var _entries: Dictionary = {}
static var _loaded := false

# Numbered rules use their matching team-built station, or a dedicated voxel scene.
const TEAM_STATIONS := {
	3: &"savings", 4: &"information", 5: &"seal", 10: &"first_aid", 11: &"consign",
	12: &"expand", 13: &"compress", 14: &"recycle", 15: &"pawn", 16: &"shortcut",
	18: &"coil", 19: &"demine", 20: &"clock_in", 21: &"recon", 22: &"rps",
	23: &"relief", 24: &"cage", 25: &"shop",
}
# Width and depth in model metres, measured at each plinth.
const DEDICATED_STATIONS := {
	1: ["E01_NoticeBoard", Vector2(2.55, 1.06)], 2: ["E02_PartsHopper", Vector2(3.04, 1.65)],
	6: ["E06_FuseCabinet", Vector2(2.31, 1.46)], 7: ["E07_SampleStand", Vector2(2.44, 1.63)],
	8: ["E08_ReceiptScale", Vector2(3.0, 1.52)], 9: ["E09_Damper", Vector2(2.90, 1.62)],
	17: ["E17_Wayfinder", Vector2(1.79, 1.56)],
}


static func numbered_room(number: int) -> Dictionary:
	var id := "e%02d" % number
	var entry: Dictionary
	if TEAM_STATIONS.has(number):
		entry = room(TEAM_STATIONS[number])
		if entry.is_empty():
			return {}
	elif DEDICATED_STATIONS.has(number):
		var spec: Array = DEDICATED_STATIONS[number]
		var size := Vector2(spec[1]) / Vector2(19.3, 14.77)
		var body := Rect2(Vector2(0.5, 0.5) - size * 0.5, size)
		var foot := Vector2(0.5, body.end.y)
		entry = {"id": id, "code": id.to_upper(), "room_type": &"Event",
			"model_path": "res://assets/B_event_rooms/devices/%s.tscn" % spec[0],
			"body_rect": body, "solids": [body], "station_anchor": foot,
			"station_size": size + Vector2(0.0, 0.12), "station_pivot": Vector2(0.5, 1),
			"interaction_pos": foot + Vector2(0, 0.084), "loot_anchor": Vector2(0.5, 0.76),
			"units": [{"id": "main_station", "ground_y": foot.y}]}
	else:
		return {}
	entry["numbered_id"] = id
	entry["geometry_key"] = "voxel_device/" + id
	return entry


static func room(event_type: StringName) -> Dictionary:
	if not _loaded:
		_loaded = true
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX))
		if data is Dictionary:
			_entries = data.get("rooms", {})
	if not _entries.has(String(event_type)):
		return {}
	var entry: Dictionary = _entries[String(event_type)].duplicate(true)
	entry["room_type"] = &"Event"
	if not ResourceLoader.exists(String(entry.model_path)):
		return {}
	for key in ["body_rect"]:
		var a: Array = entry[key]
		entry[key] = Rect2(a[0], a[1], a[2], a[3])
	for key in ["interaction_pos", "station_anchor", "loot_anchor"]:
		var a: Array = entry[key]
		entry[key] = Vector2(a[0], a[1])
	var solids: Array[Rect2] = []
	for a: Array in entry.solids:
		solids.append(Rect2(a[0], a[1], a[2], a[3]))
	entry.solids = solids
	entry["station_size"] = Vector2(entry.body_rect.size.x, entry.body_rect.size.y + 0.12)
	entry["station_pivot"] = Vector2(0.5, 1.0)
	return entry

static func project(snapshot: Dictionary, projection: Dictionary, entry: Dictionary) -> Dictionary:
	var payload: Dictionary = projection.payload
	var state: Dictionary = snapshot.get("event_state", {})
	payload["event_room_id"] = entry.get("numbered_id", entry.id)
	payload["B_model_path"] = entry.model_path
	payload["station_state"] = &"complete" if bool(state.get("completed", false)) else &"ready"
	payload["station_markers"] = {"completed": bool(state.get("completed", false))}
	if entry.has("numbered_id"):
		var event_type := StringName(payload.event_type)
		var device := Z1EventRoomState.describe(event_type, state, snapshot.get("position", Vector2i.ZERO))
		payload.station_state = device.state_id
		payload.station_markers = device.markers
		payload["station_stock"] = device.get("stock", [])
		projection.enabled = not bool(device.markers.get("cage_locked", false))
	projection.local_pos = entry.interaction_pos
	projection.ground_anchor_local = entry.station_anchor
	projection.body_rect = entry.body_rect
	projection.context_anchor_local = entry.interaction_pos + Vector2(0.0, -0.10)
	projection.display_size_local = entry.station_size
	projection.pivot_normalized = entry.station_pivot
	projection.visual_key = StringName("B.room.%s" % entry.code)
	return projection
