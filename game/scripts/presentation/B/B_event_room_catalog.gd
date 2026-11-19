extends RefCounted

const INDEX := "res://data/assets/B_event_rooms.json"
static var _entries: Dictionary = {}
static var _loaded := false

static func room(event_type: StringName) -> Dictionary:
	if not _loaded:
		_loaded = true
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX))
		if data is Dictionary:
			_entries = data.get("rooms", {})
	if not _entries.has(String(event_type)):
		return {}
	var entry: Dictionary = _entries[String(event_type)].duplicate(true)
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
	payload["event_room_id"] = entry.id
	payload["B_model_path"] = entry.model_path
	payload["station_state"] = &"complete" if bool(state.get("completed", false)) else &"ready"
	payload["station_markers"] = {"completed": bool(state.get("completed", false))}
	projection.local_pos = entry.interaction_pos
	projection.ground_anchor_local = entry.station_anchor
	projection.body_rect = entry.body_rect
	projection.context_anchor_local = entry.interaction_pos + Vector2(0.0, -0.10)
	projection.display_size_local = entry.station_size
	projection.pivot_normalized = entry.station_pivot
	projection.visual_key = StringName("B.room.%s" % entry.code)
	return projection
