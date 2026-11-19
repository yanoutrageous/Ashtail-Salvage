extends SceneTree

const WorldProjection := preload("res://scripts/gameplay/runtime/g41_world_object_projection.gd")
const RoomView := preload("res://scripts/gameplay/runtime/g41_room_runtime_view.gd")
const Layout := preload("res://scripts/gameplay/runtime/g41_runtime_layout.gd")
const GRID_STEPS := 40
const CARDINALS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

var failures: Array[String] = []
var art_hashes: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var view := RoomView.new()
	root.add_child(view)
	var player := PlayerController.new()
	root.add_child(player)
	var event_types: Array[StringName] = [&"trader", &"dice", &"altar", &"trap"]
	for number in range(1, 26):
		event_types.append(StringName("z1_event_e%02d" % number))
	for event_type in event_types:
		_check_room(view, player, event_type)
	_check(art_hashes.size() == 78, "26 retained raster rooms must load 78 distinct textures; the three shared canonical event ids now use B GLB")
	_check_same_room_update(view)
	_check_unresolved_event(view)
	player.free()
	view.free()
	if failures.is_empty():
		print("Z1_EVENT_ROOM_PROJECTION=PASS rooms=29 raster_textures=78 glb_rooms=3 placement,collision,proximity,doors,loot,reprojection,legacy")
		quit(0)
	else:
		for failure in failures:
			print("Z1_EVENT_ROOM_PROJECTION_FAIL " + failure)
		quit(1)


func _check_room(view: G41RoomRuntimeView, player: PlayerController, event_type: StringName) -> void:
	var id := String(event_type).trim_prefix("z1_event_")
	var snapshot := _event_snapshot(event_type)
	var original := snapshot.duplicate(true)
	var projected := WorldProjection.build(snapshot)
	var room: Dictionary = projected.get("event_room", {})
	if room.has("model_path"):
		# These three canonical ids are no longer raster-backed. Exercise the
		# production path rather than asserting the retired PNG layers exist.
		_check(event_type in [&"trader", &"dice", &"altar"], "unexpected legacy id switched renderer")
		view.configure_room(snapshot)
		var renderer := view.get_node_or_null("BModelRoom")
		_check(renderer != null and bool(renderer.call("debug_snapshot").get("model_loaded", false)), "%s GLB failed to load" % id)
		_check(view.get_logical_obstacles() == WorldProjection.room_solid_rects(&"Event", event_type), "%s GLB solids disagree" % id)
		_check(bool(view.request_nearest_interaction(room.interaction_pos).get("accepted", false)), "%s GLB service is inaccessible" % id)
		_check(snapshot == original, "%s GLB mutated its input snapshot" % id)
		return
	_check(String(room.get("id", "")) == id, "%s lacks its public event room projection" % id)
	if room.is_empty():
		return

	var floor := _load_room_texture(String(room.get("floor_path", "")), id + " floor")
	var wall := _load_room_texture(String(room.get("wall_path", "")), id + " wall")
	var station_path := String(room.get("station_path", ""))
	var station_texture := _load_room_texture(station_path, id + " station")
	var size: Vector2 = room.get("station_size", Vector2.ZERO)
	if event_type == &"z1_event_e24" and not String(room.get("station_open_path", "")).is_empty():
		station_path = String(room["station_open_path"])
		station_texture = ResourceLoader.load(station_path, "Texture2D") as Texture2D
		size = room["station_open_size"]
	var plate := Rect2(Vector2.ZERO, Vector2.ONE)
	for key in ["floor_rect", "wall_rect"]:
		var rect: Rect2 = room.get(key, Rect2())
		_check(rect.has_area() and plate.encloses(rect), "%s has an invalid %s" % [id, key])

	var station := _object_of_kind(projected, &"event")
	var payload: Dictionary = station.get("payload", {})
	var anchor: Vector2 = room.get("station_anchor", Vector2.ZERO)
	var footprint: Rect2 = room.get("body_rect", Rect2())
	var interaction: Vector2 = room.get("interaction_pos", Vector2.ZERO)
	_check(String(station.get("visual_key", "")) == "z1.room.%s.station" % id, "%s uses the wrong station visual key" % id)
	_check(String(payload.get("event_room_id", "")) == id and payload.get("station_texture_path") == station_path, "%s station payload lost its room art binding" % id)
	_check(payload.has_all(["station_state", "last_result"]), "%s station lacks public state fields" % id)
	_check(station.get("ground_anchor_local") == anchor and station.get("display_size_local") == size and size.x > 0.0 and size.y > 0.0, "%s station lost its foot or display size" % id)
	_check(station.get("local_pos") == interaction and station.get("body_rect") == footprint and footprint.has_area() and footprint.grow(0.001).has_point(anchor), "%s station foot, interaction and solid footprint disagree" % id)

	view.configure_room(snapshot)
	_check_view_texture(view.get_node_or_null("EventRoomDecor/Floor"), floor, id + " floor")
	_check_view_texture(view.get_node_or_null("EventRoomDecor/Wall"), wall, id + " wall")
	var entity := view.special_entities.get(String(station.get("projection_id", ""))) as Node2D
	var sprite := entity.get_node_or_null("VisualRoot/ArtVisual") as Sprite2D if entity != null else null
	_check_view_texture(sprite, station_texture, id + " station")
	if sprite != null and sprite.texture != null:
		var sprite_rect: Rect2 = sprite.get_global_transform() * sprite.get_rect()
		var pivot: Vector2 = station.get("pivot_normalized", Vector2(0.5, 1.0))
		_check((sprite_rect.position + sprite_rect.size * pivot).is_equal_approx(Layout.local_to_world(anchor)), "%s station sprite does not stand at its projected foot" % id)
		_check(sprite_rect.size.is_equal_approx(Layout.local_size_to_world(size)), "%s station sprite does not use the projected size" % id)

	var solids := view.get_logical_obstacles()
	var projected_solids: Array = WorldProjection.new().call("room_solid_rects", &"Event", event_type)
	_check(solids == projected_solids and solids.has(footprint) and solids.size() == WorldProjection.ROOM_WALL_RECTS.size() + 1, "%s view and room collision do not share the station footprint and walls" % id)
	var clearance: Array[Rect2] = []
	for solid in solids:
		clearance.append(solid.grow(Layout.PLAYER_BODY_RADIUS - 0.0001))
	_check(_clear_point(interaction, clearance), "%s interaction position puts the player inside a solid" % id)
	var near := view.request_nearest_interaction(interaction)
	var far := Vector2(0.06 if interaction.x > 0.5 else 0.94, 0.5)
	_check(bool(near.get("accepted", false)) and near.get("interaction_kind") == &"event", "%s does not accept an interaction at its approach" % id)
	_check(not bool(view.request_nearest_interaction(far).get("accepted", false)), "%s can be interacted with from a distant door" % id)
	_check(snapshot == original, "%s presentation mutated its input snapshot" % id)
	player.set_logical_obstacles(solids)
	_check_navigation(player, view.get_door_projections(), clearance, id)
	_check_loot(snapshot, room, clearance, id)


func _check_navigation(player: PlayerController, doors: Array[Dictionary], clearance: Array[Rect2], id: String) -> void:
	var reached := _reachable_cells(Vector2(0.50, 0.06), clearance)
	_check(doors.size() == 4, "%s does not project all four doors" % id)
	player.set_door_projections(doors)
	for door in doors:
		var pos: Vector2 = door.get("local_pos", Vector2.ZERO)
		var direction: Vector2i = door.get("payload", {}).get("direction", Vector2i.ZERO)
		_check(door.get("visual_state") == &"available" and reached.has(_grid_cell(pos)), "%s has a blocked %s door approach" % [id, door.get("orientation")])
		_check(_clear_point(player.place_from_entry(-direction), clearance), "%s places the player inside a solid at its %s door" % [id, door.get("orientation")])
	player.reset_local_position()
	var return_pos := player.get_local_position()
	_check(_clear_point(return_pos, clearance) and reached.has(_grid_cell(return_pos)), "%s has no clear fast-return landing" % id)
	var aisle := WorldProjection.room_floor_interior().grow(-Layout.PLAYER_BODY_RADIUS - 0.025)
	for corner in [aisle.position, Vector2(aisle.end.x, aisle.position.y), aisle.end, Vector2(aisle.position.x, aisle.end.y)]:
		_check(reached.has(_grid_cell(corner)), "%s outer aisle is disconnected at %s" % [id, corner])


func _reachable_cells(origin: Vector2, clearance: Array[Rect2]) -> Dictionary:
	var first := _grid_cell(origin)
	if not _clear_point(_grid_position(first), clearance):
		return {}
	var reached := {first: true}
	var frontier: Array[Vector2i] = [first]
	var cursor := 0
	while cursor < frontier.size():
		var current := frontier[cursor]
		cursor += 1
		for direction: Vector2i in CARDINALS:
			var next := current + direction
			if next.x < 0 or next.y < 0 or next.x > GRID_STEPS or next.y > GRID_STEPS or reached.has(next):
				continue
			if _clear_point(_grid_position(next), clearance):
				reached[next] = true
				frontier.append(next)
	return reached


func _grid_cell(pos: Vector2) -> Vector2i:
	var span := 1.0 - 2.0 * Layout.PLAYER_BODY_RADIUS
	return Vector2i(((pos - Vector2.ONE * Layout.PLAYER_BODY_RADIUS) / span * GRID_STEPS).round())


func _grid_position(cell: Vector2i) -> Vector2:
	var span := 1.0 - 2.0 * Layout.PLAYER_BODY_RADIUS
	return Vector2.ONE * Layout.PLAYER_BODY_RADIUS + Vector2(cell) * (span / GRID_STEPS)


func _clear_point(pos: Vector2, clearance: Array[Rect2]) -> bool:
	if not Rect2(Vector2.ZERO, Vector2.ONE).has_point(pos):
		return false
	for rect in clearance:
		if rect.has_point(pos):
			return false
	return true


func _check_loot(snapshot: Dictionary, room: Dictionary, clearance: Array[Rect2], id: String) -> void:
	var loot_snapshot := snapshot.duplicate(true)
	var items: Array[Dictionary] = []
	for index in range(24):
		items.append({"instance_id": "fixture_loot_%02d" % index, "item_id": "col_01"})
	loot_snapshot["room_floor_items"] = items
	var projected := WorldProjection.build(loot_snapshot)
	var anchor: Vector2 = room.get("loot_anchor", Vector2(-1, -1))
	_check(_clear_point(anchor, clearance), "%s loot anchor overlaps player clearance" % id)
	var count := 0
	for object: Dictionary in projected.get("world_objects", []):
		if object.get("interaction_kind") != &"ground_loot":
			continue
		count += 1
		_check(_clear_point(Vector2(object.get("local_pos", Vector2(-1, -1))), clearance), "%s projects loot into a solid at %s" % [id, object.get("projection_id")])
	_check(count == items.size(), "%s omitted floor item projections" % id)


func _check_same_room_update(view: G41RoomRuntimeView) -> void:
	var pos := Vector2i(2, 2)
	var context := RunContext.new()
	context.start_run({
		"id": "z1_room_projection", "seed": 10, "width": 5, "height": 5,
		"manual_map": {"spawn": Vector2i(2, 1), "events": [pos]},
	})
	context.asset_ledger.add_currency(&"black_coin", 100, "test")
	var bus := CommandBus.new()
	bus.bind_context(context)
	bus.dispatch(&"move_by", {"delta": Vector2i.DOWN})
	var before := context.get_status_snapshot()
	_check(before.get("event_state", {}).get("event_type") == &"z1_event_e06", "same-room fixture did not reach E06")
	view.configure_room(before)
	var initial_projection: Dictionary = view.build_read_only_snapshot().get("world_projection", {})
	var initial := _object_of_kind(initial_projection, &"event")
	var id := String(initial.get("projection_id", ""))
	var entity := view.special_entities.get(id) as Node2D
	var action := bus.dispatch(&"select_event_option", {"option_id": &"force_open"})
	_check(bool(action.get("ok", false)), "same-room fixture did not open the E06 cabinet")
	var after := context.get_status_snapshot()
	var authority := after.duplicate(true)
	view.configure_room(after)
	var updated_projection: Dictionary = view.build_read_only_snapshot().get("world_projection", {})
	var updated := _object_of_kind(updated_projection, &"event")
	var initial_payload: Dictionary = initial.get("payload", {})
	var updated_payload: Dictionary = updated.get("payload", {})
	var event_room: Dictionary = updated_projection.get("event_room", {})
	var last_result: Dictionary = updated_payload.get("last_result", {})
	var published_result: Dictionary = after.get("event_state", {}).get("last_result", {})
	_check(not event_room.is_empty() and initial_projection.get("event_room", {}).get("station_path") == event_room.get("station_path"), "same-room update changed its station art")
	_check(entity != null and entity == view.special_entities.get(id) and updated.get("projection_id") == id, "same-room update did not reconfigure the existing station")
	_check(updated_payload.get("station_state") != initial_payload.get("station_state") and bool(updated_payload.get("display_only", false)), "opened E06 did not update station state")
	var open_path := String(event_room.get("station_open_path", ""))
	var sprite := entity.get_node_or_null("VisualRoot/ArtVisual") as Sprite2D if entity != null else null
	_check(not open_path.is_empty() and open_path != String(initial_payload.get("station_texture_path", "")) and updated_payload.get("station_texture_path") == open_path, "opened E06 did not switch to its cabinet art")
	_check(sprite != null and sprite.texture != null and sprite.texture.resource_path == open_path, "opened E06 cabinet art was not mounted")
	_check(initial.get("body_rect") == updated.get("body_rect") and initial.get("ground_anchor_local") == updated.get("ground_anchor_local"), "opening E06 shifted the collision or foot position")
	_check(not published_result.is_empty() and not last_result.is_empty() and last_result.get("message") == published_result.get("message"), "same-room update lost the authoritative event result")
	var repeated := view.request_nearest_interaction(Vector2(event_room.get("interaction_pos", Vector2.ZERO)))
	_check(repeated.get("interaction_kind") != &"event", "completed station accepted a repeat action")
	_check(after == authority and context.get_status_snapshot() == authority, "same-room view changed the run authority")


func _check_unresolved_event(view: G41RoomRuntimeView) -> void:
	for event_type in [&"", &"unknown_event_room"]:
		var snapshot := _event_snapshot(event_type)
		if event_type == &"":
			snapshot.erase("event_state")
		view.configure_room(snapshot)
		var projected: Dictionary = view.build_read_only_snapshot().get("world_projection", {})
		var event := _object_of_kind(projected, &"event")
		_check(projected.get("event_room", {}).is_empty() and String(event.get("visual_key", "")).begins_with("ui.art25.long_term.event."), "unresolved event did not retain the compatible event badge")
		var floor := view.get_node_or_null("EventRoomDecor/Floor") as CanvasItem
		_check(floor == null or not floor.is_visible_in_tree() or floor.get("texture") == null, "unresolved event retained the previous room decor")


func _event_snapshot(event_type: StringName) -> Dictionary:
	return {
		"position": Vector2i(2, 2), "width": 5, "height": 5, "current_room": &"Event",
		"event_state": {"event_type": event_type, "completed": false},
	}


func _object_of_kind(projected: Dictionary, kind: StringName) -> Dictionary:
	for object: Dictionary in projected.get("world_objects", []):
		if object.get("interaction_kind") == kind:
			return object
	return {}


func _load_room_texture(path: String, label: String) -> Texture2D:
	if not ResourceLoader.exists(path, "Texture2D"):
		_check(false, "%s texture is missing at %s" % [label, path])
		return null
	var texture := ResourceLoader.load(path, "Texture2D") as Texture2D
	_check(texture != null, "%s did not load as a texture" % label)
	var hash := FileAccess.get_sha256(path)
	_check(not hash.is_empty() and not art_hashes.has(hash), "%s reuses the same image as %s" % [label, art_hashes.get(hash, "<missing image>")])
	if not hash.is_empty():
		art_hashes[hash] = label
	return texture


func _check_view_texture(node: Node, texture: Texture2D, label: String) -> void:
	_check(node is CanvasItem and node.is_visible_in_tree() and texture != null and node.get("texture") == texture, "%s is not mounted on its world layer" % label)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
