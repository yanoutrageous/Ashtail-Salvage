extends RefCounted

const Layout := preload("res://scripts/gameplay/rooms/voxel_room_breakables.gd")
const STATE_KEY := "voxel_breakable_hp"


static func room_health(context: RunContext) -> Dictionary:
	var rooms: Dictionary = context.z1_event_flags.get(STATE_KEY, {})
	return rooms.get(context.cell_key(context.get_current_pos()), {})


static func breakable_hits(context: RunContext, fact: Dictionary, obstacles: Array) -> Dictionary:
	if not context.run_active or context.mode == &"tutorial":
		return {}
	var event_type := EventService.get_event_type(context, context.get_current_pos()) if context.current_room_type == &"Event" else &""
	var health := room_health(context)
	var impacted := {}
	for prop: Dictionary in Layout.for_room(context.current_room_type, event_type, context.cell_key(context.get_current_pos())):
		var id: String = prop["id"]
		var hp := int(health.get(id, prop["max_hp"]))
		if hp > 0 and _contact(fact, prop["rect"], obstacles):
			impacted[id] = maxi(0, hp - _damage(fact))
	return impacted


static func install_hits(context: RunContext, impacted: Dictionary) -> void:
	if impacted.is_empty():
		return
	var rooms: Dictionary = context.z1_event_flags.get(STATE_KEY, {})
	var room := room_health(context).duplicate()
	room.merge(impacted, true)
	rooms[context.cell_key(context.get_current_pos())] = room
	context.z1_event_flags[STATE_KEY] = rooms


static func _damage(fact: Dictionary) -> int:
	if not String(fact.get("skill_id", "")).is_empty():
		return 18
	return 12 if fact.get("weapon", &"axe") == &"axe" else 8


static func _contact(fact: Dictionary, rect: Rect2, obstacles: Array) -> bool:
	var origin := Vector2(fact.get("origin", Vector2.ZERO))
	if fact.get("shape", &"sector") == &"rays":
		for endpoint: Vector2 in fact.get("shot_endpoints", []):
			if _segment_hits_rect(origin, endpoint, rect):
				return true
		return false
	var direction := Vector2(fact.get("facing", Vector2.RIGHT)).normalized()
	var reach := float(fact.get("range", 0.0))
	var cone := float(fact.get("cone_dot", 1.0))
	var points := [origin.clamp(rect.position, rect.end), rect.get_center(), rect.position, rect.end,
		Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y)]
	for target: Vector2 in points:
		var offset := target - origin
		if offset.length_squared() > reach * reach or (offset.length_squared() > 0.000001 and direction.dot(offset.normalized()) < cone):
			continue
		if _clear_contact(origin, target, obstacles):
			return true
	return false


static func _clear_contact(origin: Vector2, target: Vector2, obstacles: Array) -> bool:
	for obstacle: Rect2 in obstacles:
		if _segment_hits_rect(origin, target, obstacle):
			return false
	return true


static func _segment_hits_rect(origin: Vector2, endpoint: Vector2, rect: Rect2) -> bool:
	if rect.has_point(origin) or rect.has_point(endpoint):
		return true
	var points := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	for side in 4:
		if Geometry2D.segment_intersects_segment(origin, endpoint, points[side], points[(side + 1) % 4]) != null:
			return true
	return false
